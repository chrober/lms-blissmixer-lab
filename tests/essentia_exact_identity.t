use strict;
use warnings;
use utf8;

use Digest::SHA qw(sha256_hex);
use File::Temp qw(tempdir);
use FindBin;
use JSON::PP ();
use Test::More;

{
    package ExactTestTrack;
    sub new { my ($class, %data) = @_; bless \%data, $class }
    sub url { $_[0]->{url} }
    sub path { $_[0]->{path} }
    sub tracknum { $_[0]->{tracknum} }

    package ExactTestDB;
    sub new { my ($class, $kind, $keys) = @_; bless { kind => $kind, keys => $keys }, $class }
    sub prepare {
        my ($self, $sql) = @_;
        die 'SQL must use exact binary match' unless $sql =~ /COLLATE BINARY/;
        die 'unexpected table' if $self->{kind} eq 'bliss' && $sql !~ /TracksV2/;
        die 'unexpected table' if $self->{kind} eq 'features' && $sql !~ /feature_tracks/;
        return bless { db => $self }, 'ExactTestStatement';
    }

    package ExactTestStatement;
    sub execute { $_[0]->{key} = $_[1]; 1 }
    sub fetchrow_array {
        my $self = shift;
        my $n = $self->{db}->{keys}{$self->{key}} || 0;
        return ($self->{db}->{kind} eq 'features' ? ($n > 0 ? 1 : 0) : $n);
    }
}

use lib "$FindBin::Bin/..";
require 'BlissMixerLab/EssentiaExactIdentity.pm';

my $module = 'Plugins::BlissMixerLab::EssentiaExactIdentity';
my $seed = ExactTestTrack->new(
    url => 'file:///mnt/music/seed.flac', path => '/mnt/music/seed.flac'
);
my $unicode = ExactTestTrack->new(
    url => 'file:///mnt/music/Artist/Caf%C3%A9.flac',
    path => '/mnt/music/Artist/Café.flac'
);
my $cue = ExactTestTrack->new(
    url => 'file:///mnt/music/album.flac#35-70',
    path => '/mnt/music/album.flac', tracknum => 2
);
my @keys = ('seed.flac', 'Artist/Café.flac', 'album.flac.CUE_TRACK.2');
my $bliss = ExactTestDB->new('bliss', { map { $_ => 1 } @keys });
my $features = ExactTestDB->new('features', { map { $_ => 4 } @keys });
my $verify = Plugins::BlissMixerLab::EssentiaExactIdentity::verifier_from_db_handles(
    $bliss, $features
);
my $temp = tempdir(CLEANUP => 1);
my %args = (
    anchors => [$seed], candidates => [$unicode, $cue],
    media_dirs => ['/mnt/music'], verify_key => $verify,
    job_id => 'test-job-123', directory => $temp,
);

my $artifact = Plugins::BlissMixerLab::EssentiaExactIdentity::write_artifact(%args);
is($artifact->{kind}, 'essentia-exact-track-keys-v1', 'provider-compatible kind');
like($artifact->{sha256}, qr/\A[a-f0-9]{64}\z/, 'content-addressed artifact');
my $bytes = do {
    local $/;
    open my $fh, '<:raw', $artifact->{path} or die $!;
    <$fh>;
};
is(sha256_hex($bytes), $artifact->{sha256}, 'hash covers actual artifact bytes');
my $doc = JSON::PP->new->utf8->decode($bytes);
is($doc->{schema}, 'essentia-exact-track-keys-v1', 'schema matches native provider');
is($doc->{schema_version}, 1, 'schema version pinned');
is($doc->{job_id}, 'test-job-123', 'job-bound artifact');
is_deeply(
    [map { $_->{track_file} } @{$doc->{tracks}}],
    \@keys, 'exact Unicode and CUE track identities are preserved'
);
is_deeply(
    [map { $_->{track_id} } @{$doc->{tracks}}],
    [$seed->url, $unicode->url, $cue->url], 'host-owned opaque track IDs retained'
);
my $mode = (stat($artifact->{path}))[2] & 0777;
is($mode & 0077, 0, 'artifact inaccessible to group/other');

sub rejects {
    my ($name, %overrides) = @_;
    my %actual = (%args, %overrides);
    my $before = scalar glob("$temp/essentia-exact-keys-*");
    my $success = eval {
        Plugins::BlissMixerLab::EssentiaExactIdentity::write_artifact(%actual);
        1;
    };
    ok(!$success, $name);
    return;
}

rejects('missing feature row fails closed',
    verify_key => sub { $_[0] ne 'Artist/Café.flac' && $verify->($_[0]) });
