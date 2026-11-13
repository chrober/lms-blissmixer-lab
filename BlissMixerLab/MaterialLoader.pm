package Plugins::BlissMixerLab::MaterialLoader;

use strict;
use warnings;
use File::Basename qw(dirname);
use File::Path qw(make_path);
use File::Temp qw(tempfile);
use Digest::SHA qw(sha256_hex);

my $begin = '// BLISSMIXERLAB MATERIAL LOADER BEGIN';
my $end = '// BLISSMIXERLAB MATERIAL LOADER END';
my $loader = <<'LOADER';
// BLISSMIXERLAB MATERIAL LOADER BEGIN
(function(){var s=document.createElement('script');s.src='/plugins/BlissMixerLab/material-library-sync.js';document.head.appendChild(s)}());
// BLISSMIXERLAB MATERIAL LOADER END
LOADER

sub install {
    my ($path) = @_;
    die "Invalid Material customization path" unless defined $path && length $path;
    die "Material customization is a symlink" if -l $path;
    my $existing = '';
    if (-e $path) {
        open my $in, '<', $path or die "Cannot read Material customization: $!";
        binmode $in; local $/; $existing = <$in>; close $in or die "Cannot close Material customization: $!";
        $existing = '' unless defined $existing;
    }
    my $original = $existing;
    if (index($existing, 'Experimental Material customization; not part of Material or Bliss Mixer Lab.') >= 0) {
        die "Unrecognized standalone Material synchronization prototype; preserve it and migrate manually"
            unless sha256_hex($existing) eq '784fcf433c4377fb9979a95c1fd86fface35eba14d0fe33c13169c8a3d8744b0';
        $existing = '';
    }
    my $has_begin = index($existing, $begin) >= 0;
    my $has_end = index($existing, $end) >= 0;
    die "Malformed Material loader marker" if $has_begin != $has_end;
    if ($has_begin && $has_end) {
        die "Duplicate Material loader marker"
            if index($existing, $begin, index($existing, $begin) + length($begin)) >= 0
                || index($existing, $end, index($existing, $end) + length($end)) >= 0;
        die "Modified Material loader marker" unless index($existing, $loader) >= 0;
        return 1;
    }
    my $dir = dirname($path);
    make_path($dir) unless -d $dir;
    my ($out, $temp) = tempfile('.blissmixerlab-loader-XXXXXX', DIR => $dir, UNLINK => 0);
    binmode $out;
    my $mode = -e $path ? (stat($path))[2] & 07777 : undef;
    my $ok = eval {
        if (-e $path) {
            my ($backup) = tempfile('.blissmixerlab-custom-backup-XXXXXX', DIR => $dir, UNLINK => 0);
            binmode $backup;
            print {$backup} $original or die "Cannot back up Material customization: $!";
            close $backup or die "Cannot close Material backup: $!";
            open my $check, '<', $path or die "Cannot recheck Material customization: $!";
            binmode $check; local $/; my $current = <$check>; close $check;
            $current = '' unless defined $current;
            die "Material customization changed while installing loader" if $current ne $original;
        }
        print {$out} $existing or die "Cannot preserve Material customization: $!";
        print {$out} "\n" if length($existing) && $existing !~ /\n\z/;
        print {$out} ";\n" if length $existing;
        print {$out} $loader or die "Cannot write Material loader: $!";
        close $out or die "Cannot close Material loader: $!";
        chmod $mode, $temp if defined $mode;
        rename $temp, $path or die "Cannot install Material loader: $!";
        1;
    };
    if (!$ok) { my $error = $@; close $out; unlink $temp; die $error }
    return 1;
}

1;
