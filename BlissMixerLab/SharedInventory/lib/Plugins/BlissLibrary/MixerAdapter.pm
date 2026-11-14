package Plugins::BlissLibrary::MixerAdapter;
use strict;
use warnings;
use Digest::SHA qw(sha256_hex);
use File::Spec;
use File::Temp qw(tempfile);
use Plugins::BlissLibrary::BuildLock;
use Plugins::BlissLibrary::Builder;
use Plugins::BlissLibrary::Cache;
use Plugins::BlissLibrary::CandidateInventory;
use Plugins::BlissLibrary::JsonCodec;
use Plugins::BlissLibrary::SourceIdentity;
use Plugins::BlissLibrary::Store;

sub native_artifact {
    my %args = @_;
    my $cached = cached_files(%args);
    return $cached if $cached->{state} eq 'busy';
    my $lock = Plugins::BlissLibrary::BuildLock::try_acquire($args{dir}, scope => $args{scope}, source => $args{source});
    return {state => 'busy'} unless $lock;
    my $expected = $args{source}->{bliss_database};
    die 'Bliss database changed before native artifact publication' unless
        $expected eq Plugins::BlissLibrary::SourceIdentity::database_fingerprint($args{bliss_path});
    my $bytes = Plugins::BlissLibrary::JsonCodec::canonical()->encode($cached->{files});
    my $digest = sha256_hex($bytes);
    my $path = File::Spec->catfile($args{dir}, "mixer-files-$digest.json");
    if (-e $path) {
        my $existing = Plugins::BlissLibrary::Store::_read($path);
        die 'Cannot read native mixer artifact' unless defined $existing;
        Plugins::BlissLibrary::Cache::_quarantine($args{dir}, $path) if $existing ne $bytes;
    }
    unless (-e $path) {
        my ($fh, $temporary) = tempfile('mixer-native-XXXXXXXX', DIR => $args{dir}, UNLINK => 1);
        binmode $fh, ':raw' or die "Cannot set native mixer artifact binary mode: $!";
        print {$fh} $bytes or die "Cannot write native mixer artifact: $!";
        close $fh or die "Cannot close native mixer artifact: $!";
        if (!link($temporary, $path)) {
            my $error = "$!";
            my $existing = Plugins::BlissLibrary::Store::_read($path);
            die "Cannot publish native mixer artifact atomically: $error"
                unless defined($existing) && $existing eq $bytes;
        }
    }
    die 'Bliss database changed during native artifact publication' unless
        $expected eq Plugins::BlissLibrary::SourceIdentity::database_fingerprint($args{bliss_path});
    $lock->release;
    return {state => $cached->{state}, path => $path, sha256 => $digest};
}

