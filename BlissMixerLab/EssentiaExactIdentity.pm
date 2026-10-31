package Plugins::BlissMixerLab::EssentiaExactIdentity;

use strict;
use warnings;

use Digest::SHA qw(sha256_hex);
use File::Spec;
use File::Temp qw(tempfile);
use JSON::PP ();

# Deliberately not wired into live DSTM selection. The host must supply
# independently opened, read-only, snapshot-consistent database handles.
# This module never infers identity from urlmd5, artist/title or case folding.
sub verifier_from_db_handles {
    my ($bliss_dbh, $feature_dbh) = @_;
    die 'read-only database handles are required'
        unless $bliss_dbh && $feature_dbh;

    my $bliss = $bliss_dbh->prepare(
        'SELECT COUNT(*) FROM TracksV2 WHERE File = ? COLLATE BINARY AND Ignore IS NOT 1'
    );
    my $features = $feature_dbh->prepare(
        'SELECT EXISTS(SELECT 1 FROM feature_tracks WHERE track_file = ? COLLATE BINARY)'
    );
    die 'exact identity verification unavailable' unless $bliss && $features;

    return sub {
        my ($key) = @_;
        return 0 unless defined $key && length $key;
        my $valid = eval {
            $bliss->execute($key);
            my ($bliss_count) = $bliss->fetchrow_array();
            $features->execute($key);
            my ($feature_present) = $features->fetchrow_array();
            defined $bliss_count && $bliss_count == 1
                && defined $feature_present && $feature_present == 1;
        };
        return $valid ? 1 : 0;
    };
}

# One global anchor and 2..50 already host-admitted candidates.
# All inputs are trusted host-owned objects; the provider owns the second
# check of keys, model fingerprints and actual Essentia feature validity.
sub write_artifact {
    my (%args) = @_;
    my $anchors = $args{anchors};
    my $candidates = $args{candidates};
    my $roots = $args{media_dirs};
    my $verify = $args{verify_key};
    my $job_id = $args{job_id};
    my $directory = $args{directory};
    my $windows = $args{windows} ? 1 : 0;

    die 'one anchor is required'
        unless ref($anchors) eq 'ARRAY' && @$anchors == 1;
    die 'bounded complete candidate list required'
        unless ref($candidates) eq 'ARRAY' && @$candidates >= 2 && @$candidates <= 50;
    die 'trusted media directories required'
        unless ref($roots) eq 'ARRAY' && @$roots && @$roots <= 32;
    die 'exact database verifier required' unless ref($verify) eq 'CODE';
    die 'valid job ID required'
        unless defined($job_id) && $job_id =~ /\A[A-Za-z0-9._:-]{1,128}\z/;
    die 'trusted artifact directory required'
        unless defined($directory) && -d $directory;

    my (%seen_ids, %seen_keys, @tracks);
    for my $track (@$anchors, @$candidates) {
        my ($id, $key) = _exact_file_key($track, $roots, $windows);
        die 'duplicate track identity' if $seen_ids{$id}++;
        die 'ambiguous track key' if $seen_keys{$key}++;
        die 'unverified exact feature identity' unless $verify->($key);
        push @tracks, { track_id => $id, track_file => $key };
    }

    my $bytes = JSON::PP->new->canonical->utf8->encode({
        schema => 'essentia-exact-track-keys-v1',
        schema_version => 1,
        job_id => $job_id,
        tracks => \@tracks,
    });
    die 'identity artifact exceeds provider limit' if length($bytes) > 256 * 1024;

    my ($fh, $path) = tempfile('essentia-exact-keys-XXXXXX',
        DIR => $directory, UNLINK => 0);
    binmode($fh, ':raw');
    my $ok = eval {
        print {$fh} $bytes or die 'cannot write identity artifact';
        close($fh) or die 'cannot close identity artifact';
        1;
    };
    unless ($ok) {
        close($fh);
        unlink($path);
        die 'cannot write identity artifact';
    }
    return {
        kind => 'essentia-exact-track-keys-v1',
        path => $path,
        sha256 => sha256_hex($bytes),
    };
}

sub _exact_file_key {
    my ($track, $roots, $windows) = @_;
    die 'missing track object' unless $track;

    my $id = eval { $track->url };
    my $path = eval { $track->path };
    die 'missing exact local track identity'
        unless defined($id) && length($id) && length($id) <= 4096
            && defined($path) && length($path) && length($path) <= 4096
            && index($id, "\0") == -1 && index($path, "\0") == -1;
    die 'nonlocal LMS source' unless $id =~ /\Afile:\/\//i;
    $path =~ s{\\}{/}g if $windows;
    die 'nonabsolute local track' unless _absolute($path, $windows);

    # TracksV2.File records only a relative path, not which LMS music root
    # originally owned it. Distinct roots can contain the same relative
    # file name. Never treat a two-database key hit as root provenance.
    my %unique_roots;
    for my $root (@$roots) {
        die 'invalid media root' unless defined($root) && length($root);
        my $clean = $root;
        $clean =~ s{\\}{/}g if $windows;
        $clean =~ s{/$}{} unless $clean eq '/';
        die 'invalid media root'
            unless _absolute($clean, $windows)
                && $clean !~ m{(?:\A|/)\.\.?(?:/|\z)};
        $unique_roots{$clean} = 1;
    }
    die 'multi-root provenance unavailable' unless keys(%unique_roots) == 1;

    my %matched;
    for my $root (keys %unique_roots) {
        next unless defined($root) && length($root) && index($root, "\0") == -1;
        my $clean = $root;
        $clean =~ s{\\}{/}g if $windows;
        $clean =~ s{/$}{} unless $clean eq '/';
        next unless _absolute($clean, $windows);
        my $prefix = $clean eq '/' ? '/' : "$clean/";
        next unless index($path, $prefix) == 0;
        my $relative = substr($path, length($prefix));
        next unless length($relative);
        next if $relative =~ m{(?:\A|/)\.\.?(?:/|\z)};
        $matched{$relative} = 1;
    }
    my @keys = keys %matched;
    die 'missing or ambiguous media root' unless @keys == 1;

    my $key = $keys[0];
    if (index($id, '#') >= 0) {
        my @parts = split /#/, $id, -1;
        my $number = eval { $track->tracknum };
        die 'unverified CUE track identity'
            unless @parts == 2 && $parts[1] =~ /\A[0-9]+(?:\.[0-9]+)?-[0-9]+(?:\.[0-9]+)?\z/
                && defined($number) && $number =~ /\A[1-9][0-9]*\z/;
        $key .= '.CUE_TRACK.' . $number;
    }
    return ("$id", $key);
}

sub _absolute {
    my ($path, $windows) = @_;
    return 0 unless defined $path;
    return $path =~ m{\A(?:[A-Za-z]:/|//[^/]+/[^/]+(?:/|\z))} if $windows;
    return $path =~ m{\A/};
}

1;
