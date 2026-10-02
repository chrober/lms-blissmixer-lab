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
    sub set { $values{$_[0]->{name}}{$_[1]} = $_[2] }

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
    sub enabledPlugins { return ('Plugins::LibrarySignals::Plugin') }
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

    package Plugins::LibrarySignals::Plugin;
    sub guidance_provider_descriptor_v1 {
        return {
            protocol_version => 1,
            provider_id => 'library-signals',
            display_name => 'Bliss Guidance: Library Signals',
            settings_uri => 'plugins/LibrarySignals/settings/librarysignals.html',
            capabilities => [qw(play_count last_played library_age)],
            scopes => ['global_candidate'],
            settings_schema_version => 1,
            controls => [
                { key => 'playcount_influence', type => 'integer', minimum => -100, maximum => 100, factory_default => 0, host_overridable => 1, guidance_channel => 'playcount', render_as => 'slider' },
                { key => 'last_played_influence', type => 'integer', minimum => -100, maximum => 100, factory_default => 0, host_overridable => 1, guidance_channel => 'last_played', render_as => 'slider' },
                { key => 'last_played_horizon_days', type => 'integer', minimum => 30, maximum => 1825, factory_default => 180, host_overridable => 1, render_as => 'number' },
                { key => 'library_age_influence', type => 'integer', minimum => -100, maximum => 100, factory_default => 0, host_overridable => 1, guidance_channel => 'library_age', render_as => 'slider' },
                { key => 'library_age_horizon_days', type => 'integer', minimum => 30, maximum => 3650, factory_default => 365, host_overridable => 1, render_as => 'number' },
            ],
            native_spi => {
                provider_id => 'library-signals-guidance', spi_version => 2,
                protocol => 'bliss-guidance-jsonl-v2',
                channels => { play_count => 'playcount', last_played => 'last_played', library_age => 'library_age' },
                artifact_kinds => ['eligible-candidate-identities-v1'], resource_kinds => ['lms-persist-sqlite-v1'],
            },
        };
    }
    sub guidance_provider_defaults_v1 {
        return {
            playcount_influence => 0,
            last_played_influence => 0,
            last_played_horizon_days => 180,
            library_age_influence => 0,
            library_age_horizon_days => 365,
            settings_revision => 1,
        };
    }
    sub guidance_provider_status_v1 { return { available => 1 } }
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
    [qw(learned_blend lastfm_track_guidance_percent lastfm_artist_reranking_strategy lastfm_artist_influence_percent last_played_influence last_played_horizon_days library_age_influence library_age_horizon_days triplets_backup_path)],
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
is(
    $request_host{guidance_provider_sections}->[0]->{provider_id},
    'library-signals',
    'the discoverable Library Signals provider is rendered for an opt-in host',
);
is(
    $request_host{guidance_provider_section_count},
    1,
    'Lab supplies an explicit provider-section count for settings rendering',
);
ok(
    !$request_host{guidance_provider_sections}->[0]->{enabled},
    'a newly discovered provider remains disabled until Lab explicitly enables it',
);
ok(
    exists $request_host{legacy_local_signals_visible},
    'Lab explicitly supplies the legacy-local-signals visibility state',
);
ok(
    !$request_host{legacy_local_signals_visible},
    'a discovered Library Signals provider replaces the legacy direct control group even while disabled',
);
is(
    $request_host{guidance_provider_sections}->[0]->{controls}->[2]->{render_as},
    'number',
    'Lab preserves the provider-declared control presentation',
);
is(
    $request_host{guidance_provider_sections}->[0]->{enable_field_name},
    'pref_guidance_provider_library-signals_enabled',
    'provider enable field follows the shared host contract',
);
my $playcount_control = $request_host{guidance_provider_sections}->[0]->{controls}->[0];
is(
    $playcount_control->{field_name},
    'pref_guidance_provider_library-signals_playcount_influence',
    'provider control field follows the shared host contract',
);
is(
    $playcount_control->{inherit_field_name},
    'inherit_guidance_provider_library-signals_playcount_influence',
    'provider control has Better Call Bliss style inheritance marker',
);
is(
    $playcount_control->{dirty_field_name},
    'dirty_guidance_provider_library-signals_playcount_influence',
    'provider control has Better Call Bliss style dirty marker',
);
is($playcount_control->{origin}, 'provider_default',
    'a new provider control reports its provider setting origin');
is($playcount_control->{origin_label_token},
    'BLISSMIXERLAB_GUIDANCE_PROVIDER_ORIGIN_PROVIDER',
    'provider origin is rendered with the Lab-localized human label');

my %fallback_host;
Plugins::BlissMixerLab::Settings->beforeRender(\%fallback_host);
is(
    $fallback_host{jsonrpc_url},
    'http://127.0.0.1:9000/jsonrpc.js',
    'server address is used only when the request has no host',
);

my %submitted = (
    pref_lastfm_track_guidance_percent => 101,
    pref_lastfm_artist_reranking_strategy => 'invalid',
    pref_lastfm_artist_influence_percent => 101,
    pref_last_played_influence => -101,
    pref_last_played_horizon_days => 1,
    pref_library_age_influence => 101,
    pref_library_age_horizon_days => 10000,
);
Plugins::BlissMixerLab::Settings->handler(undef, \%submitted);
is($submitted{pref_lastfm_track_guidance_percent}, 100,
    'submitted Last.fm track guidance is clamped');
is($submitted{pref_lastfm_artist_reranking_strategy}, 'bounded_influence',
    'submitted artist reranking strategy is constrained to known values');
