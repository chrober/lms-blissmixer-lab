package Plugins::BlissMixerLab::RepeatIdentitySnapshot;

use strict;

use DBI;
use Digest::SHA qw(sha256_hex);
use Encode qw(encode_utf8);
use File::Path qw(make_path);
use File::Spec::Functions qw(catdir catfile);
use Unicode::Normalize qw(NFKC);
use URI::Escape qw(uri_unescape);

use Slim::Utils::Misc;
use Slim::Utils::OSDetect;
use Slim::Utils::Unicode;

use constant SCHEMA_IDENTITY => 'lyrion-track-identities-v1';

my ($cached_scan_time, $cached_roots_identity, $cached_path);

sub _database_text {
    my $value = shift;
    return unless defined $value;
    return $value if utf8::is_utf8($value);
    return Slim::Utils::Unicode::utf8decode_locale($value);
}

sub _starts_with {
    my ($value, $prefix) = @_;
    return index($value, $prefix) == 0 ? 1 : 0;
}

sub _database_file_for_url {
    my ($url, $tracknum, $roots) = @_;
    return unless $url && $url =~ /^file:/i;
    my $file_url = $url;
    $file_url =~ s/#.*$//;
    for my $root (sort { length($b) <=> length($a) } @$roots) {
        my $prefix = Slim::Utils::Misc::fileURLFromPath($root);
        $prefix =~ s{/+$}{};
        next unless _starts_with($file_url, $prefix . '/');
        my $relative = uri_unescape(substr($file_url, length($prefix) + 1));
        $relative = _database_text($relative);
        $relative .= '.CUE_TRACK.' . $tracknum if $url =~ /#/ && $tracknum;
        return $relative;
    }

    my $path = Slim::Utils::Misc::pathFromFileURL($url);
    $path =~ s{\\}{/}g;
    for my $root (sort { length($b) <=> length($a) } @$roots) {
        my $normalized_root = $root;
        $normalized_root =~ s{\\}{/}g;
        $normalized_root =~ s{/+$}{};
        next unless _starts_with($path, $normalized_root . '/');
        my $relative = _database_text(substr($path, length($normalized_root) + 1));
        $relative .= '.CUE_TRACK.' . $tracknum if $url =~ /#/ && $tracknum;
        return $relative;
    }
    return;
}

sub _canonical_name {
    my $value = NFKC(defined $_[0] ? $_[0] : '');
    $value = lc $value;
    $value =~ s/^\s+|\s+$//g;
    $value =~ s/\s+/ /g;
    return $value;
}

sub _media_roots_identity {
    my $roots = shift || [];
    my @normalized = sort map {
        my $root = NFKC(defined $_ ? $_ : '');
        $root =~ s{\\}{/}g;
        $root =~ s{/+$}{};
        $root;
    } @$roots;
    return sha256_hex(encode_utf8(join("\0", @normalized)));
}

sub _normalize_mbid {
    my $value = lc(defined $_[0] ? $_[0] : '');
    $value =~ s/^\s+|\s+$//g;
    return $value
        if $value
            =~ /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/;
    return '';
}

sub _canonical_key {
    my ($mbid, $contributor_id, $name) = @_;
    my $normalized = _canonical_name($name);
    return if $normalized eq 'various artists';
    my $valid_mbid = _normalize_mbid($mbid);
    return 'artist-mbid:' . $valid_mbid if length $valid_mbid;
    return 'lms-contributor:' . int($contributor_id) if defined $contributor_id;
    return if !$normalized || $normalized eq 'various artists';
    return 'artist-name:' . $normalized;
}

sub _create_schema {
    my $dbh = shift;
    $dbh->do('CREATE TABLE metadata (key TEXT PRIMARY KEY, value TEXT NOT NULL)');
    $dbh->do(
        'CREATE TABLE track_identity ('
        . 'database_file TEXT PRIMARY KEY, lms_track_id INTEGER NOT NULL, '
        . 'lms_urlmd5 TEXT, recording_mbid TEXT, primary_contributor_id INTEGER, '
        . 'primary_artist_mbid TEXT, primary_artist_name TEXT, '
        . 'legacy_artist_credit TEXT NOT NULL)'
    );
    $dbh->do(
        'CREATE TABLE track_artist_identity ('
        . 'database_file TEXT NOT NULL, role TEXT NOT NULL, canonical_key TEXT NOT NULL, '
        . 'contributor_id INTEGER, artist_mbid TEXT, artist_name TEXT NOT NULL, '
        . 'PRIMARY KEY (database_file, role, canonical_key))'
    );
    $dbh->do('CREATE INDEX track_artist_file_idx ON track_artist_identity(database_file)');
}

