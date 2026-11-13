use strict;
use warnings;
use FindBin;
use Test::More tests => 6;
require "$FindBin::Bin/../BlissMixerLab/LibraryPolicy.pm";

my $effective = \&Plugins::BlissMixerLab::LibraryPolicy::effective_christmas_filter;
is($effective->(1, 'christmas-id', ['christmas-id']), 0, 'selected library suppresses Christmas exclusion');
is($effective->(1, 'other-id', ['christmas-id']), 1, 'other libraries retain exclusion');
is($effective->(1, '', ['christmas-id']), 1, 'all tracks retains exclusion');
is($effective->(1, 'christmas-id', []), 1, 'empty exception list retains exclusion');
is($effective->(0, 'other-id', ['christmas-id']), 0, 'disabled upstream filter remains disabled');
is($effective->(1, 'christmas-id', undef), 1, 'malformed settings fail closed');
