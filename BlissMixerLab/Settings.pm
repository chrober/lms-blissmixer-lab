package Plugins::BlissMixerLab::Settings;

#
# Bliss Mixer Lab companion for Lyrion Music Server
#
# Licence: GPL v3
#

use strict;
use base qw(Slim::Web::Settings);

use File::Spec;
use Slim::Utils::Misc;
use Slim::Utils::Network;
use Slim::Utils::OSDetect;
use Slim::Utils::PluginManager;
use Slim::Utils::Prefs;
use Slim::Utils::Strings qw(string);
use Slim::Utils::Versions;

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
}

sub handler {
    my ($class, $client, $paramRef) = @_;
    for my $setting (
        ['pref_learned_blend', 0, 100],
        ['pref_lastfm_track_guidance_percent', 0, 100],
    ) {
        my ($name, $minimum, $maximum) = @$setting;
        next unless defined $paramRef->{$name};
        my $value = int($paramRef->{$name});
        $value = $minimum if $value < $minimum;
        $value = $maximum if $value > $maximum;
        $paramRef->{$name} = $value;
    }
    return $class->SUPER::handler($client, $paramRef);
}

1;

__END__
