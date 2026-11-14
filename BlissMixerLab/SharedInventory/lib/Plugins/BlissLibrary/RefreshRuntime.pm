package Plugins::BlissLibrary::RefreshRuntime;
use strict;
use warnings;
use File::Spec;
use Plugins::BlissLibrary::RefreshQueue;
use Plugins::BlissLibrary::ScopeRegistry;
my $shared;

sub shared {
    my ($class, %args) = @_;
    die 'Shared refresh directory is required' unless defined($args{dir}) && -d $args{dir};
    my $dir = File::Spec->rel2abs($args{dir});
    if ($shared) {
        die 'Incompatible shared refresh directories' unless $shared->{shared_dir} eq $dir;
        return $shared;
    }
    my $runtime = $class->new(%args);
    $runtime->{shared_dir} = $dir;
    return $shared = $runtime;
}

sub new {
    my ($class, %args) = @_;
    for my $key (qw(subscribe schedule launch)) {
        die "Refresh $key callback is required" unless ref($args{$key}) eq 'CODE';
    }
    die 'Refresh clock must be a callback' if exists($args{clock}) && ref($args{clock}) ne 'CODE';
    die 'Refresh error handler must be a callback' if exists($args{on_error}) && ref($args{on_error}) ne 'CODE';
    my $loaded = Plugins::BlissLibrary::ScopeRegistry::load($args{dir});
    my $self = bless {dir => $args{dir}, schedule => $args{schedule}, launch => $args{launch}, invalid => $loaded->{invalid}}, $class;
    my %queue_args = (start => sub {
        my ($scope, $done) = @_;
        $self->{launch}->($scope, sub { return if $self->{stopped}; $done->(@_); $self->_arm });
    });
    $queue_args{clock} = $args{clock} if $args{clock};
    $queue_args{on_error} = $args{on_error} if $args{on_error};
    $self->{queue} = Plugins::BlissLibrary::RefreshQueue->new(%queue_args);
    $self->{queue}->remember($_) for @{$loaded->{scopes}};
    $self->{listener} = sub { return if $self->{stopped}; $self->{queue}->scan_done; $self->_arm };
    $self->{unsubscribe} = $args{unsubscribe};
    $args{subscribe}->($self->{listener});
    return $self;
}

sub _arm {
    my ($self) = @_;
    my $status = $self->{queue}->status;
    return if $self->{stopped} || $self->{scheduled} || $status->{running} || !$status->{retryable};
    $self->{scheduled} = 1;
    $self->{schedule}->(1, sub {
        $self->{scheduled} = 0;
        return if $self->{stopped};
        $self->{queue}->poll;
        $self->_arm;
    });
}

sub remember {
    my ($self, $scope) = @_;
    Plugins::BlissLibrary::ScopeRegistry::remember($self->{dir}, $scope);
    $self->{queue}->remember($scope);
    return 1;
}

sub stop {
    my ($self) = @_;
    return if $self->{stopped}++;
    my $listener = delete $self->{listener};
    $self->{unsubscribe}->($listener) if $self->{unsubscribe};
    delete $self->{queue};
    $shared = undef if $shared && $shared == $self;
    return 1;
}

sub status {
    my ($self) = @_;
    return {%{$self->{queue}->status}, invalid_records => $self->{invalid}};
}
1;