sub _snapshot_is_current {
    my ($path, $scan_time, $roots_identity) = @_;
    return 0 unless -r $path;
    my $dbh = eval { DBI->connect('dbi:SQLite:dbname=' . $path, '', '', {
        RaiseError => 1, PrintError => 0, sqlite_unicode => 1, sqlite_open_flags => 1,
    }) };
    return 0 unless $dbh;
    my ($schema) = eval {
        $dbh->selectrow_array("SELECT value FROM metadata WHERE key='schema_identity'")
    };
    my ($captured_scan) = eval {
        $dbh->selectrow_array("SELECT value FROM metadata WHERE key='lms_scan_time'")
    };
    my ($captured_roots) = eval {
        $dbh->selectrow_array("SELECT value FROM metadata WHERE key='media_roots_identity'")
    };
    $dbh->disconnect;
    return defined $schema && $schema eq SCHEMA_IDENTITY
        && defined $captured_scan && int($captured_scan) == int($scan_time)
        && defined $captured_roots && $captured_roots eq $roots_identity;
}

sub prepare {
    my $scan_time = int(Slim::Music::Import->lastScanTime() || 0);
    my $roots = Slim::Utils::Misc::getMediaDirs('audio') || [];
    my $roots_identity = _media_roots_identity($roots);
    my $cache_root = Slim::Utils::OSDetect::dirsFor('cache');
    my $directory = catdir($cache_root, 'BlissMixerLab');
    make_path($directory) unless -d $directory;
    my $path = catfile($directory, 'artist-repeat-identities.sqlite');
    return $cached_path
        if defined $cached_scan_time && $cached_scan_time == $scan_time
            && defined $cached_roots_identity
            && $cached_roots_identity eq $roots_identity
            && defined $cached_path && -r $cached_path;
    if (_snapshot_is_current($path, $scan_time, $roots_identity)) {
        ($cached_scan_time, $cached_roots_identity, $cached_path) =
            ($scan_time, $roots_identity, $path);
        return $path;
    }

    my $temporary = $path . '.tmp-' . $$;
    unlink $temporary if -e $temporary;
    my $target = DBI->connect('dbi:SQLite:dbname=' . $temporary, '', '', {
        RaiseError => 1, PrintError => 0, AutoCommit => 0, sqlite_unicode => 1,
    });
    _create_schema($target);
    my $metadata = $target->prepare('INSERT INTO metadata(key, value) VALUES (?, ?)');
    $metadata->execute('schema_identity', SCHEMA_IDENTITY);
    $metadata->execute('lms_scan_time', $scan_time);
    $metadata->execute('media_roots_identity', $roots_identity);

    my $insert_track = $target->prepare(
        'INSERT INTO track_identity '
        . '(database_file, lms_track_id, lms_urlmd5, recording_mbid, '
        . 'primary_contributor_id, primary_artist_mbid, primary_artist_name, '
        . 'legacy_artist_credit) VALUES (?, ?, ?, ?, ?, ?, ?, ?)'
    );
    my $insert_artist = $target->prepare(
        'INSERT OR IGNORE INTO track_artist_identity '
        . '(database_file, role, canonical_key, contributor_id, artist_mbid, artist_name) '
        . 'VALUES (?, ?, ?, ?, ?, ?)'
    );
    my $source = Slim::Schema->dbh;
    my $tracks = $source->prepare(
        'SELECT tracks.id, tracks.url, tracks.tracknum, tracks.urlmd5, '
        . 'tracks.musicbrainz_id, contributors.id, contributors.musicbrainz_id, '
        . 'contributors.name FROM tracks '
        . 'LEFT JOIN contributors ON contributors.id = tracks.primary_artist '
        . 'WHERE tracks.remote = 0 AND tracks.audio = 1'
    );
    $tracks->execute;
    while (my @row = $tracks->fetchrow_array) {
        my ($track_id, $url, $tracknum, $urlmd5, $recording_mbid,
            $contributor_id, $artist_mbid, $artist_name) = @row;
        my $file = _database_file_for_url($url, $tracknum, $roots);
        next unless defined $file && length $file;
        $insert_track->execute(
            $file, int($track_id), $urlmd5, $recording_mbid, $contributor_id,
            $artist_mbid, $artist_name, defined $artist_name ? $artist_name : '',
        );
    }
    $tracks->finish;

    my $artists = $source->prepare(
        'SELECT tracks.url, tracks.tracknum, contributor_track.role, '
        . 'contributors.id, contributors.musicbrainz_id, contributors.name '
        . 'FROM contributor_track '
        . 'JOIN tracks ON tracks.id = contributor_track.track '
        . 'JOIN contributors ON contributors.id = contributor_track.contributor '
        . 'WHERE tracks.remote = 0 AND tracks.audio = 1 '
        . 'AND contributor_track.role IN (1, 6)'
    );
    $artists->execute;
    while (my @row = $artists->fetchrow_array) {
        my ($url, $tracknum, $role, $contributor_id, $mbid, $name) = @row;
        my $file = _database_file_for_url($url, $tracknum, $roots);
        next unless defined $file && length $file;
        my $key = _canonical_key($mbid, $contributor_id, $name);
        next unless defined $key;
        $insert_artist->execute(
            $file, int($role) == 6 ? 'TRACKARTIST' : 'ARTIST', $key,
            $contributor_id, $mbid, defined $name ? $name : '',
        );
    }
    $artists->finish;
    $target->commit;
    $target->disconnect;
    rename($temporary, $path) or die "Could not publish repeat identity snapshot '$path': $!";
    ($cached_scan_time, $cached_roots_identity, $cached_path) =
        ($scan_time, $roots_identity, $path);
    return $path;
}

1;
