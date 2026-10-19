use strict;
use warnings;
use FindBin;
use File::Temp qw(tempdir);
use JSON::PP qw(decode_json);
use Test::More;

{
    package TestArtist;
    sub new { bless { mbid => $_[1] }, $_[0] }
    sub musicbrainz_id { $_[0]->{mbid} }

    package TestTrack;
    sub new {
        bless {
            url => $_[1], urlmd5 => $_[2],
            artist_name => $_[3], title => $_[4],
            recording_mbid => $_[5], artist_mbid => $_[6],
        }, $_[0]
    }
    sub url { $_[0]->{url} }
    sub urlmd5 { $_[0]->{urlmd5} }
    sub artistName { $_[0]->{artist_name} }
    sub title { $_[0]->{title} }
    sub albumname { return undef }
    sub musicbrainz_id { $_[0]->{recording_mbid} }
    sub artist { TestArtist->new($_[0]->{artist_mbid}) }
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

my $apc_profile = Plugins::BlissMixerLab::GuidanceProviderAdapter::profile_from_native_result(
    [TestTrack->new('file:///library/a.flac', 'a1')],
    { playcount_influence => -80 },
    {
        valid => 1,
        signals => [
            { candidate_id => 'file:///library/a.flac', channel => 'playcount', score => -0.5, observation => { playcount => 3 } },
        ],
        diagnostics => {
            details => {
                source_by_channel => {
                    playcount => 'alternative_play_count',
                    last_played => 'alternative_play_count',
                    library_age => 'lyrion',
                },
            },
        },
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
    $apc_profile->{guidance_source_provenance},
    {
        provider_id => 'library-signals-guidance',
        source_by_channel => {
            playcount => 'alternative_play_count',
            last_played => 'alternative_play_count',
            library_age => 'lyrion',
        },
    },
    'native provider source provenance is retained for the Lab debug formatter',
);

my ($lastfm_native_context, $lastfm_score_request);
my $lastfm_evidence = Plugins::BlissMixerLab::GuidanceProviderAdapter::lastfm_evidence_from_provider(
    [TestTrack->new(
        'file:///library/seed.flac', 'seed1', 'Seed Artist', 'Seed Song',
        '11111111-1111-4111-8111-111111111111',
        '22222222-2222-4222-8222-222222222222',
    )],
    [TestTrack->new(
        'file:///library/candidate.flac', 'candidate1', 'Candidate Artist',
        'Candidate Song', '33333333-3333-4333-8333-333333333333',
        '44444444-4444-4444-8444-444444444444',
    )],
    { provider_id => 'lastfm' },
    {
        valid => 1,
        enabled => 1,
        effective => {
            source => 'api_key',
            lastfm_track_influence => 75,
            lastfm_artist_mode => 'bounded_influence',
            lastfm_artist_level => 75,
        },
    },
    {
        trusted_context => {
            cache_path => '/trusted/lastfm-cache.json',
            cache_ttl_seconds => 86400,
            request_deadline_ms => 5000,
            max_concurrent_requests => 4,
        },
        native_config => sub {
            (undef, undef, $lastfm_native_context) = @_;
            return {
                id => 'lastfm-guidance', program => '/trusted/provider',
                timeout_ms => 5000,
            };
        },
        score_batch => sub {
            (undef, $lastfm_score_request) = @_;
            return {
                valid => 1,
                signals => [
                    {
                        candidate_id => 'file:///library/candidate.flac',
                        channel => 'lastfm_artist', score => 0.8,
                    },
                    {
                        candidate_id => 'file:///library/candidate.flac',
                        channel => 'lastfm_track', score => 0.6,
                    },
                ],
                diagnostics => { state => 'fresh', request_count => 2, failure_count => 0 },
            };
        },
    },
);
is($lastfm_native_context->{cache_path}, '/trusted/lastfm-cache.json',
    'direct Last.fm native configuration receives only trusted cache context');
is_deeply(
    $lastfm_score_request->{context}{context_track_ids},
    ['seed-1'],
    'direct Last.fm scoring uses the frozen seed anchors as global context',
);
is($lastfm_score_request->{anchors}[0]{recording_mbid},
    '11111111-1111-4111-8111-111111111111',
    'direct Last.fm prepare receives the seed recording MBID');
is_deeply($lastfm_score_request->{anchors}[0]{artist_mbids},
    ['22222222-2222-4222-8222-222222222222'],
    'direct Last.fm prepare receives the seed artist MBID');
is($lastfm_score_request->{candidates}[0]{recording_mbid},
    '33333333-3333-4333-8333-333333333333',
    'direct Last.fm scoring receives candidate identity metadata');
is($lastfm_evidence->{artist_candidates}{'file:///library/candidate.flac'}, 0.8,
    'direct Last.fm artist evidence remains candidate-specific');
is($lastfm_evidence->{track_candidates}{'file:///library/candidate.flac'}, 0.6,
    'direct Last.fm track evidence remains candidate-specific');

done_testing();
