package Plugins::BlissLibrary::Store;
use strict;
use warnings;
use Digest::SHA qw(sha256_hex);
use File::Basename qw(basename);
use File::Spec;
use File::Temp qw(tempfile);
use Plugins::BlissLibrary::JsonCodec;
use Plugins::BlissLibrary::CandidateInventory;

sub _read {
    my ($path) = @_;
    open my $fh, '<:raw', $path or return;
    local $/;
    my $bytes = <$fh>;
    close $fh or return;
    return $bytes;
}

sub publish {
    my ($dir, $inventory) = @_;
    die 'Cache directory is unavailable' unless defined($dir) && -d $dir;
    die 'Invalid inventory' unless ref($inventory) eq 'HASH'
        && Plugins::BlissLibrary::CandidateInventory::validate_inventory(
            $inventory, scope => $inventory->{scope}, source => $inventory->{source},
        );
    my $bytes = Plugins::BlissLibrary::JsonCodec::canonical()->encode($inventory);
    my $digest = sha256_hex($bytes);
    my $path = File::Spec->catfile($dir, "inventory-$digest.json");
    if (-e $path) {
        my $existing = _read($path);
        die 'Existing inventory artifact is corrupt' unless defined($existing) && $existing eq $bytes;
        return $path;
    }
    my ($fh, $temporary) = tempfile('inventory-XXXXXXXX', DIR => $dir, UNLINK => 1);
    binmode $fh, ':raw' or die "Cannot set binary mode: $!";
    print {$fh} $bytes or die "Cannot write inventory: $!";
    close $fh or die "Cannot close inventory: $!";
    if (!link($temporary, $path)) {
        my $error = "$!";
        my $existing = _read($path);
        die "Cannot publish inventory atomically: $error" unless defined($existing) && $existing eq $bytes;
    }
    return $path;
}

sub load {
    my ($path, %expected) = @_;
    return unless defined($path) && basename($path) =~ /\Ainventory-([0-9a-f]{64})\.json\z/;
    my $digest = $1;
    my $bytes = _read($path);
    return unless defined($bytes) && sha256_hex($bytes) eq $digest;
    my $inventory = eval { Plugins::BlissLibrary::JsonCodec::canonical()->decode($bytes) };
    return unless $inventory && Plugins::BlissLibrary::CandidateInventory::validate_inventory(
        $inventory, %expected,
    );
    return $inventory;
}
1;
