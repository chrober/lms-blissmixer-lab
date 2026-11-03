use strict;
use warnings;
use Test::More;
plan skip_all => 'Node.js is required for option help checks' unless system('node', '--version') == 0;
plan tests => 1;
is(system('node', 'tests/option_help_i18n.js'), 0, 'artist identity help describes each choice in English and German');
