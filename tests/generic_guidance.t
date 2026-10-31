use strict;
use warnings;
use FindBin;
use Test::More;
use lib "$FindBin::Bin/..";
require 'BlissMixerLab/GenericGuidance.pm';

{
    package GenericGuidanceTrack;
    sub new { bless { url => $_[1], key => $_[2] }, $_[0] }
    sub url { $_[0]->{url} }
    sub urlmd5 { 'aabbccddee' }
    sub path { $_[0]->{key} }
    sub title { 'fixture' }
    sub artistName { 'fixture artist' }
    sub albumname { 'fixture album' }
    sub musicbrainz_id { return undef }
    sub artist { return undef }
}

my $seed = GenericGuidanceTrack->new('file:///library/seed.flac', 'Artist/Seed.flac');
my $a = GenericGuidanceTrack->new('file:///library/a.flac', 'Artist/A.flac');
my $b = GenericGuidanceTrack->new('file:///library/b.flac', 'Artist/B.flac');
my $descriptor = {
    controls => [
        {key=>'genre_influence',type=>'integer',minimum=>-100,maximum=>100,
         guidance_channel=>'genre',guidance_policy=>'bounded_influence'},
        {key=>'mood_influence',type=>'integer',minimum=>-100,maximum=>100,
         guidance_channel=>'mood_theme'},
        {key=>'experimental_value',type=>'integer',minimum=>0,maximum=>200,
         guidance_channel=>'unsupported'},
        {key=>'artist_level',type=>'integer',minimum=>0,maximum=>100,
         guidance_channel=>'artist',guidance_policy=>'target_share_or_bounded'},
    ],
};
my $generic = Plugins::BlissMixerLab::GenericGuidance::provider_channels($descriptor);
is_deeply($generic, {genre=>'genre_influence',mood_theme=>'mood_influence'},
    'new SPI channels are discovered from descriptor controls without hardcoding names');

my $provider = {
    provider_id=>'fresh-provider',available=>1,descriptor=>$descriptor
};
my $resolved = {valid=>1,enabled=>1,effective=>{
    genre_influence=>80,mood_influence=>-40
}};
my $entries = [{provider=>$provider,resolved=>$resolved}];
ok(Plugins::BlissMixerLab::GenericGuidance::has_influence($entries),
    'descriptor-declared nonzero bounded influence permits generic scoring');

my ($config_calls,$score_calls,$received);
my $operations = {
    database_file => sub { $_[0]->path },
    native_config => sub {
        $config_calls++;
        return {id=>'new-guidance',program=>'/trusted/binary'};
    },
    score_batch => sub {
        my ($config,$request,$effective,$source)=@_;
        $score_calls++;
        $received=$request;
        is($source->{provider_id},'fresh-provider',
            'native runtime receives the independently discovered provider');
        return {valid=>1,signals=>[
            {candidate_id=>'file:///library/a.flac',channel=>'genre',score=>0.8},
            {candidate_id=>'file:///library/b.flac',channel=>'genre',score=>-0.8},
            {candidate_id=>'file:///library/a.flac',channel=>'mood_theme',score=>-0.6},
            {candidate_id=>'file:///library/b.flac',channel=>'mood_theme',score=>0.6},
            {candidate_id=>'file:///outside.flac',channel=>'genre',score=>1.0},
            {candidate_id=>'file:///library/a.flac',channel=>'not_declared',score=>1.0},
        ]};
    },
};
my $weighted=Plugins::BlissMixerLab::GenericGuidance::score_enabled_providers(
    $entries,[$seed],[$a,$b],$operations
);
ok($weighted->{active}, 'new provider contributes to candidate selection');
is(scalar(@{$received->{anchors}}),1,'generic host supplies seed anchors');
is($received->{anchors}[0]{database_file},'Artist/Seed.flac',
    'seed carries optional host-scoped database_file');
is($received->{candidates}[1]{database_file},'Artist/B.flac',
    'candidate carries optional host-scoped database_file');
