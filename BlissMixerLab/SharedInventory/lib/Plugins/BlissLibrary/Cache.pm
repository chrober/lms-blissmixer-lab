package Plugins::BlissLibrary::Cache;
use strict;
use warnings;
use Digest::SHA qw(sha256_hex);
use File::Basename qw(basename);
use File::Spec;
use File::Temp qw(tempfile);
use Plugins::BlissLibrary::CandidateInventory;
use Plugins::BlissLibrary::JsonCodec;
use Plugins::BlissLibrary::Store;

sub _index_path {
    my ($dir, %identity) = @_;
    my $key = Plugins::BlissLibrary::CandidateInventory::cache_key(%identity);
    return File::Spec->catfile($dir, "index-$key.txt");
}

sub _read_index {
    my ($path) = @_;
    return undef unless -f $path && -s $path <= 80;
    my $value = Plugins::BlissLibrary::Store::_read($path);
    return undef unless defined($value) && $value =~ /\A(inventory-[0-9a-f]{64}\.json)\n\z/;
    return $1;
}

sub put {
    my ($dir, $inventory) = @_;
    die 'Invalid inventory' unless ref($inventory) eq 'HASH'
        && Plugins::BlissLibrary::CandidateInventory::validate_inventory(
            $inventory, scope => $inventory->{scope}, source => $inventory->{source},
        );
    my $index = _index_path($dir, scope => $inventory->{scope}, source => $inventory->{source});
    my $artifact = Plugins::BlissLibrary::Store::publish($dir, $inventory);
    my $name = basename($artifact);
    if (-e $index) {
        my $existing = _read_index($index);
        die 'Conflicting or invalid cache index' unless defined($existing) && $existing eq $name;
        return $artifact;
    }
    my ($fh, $temp) = tempfile('index-XXXXXXXX', DIR => $dir, UNLINK => 1);
    binmode $fh, ':raw' or die "Cannot set binary mode: $!";
    print {$fh} "$name\n" or die "Cannot write cache index: $!";
    close $fh or die "Cannot close cache index: $!";
    if (!link($temp, $index)) {
        my $error = "$!";
        my $existing = _read_index($index);
        die "Cannot publish cache index atomically: $error" unless defined($existing) && $existing eq $name;
    }
    return $artifact;
}

sub get {
    my ($dir, %identity) = @_;
    return undef unless defined($dir) && -d $dir;
    my $index = eval { _index_path($dir, %identity) };
    return undef unless defined($index);
    my $name = _read_index($index);
    return undef unless defined $name;
    return scalar Plugins::BlissLibrary::Store::load(File::Spec->catfile($dir, $name), %identity);
}

# Called only while holding the generation's build lock. Preserve damaged files
# for diagnosis rather than replacing them in place underneath other readers.
sub _quarantine {
    my ($dir, $path) = @_;
    my ($fh, $target) = tempfile('quarantine-XXXXXXXX', DIR => $dir, UNLINK => 0);
    close $fh or die "Cannot close quarantine placeholder: $!";
    unlink $target or die "Cannot prepare quarantine destination: $!";
    link($path, $target) or die "Cannot preserve damaged cache file: $!";
    unlink $path or die "Cannot detach damaged cache file: $!";
    return $target;
}

sub _recover_invalid {
    my ($dir, %identity) = @_;
    my $index = _index_path($dir, %identity);
    return unless -e $index;
    my $name = _read_index($index);
    if (defined $name) {
        my $path = File::Spec->catfile($dir, $name);
        if (-e $path) {
            my $bytes = Plugins::BlissLibrary::Store::_read($path);
            die 'Cannot read cached inventory during recovery' unless defined $bytes;
            my ($digest) = $name =~ /\Ainventory-([0-9a-f]{64})\.json\z/;
            _quarantine($dir, $path) if sha256_hex($bytes) ne $digest;
        }
    }
    _quarantine($dir, $index);
    return 1;
}

sub _recover_orphan {
    my ($dir, $inventory) = @_;
    my $bytes = Plugins::BlissLibrary::JsonCodec::canonical()->encode($inventory);
    my $digest = sha256_hex($bytes);
    my $path = File::Spec->catfile($dir, "inventory-$digest.json");
    return unless -e $path;
    my $existing = Plugins::BlissLibrary::Store::_read($path);
    die 'Cannot read existing inventory during recovery' unless defined $existing;
    _quarantine($dir, $path) if sha256_hex($existing) ne $digest;
    return 1;
}
1;
