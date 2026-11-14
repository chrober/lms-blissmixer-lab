package Plugins::BlissLibrary::JsonCodec;
use strict;
use warnings;
use JSON::PP ();
my $native = eval { require JSON::XS; 1 };
sub canonical {
    return ($native ? JSON::XS->new : JSON::PP->new)->canonical->utf8;
}
1;
