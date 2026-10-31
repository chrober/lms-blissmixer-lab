use strict;
use warnings;
use FindBin;
use File::Spec;
use File::Temp qw(tempdir);
use Config qw(%Config);
use Test::More;

use lib "$FindBin::Bin/..";
require 'BlissMixerLab/Plugins/BlissGuidance/Runtime.pm';

my $temp = tempdir(CLEANUP => 1);
my $fixture = File::Spec->catfile($temp, 'echo_spi.pl');
open my $fh, '>', $fixture or die $!;
print {$fh} <<'SPI';
use strict;
use warnings;
use JSON::PP qw(encode_json decode_json);
$| = 1;
while (my $line = <STDIN>) {
    my $request = decode_json($line);
    if ($request->{type} eq 'describe') {
        print encode_json({type=>'manifest',spi_version=>2,
            provider_id=>'generic-fixture',provider_version=>'test',
            protocol=>'bliss-guidance-jsonl-v2',capabilities=>[],channels=>[]})."\n";
    } elsif ($request->{type} eq 'prepare') {
        print encode_json({type=>'prepared',provider_id=>'generic-fixture',
            snapshot_id=>'fixture', diagnostics=>{
                anchors_seen=>$request->{anchors},
            }})."\n";
    } elsif ($request->{type} eq 'score') {
        print encode_json({type=>'scores',provider_id=>'generic-fixture',
            request_id=>$request->{request_id},signals=>[]})."\n";
    } elsif ($request->{type} eq 'close') {
        print encode_json({type=>'closed',provider_id=>'generic-fixture'})."\n";
    }
}
SPI
close $fh or die $!;

sub native {
    my ($request) = @_;
    return Plugins::BlissGuidance::Runtime::score_batch({
        id => 'generic-fixture', program => $Config{perlpath},
        argv => [$fixture], options => {}, artifacts => [], resources => [],
    }, {
        job_id => 'lab-vendored-runtime',
        deadline_ms => 500,
        candidates => [{candidate_id=>'candidate-a',lms_urlmd5=>'abcd'}],
        %$request,
    });
}

my $seed = {
    anchor_id => 'seed-1',
    candidate_id => 'file:///test/song.flac',
    lms_urlmd5 => 'ab12',
    database_file => 'song.flac',
};
my $with_anchor = native({
    anchors => [$seed],
    context => {scope=>'global',context_track_ids=>['seed-1'],
        left_anchor_id=>undef,right_anchor_id=>undef},
});
ok($with_anchor->{valid}, 'vendored generic host completes the existing SPI v2 lifecycle');
is_deeply($with_anchor->{prepared}{diagnostics}{anchors_seen}, [$seed],
    'vendored host forwards exact seed identity without provider-specific mapping');
is_deeply($with_anchor->{signals}, [], 'neutral fixture leaves candidate ranking unchanged');

my $without = native({});
ok($without->{valid}, 'legacy request without anchors still works');
is_deeply($without->{prepared}{diagnostics}{anchors_seen}, [],
    'anchor-free guidance remains compatible');

my $wrong_shape = native({anchors=>{anchor_id=>'non-array'}});
ok($wrong_shape->{valid}, 'invalid optional anchor container safely falls back');
is_deeply($wrong_shape->{prepared}{diagnostics}{anchors_seen}, [],
    'non-array anchor container is never passed through');

done_testing();
