use strict;
use warnings;
use FindBin;
use JSON::PP qw(decode_json);
use Test::More;

{
    package GenericSpiTrack;
    sub new { bless { url => $_[1], hash => $_[2] }, $_[0] }
    sub url { $_[0]->{url} }
    sub urlmd5 { $_[0]->{hash} }
}
use lib "$FindBin::Bin/..";
require 'BlissMixerLab/GuidanceProviderAdapter.pm';

my @seed = (GenericSpiTrack->new('file:///music/seed.flac', 'a1'));
my @pool = (
    GenericSpiTrack->new('file:///music/a.flac', 'b2'),
    GenericSpiTrack->new('file:///music/b.flac', 'c3'),
);
my ($config_context, $wire, $artifact_payload, $calls) = (undef, undef, undef, 0);
my $policy = { enabled => 1, valid => 1, effective => {} };
my $provider = { provider_id => 'generic-research' };
my %operation = (
    shadow_opt_in => '1',
    native_config => sub {
        my (undef, undef, $context) = @_;
        $config_context = $context;
        open my $fh, '<', $context->{candidate_identity_artifact}{path} or die $!;
        local $/;
        $artifact_payload = decode_json(<$fh>);
        close $fh;
        return { id => 'generic-research', program => '/test/native-spi' };
    },
    score_batch => sub {
        $calls++;
        (undef, $wire) = @_;
        return { valid => 1, signals => [], diagnostics => { state => 'passive' } };
    },
);
my $disabled = Plugins::BlissMixerLab::GuidanceProviderAdapter::observe_via_spi(
    \@seed, \@pool, $provider, $policy, { %operation, shadow_opt_in => 0 });
is($disabled->{status}, 'neutral', 'observation is disabled without literal opt-in');
is($calls, 0, 'disabled observer never contacts SPI host');
my $false = Plugins::BlissMixerLab::GuidanceProviderAdapter::observe_via_spi(
    \@seed, \@pool, $provider, $policy, { %operation, shadow_opt_in => 'false' });
is($false->{status}, 'neutral', 'string false does not enable observation');

my $result = Plugins::BlissMixerLab::GuidanceProviderAdapter::observe_via_spi(
    \@seed, \@pool, $provider, $policy, \%operation);
is($result->{status}, 'spi_completed_neutral', 'completed SPI exchange does not imply feature evaluation');
is($result->{candidate_count}, 2, 'complete original candidate count preserved');
is($calls, 1, 'observer uses precisely the existing SPI scoring callback');
is($config_context->{candidate_identity_artifact}{kind},
    'eligible-candidate-identities-v1', 'uses the existing generic identity artifact');
is($config_context->{job_id}, $wire->{job_id}, 'job ID shared with provider configuration');
is_deeply([map { $_->{candidate_id} } @{$artifact_payload->{candidates}}],
    [map { $_->url } (@seed, @pool)], 'generic artifact freezes seed and candidates in order');
is_deeply($wire->{context}{context_track_ids}, [$seed[0]->url],
    'same exact seed is the global scoring context');
is($wire->{anchors}[0]{anchor_id}, $seed[0]->url,
    'SPI anchor is the unchanged LMS seed identity');
is_deeply([map { $_->{candidate_id} } @{$wire->{candidates}}],
    [map { $_->url } @pool], 'SPI receives same admitted candidate order');
is($wire->{deadline_ms}, 500, 'provider-neutral bounded deadline is supplied');
ok(!exists($wire->{provider_specific_data}),
    'no out-of-band provider-specific API or payload is added');
ok(!exists($result->{signals}), 'passive result exposes no active score signals');

my $calls_before = $calls;
my $duplicate = Plugins::BlissMixerLab::GuidanceProviderAdapter::observe_via_spi(
    \@seed, [$pool[0], $pool[0]], $provider, $policy, \%operation);
is($duplicate->{status}, 'neutral', 'duplicate admitted candidate fails as one batch');
is($calls, $calls_before, 'invalid cohort does not invoke SPI');
my $missing_identity = Plugins::BlissMixerLab::GuidanceProviderAdapter::observe_via_spi(
    \@seed, [$pool[0], GenericSpiTrack->new('file:///music/unknown', undef)],
    $provider, $policy, \%operation);
is($missing_identity->{status}, 'neutral', 'incomplete generic identity is rejected');
is($calls, $calls_before, 'incomplete cohort never calls provider');
my %active = (%operation, score_batch => sub {
    $calls++;
    return { valid => 1, signals => [{ candidate_id => 'x', score => 1 }] };
});
my $active_result = Plugins::BlissMixerLab::GuidanceProviderAdapter::observe_via_spi(
    \@seed, \@pool, $provider, $policy, \%active);
is($active_result->{status}, 'neutral', 'non-empty active guidance signals rejected by passive observer');
my %broken = (%operation, score_batch => sub { die 'private song/file path'; });
my $broken_result = Plugins::BlissMixerLab::GuidanceProviderAdapter::observe_via_spi(
    \@seed, \@pool, $provider, $policy, \%broken);
is_deeply($broken_result, {status => 'neutral', candidate_count => 0},
    'provider exceptions fail closed without leaking private details');
my $not_allowed = Plugins::BlissMixerLab::GuidanceProviderAdapter::observe_via_spi(
    \@seed, \@pool, $provider, { %$policy, enabled => 0 }, \%operation);
is($not_allowed->{status}, 'neutral', 'provider host policy must explicitly permit call');

done_testing();
