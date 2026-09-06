use strict;
use warnings;
use FindBin;
use Test::More;

BEGIN {
    package main;
    sub STATISTICS () { 0 }

    package Slim::Web::Settings;
    sub handler { return $_[2] }
    $INC{'Slim/Web/Settings.pm'} = __FILE__;

    package Slim::Web::HTTP::CSRF;
    sub protectName { return $_[1] }
    sub protectURI { return $_[1] }
    $INC{'Slim/Web/HTTP/CSRF.pm'} = __FILE__;

    package TestNoStatisticsPrefs;
    our %values = (
        'plugin.blissmixerlab' => {},
        server => {httpport => 9000},
    );
    sub get { return $values{$_[0]->{name}}{$_[1]} }

    package Slim::Utils::Prefs;
    sub preferences { return bless {name => $_[0]}, 'TestNoStatisticsPrefs' }
    sub dir { return '/missing-test-prefs' }
    sub import {
        no strict 'refs';
        *{caller() . '::preferences'} = \&preferences;
    }
    $INC{'Slim/Utils/Prefs.pm'} = __FILE__;

    package Slim::Utils::Misc;
    sub findbin { return '/test/bliss-learner' }
    $INC{'Slim/Utils/Misc.pm'} = __FILE__;

    package Slim::Utils::Network;
    sub serverAddr { return '127.0.0.1' }
    $INC{'Slim/Utils/Network.pm'} = __FILE__;

    package Slim::Utils::OSDetect;
    sub dirsFor { return '/missing-test-prefs' }
    $INC{'Slim/Utils/OSDetect.pm'} = __FILE__;

    package Slim::Utils::PluginManager;
    sub dataForPlugin { return {version => '0.10.0'} }
    sub isEnabled { return 1 }
    $INC{'Slim/Utils/PluginManager.pm'} = __FILE__;

    package Slim::Utils::Strings;
    sub string { return $_[0] }
    sub import {
        no strict 'refs';
        *{caller() . '::string'} = \&string;
    }
    $INC{'Slim/Utils/Strings.pm'} = __FILE__;

    package Slim::Utils::Versions;
    sub compareVersions { return 0 }
    $INC{'Slim/Utils/Versions.pm'} = __FILE__;
}

use lib "$FindBin::Bin/..";
require Plugins::BlissMixerLab::Settings;

my %params;
Plugins::BlissMixerLab::Settings->beforeRender(\%params);
ok(!$params{statistics_enabled},
    'settings report disabled LMS listening statistics');

done_testing();
