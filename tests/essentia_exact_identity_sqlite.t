use strict;
use warnings;
use utf8;

use FindBin;
use File::Temp qw(tempdir);
use JSON::PP ();
use Test::More;

BEGIN {
    eval { require DBI; require DBD::SQLite; 1 }
        or plan skip_all => 'DBD::SQLite unavailable (CI installs it)';
}

{
    package SQLiteFixtureTrack;
    sub new { my ($class, $url, $path) = @_; bless {url => $url, path => $path}, $class }
    sub url { $_[0]->{url} }
    sub path { $_[0]->{path} }
}

use lib "$FindBin::Bin/..";
require 'BlissMixerLab/EssentiaExactIdentity.pm';

sub open_db {
    my ($file) = @_;
    return DBI->connect("dbi:SQLite:dbname=$file", '', '', {
        RaiseError => 1, PrintError => 0, AutoCommit => 1,
        sqlite_unicode => 1,
    });
}

my $dir = tempdir(CLEANUP => 1);
my $bliss = open_db("$dir/bliss.db");
my $features = open_db("$dir/features.db");
$bliss->do('CREATE TABLE TracksV2 (File TEXT NOT NULL, Ignore INTEGER)');
$features->do('CREATE TABLE feature_tracks (track_file TEXT NOT NULL)');
my @keys = ('seed.flac', 'Artist/Café.flac', 'other.flac');
my $bliss_insert = $bliss->prepare('INSERT INTO TracksV2 (File, Ignore) VALUES (?, 0)');
my $feature_insert = $features->prepare('INSERT INTO feature_tracks (track_file) VALUES (?)');
for my $key (@keys) {
    $bliss_insert->execute($key);
    $feature_insert->execute($key);
    $feature_insert->execute($key); # Multiple model heads are not ambiguous.
}
$bliss->do('PRAGMA query_only = ON');
$features->do('PRAGMA query_only = ON');
my $verify = Plugins::BlissMixerLab::EssentiaExactIdentity::verifier_from_db_handles(
    $bliss, $features
);
ok($verify->('seed.flac'), 'actual SQLite exact Bliss and Essentia key matches');
ok($verify->('Artist/Café.flac'), 'actual SQLite preserves Unicode key');
ok(!$verify->('Artist/café.flac'), 'actual SQLite rejects case-changed keys');
ok(!$verify->('missing.flac'), 'actual SQLite rejects missing source keys');

my @tracks = (
    SQLiteFixtureTrack->new('file:///music/seed.flac', '/music/seed.flac'),
    SQLiteFixtureTrack->new('file:///music/Artist/Caf%C3%A9.flac',
        '/music/Artist/Café.flac'),
    SQLiteFixtureTrack->new('file:///music/other.flac', '/music/other.flac'),
);
my $artifact = Plugins::BlissMixerLab::EssentiaExactIdentity::write_artifact(
    anchors => [ $tracks[0] ], candidates => [ @tracks[1, 2] ],
    media_dirs => ['/music'], verify_key => $verify,
    directory => $dir, job_id => 'sqlite-real-fixture',
);
ok(-f $artifact->{path}, 'real SQLite verified complete batch produces artifact');
my $bytes = do {
    local $/;
    open my $fh, '<:raw', $artifact->{path} or die $!;
    <$fh>;
};
my $data = JSON::PP->new->utf8->decode($bytes);
is_deeply(
    [map { $_->{track_file} } @{$data->{tracks}}],
    \@keys, 'artifact matches exact real SQLite rows'
);

my $write_allowed = eval {
    $bliss->do("INSERT INTO TracksV2 (File, Ignore) VALUES ('unexpected', 0)");
    1;
};
ok(!$write_allowed, 'read-only SQLite query_only guard prevents Bliss writes');
$write_allowed = eval {
    $features->do("INSERT INTO feature_tracks (track_file) VALUES ('unexpected')");
    1;
};
ok(!$write_allowed, 'read-only SQLite query_only guard prevents sidecar writes');

$bliss->disconnect;
$features->disconnect;
done_testing();
