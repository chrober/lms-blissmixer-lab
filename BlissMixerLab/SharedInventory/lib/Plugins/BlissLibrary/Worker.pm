package Plugins::BlissLibrary::Worker;
use strict;
use warnings;
use Fcntl qw(O_CREAT O_EXCL O_WRONLY);
use Proc::Background;

sub start {
    my ($class, %args) = @_;
    my $command = $args{command};
    die 'Worker command must be an argument array' unless ref($command) eq 'ARRAY' && @$command >= 2
        && !grep { !defined($_) || ref($_) || !length($_) } @$command;
    for my $key (qw(stdout_path stderr_path)) {
        die "Missing worker $key" unless defined($args{$key}) && !ref($args{$key}) && length($args{$key});
    }
    sysopen(my $stdout, $args{stdout_path}, O_WRONLY | O_CREAT | O_EXCL, 0600)
        or die "Cannot create worker output: $!";
    sysopen(my $stderr, $args{stderr_path}, O_WRONLY | O_CREAT | O_EXCL, 0600)
        or die "Cannot create worker error output: $!";
    binmode $stdout, ':raw';
    binmode $stderr, ':raw';
    my $proc = Proc::Background->new({
        autodie => 1, die_upon_destroy => 0,
        stdin => undef, stdout => $stdout, stderr => $stderr,
    }, @$command) or die 'Could not start worker';
    close $stdout;
    close $stderr;
    return bless {proc => $proc, cancel_requested => 0}, $class;
}

sub poll {
    my ($self) = @_;
    return $self->{terminal} if $self->{terminal};
    my $proc = $self->{proc};
    return {state => $self->{cancel_requested} ? 'cancelling' : 'running'} if $proc->alive;
    my $code = $proc->exit_code;
    my $signal = $proc->exit_signal;
    my $state = $self->{cancel_requested} ? 'cancelled'
        : defined($code) && defined($signal) && !$code && !$signal ? 'completed' : 'failed';
    return $self->{terminal} = {state => $state, exit_code => $code, exit_signal => $signal};
}

sub cancel {
    my ($self) = @_;
    return if $self->{terminal};
    return unless $self->{proc}->alive;
    $self->{cancel_requested} = 1;
    $self->{proc}->terminate('TERM');
    return 1;
}
1;
