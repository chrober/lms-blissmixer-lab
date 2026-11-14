package Plugins::BlissLibrary::FileIdentity;
use strict;
use warnings;
use Encode qw(decode FB_CROAK);
use URI::Escape qw(uri_unescape);
use Slim::Utils::Misc;
use Slim::Utils::Unicode;

sub _text {
    my ($value) = @_;
    return $value if !defined($value) || utf8::is_utf8($value);
    my $bytes = $value;
    my $text = eval { decode('UTF-8', $bytes, FB_CROAK) };
    return $text unless $@;
    return Slim::Utils::Unicode::utf8decode_locale($value);
}

sub database_file_for_url {
    my ($url, $tracknum, $roots) = @_;
    return undef unless ref($roots) eq 'ARRAY';
    return make_mapper($roots)->($url, $tracknum);
}

sub make_mapper {
    my ($roots) = @_;
    my $aliases = make_alias_mapper($roots);
    return sub { $aliases->(@_)->[0] };
}

sub make_alias_mapper {
    my ($roots) = @_;
    die 'Media roots must be an array' unless ref($roots) eq 'ARRAY';
    my @descriptors;
    for my $root (sort { length($b) <=> length($a) } grep { defined($_) && length($_) } @$roots) {
        my $prefix = Slim::Utils::Misc::fileURLFromPath($root);
        $prefix =~ s{/+$}{} if defined $prefix;
        my $normalized = $root;
        $normalized =~ s{\\}{/}g;
        $normalized =~ s{/+$}{};
        push @descriptors, {prefix => $prefix, root => $normalized};
    }
    return sub { _map_urls($_[0], $_[1], \@descriptors) };
}

sub _map_urls {
    my ($url, $tracknum, $descriptors) = @_;
    return [] unless defined($url) && $url =~ /^file:/i;
    my (@files, %seen);
    my $file_url = $url;
    $file_url =~ s/#.*$//;
    for my $descriptor (@$descriptors) {
        my $prefix = $descriptor->{prefix};
        next unless defined($prefix) && length($prefix);
        my $boundary = $prefix eq 'file:' ? 'file:///' : "$prefix/";
        next unless index($file_url, $boundary) == 0;
        my $relative = _text(uri_unescape(substr($file_url, length($boundary))));
        $relative .= '.CUE_TRACK.' . $tracknum if $url =~ /#/ && $tracknum;
        push @files, $relative unless $seen{$relative}++;
    }
    return \@files if @files;
    my $path = Slim::Utils::Misc::pathFromFileURL($url);
    return \@files unless defined $path;
    $path =~ s{\\}{/}g;
    for my $descriptor (@$descriptors) {
        my $normalized = $descriptor->{root};
        next unless index($path, "$normalized/") == 0;
        my $relative = _text(substr($path, length($normalized) + 1));
        $relative .= '.CUE_TRACK.' . $tracknum if $url =~ /#/ && $tracknum;
        push @files, $relative unless $seen{$relative}++;
    }
    return \@files;
}
1;
