package Plugins::BlissLibrary::BuildLock;
use strict;
use warnings;
use Fcntl qw(O_CREAT O_RDWR LOCK_EX LOCK_NB F_GETFD F_SETFD FD_CLOEXEC);
use Errno qw(EAGAIN EWOULDBLOCK);
use File::Spec;
use Plugins::BlissLibrary::CandidateInventory;

sub try_acquire {
    my ($dir, %identity) = @_;
    die 'Build-lock directory is unavailable' unless defined($dir) && -d $dir;
    my $key = Plugins::BlissLibrary::CandidateInventory::cache_key(%identity);
    my $path = File::Spec->catfile($dir, "build-$key.lock");
    sysopen(my $fh, $path, O_CREAT | O_RDWR, 0600) or die "Cannot open build lock: $!";
    my $flags = fcntl($fh, F_GETFD, 0);
    die "Cannot inspect build-lock descriptor: $!" unless defined $flags;
    fcntl($fh, F_SETFD, $flags | FD_CLOEXEC) or die "Cannot protect build-lock descriptor: $!";
    unless (flock($fh, LOCK_EX | LOCK_NB)) {
        my $error = 0 + $!;
        close $fh;
        return undef if $error == EAGAIN || $error == EWOULDBLOCK;
        die "Cannot acquire build lock: $error";
    }
    return bless {fh => $fh}, __PACKAGE__;
}

sub release {
    my ($self) = @_;
    return 1 unless $self->{fh};
    my $fh = delete $self->{fh};
    close $fh or die "Cannot release build lock: $!";
    return 1;
}
1;
