package Plugins::BlissLibrary::MixerClient;
use strict;
use warnings;
use File::Spec;
use Config ();
use File::Temp ();
use Time::HiRes ();
use Plugins::BlissLibrary::CandidateInventory;
use Plugins::BlissLibrary::JsonCodec;
use Plugins::BlissLibrary::SourceIdentity;
use Plugins::BlissLibrary::Worker;

sub start {
    my ($class, %args) = @_;
    die 'Host freshness callback is required' unless ref($args{is_current}) eq 'CODE';
    die 'Clock must be a callback' if exists($args{clock}) && ref($args{clock}) ne 'CODE';
    die 'Worker command must be an argument array' unless ref($args{command}) eq 'ARRAY' && @{$args{command}} >= 2;
    die 'Worker request is required' unless ref($args{request}) eq 'HASH';
    die 'Worker directory is unavailable' unless defined($args{work_dir}) && -d $args{work_dir};
    my $json = Plugins::BlissLibrary::JsonCodec::canonical();
    my $request = $json->decode($json->encode($args{request}));
    Plugins::BlissLibrary::CandidateInventory::_scope($request->{scope});
    die 'Cache directory is unavailable' unless defined($request->{cache_dir}) && -d $request->{cache_dir};
    Plugins::BlissLibrary::SourceIdentity::media_roots_fingerprint($request->{media_roots});
    die 'Scan generation is required' unless defined($request->{scan_generation}) && !ref($request->{scan_generation}) && length($request->{scan_generation});
    $request->{output_kind} = 'mixer-descriptor-v1';
    my $directory = File::Temp->newdir('bliss-mixer-worker-XXXXXXXX', DIR => $args{work_dir}, CLEANUP => 1);
    my $request_path = File::Spec->catfile("$directory", 'request.json');
    open my $fh, '>:raw', $request_path or die "Cannot write worker request: $!";
    print {$fh} $json->encode($request) or die "Cannot write worker request: $!";
    close $fh or die "Cannot close worker request: $!";
    my $self = bless {directory => $directory, request => $request, request_path => $request_path,
        command => [@{$args{command}}], attempt => 0, is_current => $args{is_current},
        clock => $args{clock} || sub { Time::HiRes::time() }}, $class;
    $self->_spawn;
    return $self;
}

sub _spawn {
    my ($self) = @_;
    my $attempt = ++$self->{attempt};
    $self->{stdout} = File::Spec->catfile("$self->{directory}", "result-$attempt.json");
    my $stderr = File::Spec->catfile("$self->{directory}", "error-$attempt.log");
    $self->{stderr} = $stderr;
    my $separator = $Config::Config{path_sep};
    my @existing = split /\Q$separator\E/, ($ENV{PERL5LIB} || '');
    local $ENV{PERL5LIB} = join($separator, grep { defined($_) && !ref($_) && -d $_ } (@existing, @INC));
    $self->{worker} = Plugins::BlissLibrary::Worker->start(command => [@{$self->{command}}, $self->{request_path}],
        stdout_path => $self->{stdout}, stderr_path => $stderr);
}

sub poll {
    my ($self) = @_;
    return $self->{terminal} if $self->{terminal};
    if (defined $self->{retry_at}) {
        return {state => 'running', waiting => 1} if $self->{clock}->() < $self->{retry_at};
        delete $self->{retry_at};
        my $ok = eval { $self->_spawn; 1 };
        return $self->{terminal} = {state => 'failed', error => $@ || 'Could not restart worker'} unless $ok;
    }
    my $status = $self->{worker}->poll;
    return $status if $status->{state} eq 'running' || $status->{state} eq 'cancelling';
    if ($status->{state} eq 'failed' && defined($status->{exit_code}) && $status->{exit_code} == 75
        && defined($status->{exit_signal}) && $status->{exit_signal} == 0) {
        return $self->{terminal} = {state => 'failed', error => 'Inventory build lock contention exceeded the retry limit'} if $self->{attempt} > 30;
        my $delay = 2;
        for (2 .. $self->{attempt}) { $delay *= 2; last if $delay >= 30 }
        $delay = 30 if $delay > 30;
        $self->{retry_at} = $self->{clock}->() + $delay;
        delete $self->{worker};
        return {state => 'running', waiting => 1};
    }
    if ($status->{state} eq 'failed') {
        if (open my $fh, '<:raw', $self->{stderr}) {
            my $message = '';
            read($fh, $message, 4096);
            close $fh;
            $message =~ s/\s+\z//;
            $status->{error} = $message if length $message;
        }
    }
    return $self->{terminal} = $status unless $status->{state} eq 'completed';
    my $result = eval {
        die 'Worker descriptor is missing or too large' unless -f $self->{stdout} && -s $self->{stdout} <= 65536;
        open my $fh, '<:raw', $self->{stdout} or die "Cannot read worker descriptor: $!";
        my $bytes = do { local $/; <$fh> };
        close $fh or die "Cannot close worker descriptor: $!";
        my $json = Plugins::BlissLibrary::JsonCodec::canonical();
        my $value = $json->decode($bytes);
        die 'Invalid worker descriptor' unless ref($value) eq 'HASH'
            && ($value->{schema} || '') eq 'bliss-library-mixer-descriptor-v1';
        my $scope = Plugins::BlissLibrary::CandidateInventory::_scope($value->{scope});
        die 'Worker returned the wrong library scope' unless $json->encode($scope) eq
            $json->encode(Plugins::BlissLibrary::CandidateInventory::_scope($self->{request}->{scope}));
        my $source = Plugins::BlissLibrary::CandidateInventory::_source($value->{source});
        die 'Worker returned the wrong source context' unless $source->{scan_generation} eq "$self->{request}->{scan_generation}"
            && $source->{media_roots} eq Plugins::BlissLibrary::SourceIdentity::media_roots_fingerprint($self->{request}->{media_roots});
        my $artifact = $value->{mixer_artifact};
        die 'Worker returned an invalid mixer artifact' unless ref($artifact) eq 'HASH'
            && defined($artifact->{sha256}) && $artifact->{sha256} =~ /\A[0-9a-f]{64}\z/
            && defined($artifact->{path}) && !ref($artifact->{path});
        my $expected = File::Spec->rel2abs(File::Spec->catfile($self->{request}->{cache_dir}, 'mixer-files-' . $artifact->{sha256} . '.json'));
        die 'Worker returned an unsafe mixer artifact path' unless File::Spec->rel2abs($artifact->{path}) eq $expected
            && -f $artifact->{path} && -r $artifact->{path} && !-l $artifact->{path};
        die 'Library state changed while preparing the mixer' unless $self->{is_current}->($value);
        {state => 'completed', artifact => {path => $artifact->{path}, sha256 => $artifact->{sha256}}, source => $source};
    };
    return $self->{terminal} = $result || {state => 'failed', error => $@ || 'Invalid worker descriptor'};
}

sub cancel {
    my ($self) = @_;
    return if $self->{terminal};
    if (defined $self->{retry_at}) {
        delete $self->{retry_at};
        $self->{terminal} = {state => 'cancelled'};
        return 1;
    }
    return $self->{worker}->cancel;
}
1;
