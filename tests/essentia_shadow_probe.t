use strict;
use warnings;
use utf8;

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
{
    package ShadowTestTrack;
    sub new { my ($class, $name, $path) = @_; bless {name => $name, path => $path}, $class }
    sub url { $_[0]->{name} }
    sub path { $_[0]->{path} }
}
use lib "$FindBin::Bin/..";
require 'BlissMixerLab/EssentiaShadowProbe.pm';

sub new_db {
    my ($path) = @_;
    return DBI->connect("dbi:SQLite:dbname=$path", '', '', {
        AutoCommit => 1, RaiseError => 1, PrintError => 0, sqlite_unicode => 1
    });
}

my $dir = tempdir(CLEANUP => 1);
my $bliss_file = File::Spec->catfile($dir, 'bliss.db');
my $feature_file = File::Spec->catfile($dir, 'essentia.db');
my $bliss = new_db($bliss_file);
my $feature = new_db($feature_file);
$bliss->do('CREATE TABLE TracksV2(File TEXT NOT NULL, Ignore INTEGER)');
$feature->do('PRAGMA user_version=3');
$feature->do(q{
    CREATE TABLE feature_models(
       model_key TEXT PRIMARY KEY, preprocessing_version TEXT,
       aggregation TEXT, classes_json TEXT, validated_against_essentia INTEGER)
});
$feature->do(q{
    CREATE TABLE feature_tracks(
       track_file TEXT NOT NULL, model_id TEXT, capability TEXT,
       model_key TEXT, scores_f32_le BLOB,
       PRIMARY KEY(track_file,model_id))
});
my @class_names = map { "class$_" } 0..86;
$feature->do(
    'INSERT INTO feature_models VALUES (?,?,?,?,?)', undef,
    'test-model-key', 'preprocess-v1', 'mean',
    JSON::PP->new->encode(\@class_names), 1
);
my @keys = ('fictional/seed.flac', 'fictional/one.flac', 'fictional/two.flac');
my $bi = $bliss->prepare('INSERT INTO TracksV2(File,Ignore) VALUES (?,0)');
my $fi = $feature->prepare('INSERT INTO feature_tracks VALUES (?,?,?,?,?)');
for my $i (0..$#keys) {
    my @scores = map { 0.05 + ((($_ + ($i * 10)) * 31) % 83) / 100 } 0..86;
    $bi->execute($keys[$i]);
    $fi->bind_param(1, $keys[$i]);
    $fi->bind_param(2, 'genre');
    $fi->bind_param(3, 'genre');
    $fi->bind_param(4, 'test-model-key');
    $fi->bind_param(5, pack('f<*', @scores), DBI::SQL_BLOB());
    $fi->execute();
}
is($feature->selectrow_array(
    'SELECT typeof(scores_f32_le) FROM feature_tracks LIMIT 1'),
    'blob', 'synthetic Float32LE audio vector has required SQLite BLOB storage');
$bi->finish;
$fi->finish;
$bliss->disconnect;
$feature->disconnect;
my $pre_bliss = do { open my $f, '<:raw', $bliss_file or die $!; local $/; sha256_hex(<$f>) };
my $pre_feature = do { open my $f, '<:raw', $feature_file or die $!; local $/; sha256_hex(<$f>) };
my @tracks = map {
    ShadowTestTrack->new("file:///media/music/$keys[$_]", "/media/music/$keys[$_]")
} 0..2;
my $read_handle = eval {
    Plugins::BlissMixerLab::EssentiaBoundedSnapshot::open_source($bliss_file)
};
diag('read-only source error: ' . $@) unless $read_handle;
ok($read_handle, 'actual SQLite READONLY source transaction without full backup');
$read_handle->do('ROLLBACK') if $read_handle;
$read_handle->disconnect if $read_handle;

my %base = (
    shadow_opt_in => 1,
    bliss_db => $bliss_file,
    feature_db => $feature_file,
    anchors => [$tracks[0]],
    candidates => [@tracks[1,2]],
    media_dirs => ['/media/music'],
    job_id => 'fictional-shadow-1',
    model_id => 'genre',
    metric => 'affine_centered_cosine_v1',
    expected_model_key => 'test-model-key',
);
my $disabled = Plugins::BlissMixerLab::EssentiaShadowProbe::run_shadow(
    %base, shadow_opt_in => 0
);
is($disabled->{reason}, 'NOT_ENABLED', 'manual opt-in required');
my $false_text = Plugins::BlissMixerLab::EssentiaShadowProbe::run_shadow(
    %base, shadow_opt_in => 'false'
);
is($false_text->{reason}, 'NOT_ENABLED', 'string false never activates shadow mode');
ok(!exists($disabled->{candidate_count}), 'disabled status discloses no song identities');
my $missing_binary = Plugins::BlissMixerLab::EssentiaShadowProbe::run_shadow(
    %base, provider_binary => File::Spec->catfile($dir, 'not-installed')
);
is($missing_binary->{reason}, 'SHADOW_PROBE_UNAVAILABLE',
    'missing native binary fails neutrally');
