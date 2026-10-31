use strict;
use warnings;

use Digest::SHA qw(sha256_hex);
use File::Spec;
use File::Temp qw(tempdir);
use FindBin;
use JSON::PP ();
use Test::More;

BEGIN {
    eval { require DBI; require DBD::SQLite; 1 }
        or plan skip_all => 'SQLite Perl driver unavailable';
}
use lib "$FindBin::Bin/..";
require 'BlissMixerLab/EssentiaBoundedSnapshot.pm';

sub db {
    my ($path) = @_;
    return DBI->connect("dbi:SQLite:dbname=$path", '', '', {
        RaiseError => 1, PrintError => 0, AutoCommit => 1, sqlite_unicode => 1,
    });
}
my $dir = tempdir(CLEANUP => 1);
my $src = File::Spec->catfile($dir, 'source-features.sqlite');
my $dst = File::Spec->catfile($dir, 'projected.sqlite');
my $writer = db($src);
$writer->do('PRAGMA journal_mode=WAL');
$writer->do('PRAGMA user_version=3');
$writer->do(q{CREATE TABLE feature_models(
    model_key TEXT PRIMARY KEY, preprocessing_version TEXT, aggregation TEXT,
    classes_json TEXT, validated_against_essentia INTEGER)});
$writer->do(q{CREATE TABLE feature_tracks(
    track_file TEXT, model_id TEXT, capability TEXT, model_key TEXT,
    scores_f32_le BLOB, PRIMARY KEY(track_file, model_id))});
my @labels = map { "class$_" } 0..86;
$writer->do('INSERT INTO feature_models VALUES(?,?,?,?,?)', undef,
    'model-v3', 'pcm-v1', 'mean', JSON::PP->new->encode(\@labels), 1);
my @keys = ('seed.flac', 'one.flac', 'two.flac');
my $ins = $writer->prepare('INSERT INTO feature_tracks VALUES(?,?,?,?,?)');
my $original = pack('f<*', (0.25) x 87);
for my $key (@keys, (map { "unrelated/track-$_" } 0..599)) {
    $ins->bind_param(1, $key);
    $ins->bind_param(2, 'genre');
    $ins->bind_param(3, 'genre');
    $ins->bind_param(4, 'model-v3');
    $ins->bind_param(5, $original, DBI::SQL_BLOB());
    $ins->execute;
}
$ins->finish;
$writer->do('PRAGMA wal_checkpoint(TRUNCATE)');
my $source_bytes = -s $src;
my $reader = Plugins::BlissMixerLab::EssentiaBoundedSnapshot::open_source($src);

# A concurrent WAL writer changes the live feature value, not the pinned
# read transaction. The projection must use the pinned original generation.
my $new = pack('f<*', (0.75) x 87);
$writer->do('UPDATE feature_tracks SET scores_f32_le=? WHERE track_file=?',
    undef, $new, 'seed.flac');
my @verified = map {
    { track_id => "file:///music/$_", track_file => $_ }
} @keys;
my $result = Plugins::BlissMixerLab::EssentiaBoundedSnapshot::project_features(
    source_dbh => $reader, verified_tracks => \@verified,
    model_id => 'genre', expected_model_key => 'model-v3', destination => $dst,
);
is($result->{exported_tracks}, 3, 'only host-verified seed and candidates exported');
ok(-f $dst && -s $dst < $source_bytes, 'projected SQLite is smaller than full source');
ok((-s $dst) < 4 * 1024 * 1024, 'private bounded snapshot below 4 MiB');
my $project = db($dst);
is($project->selectrow_array('PRAGMA user_version'), 3, 'native sidecar schema v3 retained');
is($project->selectrow_array('SELECT count(*) FROM feature_tracks'), 3,
   'unrelated tracks not exported');
is($project->selectrow_array('SELECT count(*) FROM feature_models'), 1,
   'only selected model stored');
is($project->selectrow_array(
    "SELECT typeof(scores_f32_le) FROM feature_tracks WHERE track_file='seed.flac'"),
   'blob', 'scores retain SQLite BLOB storage class');
my ($pinned) = $project->selectrow_array(
    "SELECT scores_f32_le FROM feature_tracks WHERE track_file='seed.flac'");
is(unpack('f<', $pinned), 0.25, 'WAL concurrent writer did not contaminate frozen cohort');
my ($live) = $writer->selectrow_array(
    "SELECT scores_f32_le FROM feature_tracks WHERE track_file='seed.flac'");
is(unpack('f<', $live), 0.75, 'source continues to advance independently');
$project->disconnect;
$reader->do('ROLLBACK');
$reader->disconnect;

my $reader2 = Plugins::BlissMixerLab::EssentiaBoundedSnapshot::open_source($src);
my $missing = eval {
    Plugins::BlissMixerLab::EssentiaBoundedSnapshot::project_features(
        source_dbh => $reader2, verified_tracks => [@verified[0,1],
            { track_id => 'missing', track_file => 'missing.flac' }],
        model_id => 'genre', expected_model_key => 'model-v3',
        destination => File::Spec->catfile($dir, 'missing-out.sqlite'));
    1;
};
ok(!$missing, 'missing candidate rejects complete bounded batch');
ok(!-e File::Spec->catfile($dir, 'missing-out.sqlite'),
    'missing cohort never creates output sidecar');
my $mismatch = eval {
    Plugins::BlissMixerLab::EssentiaBoundedSnapshot::project_features(
        source_dbh => $reader2, verified_tracks => \@verified,
        model_id => 'genre', expected_model_key => 'other-model',
        destination => File::Spec->catfile($dir, 'model-out.sqlite'));
    1;
};
ok(!$mismatch, 'unknown model fingerprint rejected');
my $dupe = eval {
    Plugins::BlissMixerLab::EssentiaBoundedSnapshot::project_features(
        source_dbh => $reader2, verified_tracks => [@verified[0,1], $verified[1]],
        model_id => 'genre', expected_model_key => 'model-v3',
        destination => File::Spec->catfile($dir, 'dupe-out.sqlite'));
    1;
};
ok(!$dupe, 'duplicate candidate identity rejected');
$reader2->do('ROLLBACK');
$reader2->disconnect;

# The production source is opened read-only even if the OS permissions are
# writable. Missing databases must never be silently created.
my $absent = File::Spec->catfile($dir, 'not-there.sqlite');
my $bad = eval {
    Plugins::BlissMixerLab::EssentiaBoundedSnapshot::open_source($absent);
    1;
};
ok(!$bad && !-e $absent, 'missing source fails without creating a database');
$writer->disconnect;
done_testing();
