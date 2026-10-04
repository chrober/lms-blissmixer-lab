use strict;
use warnings;
use FindBin;
use File::Temp qw(tempdir);
use JSON::PP qw(decode_json);
use Test::More;

{
    package TestTrack;
    sub new { bless { url => $_[1], urlmd5 => $_[2] }, $_[0] }
    sub url { $_[0]->{url} }
    sub urlmd5 { $_[0]->{urlmd5} }
}

use lib "$FindBin::Bin/..";
require 'BlissMixerLab/GuidanceProviderAdapter.pm';

my $profile = Plugins::BlissMixerLab::GuidanceProviderAdapter::profile_from_signals(
    [TestTrack->new('track-a'), TestTrack->new('track-b')],
    {
        playcount_influence => -80,
        last_played_influence => -60,
        last_played_horizon_days => 180,
        library_age_influence => 70,
        library_age_horizon_days => 365,
    },
    [
        { candidate_id => 'track-a', channel => 'playcount', score => -0.5, observation => { playcount => 3 } },
        { candidate_id => 'track-b', channel => 'playcount', score => 0.5, observation => { playcount => 12 } },
        { candidate_id => 'track-a', channel => 'last_played', score => -1, observation => { last_played => 0 } },
        { candidate_id => 'track-b', channel => 'last_played', score => 0.5, observation => { last_played => 100 } },
        { candidate_id => 'track-a', channel => 'library_age', score => -0.75, observation => { added => 50 } },
        { candidate_id => 'track-b', channel => 'library_age', score => 0.25, observation => { added => 200 } },
    ],
    1_000,
);

ok($profile->{active}, 'provider profile activates when configured channels vary');
is($profile->{by_url}->{'track-a'}->{playcount}, 3, 'raw play count is retained for the existing log line');
is($profile->{by_url}->{'track-a'}->{last_played}, 0, 'raw never-played value is retained for the existing log line');
is($profile->{by_url}->{'track-b'}->{added}, 200, 'raw added timestamp is retained for the existing log line');
ok($profile->{by_url}->{'track-a'}->{playcount_weight} > 1,
    'negative play-count influence boosts a lower provider signal');
ok($profile->{by_url}->{'track-a'}->{last_played_weight} > 1,
    'negative last-played influence boosts a never-played provider signal');
ok($profile->{by_url}->{'track-a'}->{library_age_weight} < 1,
    'positive library-age influence penalizes an older provider signal');
is($profile->{last_played_horizon_days}, 180, 'effective last-played horizon is retained');
is($profile->{library_age_horizon_days}, 365, 'effective library-age horizon is retained');

my $artifact_dir = tempdir(CLEANUP => 1);
my $artifact = Plugins::BlissMixerLab::GuidanceProviderAdapter::write_candidate_identity_artifact(
    [
        TestTrack->new('file:///library/a.flac', 'a1'),
        TestTrack->new('file:///library/b.flac', 'b2'),
        TestTrack->new('file:///missing-md5.flac'),
    ],
    $artifact_dir,
);
is($artifact->{kind}, 'eligible-candidate-identities-v1',
    'provider identity artifact declares the trusted eligible-candidate schema');
like($artifact->{sha256}, qr/^[a-f0-9]{64}$/,
    'provider identity artifact is integrity-addressable');
my $artifact_json = do {
    local $/;
    open my $fh, '<', $artifact->{path} or die "cannot read identity artifact: $!";
    <$fh>;
};
my $payload = decode_json($artifact_json);
is_deeply(
    $payload->{candidates},
    [
        { candidate_id => 'file:///library/a.flac', lms_urlmd5 => 'a1' },
        { candidate_id => 'file:///library/b.flac', lms_urlmd5 => 'b2' },
    ],
    'identity artifact contains only DSTM candidates with trusted LMS identities',
);

