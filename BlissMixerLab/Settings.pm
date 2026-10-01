package Plugins::BlissMixerLab::Settings;

#
# Bliss Mixer Lab companion for Lyrion Music Server
#
# Licence: GPL v3
#

use strict;
use base qw(Slim::Web::Settings);

use File::Basename qw(dirname);
use File::Spec;
use Slim::Utils::Misc;
use Slim::Utils::Network;
use Slim::Utils::OSDetect;
use Slim::Utils::PluginManager;
use Slim::Utils::Prefs;
use Slim::Utils::Strings qw(string);
use Slim::Utils::Versions;

# The shared host package is vendored below BlissMixerLab/Plugins by
# scripts/sync-guidance-host.ps1.  Keeping it beneath this sidecar makes the
# release self-contained without claiming a package-manager dependency.
use lib dirname(__FILE__);
use Plugins::BlissGuidance::Discovery;
use Plugins::BlissGuidance::Policy;

my $prefs = preferences('plugin.blissmixerlab');
my $serverprefs = preferences('server');

sub name {
    return Slim::Web::HTTP::CSRF->protectName('BLISSMIXERLAB');
}

sub page {
    return Slim::Web::HTTP::CSRF->protectURI('plugins/BlissMixerLab/settings/blissmixerlab.html');
}

sub prefs {
    return ($prefs, 'learned_blend', 'lastfm_track_guidance_percent',
        'lastfm_artist_reranking_strategy', 'lastfm_artist_influence_percent',
        'last_played_influence', 'last_played_horizon_days',
        'library_age_influence', 'library_age_horizon_days',
        'triplets_backup_path');
}

sub beforeRender {
    my ($class, $paramRef) = @_;

    my $dbDir = Slim::Utils::Prefs::dir() || Slim::Utils::OSDetect::dirsFor('prefs');
    my $manifest = Slim::Utils::PluginManager->dataForPlugin('Plugins::BlissMixer::Plugin');
    my $host = $paramRef->{host}
        || (Slim::Utils::Network::serverAddr() . ':' . ($serverprefs->get('httpport') || 9000));

    $paramRef->{jsonrpc_url} = "http://${host}/jsonrpc.js";
    $paramRef->{survey_url} = '/blissmixerlab/survey.html';
    $paramRef->{upstream_enabled} = $manifest ? 1 : 0;
    $paramRef->{upstream_version} = $manifest ? ($manifest->{version} || 'unknown') : '';
    $paramRef->{upstream_compatible} = $manifest
        && Slim::Utils::Versions->compareVersions($manifest->{version} || '0', '0.10.0') >= 0
        && eval { require Plugins::BlissMixer::CandidateSelection; 1 }
        && Plugins::BlissMixer::Plugin->can('_fetchSimilarArtistsForSeeds')
        && Plugins::BlissMixer::Plugin->can('_lastfmNormalizeArtist') ? 1 : 0;
    $paramRef->{database_exists} = -e File::Spec->catfile($dbDir, 'bliss.db') ? 1 : 0;
    $paramRef->{matrix_exists} = -e File::Spec->catfile($dbDir, 'learned_matrix.json') ? 1 : 0;
    $paramRef->{lastmix_available} = Slim::Utils::PluginManager->isEnabled(
        'Plugins::LastMix::Plugin'
    ) ? 1 : 0;
    $paramRef->{no_learner_binary} = !Slim::Utils::Misc::findbin('bliss-learner');
    $paramRef->{learning_start_text} = string('BLISSMIXERLAB_LEARNING_START_TIME');
    $paramRef->{learning_duration_text} = string('BLISSMIXERLAB_LEARNING_DURATION');
    $paramRef->{learning_status_text} = string('BLISSMIXERLAB_LEARNING_STATUS');
    $paramRef->{learning_failed_text} = string('BLISSMIXERLAB_LEARNING_FAILED');
    $paramRef->{restore_in_progress_text} = string('BLISSMIXERLAB_RESTORE_IN_PROGRESS');
    $paramRef->{restore_success_text} = string('BLISSMIXERLAB_RESTORE_SUCCESS');
    $paramRef->{restore_failed_text} = string('BLISSMIXERLAB_RESTORE_FAILED');
    $paramRef->{backup_now_text} = string('BLISSMIXERLAB_BACKUP_NOW');
    $paramRef->{backup_success_text} = string('BLISSMIXERLAB_BACKUP_SUCCESS');
    $paramRef->{backup_failed_text} = string('BLISSMIXERLAB_BACKUP_FAILED');
    $paramRef->{guidance_provider_sections} = _guidance_provider_sections();
    $paramRef->{legacy_local_signals_enabled} = !grep {
        $_->{provider_id} eq 'library-signals' && $_->{enabled}
    } @{$paramRef->{guidance_provider_sections}};
}

