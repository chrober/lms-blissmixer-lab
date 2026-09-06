use strict;
use warnings;
use FindBin;
use File::Spec;
use File::Temp qw(tempdir);
use Test::More;

BEGIN {
    package main;
    sub INFOLOG () { 0 }
    sub DEBUGLOG () { 0 }

    package TestSurveyPrefs;
    our %values;
    sub get { return $values{$_[1]} }

    package Slim::Utils::Prefs;
    sub preferences { return bless {}, 'TestSurveyPrefs' }
    sub import {
        no strict 'refs';
        *{caller() . '::preferences'} = \&preferences;
    }
    $INC{'Slim/Utils/Prefs.pm'} = __FILE__;

    package TestLearnerProcess;
    sub alive { return 1 }
    sub die { return }

    package Proc::Background;
    our @arguments;
    sub new {
        my $class = shift;
        @arguments = @_;
        return bless {}, 'TestLearnerProcess';
    }
    $INC{'Proc/Background.pm'} = __FILE__;

    package TestSurveyLog;
    sub warn { return }
    sub info { return }
    sub debug { return }
    sub error { return }

    package Slim::Utils::Log;
    sub logger { return bless {}, 'TestSurveyLog' }
    sub import {
        no strict 'refs';
        *{caller() . '::logger'} = \&logger;
    }
    $INC{'Slim/Utils/Log.pm'} = __FILE__;

    package Slim::Utils::Misc;
    our $learner_binary = '/test/bliss-learner';
    sub findbin { return $learner_binary }
    $INC{'Slim/Utils/Misc.pm'} = __FILE__;

    package Slim::Utils::Timers;
    sub killTimers { return }
    sub setTimer { return }
    $INC{'Slim/Utils/Timers.pm'} = __FILE__;

    package Slim::Web::Pages;
    our @handlers;
    sub addRawFunction { push @handlers, [$_[1], $_[2]] }
    $INC{'Slim/Web/Pages.pm'} = __FILE__;

    package Plugins::BlissMixerLab::Plugin;
    our $analyser_running = 0;
    our $mixer_stop_count = 0;
    sub _originalAnalyserRunning { return $analyser_running }
    sub _stopMixer { $mixer_stop_count++ }
    $INC{'Plugins/BlissMixerLab/Plugin.pm'} = __FILE__;
}

use lib "$FindBin::Bin/..";
require Plugins::BlissMixerLab::Survey;

my $temporary = tempdir(CLEANUP => 1);
my $database = File::Spec->catfile($temporary, 'bliss.db');
my $matrix = File::Spec->catfile($temporary, 'learned_matrix.json');
my $triplets = File::Spec->catfile($temporary, 'training_triplets.json');
$TestSurveyPrefs::values{triplets_backup_path} = $temporary;
$TestSurveyPrefs::values{httpport} = 9123;

Plugins::BlissMixerLab::Survey::init($database, $matrix, $triplets);
is(Plugins::BlissMixerLab::Survey::matrixPath(), $matrix,
    'survey exposes the canonical learned matrix path');
is(scalar @Slim::Web::Pages::handlers, 2,
    'survey page and API handlers are registered');

my $training = [
    ['one.flac', 'two.flac', 'three.flac'],
    ['four.flac', 'five.flac', 'six.flac'],
];
Plugins::BlissMixerLab::Survey::_saveTriplets($training);
is(Plugins::BlissMixerLab::Survey::_countTriplets(), 2,
    'saved survey rounds can be counted');
is_deeply(Plugins::BlissMixerLab::Survey::_loadTriplets(), $training,
    'survey triplets round-trip through JSON storage');

my ($backup_ok, $backup_error) = Plugins::BlissMixerLab::Survey::_backupTriplets();
ok($backup_ok, 'training data can be backed up');
ok(!defined $backup_error, 'successful backup has no error');
my @backups = glob(File::Spec->catfile($temporary, 'blissmixer-triplets-*.zip'));
is(scalar @backups, 1, 'one timestamped backup archive is created');

unlink $triplets or die "Cannot remove $triplets: $!";
my $restore_error = Plugins::BlissMixerLab::Survey::_restoreBackup($backups[0]);
ok(!defined $restore_error, 'training data backup restores successfully');
is_deeply(Plugins::BlissMixerLab::Survey::_loadTriplets(), $training,
    'restored training data matches the original');

unlink $database if -e $database;
like(Plugins::BlissMixerLab::Survey::_startLearning(), qr/database was not found/,
    'learning refuses to run without the upstream BlissMixer database');

open my $database_fh, '>', $database or die "Cannot create $database: $!";
close $database_fh;
$Plugins::BlissMixerLab::Plugin::analyser_running = 1;
like(Plugins::BlissMixerLab::Survey::_startLearning(), qr/analysis is running/,
    'learning does not compete with upstream analysis');
$Plugins::BlissMixerLab::Plugin::analyser_running = 0;
like(Plugins::BlissMixerLab::Survey::_startLearning(), qr/Not enough training data \(2 triplets\)/,
    'learning requires the minimum number of survey rounds');

Plugins::BlissMixerLab::Survey::_saveTriplets([($training->[0]) x 10]);
is(Plugins::BlissMixerLab::Survey::_startLearning(), 'Learning started',
    'learning starts when sufficient training data is available');
my $learner_command = join ' ', @Proc::Background::arguments;
like($learner_command,
    qr/--lms 127\.0\.0\.1 --json 9123 --notifs --lms-command blissmixerlab/,
    'the learner sends its detailed progress to the sidecar command');
Plugins::BlissMixerLab::Survey::_stopLearning();

open my $matrix_fh, '>', $matrix or die "Cannot create $matrix: $!";
print {$matrix_fh} 'old matrix';
close $matrix_fh;
open my $new_matrix_fh, '>', "$matrix.new" or die "Cannot create $matrix.new: $!";
print {$new_matrix_fh} 'new matrix';
close $new_matrix_fh;
Plugins::BlissMixerLab::Survey::_learningEnded();
open my $installed_fh, '<', $matrix or die "Cannot read $matrix: $!";
my $installed = do { local $/; <$installed_fh> };
close $installed_fh;
is($installed, 'new matrix', 'a completed experiment atomically replaces the old matrix');
is($Plugins::BlissMixerLab::Plugin::mixer_stop_count, 1,
    'installing a learned matrix restarts only the sidecar mixer');

Plugins::BlissMixerLab::Survey::_clearTrainingData();
ok(!-e $triplets, 'clearing training data removes sidecar triplets');
ok(!-e $matrix, 'clearing training data removes the learned matrix');
is($Plugins::BlissMixerLab::Plugin::mixer_stop_count, 2,
    'clearing the matrix restarts only the sidecar mixer');

done_testing();
