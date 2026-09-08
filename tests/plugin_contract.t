use strict;
use warnings;
use FindBin;
use File::Spec;
use File::Temp qw(tempdir);
use Test::More;
use JSON::PP ();

BEGIN {
    package main;
    sub INFOLOG () { 0 }
    sub DEBUGLOG () { 0 }
    sub WEBUI () { 0 }
    sub ISWINDOWS () { 0 }
    sub ISMAC () { 0 }
    sub STATISTICS () { 1 }

    package TestPrefs;
    our %values = (
        'plugin.blissmixer' => {
            mixer_port => 12000,
            weight_tempo => 4,
            weight_timbre => 30,
            weight_loudness => 9,
            weight_chroma => 57,
            _ts_genre_groups => 1,
            _ts_use_track_genre => 1,
            genre_groups => " Rock ; Hard Rock \n Jazz* ; \n ; Ambient ",
            use_track_genre => 0,
            use_adaptive_weights => 1,
            num_seed_tracks => 3,
            filter_xmas => 1,
            filter_genres => 1,
            min_duration => 30,
            max_duration => 600,
            max_bpm_diff => 20,
            match_all_genres => 0,
            lastfm_weighting_weight => 25,
            playcount_influence => -40,
        },
        'plugin.blissmixerlab' => {
            learned_blend => 50,
            lastfm_track_guidance_percent => 25,
        },
    );
    sub get { return $values{$_[0]->{name}}{$_[1]} }
    sub init { return }
    sub setChange { return }

    package Slim::Utils::Prefs;
    sub preferences { return bless {name => $_[0]}, 'TestPrefs' }
    sub dir { return '/tmp' }
    sub import {
        no strict 'refs';
        *{caller() . '::preferences'} = \&preferences;
    }
    $INC{'Slim/Utils/Prefs.pm'} = __FILE__;

    package TestLog;
    sub warn { return }
    sub info { return }
    sub debug { return }
    sub error { return }
    sub is_info { return 0 }
    sub is_debug { return 0 }

    package Slim::Utils::Log;
    sub addLogCategory { return bless {}, 'TestLog' }
    sub logger { return bless {}, 'TestLog' }
    $INC{'Slim/Utils/Log.pm'} = __FILE__;

    package Slim::Utils::Misc;
    sub addFindBinPaths { return }
    sub findbin { return undef }
    sub getMediaDirs { return ['/music'] }
    $INC{'Slim/Utils/Misc.pm'} = __FILE__;

    package Slim::Utils::OSDetect;
    sub dirsFor { return '/tmp' }
    $INC{'Slim/Utils/OSDetect.pm'} = __FILE__;

    package Slim::Utils::PluginManager;
    our $manifest;
    our $dstm_enabled = 1;
    sub dataForPlugin { return $manifest }
    sub isEnabled { return $dstm_enabled }
    $INC{'Slim/Utils/PluginManager.pm'} = __FILE__;

    package Slim::Utils::Versions;
    sub compareVersions {
        my ($class, $left, $right) = @_;
        my @left = split /\./, $left;
        my @right = split /\./, $right;
        my $last = @left > @right ? $#left : $#right;
        for my $index (0 .. $last) {
            my $comparison = ($left[$index] || 0) <=> ($right[$index] || 0);
            return $comparison if $comparison;
        }
        return 0;
    }
    $INC{'Slim/Utils/Versions.pm'} = __FILE__;

    package Slim::Utils::Strings;
    sub cstring { return $_[1] }
    sub import {
        no strict 'refs';
        *{caller() . '::cstring'} = \&cstring;
    }
    $INC{'Slim/Utils/Strings.pm'} = __FILE__;

    package Slim::Utils::Unicode;
    sub utf8decode_locale { return $_[0] }
    $INC{'Slim/Utils/Unicode.pm'} = __FILE__;

    package LWP::UserAgent;
    sub new { return bless {}, $_[0] }
    sub timeout { return }
    $INC{'LWP/UserAgent.pm'} = __FILE__;

    package Proc::Background;
    sub new { return bless {}, $_[0] }
    sub alive { return 0 }
    sub die { return }
    $INC{'Proc/Background.pm'} = __FILE__;

    package JSON::XS::VersionOneAndTwo;
    sub import {
        no strict 'refs';
        my $caller = caller();
        *{"${caller}::to_json"} = sub { JSON::PP::encode_json($_[0]) };
        *{"${caller}::from_json"} = sub { JSON::PP::decode_json($_[0]) };
    }
    $INC{'JSON/XS/VersionOneAndTwo.pm'} = __FILE__;

    package Plugins::BlissMixer::CandidateSelection;
    our @calls;
    sub candidatePoolMultiplier {
        my ($lastfm, $playcount) = @_;
        return 10 if $lastfm || $playcount;
        return 1;
    }
    sub selectCandidates {
        my ($tracks, $finalCount, $playcount, $artists, $target, $random,
            $extraWeight) = @_;
        push @calls, [@_];
        my @entries;
        my $unknown = 0;
        for my $index (0 .. $#$tracks) {
            my $track = $tracks->[$index];
            my $raw = $track->playcount;
            $unknown++ unless defined $raw;
            my $artist = lc($track->artistName || '');
            $artist =~ s/^\s+|\s+$//g;
            my $entry = {
                track => $track,
                rank => $index + 1,
                playcount => defined $raw ? $raw : 0,
                endorsed => $artists && $artists->{$artist} ? 1 : 0,
                similarity_weight => 1,
                playcount_weight => 1,
                lastfm_weight => 1,
            };
            my $weight = $extraWeight ? $extraWeight->($track, $entry) : 1;
            $entry->{weight} = $weight;
            push @entries, $entry;
        }
        my @selected = sort {
            $b->{weight} <=> $a->{weight} || $a->{rank} <=> $b->{rank}
        } @entries;
        splice(@selected, $finalCount) if @selected > $finalCount;
        return {
            entries => \@entries,
            selected => \@selected,
            pool_size => scalar(@entries),
            reranked => scalar(grep { $_->{weight} != 1 } @entries) ? 1 : 0,
            effective_playcount_influence => $playcount,
            unknown_playcounts => $unknown,
            endorsed_count => scalar(grep { $_->{endorsed} } @entries),
        };
    }
    $INC{'Plugins/BlissMixer/CandidateSelection.pm'} = __FILE__;

    package Plugins::BlissMixer::Plugin;
    sub _lastfmNormalizeArtist {
        my $artist = shift;
        my $normalized = lc($artist || '');
        $normalized =~ s/^\s+|\s+$//g;
        return $normalized;
    }
    sub _fetchSimilarArtistsForSeeds {
        my ($seedInfo, $resultHash, $cb, $stats) = @_;
        $cb->(0, $stats || {succeeded => 1, failed => 0});
    }

    package Plugins::BlissMixerLab::Settings;
    sub new { return bless {}, $_[0] }
    $INC{'Plugins/BlissMixerLab/Settings.pm'} = __FILE__;

    package Plugins::BlissMixerLab::Survey;
    our $matrix_path;
    sub init { return }
    sub shutdown { return }
    sub cliCommand { return }
    sub matrixPath { return $matrix_path }
    $INC{'Plugins/BlissMixerLab/Survey.pm'} = __FILE__;

    package Slim::Plugin::DontStopTheMusic::Plugin;
    our @registered;
    sub registerHandler { push @registered, [$_[1], $_[2]] }
    sub unregisterHandler { return }
    $INC{'Slim/Plugin/DontStopTheMusic/Plugin.pm'} = __FILE__;

    package TestTrack;
    sub new {
        my ($class, $url, $playcount, $artist, $title, $mbid) = @_;
        return bless {
            url => $url,
            playcount => $playcount,
            artist => $artist || 'Artist',
            title => $title || $url,
            mbid => $mbid,
        }, $class;
    }
    sub url { return $_[0]->{url} }
    sub playcount { return $_[0]->{playcount} }
    sub artistName { return $_[0]->{artist} }
    sub title { return $_[0]->{title} }
    sub musicbrainz_id { return $_[0]->{mbid} }
    sub id { return $_[0]->{id} // 42 }
    sub path { return $_[0]->{path} // ('/music/' . $_[0]->{url}) }
    sub tracknum { return 0 }

    package TestRequest;
    sub new { return bless {params => $_[1] || {}}, $_[0] }
    sub getParam { return $_[0]->{params}{$_[1]} }
}

use lib "$FindBin::Bin/..";
require Plugins::BlissMixerLab::Plugin;

$Slim::Utils::PluginManager::manifest = undef;
ok(!Plugins::BlissMixerLab::Plugin::_upstreamCompatible(),
    'missing upstream BlissMixer is rejected');

$Slim::Utils::PluginManager::manifest = {version => '0.9.9'};
ok(!Plugins::BlissMixerLab::Plugin::_upstreamCompatible(),
    'older upstream BlissMixer is rejected');

$Slim::Utils::PluginManager::manifest = {version => '0.10.0'};
ok(Plugins::BlissMixerLab::Plugin::_upstreamCompatible(),
    'minimum supported upstream BlissMixer is accepted');

@Slim::Plugin::DontStopTheMusic::Plugin::registered = ();
Plugins::BlissMixerLab::Plugin->postinitPlugin();
is(scalar @Slim::Plugin::DontStopTheMusic::Plugin::registered, 1,
    'one sidecar DSTM provider is registered');
is($Slim::Plugin::DontStopTheMusic::Plugin::registered[0][0], 'BLISSMIXERLAB_DSTM',
    'the sidecar uses its distinct DSTM provider id');
is(ref $Slim::Plugin::DontStopTheMusic::Plugin::registered[0][1], 'CODE',
    'the sidecar DSTM provider has a callback');

$Slim::Utils::PluginManager::manifest = {version => '0.9.9'};
@Slim::Plugin::DontStopTheMusic::Plugin::registered = ();
Plugins::BlissMixerLab::Plugin->postinitPlugin();
is(scalar @Slim::Plugin::DontStopTheMusic::Plugin::registered, 0,
    'incompatible upstream prevents DSTM registration');

{
    no warnings 'redefine';
    local *Plugins::BlissMixerLab::Plugin::_portAvailable = sub {
        return $_[0] == 12003;
    };
    $TestPrefs::values{'plugin.blissmixer'}{mixer_port} = 12002;
    is(Plugins::BlissMixerLab::Plugin::_availableMixerPort(), 12003,
        'the sidecar automatically selects the first available loopback port');
}

{
    no warnings 'redefine';
    local *Plugins::BlissMixerLab::Plugin::_portAvailable = sub { return 1 };
    $TestPrefs::values{'plugin.blissmixer'}{mixer_port} = 12001;
    is(Plugins::BlissMixerLab::Plugin::_availableMixerPort(), 12002,
        'automatic selection never reuses the configured upstream mixer port');
}

my @default_weights = split /,/, Plugins::BlissMixerLab::Plugin::_weightParam();
is(scalar @default_weights, 23, 'BlissMixer weights expand to all 23 analysis features');
ok(!(grep { abs($_ - 1) > 0.000001 } @default_weights),
    'the upstream default sliders produce neutral per-feature weights');

$TestPrefs::values{'plugin.blissmixer'}{weight_tempo} = 25;
$TestPrefs::values{'plugin.blissmixer'}{weight_timbre} = 25;
$TestPrefs::values{'plugin.blissmixer'}{weight_loudness} = 25;
$TestPrefs::values{'plugin.blissmixer'}{weight_chroma} = 25;
my @custom_weights = split /,/, Plugins::BlissMixerLab::Plugin::_weightParam();
cmp_ok(abs($custom_weights[0] - 6.25), '<', 0.000001,
    'tempo weight is derived from the upstream slider');
cmp_ok(abs($custom_weights[1] - (25 / 30)), '<', 0.000001,
    'timbre feature weights are derived from the upstream slider');

is(Plugins::BlissMixerLab::Plugin::_lastfmTrackWeight(1, 0), 1,
    'zero Last.fm track guidance is neutral');
cmp_ok(abs(Plugins::BlissMixerLab::Plugin::_lastfmTrackWeight(1, 100) - 10),
    '<', 0.000001, 'maximum recording evidence has a bounded tenfold weight');
$TestPrefs::values{'plugin.blissmixerlab'}{lastfm_track_guidance_percent} = 125;
is(Plugins::BlissMixerLab::Plugin::_lastfmTrackGuidance(), 100,
    'Last.fm similar-track guidance is clamped at the positive limit');

is(Plugins::BlissMixerLab::Plugin::_upstreamLastfmProbability(), 25,
    'Last.fm artist probability is inherited from upstream Bliss Mixer');
is(Plugins::BlissMixerLab::Plugin::_upstreamPlayCountInfluence(), -40,
    'play-count influence is inherited from upstream Bliss Mixer');
my @lastfm_track_candidates = (
    TestTrack->new('unmatched', 0, 'Artist', 'Unmatched'),
    TestTrack->new('track-match', 0, 'Artist', 'Matched'),
);
is_deeply(
    Plugins::BlissMixerLab::Plugin::_selectWeightedCandidates(
        \@lastfm_track_candidates,
        1,
        0,
        undef,
        undef,
        sub { 0.5 },
        {mbid => {}, name => {'artist|matched' => 1}},
        100,
        'static weights',
    ),
    ['track-match'],
    'Last.fm recording evidence can promote a matching Bliss candidate',
);
is(
    $Plugins::BlissMixer::CandidateSelection::calls[-1][2],
    0,
    'Lab delegates candidate selection to the upstream component',
);

is(Plugins::BlissMixerLab::Plugin::_databaseRefreshAction(1, 1, 'old', 'new', 0),
    'defer', 'database refresh is deferred while upstream analysis is running');
is(Plugins::BlissMixerLab::Plugin::_databaseRefreshAction(1, 1, 'same', 'same', 0),
    'none', 'analysis alone does not interrupt an existing mixer');
is(Plugins::BlissMixerLab::Plugin::_databaseRefreshAction(0, 1, 'old', 'new', 0),
    'restart', 'a database change outside analysis refreshes the mixer');
is(Plugins::BlissMixerLab::Plugin::_databaseRefreshAction(0, 1, 'same', 'same', 1),
    'restart', 'a deferred refresh runs once after analysis finishes');
is(Plugins::BlissMixerLab::Plugin::_databaseRefreshAction(1, 0, 'old', 'new', 0),
    'none', 'analysis does not prevent an unavailable mixer from starting');

my $selection_log_lines = Plugins::BlissMixerLab::Plugin::_selectionLogLines(
    [
        {
            track => TestTrack->new('bliss-only', 13, 'Ten Years After', 'Here They Come'),
            playcount => 13,
            rank => 2,
            weight => 0.580,
            endorsed => 0,
            track_support => 0,
        },
        {
            track => TestTrack->new('artist-match', 8, 'The Stills-Young Band', 'Midnight on the Bay'),
            playcount => 8,
            rank => 6,
            weight => 3.250,
            endorsed => 1,
            track_support => 0,
        },
        {
            track => TestTrack->new('track-match', 3, 'Johnny Cash', 'You Are My Sunshine'),
            playcount => 3,
            rank => 18,
            weight => 16.965,
            endorsed => 1,
            track_support => 0.765,
        },
        {
            track => TestTrack->new('track-only', 0, 'Track Artist', 'Track Title'),
            playcount => 0,
            rank => 20,
            weight => 2.000,
            endorsed => 0,
            track_support => 0.500,
        },
    ],
    20,
    1,
);
like($selection_log_lines->[0], qr/bliss-only/,
    'combined selection log retains the Bliss-only tier');
like($selection_log_lines->[1], qr/last\.fm-endorsed \(a\)/,
    'combined selection log marks artist endorsement');
like($selection_log_lines->[2], qr/last\.fm-endorsed \(a\+t\)/,
    'combined selection log distinguishes recording plus artist evidence');
like($selection_log_lines->[3], qr/last\.fm-endorsed \(t\)/,
    'combined selection log marks recording-only endorsement');
like($selection_log_lines->[0], qr/^  \[ .* \| playcount=/,
    'selection log keeps padding immediately inside the brackets');
like($selection_log_lines->[0], qr/ similarity-rank\s+2\/20 \] /,
    'selection log keeps the historical space before the closing bracket');
unlike(join("\n", @$selection_log_lines), qr/(?:track-support|weight=)/,
    'informational selection rows omit numeric implementation diagnostics');
my ($leftTierPadding, $rightTierPadding) =
    $selection_log_lines->[0] =~ /^  \[(\s*)bliss-only(\s*)\|/;
ok(length($leftTierPadding) > 1 && length($rightTierPadding) > 1,
    'the shorter Bliss-only label has visible padding on both sides');
cmp_ok(abs(length($leftTierPadding) - length($rightTierPadding)), '<=', 1,
    'the evidence label is centered using the historical algorithm');
my @first_pipes;
my @second_pipes;
my @third_pipes;
my @fourth_pipes;
while ($selection_log_lines->[0] =~ /\|/g) { push @first_pipes, pos($selection_log_lines->[0]) }
while ($selection_log_lines->[1] =~ /\|/g) { push @second_pipes, pos($selection_log_lines->[1]) }
while ($selection_log_lines->[2] =~ /\|/g) { push @third_pipes, pos($selection_log_lines->[2]) }
while ($selection_log_lines->[3] =~ /\|/g) { push @fourth_pipes, pos($selection_log_lines->[3]) }
is_deeply(\@first_pipes, \@second_pipes,
    'combined selection log pipe separators align between Bliss and artist tiers');
is_deeply(\@first_pipes, \@third_pipes,
    'combined selection log pipe separators align for combined evidence');
is_deeply(\@first_pipes, \@fourth_pipes,
    'combined selection log pipe separators align for track evidence too');

my $artist_only_log = Plugins::BlissMixerLab::Plugin::_selectionLogLines(
    [{
        track => TestTrack->new('artist-only', 0, 'Artist', 'Title'),
        rank => 7,
        endorsed => 1,
    }],
    20,
    0,
);
like($artist_only_log->[0],
    qr/^  \[ last\.fm-endorsed \(a\) \| similarity-rank\s+7\/20 \] /,
    'artist-only output retains the historical centered two-column layout');

is_deeply(
    Plugins::BlissMixerLab::Plugin::_genreGroups(),
    [['Rock', 'Hard Rock'], ['Jazz*'], ['Ambient']],
    'genre groups are inherited from BlissMixer and trimmed without losing patterns',
);

my $menu_track = TestTrack->new('seed.flac', 0, 'Seed Artist', 'Seed Title');
my $create_track = Plugins::BlissMixerLab::Plugin::trackInfoHandler(
    undef, undef, $menu_track,
);
is($create_track->{name}, 'BLISSMIXERLAB_CREATE_MIX',
    'track menu exposes Create bliss mix (Lab)');
is_deeply($create_track->{jive}{actions}{go}{cmd}, ['blissmixerlab', 'mix'],
    'Lab mix action uses the sidecar command namespace');
is($create_track->{jive}{actions}{go}{params}{track_id}, 42,
    'track mix action forwards the track id');

my $create_album = Plugins::BlissMixerLab::Plugin::_objectInfoHandler(
    'album', undef, undef, $menu_track,
);
is($create_album->{jive}{actions}{go}{params}{album_id}, 42,
    'album mix action forwards the album id');
my $create_artist = Plugins::BlissMixerLab::Plugin::_objectInfoHandler(
    'artist', undef, undef, $menu_track,
);
is($create_artist->{jive}{actions}{go}{params}{artist_id}, 42,
    'artist mix action forwards the artist id');

my $similar = Plugins::BlissMixerLab::Plugin::similarTracksHandler(
    undef, undef, $menu_track,
);
is($similar->{name}, 'BLISSMIXERLAB_SIMILAR_TRACKS',
    'track menu exposes Similar tracks (Lab)');
is_deeply($similar->{jive}{actions}{go}{cmd}, ['blissmixerlab', 'list'],
    'Lab similarity action uses the sidecar command namespace');
is($similar->{jive}{actions}{go}{params}{byArtist}, 0,
    'general similarity action does not restrict the artist');

my $similar_artist = Plugins::BlissMixerLab::Plugin::similarTracksByArtistHandler(
    undef, undef, $menu_track,
);
is($similar_artist->{name}, 'BLISSMIXERLAB_SIMILAR_TRACKS_BY_ARTIST',
    'track menu exposes Similar tracks by artist (Lab)');
is($similar_artist->{jive}{actions}{go}{params}{byArtist}, 1,
    'artist similarity action carries its artist restriction');
is($similar_artist->{player}{modeParams}{byArtist}, 1,
    'artist restriction is also retained for classic-player navigation');

my $list_data = JSON::PP::decode_json(
    Plugins::BlissMixerLab::Plugin::_getListData($menu_track, 50, 1, 1),
);
is($list_data->{track}, 'seed.flac',
    'similarity request sends the seed path relative to the music folder');
is($list_data->{adaptiveweights}, 1,
    'similarity request respects the configured adaptive strategy');
is($list_data->{learnedblend}, 50,
    'similarity request includes the learned-matrix influence');
is($list_data->{byartist}, 1,
    'similarity request forwards the same-artist restriction');
is($list_data->{filterxmas}, 1,
    'similarity request inherits the upstream Christmas filter');

my $general_request = TestRequest->new({byArtist => 0});
my $artist_request = TestRequest->new({byArtist => 1});
is(
    Plugins::BlissMixerLab::Plugin::_interactiveActionName(
        $general_request, 'mix',
    ),
    'Create bliss mix (Lab)',
    'interactive logging names the Lab mix action',
);
is(
    Plugins::BlissMixerLab::Plugin::_interactiveActionName(
        $general_request, 'list',
    ),
    'Similar tracks (Lab)',
    'interactive logging names the general Lab similarity action',
);
is(
    Plugins::BlissMixerLab::Plugin::_interactiveActionName(
        $artist_request, 'list',
    ),
    'Similar tracks by artist (Lab)',
    'interactive logging names the same-artist Lab similarity action',
);

$Plugins::BlissMixerLab::Survey::matrix_path = undef;
my ($list_strategy, $list_uses_static) =
    Plugins::BlissMixerLab::Plugin::_interactiveStrategy(
        $artist_request, 'list', [$menu_track],
    );
like($list_strategy, qr/static weights.*same artist only.*no learned matrix/,
    'similarity logging reports its effective static fallback accurately');
is($list_uses_static, 1,
    'static fallback is marked for configured-weight logging');

my $strategy_matrix_dir = tempdir(CLEANUP => 1);
my $strategy_matrix = File::Spec->catfile($strategy_matrix_dir, 'matrix.json');
open my $strategy_matrix_fh, '>', $strategy_matrix
    or die "Cannot create $strategy_matrix: $!";
print {$strategy_matrix_fh} "{}\n";
close $strategy_matrix_fh;
$Plugins::BlissMixerLab::Survey::matrix_path = $strategy_matrix;
($list_strategy, $list_uses_static) =
    Plugins::BlissMixerLab::Plugin::_interactiveStrategy(
        $general_request, 'list', [$menu_track],
    );
like($list_strategy, qr/learned matrix.*all artists.*single-seed/,
    'similarity logging reports learned-matrix selection accurately');
is($list_uses_static, 0,
    'learned-matrix selection does not claim to use static weights');
$Plugins::BlissMixerLab::Survey::matrix_path = undef;

is(Plugins::BlissMixerLab::Plugin->title(), 'BlissMixerLab',
    'plugin identity remains distinct from upstream');

my $migration_dir = tempdir(CLEANUP => 1);
my $legacy_matrix = File::Spec->catfile($migration_dir, 'blissmixer-lab-matrix.json');
my $canonical_matrix = File::Spec->catfile($migration_dir, 'learned_matrix.json');
open my $legacy_fh, '>', $legacy_matrix or die "Cannot create $legacy_matrix: $!";
print {$legacy_fh} "legacy matrix\n";
close $legacy_fh;
is(
    Plugins::BlissMixerLab::Plugin::_migrateLearningFile(
        $legacy_matrix, $canonical_matrix,
    ),
    'migrated',
    'an Lab-specific learning file is migrated to its canonical filename',
);
ok(-e $canonical_matrix, 'the migrated canonical learning file exists');
ok(!-e $legacy_matrix, 'the successfully migrated legacy file is gone');

open my $canonical_fh, '>', $canonical_matrix
    or die "Cannot replace $canonical_matrix: $!";
print {$canonical_fh} "canonical matrix\n";
close $canonical_fh;
open $legacy_fh, '>', $legacy_matrix or die "Cannot recreate $legacy_matrix: $!";
print {$legacy_fh} "other matrix\n";
close $legacy_fh;
is(
    Plugins::BlissMixerLab::Plugin::_migrateLearningFile(
        $legacy_matrix, $canonical_matrix,
    ),
    'conflict',
    'an existing canonical learning file is never overwritten',
);
ok(-e $legacy_matrix, 'a conflicting legacy file is left untouched');

done_testing();