sub handler {
    my ($class, $client, $paramRef) = @_;
    for my $setting (
        ['pref_learned_blend', 0, 100],
        ['pref_lastfm_track_guidance_percent', 0, 100],
        ['pref_lastfm_artist_influence_percent', 0, 100],
        ['pref_last_played_influence', -100, 100],
        ['pref_last_played_horizon_days', 30, 1825],
        ['pref_library_age_influence', -100, 100],
        ['pref_library_age_horizon_days', 30, 3650],
    ) {
        my ($name, $minimum, $maximum) = @$setting;
        next unless defined $paramRef->{$name};
        my $value = int($paramRef->{$name});
        $value = $minimum if $value < $minimum;
        $value = $maximum if $value > $maximum;
        $paramRef->{$name} = $value;
    }
    if (defined $paramRef->{pref_lastfm_artist_reranking_strategy}) {
        $paramRef->{pref_lastfm_artist_reranking_strategy} =
            $paramRef->{pref_lastfm_artist_reranking_strategy} eq 'target_share'
            ? 'target_share' : 'bounded_influence';
    }
    _apply_guidance_provider_settings($paramRef);
    return $class->SUPER::handler($client, $paramRef);
}

sub _guidance_provider_sections {
    my $discovery = Plugins::BlissGuidance::Discovery::discover();
    my $all_state = _guidance_provider_state();
    my @sections;
    for my $provider (@{$discovery->{providers} || []}) {
        next unless $provider->{available};
        my $provider_id = $provider->{provider_id};
        my $state = Plugins::BlissGuidance::Policy::host_state(
            $all_state, $provider_id,
        );
        my $resolved = Plugins::BlissGuidance::Policy::resolve(
            $provider, $state, {},
        );
        next unless $resolved->{valid};
        my @controls = map {
            my $control = { %$_ };
            $control->{value} = $resolved->{effective}{$control->{key}};
            $control->{origin} = $resolved->{origins}{$control->{key}};
            $control->{provider_default} = $provider->{defaults}{$control->{key}};
            $control->{host_override} = exists($state->{overrides}{$control->{key}})
                ? 1 : 0;
            $control;
        } @{$provider->{descriptor}{controls} || []};
        push @sections, {
            provider_id => $provider_id,
            display_name => $provider->{descriptor}{display_name},
            settings_uri => $provider->{descriptor}{settings_uri} || '',
            enabled => $resolved->{enabled} ? 1 : 0,
            controls => \@controls,
        };
    }
    return \@sections;
}

sub _apply_guidance_provider_settings {
    my $params = shift || {};
    my $discovery = Plugins::BlissGuidance::Discovery::discover();
    my $all_state = _guidance_provider_state();
    my $changed = 0;
    for my $provider (@{$discovery->{providers} || []}) {
        next unless $provider->{available};
        my $provider_id = $provider->{provider_id};
        my $enabled_name = _provider_enabled_name($provider_id);
        my $current = Plugins::BlissGuidance::Policy::host_state(
            $all_state, $provider_id,
        );
        my $next = {
            enabled => exists($params->{$enabled_name})
                ? ($params->{$enabled_name} ? 1 : 0) : $current->{enabled},
            overrides => { %{$current->{overrides} || {}} },
        };

        # Preserve an existing Lab setup on its first explicit opt-in.  The
        # old preferences remain untouched for the disabled direct fallback.
        if (!$current->{enabled} && $next->{enabled}) {
            $next->{overrides}{playcount_influence} = int(
                preferences('plugin.blissmixer')->get('playcount_influence') || 0
            ) unless exists $next->{overrides}{playcount_influence};
            for my $key (qw(last_played_influence last_played_horizon_days library_age_influence library_age_horizon_days)) {
                $next->{overrides}{$key} = $prefs->get($key)
                    unless exists $next->{overrides}{$key};
            }
        }

        for my $control (@{$provider->{descriptor}{controls} || []}) {
            my $key = $control->{key};
            next unless $key;
            my $inherit_name = _provider_inherit_name($provider_id, $key);
            if ($params->{$inherit_name}) {
                delete $next->{overrides}{$key};
                next;
            }
            my $name = _provider_control_name($provider_id, $key);
            next unless exists $params->{$name};
            $next->{overrides}{$key} = $params->{$name};
        }
        my $resolved = Plugins::BlissGuidance::Policy::resolve($provider, $next, {});
        next unless $resolved->{valid};
        $all_state = Plugins::BlissGuidance::Policy::replace_host_state(
            $all_state, $provider_id, $next,
        );
        $changed = 1;
    }
    $prefs->set('guidance_provider_state', $all_state) if $changed;
}

sub _guidance_provider_state {
    my $state = $prefs->get('guidance_provider_state');
    return ref($state) eq 'HASH' ? $state : { schema_version => 1, providers => {} };
}

sub _provider_enabled_name { return 'pref_guidance_provider_' . $_[0] . '_enabled'; }
sub _provider_control_name { return 'pref_guidance_provider_' . $_[0] . '_' . $_[1]; }
sub _provider_inherit_name { return 'inherit_guidance_provider_' . $_[0] . '_' . $_[1]; }

1;

__END__
