package Plugins::BlissLibrary::Coordinator;
use strict;
use warnings;
use Plugins::BlissLibrary::JsonCodec;
use Time::HiRes ();
use Plugins::BlissLibrary::CandidateInventory;

sub new {
    my ($class, %args) = @_;
    die 'Worker spawn and collect callbacks are required'
        unless ref($args{spawn}) eq 'CODE' && ref($args{collect}) eq 'CODE';
    my $limit = defined($args{max_workers}) ? $args{max_workers} : 1;
    die 'Worker limit must be a positive integer' unless !ref($limit) && "$limit" =~ /\A[1-9][0-9]*\z/;
    die 'Callback error handler must be a callback' if exists($args{on_callback_error}) && ref($args{on_callback_error}) ne 'CODE';
    die 'Clock must be a callback' if exists($args{clock}) && ref($args{clock}) ne 'CODE';
    my $delay = defined($args{retry_delay}) ? $args{retry_delay} : 2;
    my $retries = defined($args{max_busy_retries}) ? $args{max_busy_retries} : 30;
    die 'Retry delay must be a positive integer' unless !ref($delay) && "$delay" =~ /\A[1-9][0-9]*\z/;
    die 'Retry limit must be a nonnegative integer' unless !ref($retries) && "$retries" =~ /\A(?:0|[1-9][0-9]*)\z/;
    return bless {spawn => $args{spawn}, collect => $args{collect}, on_callback_error => $args{on_callback_error},
        clock => $args{clock} || sub { Time::HiRes::time() }, retry_delay => $delay, max_busy_retries => $retries,
        jobs => {}, tokens => {}, queue => [], max_workers => $limit, next_token => 0}, $class;
}

sub _copy {
    my ($value) = @_;
    my $json = Plugins::BlissLibrary::JsonCodec::canonical();
    return $json->decode($json->encode($value));
}

sub request {
    my ($self, %args) = @_;
    die 'Completion and error callbacks are required' unless ref($args{on_done}) eq 'CODE' && ref($args{on_error}) eq 'CODE';
    my $identity = Plugins::BlissLibrary::CandidateInventory::make_inventory(
        scope => $args{scope}, source => $args{source}, row_ids => [],
    );
    my $scope = $identity->{scope};
    my $source = $identity->{source};
    my $key = Plugins::BlissLibrary::CandidateInventory::cache_key(scope => $scope, source => $source);
    my $job = $self->{jobs}->{$key};
    die 'Build cancellation is still in progress' if $job && $job->{cancelling};
    unless ($job) {
        $job = $self->{jobs}->{$key} = {scope => $scope, source => $source, subscribers => {}, state => 'queued'};
        push @{$self->{queue}}, $key;
    }
    my $token = ++$self->{next_token};
    $job->{subscribers}->{$token} = {on_done => $args{on_done}, on_error => $args{on_error}};
    $self->{tokens}->{$token} = $key;
    $self->_start_ready;
    return $token;
}

sub _start_ready {
    my ($self) = @_;
    my $active = scalar grep { $_->{state} eq 'running' || $_->{state} eq 'cancelling' } values %{$self->{jobs}};
    while ($active < $self->{max_workers} && @{$self->{queue}}) {
        my $key = shift @{$self->{queue}};
        my $job = $self->{jobs}->{$key};
        next unless $job && $job->{state} eq 'queued';
        my $worker = eval { $self->{spawn}->(_copy($job->{scope}), _copy($job->{source})) };
        my $error = $@;
        if (!$worker || !eval { $worker->can('poll') && $worker->can('cancel') }) {
            $job->{state} = 'start_failed';
            $job->{error} = $error || 'Worker could not be started';
            next;
        }
        $job->{worker} = $worker;
        $job->{state} = 'running';
        $active++;
    }
}

sub cancel {
    my ($self, $token) = @_;
    my $key = delete $self->{tokens}->{$token};
    return 0 unless defined $key;
    my $job = $self->{jobs}->{$key};
    return 0 unless $job;
    delete $job->{subscribers}->{$token};
    unless (keys %{$job->{subscribers}}) {
        if ($job->{state} eq 'running') {
            $job->{cancelling} = 1;
            $job->{state} = 'cancelling';
            $job->{worker}->cancel;
        } else {
            delete $self->{jobs}->{$key};
            @{$self->{queue}} = grep { $_ ne $key } @{$self->{queue}};
        }
    }
    return 1;
}

sub poll {
    my ($self) = @_;
    for my $key (keys %{$self->{jobs}}) {
        my $job = $self->{jobs}->{$key};
        next if $job->{state} eq 'queued';
        if ($job->{state} eq 'waiting') {
            if ($self->{clock}->() >= $job->{retry_at}) {
                $job->{state} = 'queued';
                push @{$self->{queue}}, $key;
            }
            next;
        }
        my $status = $job->{state} eq 'start_failed'
            ? {state => 'failed', error => $job->{error}}
            : eval { $job->{worker}->poll };
        $status = {state => 'failed', error => $@ || 'Invalid worker status'}
            unless ref($status) eq 'HASH' && defined $status->{state};
        next if $status->{state} eq 'running' || $status->{state} eq 'cancelling';
        if (!$job->{cancelling} && $status->{state} eq 'failed'
            && defined($status->{exit_code}) && $status->{exit_code} == 75
            && defined($status->{exit_signal}) && $status->{exit_signal} == 0) {
            $job->{busy_count} = ($job->{busy_count} || 0) + 1;
            if ($job->{busy_count} <= $self->{max_busy_retries}) {
                my $delay = $self->{retry_delay};
                for (2 .. $job->{busy_count}) { $delay *= 2; last if $delay >= 30 }
                $delay = 30 if $delay > 30;
                delete $job->{worker};
                $job->{state} = 'waiting';
                $job->{retry_at} = $self->{clock}->() + $delay;
                next;
            }
            $status->{error} = 'Inventory build lock contention exceeded the retry limit';
        }
        delete $self->{jobs}->{$key};
        delete $self->{tokens}->{$_} for keys %{$job->{subscribers}};
        next unless keys %{$job->{subscribers}};
        my ($inventory, $error);
        if ($status->{state} eq 'completed') {
            $inventory = eval { $self->{collect}->($job->{worker}, _copy($job->{scope}), _copy($job->{source})) };
            my $collect_error = $@;
            $error = $collect_error || 'Worker returned an invalid or stale inventory'
                unless Plugins::BlissLibrary::CandidateInventory::validate_inventory(
                    $inventory, scope => $job->{scope}, source => $job->{source},
                );
        } else {
            $error = $status->{error} || 'Inventory worker did not complete successfully';
        }
        for my $subscriber (values %{$job->{subscribers}}) {
            my $ok = eval { $error ? $subscriber->{on_error}->($error) : $subscriber->{on_done}->(_copy($inventory)); 1 };
            my $callback_error = $@;
            if (!$ok && $self->{on_callback_error}) {
                eval { $self->{on_callback_error}->($callback_error); 1 };
            }
        }
    }
    $self->_start_ready;
    return scalar keys %{$self->{jobs}};
}
1;
