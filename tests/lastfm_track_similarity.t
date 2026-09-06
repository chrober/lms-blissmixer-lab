use strict;
use warnings;
use FindBin;
use Test::More;

BEGIN {
    package main;
    sub INFOLOG () { 0 }
    sub DEBUGLOG () { 0 }

    package TestTrackSimilarityLog;
    sub debug { return }
    sub info { return }
    sub warn { return }

    package Slim::Utils::Log;
    sub logger { return bless {}, 'TestTrackSimilarityLog' }
    $INC{'Slim/Utils/Log.pm'} = __FILE__;

    package Plugins::LastMix::LFM;
    our ($mode, $calls);
    sub getSimilarTracks {
        my ($class, $callback, $args) = @_;
        $calls++;
        die "dispatch failed" if $mode eq 'dispatch_error';
        if ($mode eq 'rate_limit') {
            return $callback->({error => 29, message => 'Rate limit exceeded'});
        }
        if ($mode eq 'single_hash') {
            return $callback->({
                similartracks => {
                    track => {
                        name => 'One Result',
                        match => '0.5',
                        artist => {name => 'Result Artist'},
                    },
                },
            });
        }
        return $callback->({
            similartracks => {
                track => [
                    {
                        name => 'Matched Song',
                        match => '0.90',
                        mbid => 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',
                        artist => {name => 'Matched Artist'},
                    },
                    {
                        name => 'Matched Song',
                        match => '0.40',
                        artist => {name => 'Matched Artist'},
                    },
                    {
                        name => 'Ranked Song',
                        artist => {name => 'Ranked Artist'},
                    },
                ],
            },
        });
    }
    $INC{'Plugins/LastMix/LFM.pm'} = __FILE__;

    package TestSimilarityTrack;
    sub new {
        my ($class, $artist, $title, $mbid) = @_;
        return bless {artist => $artist, title => $title, mbid => $mbid}, $class;
    }
    sub artistName { return $_[0]->{artist} }
    sub title { return $_[0]->{title} }
    sub musicbrainz_id { return $_[0]->{mbid} }
}

use lib "$FindBin::Bin/..";
require Plugins::BlissMixerLab::LastFmTrackSimilarity;

my $seed_mbid = 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb';
my @duplicate_seeds = (
    TestSimilarityTrack->new('Seed Artist', 'Seed Song', $seed_mbid),
    TestSimilarityTrack->new('Seed Artist', 'Seed Song', $seed_mbid),
);
$Plugins::LastMix::LFM::mode = 'fresh';
$Plugins::LastMix::LFM::calls = 0;
my ($matches, $stats);
Plugins::BlissMixerLab::LastFmTrackSimilarity::collect(
    \@duplicate_seeds,
    sub { ($matches, $stats) = @_ },
);
is($Plugins::LastMix::LFM::calls, 1,
    'duplicate seed recordings produce one Last.fm request');
is($stats->{succeeded}, 1, 'successful track request is counted');
is($stats->{failed}, 0, 'successful track request has no failure');
cmp_ok(
    abs($matches->{mbid}->{'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa'} - 0.9),
    '<', 0.000001,
    'valid recording MBID retains full Last.fm support',
);
cmp_ok(
    abs($matches->{name}->{'matched artist|matched song'} - 0.765),
    '<', 0.000001,
    'artist/title fallback applies reduced identity confidence and keeps the strongest duplicate',
);
my $mbid_candidate = TestSimilarityTrack->new(
    'Different Metadata', 'Different Title',
    'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',
);
cmp_ok(
    abs(Plugins::BlissMixerLab::LastFmTrackSimilarity::candidateSupport(
        $mbid_candidate, $matches,
    ) - 0.9),
    '<', 0.000001,
    'candidate matching prefers recording MBID',
);
my $name_candidate = TestSimilarityTrack->new(
    '  MATCHED   ARTIST ', ' Matched Song ', undef,
);
cmp_ok(
    abs(Plugins::BlissMixerLab::LastFmTrackSimilarity::candidateSupport(
        $name_candidate, $matches,
    ) - 0.765),
    '<', 0.000001,
    'candidate matching normalizes artist and title whitespace',
);

$Plugins::LastMix::LFM::mode = 'single_hash';
my $single;
Plugins::BlissMixerLab::LastFmTrackSimilarity::collect(
    [TestSimilarityTrack->new('Other Artist', 'Other Song', undef)],
    sub { $single = shift },
);
ok($single->{name}->{'result artist|one result'},
    'a single-object Last.fm result is accepted');

$Plugins::LastMix::LFM::mode = 'rate_limit';
$Plugins::LastMix::LFM::calls = 0;
my $limited_stats;
Plugins::BlissMixerLab::LastFmTrackSimilarity::collect(
    [
        TestSimilarityTrack->new('Artist A', 'Song A', undef),
        TestSimilarityTrack->new('Artist B', 'Song B', undef),
    ],
    sub { $limited_stats = $_[1] },
);
is($Plugins::LastMix::LFM::calls, 1,
    'service-wide Last.fm error stops remaining track requests');
is_deeply($limited_stats->{error_codes}, ['LASTFM_29'],
    'Last.fm rate-limit error is retained');

$Plugins::LastMix::LFM::mode = 'dispatch_error';
my $dispatch_stats;
Plugins::BlissMixerLab::LastFmTrackSimilarity::collect(
    [TestSimilarityTrack->new('Dispatch Artist', 'Dispatch Song', undef)],
    sub { $dispatch_stats = $_[1] },
);
is($dispatch_stats->{failed}, 1, 'dispatch exception falls back through the callback');
is_deeply($dispatch_stats->{error_codes}, ['LASTMIX_DISPATCH_FAILED'],
    'dispatch exception has a stable diagnostic code');

done_testing();
