use strict;
use warnings;
use FindBin;
use Test::More;

{ package Slim::Utils::Log; our $config; sub addLogCategory { $config = $_[1]; return 1 } }

open my $fh, '<', "$FindBin::Bin/../BlissMixerLab/Plugin.pm" or die $!;
my $source = do { local $/; <$fh> };
close $fh;
my ($registration) = $source =~ /(Slim::Utils::Log->addLogCategory\(\{.*?\}\))/s;
ok($registration, 'plugin has a logging registration');
my $result = eval $registration;
ok(!$@, "logging registration executes: $@");
is($Slim::Utils::Log::config->{category}, 'plugin.blissmixerlab', 'correct category');
is($Slim::Utils::Log::config->{defaultLevel}, 'WARN', 'warning is the default log level');
done_testing();