sub cached_files {
    my %args = @_;
    my $inventory = $args{inventory};
    die 'Invalid or mismatched candidate inventory' unless
        Plugins::BlissLibrary::CandidateInventory::validate_inventory(
            $inventory, scope => $args{scope}, source => $args{source});
    my $dir = $args{dir};
    die 'Cache directory is unavailable' unless defined($dir) && -d $dir;
    my $lock = Plugins::BlissLibrary::BuildLock::try_acquire($dir, scope => $args{scope}, source => $args{source});
    return {state => 'busy'} unless $lock;
    my $expected = $args{source}->{bliss_database};
    die 'Bliss database changed before conversion' unless
        $expected eq Plugins::BlissLibrary::SourceIdentity::database_fingerprint($args{bliss_path});
    my $path = File::Spec->catfile($dir, 'mixer-paths-' . $inventory->{sha256} . '.json');
    my ($files, $state);
    if (-e $path) {
        my $bytes = Plugins::BlissLibrary::Store::_read($path);
        die 'Cannot read cached mixer paths' unless defined $bytes;
        my $json = Plugins::BlissLibrary::JsonCodec::canonical();
        my $valid = eval {
            my $value = $json->decode($bytes);
            die 'Cached mixer paths are corrupt' unless ref($value) eq 'HASH'
                && ($value->{schema} || '') eq 'bliss-mixer-paths-v1'
                && ($value->{inventory_sha256} || '') eq $inventory->{sha256}
                && ref($value->{files}) eq 'ARRAY';
            my $body = {schema => $value->{schema}, inventory_sha256 => $value->{inventory_sha256}, files => $value->{files}};
            die 'Cached mixer paths are corrupt' unless ($value->{sha256} || '') eq sha256_hex($json->encode($body))
                && $bytes eq $json->encode({%$body, sha256 => $value->{sha256}});
            my $previous;
            for my $file (@{$value->{files}}) {
                die 'Cached mixer paths are invalid' unless defined($file) && !ref($file) && length($file)
                    && (!defined($previous) || $previous lt $file);
                $previous = $file;
            }
            $files = $value->{files};
            1;
        };
        if ($valid) {
            $state = 'cached';
        } else {
            Plugins::BlissLibrary::Cache::_quarantine($dir, $path);
        }
    }
    unless (defined $files) {
        $files = files(%args);
        my $json = Plugins::BlissLibrary::JsonCodec::canonical();
        my $body = {schema => 'bliss-mixer-paths-v1', inventory_sha256 => $inventory->{sha256}, files => $files};
        my $bytes = $json->encode({%$body, sha256 => sha256_hex($json->encode($body))});
        my ($fh, $temporary) = tempfile('mixer-XXXXXXXX', DIR => $dir, UNLINK => 1);
        binmode $fh, ':raw' or die "Cannot set mixer cache binary mode: $!";
        print {$fh} $bytes or die "Cannot write mixer paths: $!";
        close $fh or die "Cannot close mixer paths: $!";
        die "Cannot publish mixer paths atomically: $!" unless link($temporary, $path);
        $state = 'built';
    }
    die 'Bliss database changed during conversion' unless
        $expected eq Plugins::BlissLibrary::SourceIdentity::database_fingerprint($args{bliss_path});
    $lock->release;
    return {state => $state, files => $files, path => $path};
}

sub files {
    my %args = @_;
    my $inventory = $args{inventory};
    die 'Invalid or mismatched candidate inventory' unless
        Plugins::BlissLibrary::CandidateInventory::validate_inventory(
            $inventory, scope => $args{scope}, source => $args{source});
    my $path = $args{bliss_path};
    my $expected = $args{source}->{bliss_database};
    die 'Bliss database changed before conversion' unless
        $expected eq Plugins::BlissLibrary::SourceIdentity::database_fingerprint($path);
    my $dbh = Plugins::BlissLibrary::Builder::_open_readonly($path);
    my $files = eval {
        $dbh->begin_work;
        my %remaining = map { $_ => 1 } @{$inventory->{row_ids}};
        my %wanted = %remaining;
        my %paths;
        my $sth = $dbh->prepare('SELECT rowid, File FROM TracksV2 WHERE Ignore IS NOT 1 ORDER BY rowid');
        $sth->execute;
        while (my ($id, $file) = $sth->fetchrow_array) {
            next unless delete $remaining{$id};
            die 'Selected Bliss row has an invalid file identity' unless defined($file) && length($file);
            $paths{$file} = 1;
        }
        $sth->finish;
        die 'Selected Bliss row is missing or ignored' if keys %remaining;
        $sth->execute;
        while (my ($id, $file) = $sth->fetchrow_array) {
            die 'File-based mixer restriction would admit an unselected Bliss row'
                if defined($file) && $paths{$file} && !$wanted{$id};
        }
        $sth->finish;
        $dbh->commit;
        [sort keys %paths];
    };
    my $error = $@;
    eval { $dbh->rollback unless $dbh->{AutoCommit} };
    $dbh->disconnect;
    die $error if $error;
    die 'Bliss database changed during conversion' unless
        $expected eq Plugins::BlissLibrary::SourceIdentity::database_fingerprint($path);
    return $files;
}
1;
