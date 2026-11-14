package Plugins::BlissLibrary::LyrionRefresh;
use strict;
use warnings;
use File::Path qw(make_path);
use File::Spec;
use FindBin ();
use Time::HiRes ();
use Slim::Control::Request;
use Slim::Music::Import;
use Slim::Music::VirtualLibraries;
use Slim::Utils::Misc;
use Slim::Utils::OSDetect;
use Slim::Utils::Prefs;
use Slim::Utils::Timers;
use Plugins::BlissLibrary::JsonCodec;
use Plugins::BlissLibrary::MixerClient;
use Plugins::BlissLibrary::RefreshRuntime;
use Plugins::BlissLibrary::SourceIdentity;

my ($runtime, $active_job, @bundles);

sub _state {
    my ($lyrion, $bliss, $roots) = @_;
    my @files;
    for my $item ([$lyrion, 0], ["$lyrion-wal", 1], [$bliss, 0], ["$bliss-wal", 1]) {
        my ($path, $optional) = @$item;
        my @stat = stat($path);
        die 'Candidate database is unavailable' if !@stat && !$optional;
        push @files, @stat ? [@stat[0, 1, 7, 9, 10]] : undef;
    }
    my ($version) = Slim::Schema->dbh->selectrow_array('PRAGMA data_version');
    return Plugins::BlissLibrary::JsonCodec::canonical()->encode({files => \@files,
        roots => $roots, scan => 0 + (Slim::Music::Import->lastScanTime || 0),
        lms_data_version => 0 + ($version || 0)});
}

sub _launch {
    my ($scope, $done, $cache_dir) = @_;
    my ($bundle) = grep { -f File::Spec->catfile($_, 'bin', 'build-inventory.pl') } @bundles;
    die 'Shared inventory worker is unavailable' unless defined $bundle;
    if ($scope->{kind} eq 'library') {
        my $id = Slim::Music::VirtualLibraries->getRealId($scope->{id});
        die 'Previously selected virtual library is unavailable' unless defined($id) && $id eq $scope->{id};
    }
    my $rows = Slim::Schema->dbh->selectall_arrayref('PRAGMA database_list');
    my ($main) = grep { ($_->[1] || '') eq 'main' && length($_->[2] || '') } @$rows;
    die 'Could not resolve the Lyrion database path' unless $main;
    my $lyrion = $main->[2];
    my $prefs = Slim::Utils::Prefs::dir() || Slim::Utils::OSDetect::dirsFor('prefs');
    my $bliss = File::Spec->catfile($prefs, 'bliss.db');
    my $roots = [@{Slim::Utils::Misc::getMediaDirs('audio') || []}];
    my $observer = Plugins::BlissLibrary::SourceIdentity::begin_session([$lyrion, $bliss]);
    my $initial = _state($lyrion, $bliss, $roots);
    my $script = File::Spec->catfile($bundle, 'bin', 'build-inventory.pl');
    local $ENV{BLISS_LYRION_ROOT} = $ENV{BLISS_LYRION_ROOT} || $FindBin::Bin;
    my $job = Plugins::BlissLibrary::MixerClient->start(work_dir => $cache_dir,
        command => [$^X, $script], request => {schema => 'bliss-library-worker-request-v1',
            lyrion_path => $lyrion, bliss_path => $bliss, scope => $scope,
            verified_library_ids => $scope->{kind} eq 'library' ? [$scope->{id}] : [],
            media_roots => $roots, scan_generation => '' . (Slim::Music::Import->lastScanTime || 0), cache_dir => $cache_dir},
        is_current => sub {
            local $Plugins::BlissLibrary::SourceIdentity::session = $observer;
            Plugins::BlissLibrary::SourceIdentity::_check_session($lyrion);
            Plugins::BlissLibrary::SourceIdentity::_check_session($bliss);
            return _state($lyrion, $bliss, Slim::Utils::Misc::getMediaDirs('audio') || []) eq $initial;
        });
    $active_job = $job;
    my $poll;
    $poll = sub {
        my $result = eval { $job->poll };
        if (!$result) { my $error = $@ || 'Candidate refresh failed'; undef $poll; $active_job = undef if $active_job && $active_job == $job; $done->($error); return }
        if ($result->{state} eq 'running' || $result->{state} eq 'cancelling') {
            Slim::Utils::Timers::setTimer(undef, Time::HiRes::time() + 1, $poll);
            return;
        }
        undef $poll;
        $active_job = undef if $active_job && $active_job == $job;
        $done->($result->{state} eq 'completed' ? undef : ($result->{error} || 'Candidate refresh failed'));
    };
    Slim::Utils::Timers::setTimer(undef, Time::HiRes::time() + 0.01, $poll);
}

sub init {
    my ($bundle) = @_;
    die 'Shared inventory bundle directory is required' unless defined($bundle) && -d $bundle;
    push @bundles, $bundle unless grep { $_ eq $bundle } @bundles;
    my $root = Slim::Utils::Prefs::preferences('server')->get('cachedir');
    die 'Lyrion cache directory is unavailable' unless defined($root) && -d $root;
    my $dir = File::Spec->catdir($root, 'bliss-library', 'candidate-inventory');
    make_path($dir) unless -d $dir;
    $runtime = Plugins::BlissLibrary::RefreshRuntime->shared(dir => $dir,
        subscribe => sub { Slim::Control::Request::subscribe($_[0], [['rescan'], ['done']]) },
        unsubscribe => sub { Slim::Control::Request::unsubscribe($_[0]) },
        schedule => sub { Slim::Utils::Timers::setTimer(undef, Time::HiRes::time() + $_[0], $_[1]) },
        launch => sub { _launch($_[0], $_[1], $dir) },
        on_error => sub {
            my ($error, $scope) = @_;
            $error =~ s/\s+/ /g;
            my $label = $scope->{kind} eq 'library' ? $scope->{id} : 'all';
            eval { require Slim::Utils::Log; Slim::Utils::Log::logger('plugin.blisslibrary')->warn("Candidate inventory refresh failed for $label: $error") };
        });
    return $runtime;
}

sub remember {
    my ($scope) = @_;
    die 'Shared inventory refresh is not initialized' unless $runtime;
    return $runtime->remember($scope);
}

sub release {
    my ($bundle) = @_;
    @bundles = grep { $_ ne $bundle } @bundles;
    return if @bundles || !$runtime;
    eval { $active_job->cancel } if $active_job;
    $runtime->stop;
    $runtime = undef;
    return 1;
}
1;
