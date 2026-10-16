use strict;
use warnings;
use FindBin;
use File::Spec;
use File::Temp qw(tempdir);
use Test::More;

BEGIN {
    eval { require DBI; require DBD::SQLite; 1 }
        or plan skip_all => 'DBI and DBD::SQLite are required';

    package Slim::Utils::Misc;
    sub getMediaDirs { return ['/music'] }
    sub fileURLFromPath { return 'file:///music' }
    sub pathFromFileURL { my $value = $_[0]; $value =~ s{^file://}{}; return $value }
    $INC{'Slim/Utils/Misc.pm'} = __FILE__;

    package Slim::Utils::OSDetect;
    our $cache_root;
    sub dirsFor { return $cache_root }
    $INC{'Slim/Utils/OSDetect.pm'} = __FILE__;

    package Slim::Utils::Unicode;
    sub utf8decode_locale { return $_[0] }
    $INC{'Slim/Utils/Unicode.pm'} = __FILE__;

    package Slim::Music::Import;
    sub lastScanTime { return 1234 }

    package Slim::Schema;
    our $dbh;
    sub dbh { return $dbh }
}

use lib "$FindBin::Bin/..";
require Plugins::BlissMixerLab::RepeatIdentitySnapshot;

my $temporary = tempdir(CLEANUP => 1);
$Slim::Utils::OSDetect::cache_root = $temporary;
$Slim::Schema::dbh = DBI->connect('dbi:SQLite:dbname=:memory:', '', '', {
    RaiseError => 1, PrintError => 0,
});
$Slim::Schema::dbh->do(
    'CREATE TABLE tracks (id INTEGER, url TEXT, tracknum INTEGER, urlmd5 TEXT, '
    . 'musicbrainz_id TEXT, primary_artist INTEGER, remote INTEGER, audio INTEGER)'
);
$Slim::Schema::dbh->do(
    'CREATE TABLE contributors (id INTEGER, musicbrainz_id TEXT, name TEXT)'
);
$Slim::Schema::dbh->do(
    'CREATE TABLE contributor_track (role INTEGER, contributor INTEGER, track INTEGER)'
);
$Slim::Schema::dbh->do(
    q{INSERT INTO contributors VALUES }
    . q{(10, '0383dadf-2a4e-4d10-a46a-e9e041da8eb3', 'Queen'), }
    . q{(11, '5441c29d-3602-4898-b1a1-b77fa23b8e50', 'David Bowie')}
);
$Slim::Schema::dbh->do(
    q{INSERT INTO tracks VALUES (1, 'file:///music/Queen/Under%20Pressure.flac', 1, 'hash', 'recording', 10, 0, 1)}
);
$Slim::Schema::dbh->do('INSERT INTO contributor_track VALUES (1, 10, 1), (1, 11, 1)');

my $path = Plugins::BlissMixerLab::RepeatIdentitySnapshot::prepare();
ok(-r $path, 'snapshot is published');
my $snapshot = DBI->connect('dbi:SQLite:dbname=' . $path, '', '', {
    RaiseError => 1, PrintError => 0, sqlite_open_flags => 1,
});
is(
    $snapshot->selectrow_array("SELECT value FROM metadata WHERE key='schema_identity'"),
    'lyrion-track-identities-v1',
    'snapshot declares the shared schema identity',
);
like(
    $snapshot->selectrow_array("SELECT value FROM metadata WHERE key='media_roots_identity'"),
    qr/^[0-9a-f]{64}$/,
    'snapshot is bound to the captured media-root mapping',
);
is(
    $snapshot->selectrow_array('SELECT database_file FROM track_identity'),
    'Queen/Under Pressure.flac',
    'snapshot uses the exact Bliss-relative database file',
);
is_deeply(
    $snapshot->selectcol_arrayref(
        'SELECT canonical_key FROM track_artist_identity ORDER BY canonical_key'
    ),
    [
        'artist-mbid:0383dadf-2a4e-4d10-a46a-e9e041da8eb3',
        'artist-mbid:5441c29d-3602-4898-b1a1-b77fa23b8e50',
    ],
    'snapshot retains every credited track artist by MBID',
);
$snapshot->disconnect;

is(
    Plugins::BlissMixerLab::RepeatIdentitySnapshot::prepare(),
    $path,
    'unchanged scan identity reuses the cached snapshot',
);

done_testing;
