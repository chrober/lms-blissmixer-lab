use strict;
use warnings;
use FindBin;
use Test::More;

BEGIN {
    package main;
    sub STATISTICS () { 1 }

    package Slim::Web::Settings;
    sub handler { return $_[2] }
    $INC{'Slim/Web/Settings.pm'} = __FILE__;

    package Slim::Web::HTTP::CSRF;
    sub protectName { return $_[1] }
    sub protectURI { return $_[1] }
    $INC{'Slim/Web/HTTP/CSRF.pm'} = __FILE__;

    package TestSettingsPrefs;
    our %values = (
        'plugin.blissmixerlab' => {},
        'plugin.blissmixer' => {},
        server => {httpport => 9000},
    );
    sub get { return $values{$_[0]->{name}}{$_[1]} }

    package Slim::Utils::Prefs;
    sub preferences { return bless {name => $_[0]}, 'TestSettingsPrefs' }
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
    sub string { return "localized:$_[0]" }
    sub import {
        no strict 'refs';
        *{caller() . '::string'} = \&string;
    }
    $INC{'Slim/Utils/Strings.pm'} = __FILE__;

    package Slim::Utils::Versions;
    sub compareVersions { return 0 }
    $INC{'Slim/Utils/Versions.pm'} = __FILE__;

    package Plugins::BlissMixer::CandidateSelection;
    $INC{'Plugins/BlissMixer/CandidateSelection.pm'} = __FILE__;

    package Plugins::BlissMixer::Plugin;
    sub _lastfmNormalizeArtist { return }
    sub _fetchSimilarArtistsForSeeds { return }
}

use lib "$FindBin::Bin/..";
require Plugins::BlissMixerLab::Settings;

is(Plugins::BlissMixerLab::Settings->name(), 'BLISSMIXERLAB',
    'settings menu uses the catalog-backed plugin name token');
is(
    Plugins::BlissMixerLab::Settings->page(),
    'plugins/BlissMixerLab/settings/blissmixerlab.html',
    'settings page keeps the sidecar route',
);
my (undef, @preference_names) = Plugins::BlissMixerLab::Settings->prefs();
is_deeply(
    \@preference_names,
    [qw(learned_blend lastfm_track_guidance_percent triplets_backup_path)],
    'settings expose only user-meaningful experimental preferences',
);

my %request_host = (host => '192.168.1.111:9000');
Plugins::BlissMixerLab::Settings->beforeRender(\%request_host);
is(
    $request_host{jsonrpc_url},
    'http://192.168.1.111:9000/jsonrpc.js',
    'JSON-RPC uses the browser-facing LMS request host',
);
ok($request_host{upstream_compatible}, 'compatible upstream is reported');
is($request_host{upstream_version}, '0.10.0',
    'the displayed upstream version comes from the live loaded manifest');
ok(!$request_host{no_learner_binary}, 'available sidecar learner is reported');
ok($request_host{lastmix_available}, 'enabled LastMix is reported');
is($request_host{backup_success_text}, 'localized:BLISSMIXERLAB_BACKUP_SUCCESS',
    'dynamic JavaScript messages are localized before rendering');
is($request_host{backup_now_text}, 'localized:BLISSMIXERLAB_BACKUP_NOW',
    'backup button text is localized before rendering like upstream');
is($request_host{learning_start_text},
    'localized:BLISSMIXERLAB_LEARNING_START_TIME',
    'live learner start time label is localized before rendering');
is($request_host{learning_duration_text},
    'localized:BLISSMIXERLAB_LEARNING_DURATION',
    'live learner duration label is localized before rendering');
is($request_host{learning_status_text},
    'localized:BLISSMIXERLAB_LEARNING_STATUS',
    'live learner progress label is localized before rendering');

my %fallback_host;
Plugins::BlissMixerLab::Settings->beforeRender(\%fallback_host);
is(
    $fallback_host{jsonrpc_url},
    'http://127.0.0.1:9000/jsonrpc.js',
    'server address is used only when the request has no host',
);

my %submitted = (
    pref_lastfm_track_guidance_percent => 101,
);
Plugins::BlissMixerLab::Settings->handler(undef, \%submitted);
is($submitted{pref_lastfm_track_guidance_percent}, 100,
    'submitted Last.fm track guidance is clamped');

done_testing();