is($submitted{pref_lastfm_artist_influence_percent}, 100,
    'submitted artist influence is clamped');
is($submitted{pref_last_played_influence}, -100,
    'submitted last-played influence preserves the signed lower bound');
is($submitted{pref_last_played_horizon_days}, 30,
    'submitted last-played horizon preserves the lower bound');
is($submitted{pref_library_age_influence}, 100,
    'submitted library-age influence preserves the signed upper bound');
is($submitted{pref_library_age_horizon_days}, 3650,
    'submitted library-age horizon preserves the upper bound');

$TestSettingsPrefs::values{'plugin.blissmixer'}{playcount_influence} = -80;
$TestSettingsPrefs::values{'plugin.blissmixerlab'}{last_played_influence} = -60;
$TestSettingsPrefs::values{'plugin.blissmixerlab'}{last_played_horizon_days} = 180;
$TestSettingsPrefs::values{'plugin.blissmixerlab'}{library_age_influence} = 70;
$TestSettingsPrefs::values{'plugin.blissmixerlab'}{library_age_horizon_days} = 365;
my %enable_provider = (
    saveSettings => 1,
    'pref_guidance_provider_library-signals_enabled' => 1,
);
Plugins::BlissMixerLab::Settings->handler(undef, \%enable_provider);
my $provider_state = $TestSettingsPrefs::values{'plugin.blissmixerlab'}{guidance_provider_state};
is_deeply(
    $provider_state->{providers}{'library-signals'}{overrides},
    {},
    'first provider enable starts from provider settings like Better Call Bliss',
);

Plugins::BlissMixerLab::Settings->beforeRender(\%request_host);
$playcount_control = $request_host{guidance_provider_sections}->[0]->{controls}->[0];
is($playcount_control->{origin}, 'provider_default',
    'first provider enable visibly inherits the provider setting');

my %save_host_override = (
    saveSettings => 1,
    'pref_guidance_provider_library-signals_enabled' => 1,
    'pref_guidance_provider_library-signals_playcount_influence' => -80,
    'dirty_guidance_provider_library-signals_playcount_influence' => 1,
);
Plugins::BlissMixerLab::Settings->handler(undef, \%save_host_override);
Plugins::BlissMixerLab::Settings->beforeRender(\%request_host);
$playcount_control = $request_host{guidance_provider_sections}->[0]->{controls}->[0];
is($playcount_control->{origin}, 'host_override',
    'an explicitly saved Lab value reports Bliss Mixer Lab setting as its origin');
is($playcount_control->{origin_label_token},
    'BLISSMIXERLAB_GUIDANCE_PROVIDER_ORIGIN_HOST',
    'the Lab override uses the Lab-localized origin annotation');

my %use_inherited_default = (
    saveSettings => 1,
    'pref_guidance_provider_library-signals_enabled' => 1,
    'inherit_guidance_provider_library-signals_playcount_influence' => 1,
    'dirty_guidance_provider_library-signals_playcount_influence' => 0,
);
Plugins::BlissMixerLab::Settings->handler(undef, \%use_inherited_default);
$provider_state = $TestSettingsPrefs::values{'plugin.blissmixerlab'}{guidance_provider_state};
ok(!exists $provider_state->{providers}{'library-signals'}{overrides}{playcount_influence},
    'explicit save after Use inherited default clears the Lab override');

Plugins::BlissMixerLab::Settings->beforeRender(\%request_host);
$playcount_control = $request_host{guidance_provider_sections}->[0]->{controls}->[0];
is($playcount_control->{origin}, 'provider_default',
    'cleared host override returns the visible origin to Provider setting');

my $template = do {
    local $/;
    open my $fh, '<', "$FindBin::Bin/../BlissMixerLab/HTML/EN/plugins/BlissMixerLab/settings/blissmixerlab.html"
        or die "cannot read settings template: $!";
    <$fh>;
};
like($template, qr/guidance_provider_sections/,
    'settings template has a dedicated discoverable-guidance section');
like($template, qr/IF\s+guidance_provider_section_count\s*>\s*0/,
    'settings template gates the discoverable-guidance section on the explicit count');
like($template, qr/provider\.controls/,
    'settings template renders controls from the provider descriptor');
like($template, qr/control\.render_as == 'slider'/,
    'settings template preserves provider slider versus number presentation');
like($template, qr/guidance-providers-section-header/,
    'provider controls use their own collapsible section like Better Call Bliss');
like($template, qr/data-guidance-provider-controls=/,
    'provider enable controls use the Better Call Bliss data contract');
like($template, qr/data-guidance-inherited-field=/,
    'provider controls expose the Better Call Bliss inherited-default contract');
like($template, qr/data-guidance-dirty-marker=/,
    'provider controls expose the Better Call Bliss dirty-marker contract');
like($template, qr/guidance-origin-\[\% control\.field_name/,
    'provider controls render the Better Call Bliss value-origin annotation');
like($template, qr/BLISSMIXERLAB_GUIDANCE_PROVIDER_RESET/,
    'provider reset control uses the same user-facing action as Better Call Bliss');
like($template, qr/bindGuidanceInheritedDefaultButtons\(\)/,
    'provider reset buttons use the Better Call Bliss client-side handler');
like($template, qr/bindGuidanceInheritedMarkers\(\)/,
    'provider controls use the Better Call Bliss dirty-state handler');
like($template, qr/restoreSectionState\('guidance-providers-section', false\)/,
    'provider section restores its collapse state like Better Call Bliss');

done_testing();
