use strict;
use warnings;
use utf8;
use FindBin;
use File::Spec;
use File::Temp qw(tempdir);
use Test::More;
use DBI;

use lib "$FindBin::Bin/..";
require 'BlissMixerLab/BlissFileIdentity.pm';

{
    package IdentityTrack;
    sub new {
        my ($class, $url, $path, $tracknum) = @_;
        return bless {url => $url, path => $path, tracknum => $tracknum}, $class;
    }
    sub url { $_[0]->{url} }
    sub path { $_[0]->{path} }
    sub tracknum { $_[0]->{tracknum} || 0 }
}

my $dir = tempdir(CLEANUP => 1);
my $db_path = File::Spec->catfile($dir, 'bliss.db');
my $db = DBI->connect("dbi:SQLite:dbname=$db_path", '', '', {
    RaiseError => 1, PrintError => 0, sqlite_unicode => 1
});
$db->do('CREATE TABLE TracksV2 (File TEXT, Ignore INTEGER)');
for my $row (
    ['Artist/Album/Track.mp3', undef],
    ['Jürgen/Älbum/Über.flac', undef],
    ['Mixed/Track.mp3', undef],
    ['Disc/Recording.flac.CUE_TRACK.2', undef],
    ['nested/Song.mp3', undef],
    ['Song.mp3', undef],
    ['Ignored.flac', 1],
    ['Track.mp3', undef],
    ['duplicate/track.flac', undef],
    ['duplicate/track.flac', undef],
) {
    $db->do('INSERT INTO TracksV2(File,Ignore) VALUES(?,?)', undef, @$row);
}
$db->disconnect();

my $resolver = Plugins::BlissMixerLab::BlissFileIdentity->open($db_path, ['/music']);
ok($resolver, 'opens Bliss file-key source without mutation');
my $to_key = sub {
    my ($root, $track) = @_;
    my $path = $track->path;
    $path =~ s{\\}{/}g;
    $root =~ s{\\}{/}g;
    $root =~ s{/$}{};
    my $relative = substr($path, length($root));
    $relative =~ s{^/}{};
    if ($track->url =~ /#/ && $track->tracknum) {
        $relative .= '.CUE_TRACK.' . $track->tracknum;
    }
    return $relative;
};
is($resolver->resolve(IdentityTrack->new(
    'file:///music/Artist/Album/Track.mp3','/music/Artist/Album/Track.mp3'
), $to_key), 'Artist/Album/Track.mp3', 'maps the exact root-relative Bliss key');

is($resolver->resolve(IdentityTrack->new(
    'file:///music/J%C3%BCrgen/%C3%84lbum/%C3%9Cber.flac',
    '/music/Jürgen/Älbum/Über.flac'
), $to_key), 'Jürgen/Älbum/Über.flac', 'preserves UTF-8 exact filename key');

is($resolver->resolve(IdentityTrack->new(
    'file:///music/Disc/Recording.flac#00:00',
    '/music/Disc/Recording.flac', 2
), $to_key), 'Disc/Recording.flac.CUE_TRACK.2',
    'resolves the existing CUE_TRACK key, without guessing a new identity');

ok(!defined $resolver->resolve(IdentityTrack->new(
    'file:///music/duplicate/track.flac','/music/duplicate/track.flac'
), $to_key), 'duplicate exact database keys are not treated as unambiguous');
ok(!defined $resolver->resolve(IdentityTrack->new(
    'file:///music/artist/album/Track.mp3','/music/artist/album/Track.mp3'
), $to_key), 'case differences cannot silently match another key');
ok(!defined $resolver->resolve(IdentityTrack->new(
    'file:///music/Ignored.flac','/music/Ignored.flac'
), $to_key), 'excluded Bliss rows are not mapped');
ok(!defined $resolver->resolve(IdentityTrack->new(
    'file:///music/Artist/Missing.flac','/music/Artist/Missing.flac'
), $to_key), 'missing songs are neutral');
ok(!defined $resolver->resolve(IdentityTrack->new(
    'file:///music-other/Track.mp3','/music-other/Track.mp3'
), $to_key), 'media-root prefix collisions are rejected');
ok(!defined $resolver->resolve(IdentityTrack->new(
    'spotify:track:123','/music/Track.mp3'
), $to_key), 'non-file URLs are rejected');
$resolver->close();

my $multiple = Plugins::BlissMixerLab::BlissFileIdentity->open(
    $db_path, ['/music', '/other/music']
);
ok($multiple, 'opens with two distinct media roots');
is($multiple->resolve(IdentityTrack->new(
    'file:///other/music/Mixed/Track.mp3','/other/music/Mixed/Track.mp3'
), $to_key), 'Mixed/Track.mp3', 'finds track under the second library root');
$multiple->close();

my $overlap = Plugins::BlissMixerLab::BlissFileIdentity->open(
    $db_path, ['/music', '/music/nested']
);
ok(!defined $overlap->resolve(IdentityTrack->new(
    'file:///music/nested/Song.mp3','/music/nested/Song.mp3'
), $to_key), 'overlapping roots with two valid Bliss keys are neutral');
$overlap->close();

my $missing = File::Spec->catfile($dir, 'nonexistent.db');
ok(!defined Plugins::BlissMixerLab::BlissFileIdentity->open($missing, ['/music']),
    'never creates a missing Bliss database');
ok(!-e $missing, 'missing input database remains missing');

my $readback = DBI->connect("dbi:SQLite:dbname=$db_path",'','',
    {RaiseError=>1, sqlite_open_flags=>1});
my ($rows) = $readback->selectrow_array('SELECT count(*) FROM TracksV2');
is($rows, 10, 'test source was not changed');
$readback->disconnect();

done_testing();