my $no_source = Plugins::BlissMixerLab::EssentiaShadowProbe::run_shadow(
    %base, bliss_db => File::Spec->catfile($dir, 'missing.db'),
    provider_binary => $^X
);
is($no_source->{status}, 'neutral_fallback',
    'missing source must not be created or silently accepted');
ok(!-e File::Spec->catfile($dir, 'missing.db'),
    'read-only source open never creates a database');
my $wrong_model = Plugins::BlissMixerLab::EssentiaShadowProbe::run_shadow(
    %base, model_id => 'unsupported', provider_binary => $^X
);
is($wrong_model->{status}, 'neutral_fallback',
    'unsupported model cannot reach subprocess');

SKIP: {
    my $binary = $ENV{ESSENTIA_SHADOW_PROVIDER_BIN};
    skip 'pinned real native provider binary not configured', 9
        unless defined $binary && -x $binary;

    # Native process control: same known-good fictional feature DB without
    # the backup path, to distinguish original schema vs snapshot semantics.
    my $direct_job = 'direct-fixture-only';
    my $payload = JSON::PP->new->canonical->utf8->encode({
        schema => 'essentia-exact-track-keys-v1', schema_version => 1,
        job_id => $direct_job,
        tracks => [map {
            { track_id => $tracks[$_]->url, track_file => $keys[$_] }
        } 0..2],
    });
    my $identity_file = File::Spec->catfile($dir, 'direct-artifact.json');
    open my $out_file, '>:raw', $identity_file or die $!;
    print {$out_file} $payload;
    close $out_file;
    my @wire = (
        { type => 'describe', spi_version => 2 },
        {
            type => 'prepare', spi_version => 2, job_id => $direct_job,
            options => {
                model_id => 'genre', metric => 'affine_centered_cosine_v1',
                expected_model_key => 'test-model-key',
                experimental_preview_opt_in => JSON::PP::false,
            },
            artifacts => [{
                kind => 'essentia-exact-track-keys-v1',
                path => $identity_file, sha256 => sha256_hex($payload),
            }],
            resources => [{
                kind => 'essentia-feature-sqlite-v3',
                path => $feature_file, access => 'read_only',
            }],
            anchors => [{
                anchor_id => $tracks[0]->url, candidate_id => $tracks[0]->url,
                database_file => $keys[0],
            }],
        },
        {
            type => 'score', spi_version => 2, request_id => 'direct-control',
            context => { scope => 'global', context_track_ids => [$tracks[0]->url] },
            candidates => [map {
                { candidate_id => $tracks[$_]->url, database_file => $keys[$_] }
            } 1..2],
        },
        { type => 'close', spi_version => 2 },
    );
    my $direct_response = eval {
        Plugins::BlissMixerLab::EssentiaShadowProbe::_native_transcript(
            $binary, \@wire
        )
    };
    diag('fictional direct source failure code: ' .
         ($direct_response->[1]{code} || 'none'))
        if $direct_response && $direct_response->[1]{type} ne 'prepared';
    ok($direct_response && $direct_response->[1]{type} eq 'prepared',
        'native SPI accepts original complete fictional SQLite v3 source');

    my $ok = Plugins::BlissMixerLab::EssentiaShadowProbe::run_shadow(
        %base, provider_binary => $binary
    );
    diag('synthetic end-to-end failure phase: ' . ($ok->{phase} || 'none')
        . ', native code: ' . ($ok->{native_code} || 'none'))
        if $ok->{status} ne 'shadow_evaluated_no_active_signals';
    is($ok->{status}, 'shadow_evaluated_no_active_signals',
        'real native SPI v2 with bounded feature projection evaluates features');
    is($ok->{candidate_count}, 2, 'complete host-qualified pool preserved');
    ok(!defined($ok->{reason}), 'successful provider did not require a fallback');
    my $wrong_fp = Plugins::BlissMixerLab::EssentiaShadowProbe::run_shadow(
        %base, expected_model_key => 'wrong-pinned-key', provider_binary => $binary
    );
    is($wrong_fp->{status}, 'neutral_fallback',
        'real model-fingerprint mismatch falls back whole query');
    my $missing_key = Plugins::BlissMixerLab::EssentiaShadowProbe::run_shadow(
        %base, candidates => [
            $tracks[1], ShadowTestTrack->new(
                'file:///media/music/fictional/missing.flac',
                '/media/music/fictional/missing.flac')
        ], provider_binary => $binary
    );
    is($missing_key->{status}, 'neutral_fallback',
        'one missing track rejects the complete native cohort');
    is($missing_key->{reason}, 'SHADOW_PROBE_UNAVAILABLE',
        'missing host join never exposes track paths');
    my $post_bliss = do { open my $f, '<:raw', $bliss_file or die $!; local $/; sha256_hex(<$f>) };
    my $post_feature = do { open my $f, '<:raw', $feature_file or die $!; local $/; sha256_hex(<$f>) };
    is($post_bliss, $pre_bliss, 'original Bliss SQLite bytes unchanged');
    is($post_feature, $pre_feature, 'original Essentia SQLite bytes unchanged');
}
done_testing();