my ($native_context, $score_request);
my $provider_profile = Plugins::BlissMixerLab::GuidanceProviderAdapter::profile_from_provider(
    [
        TestTrack->new('file:///library/a.flac', 'a1'),
        TestTrack->new('file:///library/b.flac', 'b2'),
    ],
    { provider_id => 'library-signals' },
    {
        valid => 1,
        enabled => 1,
        effective => {
            playcount_influence => -80,
            last_played_influence => -60,
            last_played_horizon_days => 180,
            library_age_influence => 70,
            library_age_horizon_days => 365,
        },
    },
    1_000,
    {
        native_config => sub {
            (undef, undef, $native_context) = @_;
            return { id => 'library-signals-guidance', program => '/trusted/provider' };
        },
        score_batch => sub {
            (undef, $score_request) = @_;
            return {
                valid => 1,
                signals => [
                    { candidate_id => 'file:///library/a.flac', channel => 'playcount', score => -0.5, observation => { playcount => 3 } },
                    { candidate_id => 'file:///library/b.flac', channel => 'playcount', score => 0.5, observation => { playcount => 12 } },
                    { candidate_id => 'file:///library/a.flac', channel => 'last_played', score => -1, observation => { last_played => 0 } },
                    { candidate_id => 'file:///library/b.flac', channel => 'last_played', score => 0.5, observation => { last_played => 100 } },
                    { candidate_id => 'file:///library/a.flac', channel => 'library_age', score => -0.75, observation => { added => 50 } },
                    { candidate_id => 'file:///library/b.flac', channel => 'library_age', score => 0.25, observation => { added => 200 } },
                ],
            };
        },
    },
);
is($native_context->{candidate_identity_artifact}{kind}, 'eligible-candidate-identities-v1',
    'native provider receives only the trusted bounded candidate artifact');
is($native_context->{as_of_unix_seconds}, 1000,
    'native provider receives the host-frozen observation time');
is($score_request->{deadline_ms}, 500,
    'Lab enforces its 500ms complete provider session deadline');
is_deeply(
    $score_request->{candidates},
    [
        { candidate_id => 'file:///library/a.flac', lms_urlmd5 => 'a1' },
        { candidate_id => 'file:///library/b.flac', lms_urlmd5 => 'b2' },
    ],
    'native provider scores the DSTM candidate pool with its trusted Lyrion identities',
);
is($provider_profile->{by_url}{'file:///library/a.flac'}{playcount}, 3,
    'provider results are normalized into the existing local profile');
is($provider_profile->{by_url}{'file:///library/b.flac'}{last_played}, 100,
    'provider last-played observations are retained for the selection log');
is($provider_profile->{by_url}{'file:///library/b.flac'}{added}, 200,
    'provider library-age observations are retained for the selection log');

my $native_host_profile = Plugins::BlissMixerLab::GuidanceProviderAdapter::profile_from_native_result(
    [
        TestTrack->new('file:///library/a.flac', 'a1'),
        TestTrack->new('file:///library/b.flac', 'b2'),
    ],
    {
        playcount_influence => -80,
        last_played_influence => -60,
        last_played_horizon_days => 180,
        library_age_influence => 70,
        library_age_horizon_days => 365,
    },
    {
        valid => 1,
        signals => [
            { candidate_id => 'file:///library/a.flac', channel => 'playcount', score => -0.5, observation => { playcount => 3 } },
            { candidate_id => 'file:///library/b.flac', channel => 'playcount', score => 0.5, observation => { playcount => 12 } },
            { candidate_id => 'file:///library/a.flac', channel => 'last_played', score => -1, observation => { last_played => 0 } },
            { candidate_id => 'file:///library/b.flac', channel => 'last_played', score => 0.5, observation => { last_played => 100 } },
            { candidate_id => 'file:///library/a.flac', channel => 'library_age', score => -0.75, observation => { added => 50 } },
            { candidate_id => 'file:///library/b.flac', channel => 'library_age', score => 0.25, observation => { added => 200 } },
        ],
        selection_trace => {
            trace_version => 'selection_trace_v1',
            provider_id => 'library-signals-guidance',
            host => 'bliss-mixer',
            policy => {},
            candidates => [],
        },
    },
    1_000,
);
is_deeply(
    $native_host_profile,
    $provider_profile,
    'native host response yields byte-for-byte identical Lab profile data for the existing formatter',
);

