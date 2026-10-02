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
    my $guidanceProviderSections = _guidance_provider_sections();
    $paramRef->{guidance_provider_sections} = $guidanceProviderSections;
    $paramRef->{guidance_provider_section_count} = scalar @{$guidanceProviderSections};
    # Once Library Signals is discovered, its provider-owned section is the
    # single source of truth.  The legacy Lab controls remain only as a
    # compatibility fallback for installations without that provider.
    $paramRef->{legacy_local_signals_visible} = !grep {
        $_->{provider_id} eq 'library-signals'
    } @{$guidanceProviderSections};
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
        my $provider_id = $provider->{provider_id};
        next unless $provider_id;
        my $descriptor = ref($provider->{descriptor}) eq 'HASH'
            ? $provider->{descriptor} : {};
        my $state = Plugins::BlissGuidance::Policy::host_state(
            $all_state, $provider_id,
        );
        my $resolved = Plugins::BlissGuidance::Policy::resolve(
            $provider, $state, {},
        );
        my @controls;
        for my $definition (@{$descriptor->{controls} || []}) {
            next unless ref($definition) eq 'HASH' && $definition->{key};
            my $key = $definition->{key};
            my $origin = $resolved->{origins}{$key} || 'factory_default';
            my $inherited_is_provider = exists $provider->{defaults}{$key};
            push @controls, {
                %$definition,
                effective => $resolved->{effective}{$key},
                origin => $origin,
                origin_label_token => _origin_label_token($origin),
                field_name => _provider_control_name($provider_id, $key),
                inherit_field_name => _provider_inherit_name($provider_id, $key),
                dirty_field_name => _provider_dirty_name($provider_id, $key),
                inherited => $inherited_is_provider
                    ? $provider->{defaults}{$key} : $definition->{factory_default},
                inherited_origin => $inherited_is_provider
                    ? 'provider_default' : 'factory_default',
                inherited_origin_label_token => $inherited_is_provider
                    ? 'BLISSMIXERLAB_GUIDANCE_PROVIDER_ORIGIN_PROVIDER'
                    : 'BLISSMIXERLAB_GUIDANCE_PROVIDER_ORIGIN_FACTORY',
                render_as => $definition->{render_as}
                    || ($definition->{type} eq 'integer' ? 'slider' : ''),
            };
        }
        push @sections, {
            provider_id => $provider_id,
            display_name => $descriptor->{display_name} || $provider_id,
            settings_uri => $descriptor->{settings_uri} || '',
            available => $provider->{available} ? 1 : 0,
            diagnostic => $provider->{diagnostic} || '',
            enabled => $resolved->{enabled} ? 1 : 0,
            policy_valid => $resolved->{valid} ? 1 : 0,
            policy_diagnostic => $resolved->{diagnostic} || '',
            enable_field_name => _provider_enabled_name($provider_id),
            controls => \@controls,
        };
    }
    return \@sections;
}

sub _apply_guidance_provider_settings {
    my $params = shift || {};
    return unless $params->{saveSettings};
    my $discovery = Plugins::BlissGuidance::Discovery::discover();
    my $all_state = _guidance_provider_state();
    my $changed = 0;
    for my $provider (@{$discovery->{providers} || []}) {
        next unless $provider->{available} && $provider->{provider_id};
        my $provider_id = $provider->{provider_id};
        my $enabled_name = _provider_enabled_name($provider_id);
        my $current = Plugins::BlissGuidance::Policy::host_state(
            $all_state, $provider_id,
        );
        my $next = {
            enabled => exists($params->{$enabled_name}) ? 1 : 0,
            overrides => { %{$current->{overrides} || {}} },
        };

        for my $control (@{$provider->{descriptor}{controls} || []}) {
            my $key = $control->{key};
            next unless $key && $control->{host_overridable};
            my $inherit_name = _provider_inherit_name($provider_id, $key);
            my $dirty_name = _provider_dirty_name($provider_id, $key);
            if ($params->{$inherit_name}) {
                delete $next->{overrides}{$key};
                next;
            }
            my $name = _provider_control_name($provider_id, $key);
            next unless exists $params->{$name}
                && (!exists $params->{$dirty_name} || $params->{$dirty_name});
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
sub _provider_dirty_name { return 'dirty_guidance_provider_' . $_[0] . '_' . $_[1]; }

sub _origin_label_token {
    my $origin = shift || '';
    return {
        host_override    => 'BLISSMIXERLAB_GUIDANCE_PROVIDER_ORIGIN_HOST',
        provider_default => 'BLISSMIXERLAB_GUIDANCE_PROVIDER_ORIGIN_PROVIDER',
        factory_default  => 'BLISSMIXERLAB_GUIDANCE_PROVIDER_ORIGIN_FACTORY',
        job_override     => 'BLISSMIXERLAB_GUIDANCE_PROVIDER_ORIGIN_JOB',
    }->{$origin} || 'BLISSMIXERLAB_GUIDANCE_PROVIDER_ORIGIN_FACTORY';
}

1;

__END__
