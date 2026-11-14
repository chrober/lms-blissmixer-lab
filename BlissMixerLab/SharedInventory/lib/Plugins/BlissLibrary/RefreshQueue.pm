package Plugins::BlissLibrary::RefreshQueue;
use strict;
use warnings;
use Time::HiRes ();
use Plugins::BlissLibrary::CandidateInventory;
use Plugins::BlissLibrary::JsonCodec;

sub new {
    my ($class, %args) = @_;
    die 'Refresh start callback is required' unless ref($args{start}) eq 'CODE';
    die 'Refresh error handler must be a callback' if exists($args{on_error}) && ref($args{on_error}) ne 'CODE';
    die 'Clock must be a callback' if exists($args{clock}) && ref($args{clock}) ne 'CODE';
    my $debounce = defined($args{debounce}) ? $args{debounce} : 5;
    die 'Debounce must be a nonnegative integer' unless !ref($debounce) && "$debounce" =~ /\A(?:0|[1-9][0-9]*)\z/;
    return bless {start => $args{start}, on_error => $args{on_error}, clock => $args{clock} || sub { Time::HiRes::time() },
        debounce => $debounce, entries => {}, order => [], epoch => 0, next_token => 0}, $class;
}

sub remember {
    my ($self, $input) = @_;
    my $scope = Plugins::BlissLibrary::CandidateInventory::_scope($input);
    my $key = Plugins::BlissLibrary::JsonCodec::canonical()->encode($scope);
    unless ($self->{entries}->{$key}) {
        $self->{entries}->{$key} = {scope => $scope};
        push @{$self->{order}}, $key;
    }
    return 1;
}

sub scan_done {
    my ($self) = @_;
    my $epoch = ++$self->{epoch};
    my $ready = $self->{clock}->() + $self->{debounce};
    for my $entry (values %{$self->{entries}}) {
        $entry->{dirty} = $epoch;
        $entry->{ready_at} = $ready;
        $entry->{attempts} = 0;
        delete $entry->{error};
    }
    return 1;
}

sub poll {
    my ($self) = @_;
    return if $self->{inflight};
    my $now = $self->{clock}->();
    for my $key (@{$self->{order}}) {
        my $entry = $self->{entries}->{$key};
        next unless $entry->{dirty} && $entry->{ready_at} <= $now && ($entry->{attempts} || 0) < 3;
        my $epoch = $entry->{dirty};
        my $token = ++$self->{next_token};
        $self->{inflight} = $token;
        my $done = sub {
            my ($error) = @_;
            return unless $self->{inflight} && $self->{inflight} == $token;
            delete $self->{inflight};
            return if $entry->{dirty} != $epoch;
            if (defined($error) && length($error)) {
                $entry->{error} = "$error";
                my $attempt = ++$entry->{attempts};
                $entry->{ready_at} = $self->{clock}->() + 5 * $attempt;
                eval { $self->{on_error}->($error, {%{$entry->{scope}}}) } if $self->{on_error};
            } else {
                delete @{$entry}{qw(dirty error ready_at attempts)};
            }
        };
        my $ok = eval { $self->{start}->({%{$entry->{scope}}}, $done); 1 };
        $done->($@ || 'Cannot start refresh') unless $ok;
        last;
    }
    return scalar grep { $_->{dirty} } values %{$self->{entries}};
}

sub status {
    my ($self) = @_;
    return {pending => scalar(grep { $_->{dirty} } values %{$self->{entries}}),
        failed => scalar(grep { $_->{error} } values %{$self->{entries}}),
        retryable => scalar(grep { $_->{dirty} && ($_->{attempts} || 0) < 3 } values %{$self->{entries}}),
        running => $self->{inflight} ? 1 : 0};
}
1;