my $lastfm_profile = Plugins::BlissMixerLab::GuidanceProviderAdapter::lastfm_profile_from_native_result(
    [
        TestTrack->new('file:///library/a.flac', 'a1'),
        TestTrack->new('file:///library/b.flac', 'b2'),
    ],
    {
        valid => 1,
        signals => [
            { candidate_id => 'file:///library/a.flac', channel => 'lastfm_artist', score => 1 },
            { candidate_id => 'file:///library/a.flac', channel => 'lastfm_track', score => 0.6 },
            { candidate_id => 'file:///library/b.flac', channel => 'lastfm_artist', score => 0 },
        ],
    },
);
ok($lastfm_profile->{active},
    'resolved native Last.fm signals activate the Last.fm profile');
is($lastfm_profile->{by_url}{'file:///library/a.flac'}{lastfm_artist_support}, 1,
    'native artist evidence is retained by trusted candidate identity');
is($lastfm_profile->{by_url}{'file:///library/a.flac'}{lastfm_track_support}, 0.6,
    'native track evidence is retained without a Perl LastMix lookup');
is($lastfm_profile->{by_url}{'file:///library/b.flac'}{lastfm_artist_support}, 0,
    'non-endorsed candidates retain a neutral artist signal');
is($lastfm_profile->{artist_match_count}, 1,
    'profile counts candidate artist matches for the unchanged Lab summary format');
is($lastfm_profile->{track_match_count}, 1,
    'profile counts candidate track matches for the unchanged Lab summary format');

my ($lastfm_native_context, $lastfm_score_request);
my $lastfm_provider_profile = Plugins::BlissMixerLab::GuidanceProviderAdapter::lastfm_profile_from_provider(
    [
        TestTrack->new('file:///library/a.flac', 'a1'),
        TestTrack->new('file:///library/b.flac', 'b2'),
    ],
    { provider_id => 'lastfm' },
    { valid => 1, enabled => 1, effective => {} },
    1_000,
    {
        trusted_context => {
            lastfm_relations_artifact => {
                kind => 'resolved-lastfm-evidence-v1', path => '/trusted/evidence.json', sha256 => 'a' x 64,
            },
        },
        context => {
            scope => 'global',
            context_track_ids => ['file:///seed.flac', 'artist:seed'],
        },
        native_config => sub {
            (undef, undef, $lastfm_native_context) = @_;
            return { id => 'lastfm-guidance', program => '/trusted/provider' };
        },
        score_batch => sub {
            (undef, $lastfm_score_request) = @_;
            return {
                valid => 1,
                signals => [
                    { candidate_id => 'file:///library/a.flac', channel => 'lastfm_artist', score => 1 },
                    { candidate_id => 'file:///library/b.flac', channel => 'lastfm_track', score => 0.6 },
                ],
            };
        },
    },
);
is(
    $lastfm_native_context->{lastfm_relations_artifact}{kind},
    'resolved-lastfm-evidence-v1',
    'Last.fm provider receives the acquired and resolved relation artifact',
);
is_deeply(
    $lastfm_score_request->{context}{context_track_ids},
    ['file:///seed.flac', 'artist:seed'],
    'Last.fm provider scores against the host-selected seed context',
);
is($lastfm_provider_profile->{artist_match_count}, 1,
    'native provider scoring supplies artist evidence to the existing Lab profile');
is($lastfm_provider_profile->{track_match_count}, 1,
    'native provider scoring supplies track evidence to the existing Lab profile');

done_testing();
