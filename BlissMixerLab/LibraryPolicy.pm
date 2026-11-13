package Plugins::BlissMixerLab::LibraryPolicy;

use strict;
use warnings;

sub effective_christmas_filter {
    my ($upstream_filter, $library_id, $exception_ids) = @_;
    my $effective = $upstream_filter ? 1 : 0;
    return $effective unless $effective && defined $library_id && length $library_id;
    return $effective unless ref $exception_ids eq 'ARRAY';
    return 0 if grep { defined $_ && !ref $_ && $_ eq $library_id } @$exception_ids;
    return $effective;
}

1;
