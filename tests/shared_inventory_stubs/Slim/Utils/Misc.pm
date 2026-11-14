package Slim::Utils::Misc;
use strict;
use warnings;
sub fileURLFromPath {
    my ($path) = @_;
    $path =~ s{ }{%20}g;
    return 'file://' . $path;
}
sub pathFromFileURL {
    my ($url) = @_;
    $url =~ s{\Afile://}{}i;
    $url =~ s/#.*//;
    $url =~ s/%20/ /g;
    return $url;
}
1;