is(scalar(@{$received->{candidates}}),2,
    'provider cannot widen Bliss candidate pool');
is($received->{deadline_ms},500,'generic provider uses existing bounded deadline');
is($config_calls,1,'generic provider config executed once');
is($score_calls,1,'generic provider scored one bounded batch');
ok($weighted->{by_url}{'file:///library/a.flac'}{combined_weight} > 1,
    'genre and mood contributions are independently signed');
ok($weighted->{by_url}{'file:///library/b.flac'}{combined_weight} < 1,
    'second candidate receives the opposite bounded factors');
ok(!exists $weighted->{by_url}{'file:///outside.flac'},
    'external candidate signals are never admitted');
is_deeply($weighted->{providers},['fresh-provider'],'generic diagnostics retain provider identity');

my $off = [{provider=>$provider,resolved=>{valid=>1,enabled=>1,
    effective=>{genre_influence=>0,mood_influence=>0}}}];
ok(!Plugins::BlissMixerLab::GenericGuidance::has_influence($off),
    'neutral influences cannot change any candidate');
my $no_calls = 0;
my $neutral=Plugins::BlissMixerLab::GenericGuidance::score_enabled_providers(
    $off,[$seed],[$a,$b],{
        native_config=>sub {$no_calls++; return {}},
        score_batch=>sub {$no_calls++; return {}},
    }
);
ok(!$neutral->{active},'disabled influence means neutral profile');
is($no_calls,0,'zero-weight provider does not execute');

my $same=Plugins::BlissMixerLab::GenericGuidance::score_enabled_providers(
    [{provider=>$provider,resolved=>{valid=>1,enabled=>1,effective=>{
        genre_influence=>100,mood_influence=>0
    }}}],[],[$a,$b],{
        native_config=>sub {return {}},
        score_batch=>sub {return {valid=>1,signals=>[
            {candidate_id=>$a->url,channel=>'genre',score=>0.9},
            {candidate_id=>$b->url,channel=>'genre',score=>0.9},
        ]}},
    }
);
ok(!$same->{active},'uniform per-head evidence is neutral, not false separation');

my $failure=Plugins::BlissMixerLab::GenericGuidance::score_enabled_providers(
    $entries,[],[$a,$b],{
        native_config=>sub {die 'unavailable provider'},
        score_batch=>sub {die 'must not be reached'},
    }
);
ok(!$failure->{active},'provider exceptions cannot change candidate ranking');

my $invalid=Plugins::BlissMixerLab::GenericGuidance::score_enabled_providers(
    $entries,[],[$a,$b],{
        native_config=>sub {return {}},
        score_batch=>sub {return {valid=>1,signals=>[
            {candidate_id=>$a->url,channel=>'genre',score=>'nan'},
            {candidate_id=>$b->url,channel=>'genre',score=>'inf'},
        ]}},
    }
);
ok(!$invalid->{active},'non-finite signals are neutral');

my $no_confidence=Plugins::BlissMixerLab::GenericGuidance::score_enabled_providers(
    $entries,[],[$a,$b],{
        native_config=>sub {return {}},
        score_batch=>sub {return {valid=>1,signals=>[
            {candidate_id=>$a->url,channel=>'genre',score=>0.9,confidence=>0},
            {candidate_id=>$b->url,channel=>'genre',score=>-0.9,confidence=>0},
        ]}},
    }
);
ok(!$no_confidence->{active}, 'zero-confidence candidate signals remain neutral');

my $bad_confidence=Plugins::BlissMixerLab::GenericGuidance::score_enabled_providers(
    $entries,[],[$a,$b],{
        native_config=>sub {return {}},
        score_batch=>sub {return {valid=>1,signals=>[
            {candidate_id=>$a->url,channel=>'genre',score=>0.9,confidence=>'nan'},
            {candidate_id=>$b->url,channel=>'genre',score=>-0.9,confidence=>2},
        ]}},
    }
);
ok(!$bad_confidence->{active}, 'invalid provider confidence never changes ranking');

done_testing();
