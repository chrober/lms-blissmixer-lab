package Plugins::BlissLibrary::SourceIdentity;
use strict;
use warnings;
use Digest::SHA qw(sha256_hex);
use JSON::PP ();
our $session;

sub _metadata {
    my ($path) = @_;
    my @files;
    for my $item ([$path, 0], ["$path-wal", 1]) {
        my ($file, $optional) = @$item;
        my @stat = stat($file);
        die "Database is unavailable: $file" if !@stat && !$optional;
        push @files, @stat ? [@stat[0, 1, 7, 9, 10]] : undef;
    }
    return JSON::PP->new->canonical->encode(\@files);
}

sub begin_session {
    my ($paths) = @_;
    die 'Database paths are required' unless ref($paths) eq 'ARRAY' && @$paths;
    require DBI;
    my %entries;
    for my $path (@$paths) {
        die 'Database path is required' unless defined($path) && !ref($path) && length($path);
        next if $entries{$path};
        my $before = _metadata($path);
        my $dbh = DBI->connect("dbi:SQLite:dbname=$path", '', '', {
            RaiseError => 1, PrintError => 0, AutoCommit => 1, sqlite_open_flags => 1,
        }) or die "Cannot watch database: $path";
        my ($version) = $dbh->selectrow_array('PRAGMA data_version');
        die "Database changed while establishing validation: $path" unless $before eq _metadata($path);
        $entries{$path} = {dbh => $dbh, version => $version, metadata => $before};
    }
    return bless \%entries, 'Plugins::BlissLibrary::SourceIdentity::Session';
}

sub _check_session {
    my ($path) = @_;
    return unless $session && $session->{$path};
    my $entry = $session->{$path};
    my ($version) = $entry->{dbh}->selectrow_array('PRAGMA data_version');
    die "Database changed during validation session: $path" unless $version == $entry->{version}
        && _metadata($path) eq $entry->{metadata};
    return $entry;
}

sub media_roots_fingerprint {
    my ($roots) = @_;
    die 'Media roots must be an array' unless ref($roots) eq 'ARRAY';
    for my $root (@$roots) {
        die 'Invalid media root' unless defined($root) && !ref($root) && length($root);
    }
    return sha256_hex(JSON::PP->new->canonical->utf8->encode({roots => $roots}));
}

sub _file_state {
    my ($path, $optional) = @_;
    if (!-e $path) {
        return undef if $optional;
        die "Database is unavailable: $path";
    }
    open my $fh, '<:raw', $path or die "Cannot read source file $path: $!";
    my @before = stat($fh);
    die "Cannot stat source file: $path" unless @before && -f _;
    my $sha = Digest::SHA->new(256);
    while (1) {
        my $read = read($fh, my $buffer, 1024 * 1024);
        die "Cannot read source file $path: $!" unless defined $read;
        last unless $read;
        $sha->add($buffer);
    }
    my @after = stat($fh);
    close $fh or die "Cannot close source file $path: $!";
    my @path_after = stat($path);
    die "Source file changed while hashing: $path" unless @after && @path_after;
    my @fields = (0, 1, 7, 9, 10);
    my $before_state = join(':', @before[@fields]);
    die "Source file changed while hashing: $path"
        unless $before_state eq join(':', @after[@fields])
            && $before_state eq join(':', @path_after[@fields]);
    return {stat => [@before[@fields]], sha256 => $sha->hexdigest};
}

sub _pass {
    my ($path) = @_;
    return {main => _file_state($path, 0), wal => _file_state($path . '-wal', 1)};
}

sub database_fingerprint {
    my ($path) = @_;
    die 'Database path is required' unless defined($path) && !ref($path) && length($path);
    my $entry = _check_session($path);
    return $entry->{fingerprint} if $entry && defined $entry->{fingerprint};
    my $json = JSON::PP->new->canonical->utf8;
    my $first = $json->encode(_pass($path));
    my $second = $json->encode(_pass($path));
    die 'Database changed while fingerprinting' unless $first eq $second;
    _check_session($path) if $entry;
    my $fingerprint = sha256_hex($first);
    $entry->{fingerprint} = $fingerprint if $entry;
    return $fingerprint;
}

package Plugins::BlissLibrary::SourceIdentity::Session;
sub DESTROY {
    my ($self) = @_;
    for my $entry (values %$self) { eval { $entry->{dbh}->disconnect } if $entry->{dbh} }
}
1;
