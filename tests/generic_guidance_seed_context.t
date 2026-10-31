use strict;
use warnings;
use FindBin;
use Test::More;

{
    package SeedContextTrack;
    sub new { bless { url=>$_[1], hash=>$_[2], title=>$_[3], mbid=>$_[4] }, $_[0] }
    sub url { $_[0]{url} }
    sub urlmd5 { $_[0]{hash} }
    sub title { $_[0]{title} }
    sub artistName { 'Fixture artist' }
    sub albumname { 'Fixture album' }
    sub musicbrainz_id { $_[0]{mbid} }
    sub artist { undef }
}
use lib "$FindBin::Bin/..";
require 'BlissMixerLab/GuidanceProviderAdapter.pm';

my $adapter = 'Plugins::BlissMixerLab::GuidanceProviderAdapter';
my $seed = SeedContextTrack->new('file:///music/seed.flac', 's01', 'Seed', '11111111-1111-4111-8111-111111111111');
my $second_seed = SeedContextTrack->new('file:///music/other-seed.flac', 's02', 'Second seed', undef);
my $a = SeedContextTrack->new('file:///music/a.flac', 'a01', 'A', undef);
my $b = SeedContextTrack->new('file:///music/b.flac', 'b02', 'B', undef);
my ($anchors, $context_ids) = $adapter->build_seed_context([$seed, $second_seed]);
is_deeply($context_ids, ['seed-1','seed-2'], 'provider-neutral IDs preserve existing Last.fm route token semantics');
is_deeply([map { $_->{candidate_id} } @$anchors],
    [$seed->url, $second_seed->url], 'anchors retain actual Lyrion source URLs');
is_deeply([map { $_->{lms_urlmd5} } @$anchors], ['s01','s02'], 'anchors retain Lyrion hashes');
is($anchors->[0]{recording_mbid}, '11111111-1111-4111-8111-111111111111',
    'Last.fm recording metadata survives shared helper');
is_deeply($adapter->build_seed_context(undef), [], 'optional absent seed list yields no anchors');
my ($holes, $hole_ids) = $adapter->build_seed_context([$seed, undef, $second_seed]);
is_deeply($hole_ids, ['seed-1', 'seed-3'], 'existing Last.fm numbering preserves original seed positions');
is_deeply([map { $_->{candidate_id} } @$holes], [$seed->url, $second_seed->url],
    'ineligible seed cannot become a candidate or replace a valid host seed');

my $policy = {valid=>1,enabled=>1,effective=>{
    playcount_influence=>-80,last_played_influence=>0,library_age_influence=>0,
}};
my @source_candidates = ($a, $b);
my @input_urls = map { $_->url } @source_candidates;
my %seen_requests;
my $library_signals = [
    {candidate_id=>$a->url,channel=>'playcount',score=>-0.5,observation=>{playcount=>3}},
    {candidate_id=>$b->url,channel=>'playcount',score=>0.5,observation=>{playcount=>12}},
];
sub stub_run {
    my ($provider_id, $seeds, $signals, $invalid) = @_;
    my $req;
    my %ops = (
        native_config=>sub { return {id=>$provider_id, program=>'/fixture/never-launched'} },
        score_batch=>sub {
            my ($cfg,$request) = @_;
            $req = $request;
            return {valid=>$invalid ? 0 : 1,signals=>$signals};
        },
    );
    $ops{seeds} = $seeds if defined $seeds;
    my $profile = $adapter->profile_from_provider(
        \@source_candidates, {provider_id=>$provider_id}, $policy, 1000, \%ops);
    return ($profile,$req);
}

my ($existing, $baseline) = stub_run('library-signals-guidance', undef, $library_signals, 0);
ok(!exists($baseline->{anchors}), 'legacy Library Signals request retains its original anchor-free shape');
is_deeply($baseline->{context}{context_track_ids}, [], 'legacy Library Signals source context remains empty');
my ($seeded_library, $library_req) = stub_run('library-signals-guidance', [$seed], $library_signals, 0);
is_deeply($seeded_library, $existing,
    'Library Signals result, weights, ranking inputs and log profile unchanged by optional seed context');
is_deeply($library_req->{context}{context_track_ids}, ['seed-1'],
    'actual DSTM seed may reach a generic provider without affecting Library Signals scoring');
is($library_req->{anchors}[0]{candidate_id}, $seed->url, 'host source bridge preserves real seed URL');
is_deeply($library_req->{candidates}, $baseline->{candidates},
    'seed context never expands or reorders the admitted Bliss candidate batch');

my ($passive, $passive_request) = stub_run(
    'essentia-guidance', [$seed], [], 0);
ok(!$passive->{active}, 'seed-aware research Essentia cannot activate a mixer channel with neutral signals');
is_deeply($passive_request->{context}{context_track_ids}, ['seed-1'],
    'passive Essentia receives the identical generic Last.fm anchor route token');
is($passive_request->{anchors}[0]{candidate_id}, $seed->url,
    'passive Essentia receives host seed identity, not an inferred music feature key');
is_deeply([map { $_->{candidate_id} } @{$passive_request->{candidates}}],
    \@input_urls, 'passive Essentia receives exclusively previously admitted candidates');
my ($failed, $failed_request) = stub_run(
    'essentia-guidance', [$seed], [], 1);
is_deeply($failed, $passive, 'invalid passive provider response degrades to exactly the same neutral mixer profile');
is_deeply([map { $_->url } @source_candidates], \@input_urls,
    'generic seed binding never mutates or reorders the caller candidate list');

done_testing();