rejects('missing Bliss row fails closed',
    verify_key => Plugins::BlissMixerLab::EssentiaExactIdentity::verifier_from_db_handles(
        ExactTestDB->new('bliss', { 'seed.flac' => 1, 'Artist/Café.flac' => 1 }),
        $features,
    ));
rejects('ambiguous duplicated Bliss rows fail closed',
    verify_key => Plugins::BlissMixerLab::EssentiaExactIdentity::verifier_from_db_handles(
        ExactTestDB->new('bliss', { map { $_ => ($_ eq 'seed.flac' ? 2 : 1) } @keys }),
        $features,
    ));
rejects('overlapping roots are ambiguous',
    media_dirs => ['/mnt', '/mnt/music']);
rejects('distinct music roots lack authoritative ownership provenance',
    media_dirs => ['/mnt/music', '/mnt/other-library']);
rejects('missing root boundary cannot match',
    media_dirs => ['/mnt/mus']);
rejects('case mismatch is not silently folded',
    media_dirs => ['/mnt/Music']);
rejects('no path traversal is permitted',
    candidates => [
        ExactTestTrack->new(url => 'file:///mnt/music/../seed.flac',
            path => '/mnt/music/../seed.flac'),
        $cue,
    ]);
rejects('duplicate candidate IDs cause whole-query fallback',
    candidates => [$unicode, $unicode]);
rejects('duplicate file keys with different IDs fail',
    candidates => [
        $unicode,
        ExactTestTrack->new(url => 'file:///different-url', path => '/mnt/music/Artist/Café.flac'),
    ]);
rejects('nonlocal stream does not acquire a file key',
    candidates => [
        ExactTestTrack->new(url => 'spotify:track:123', path => 'spotify:track:123'),
        $cue,
    ]);
rejects('remote URL cannot masquerade as a local path',
    candidates => [
        ExactTestTrack->new(url => 'spotify:track:123', path => '/mnt/music/seed.flac'),
        $cue,
    ]);
rejects('nonnumeric CUE URL fragment cannot acquire a local feature key',
    candidates => [
        $unicode,
        ExactTestTrack->new(url => 'file:///mnt/music/album.flac#unrelated',
            path => '/mnt/music/album.flac', tracknum => 2),
    ]);
rejects('CUE fragment without a verified index fails',
    candidates => [
        $unicode,
        ExactTestTrack->new(url => 'file:///mnt/music/album.flac#35-70',
            path => '/mnt/music/album.flac'),
    ]);
rejects('candidate pool shorter than native minimum fails',
    candidates => [$unicode]);
rejects('two anchors are not accepted as single global context',
    anchors => [$seed, $cue]);
rejects('missing trusted verification callback fails',
    verify_key => undef);

my $windows_seed = ExactTestTrack->new(
    url => 'file:///C:/Music/seed.flac', path => 'C:\Music\seed.flac'
);
my $windows_one = ExactTestTrack->new(
    url => 'file:///C:/Music/Artist/Caf%C3%A9.flac',
    path => 'C:\Music\Artist\Café.flac'
);
my $windows_two = ExactTestTrack->new(
    url => 'file:///C:/Music/album.flac#35-70',
    path => 'C:\Music\album.flac', tracknum => 2
);
my $win = Plugins::BlissMixerLab::EssentiaExactIdentity::write_artifact(
    %args, anchors => [$windows_seed], candidates => [$windows_one, $windows_two],
    media_dirs => ['C:\Music'], windows => 1,
);
ok(-f $win->{path}, 'Windows separators handled without case or Unicode folding');

my $unc_seed = ExactTestTrack->new(
    url => 'file:////NAS/Media/seed.flac', path => '\\\\NAS\Media\seed.flac'
);
my $unc_one = ExactTestTrack->new(
    url => 'file:////NAS/Media/Artist/Caf%C3%A9.flac',
    path => '\\\\NAS\Media\Artist\Café.flac'
);
my $unc_two = ExactTestTrack->new(
    url => 'file:////NAS/Media/album.flac#35-70',
    path => '\\\\NAS\Media\album.flac', tracknum => 2
);
my $unc = Plugins::BlissMixerLab::EssentiaExactIdentity::write_artifact(
    %args, anchors => [$unc_seed], candidates => [$unc_one, $unc_two],
    media_dirs => ['\\\\NAS\Media'], windows => 1,
);
ok(-f $unc->{path}, 'Windows UNC share root supports exact identity proof');
rejects('Windows drive case mismatch fails safely',
    anchors => [$windows_seed], candidates => [$windows_one, $windows_two],
    media_dirs => ['c:\Music'], windows => 1);

done_testing();
