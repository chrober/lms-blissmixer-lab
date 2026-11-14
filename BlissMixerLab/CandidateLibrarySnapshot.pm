package Plugins::BlissMixerLab::CandidateLibrarySnapshot;

use strict;
use Digest::SHA ();
use File::Temp;
use File::Basename qw(dirname);
use File::Path qw(make_path);
use File::Spec;
use FindBin ();
use Time::HiRes ();
use JSON::XS::VersionOneAndTwo;
use Slim::Utils::Misc;
use Plugins::BlissMixerLab::RepeatIdentitySnapshot;

my (%foreground_jobs, $next_foreground_job, $fast_snapshot);

sub init_shared_refresh {
    my $bundle = File::Spec->catdir(dirname(__FILE__), 'SharedInventory');
    local @INC = (File::Spec->catdir($bundle, 'lib'), @INC);
    require Plugins::BlissLibrary::BundleGuard;
    Plugins::BlissLibrary::BundleGuard::register($bundle);
    require Plugins::BlissLibrary::LyrionRefresh;
    Plugins::BlissLibrary::BundleGuard::register($bundle);
    return Plugins::BlissLibrary::LyrionRefresh::init($bundle);
}

sub shutdown_shared_refresh {
    $fast_snapshot = undef;
    for my $entry (values %foreground_jobs) {
        eval { $entry->{cancel}->() } if $entry->{cancel};
        eval { $entry->{finish}->(undef, 'Candidate library preparation was cancelled') };
    }
    if ($INC{'Plugins/BlissLibrary/LyrionRefresh.pm'}) {
        my $bundle = File::Spec->catdir(dirname(__FILE__), 'SharedInventory');
        Plugins::BlissLibrary::LyrionRefresh::release($bundle);
    }
}

sub _memo_current {
    my ($memo, $lms, $bliss, $roots) = @_;
    require Slim::Music::VirtualLibraries;
    my $real = Slim::Music::VirtualLibraries->getRealId($memo->{id});
    return 0 unless defined($real) && $real eq $memo->{id};
    local $Plugins::BlissLibrary::SourceIdentity::session = $memo->{observer};
    Plugins::BlissLibrary::SourceIdentity::_check_session($lms);
    Plugins::BlissLibrary::SourceIdentity::_check_session($bliss);
    return _source_state($lms, $bliss, $roots) eq $memo->{state};
}

sub _reuse_snapshot_async {
    my ($memo, $client, $id, $lms, $bliss, $roots, $callback) = @_;
    return 0 unless eval { _memo_current($memo, $lms, $bliss, $roots) };
    return 0 unless -f $memo->{path} && !-l $memo->{path};
    open my $fh, '<:raw', $memo->{path} or return 0;
    my @initial = stat($fh);
    unless (@initial) { close $fh; return 0 }
    my $sha = Digest::SHA->new(256);
    my $token = ++$next_foreground_job;
    my $notified = 0;
    my $entry = {cancel => sub { close $fh }};
    $entry->{finish} = sub { return if $notified++; $callback->(@_) };
    $foreground_jobs{$token} = $entry;
    my $step;
    $step = sub {
        if ($notified) { delete $foreground_jobs{$token}; undef $step; return }
        my $read = read($fh, my $buffer, 256 * 1024);
        if (defined($read) && $read) {
            $sha->add($buffer);
            Slim::Utils::Timers::setTimer(undef, Time::HiRes::time() + 0.001, $step);
            return;
        }
        my @after = stat($fh);
        close $fh;
        my @path = stat($memo->{path});
        my @fields = (0, 1, 7, 9, 10);
        my $same_file = @after && @path && !-l $memo->{path}
            && join(':', @initial[@fields]) eq join(':', @after[@fields])
            && join(':', @initial[@fields]) eq join(':', @path[@fields]);
        my $current_roots = Slim::Utils::Misc::getMediaDirs('audio') || [];
        my $valid = defined($read) && $same_file && $sha->hexdigest eq $memo->{sha256}
            && eval { _memo_current($memo, $lms, $bliss, $current_roots) };
        delete $foreground_jobs{$token};
        undef $step;
        if ($valid) {
            $entry->{finish}->(bless({path => $memo->{path}}, 'Plugins::BlissMixerLab::CandidateLibrarySnapshot::SharedFile'), undef);
            return;
        }
        $fast_snapshot = undef if $fast_snapshot && $fast_snapshot == $memo;
        my $started = eval { prepare_async($client, $id, $bliss, $callback); 1 };
        $entry->{finish}->(undef, $@ || 'Candidate library preparation failed') unless $started;
    };
    Slim::Utils::Timers::setTimer(undef, Time::HiRes::time() + 0.001, $step);
    return 1;
}

sub resolve_library_id {
    my ($client) = @_;
    require Slim::Music::VirtualLibraries;
    my $id = Slim::Music::VirtualLibraries->getLibraryIdForClient($client) || '';
    return '' unless length $id;
    $id = Slim::Music::VirtualLibraries->getRealId($id);
    die "Selected virtual library is unavailable" unless defined $id && length $id;
    return $id;
}

sub library_log_message {
    my ($id, $client) = @_;
    return 'DSTM candidate library: All tracks' unless defined $id && length $id;
    my $name = Slim::Music::VirtualLibraries->getNameForId($id, $client) || 'Unknown';
    return "DSTM candidate library: $name (ID: $id)";
}

sub prepare {
    my ($client, $resolved_id) = @_;
    my $id = @_ > 1 ? $resolved_id : resolve_library_id($client);
    return unless defined $id && length $id;
    my $roots = Slim::Utils::Misc::getMediaDirs('audio') || [];
    my $stmt = Slim::Schema->dbh->prepare(
        'SELECT tracks.url, tracks.tracknum FROM library_track '
        . 'JOIN tracks ON tracks.id = library_track.track '
        . 'WHERE library_track.library = ? AND tracks.remote = 0 AND tracks.audio = 1'
    );
    $stmt->execute($id);
    my @files;
    while (my ($url, $tracknum) = $stmt->fetchrow_array) {
        my $file = Plugins::BlissMixerLab::RepeatIdentitySnapshot::_database_file_for_url($url, $tracknum, $roots);
        push @files, $file if defined $file && length $file;
    }
    $stmt->finish;
    my $file = File::Temp->new(UNLINK => 1, SUFFIX => '.json');
    binmode $file;
    print {$file} to_json(\@files) or die "Cannot write candidate library snapshot: $!";
    $file->flush or die "Cannot flush candidate library snapshot: $!";
    return $file;
}

sub _source_state {
    my ($lms_path, $bliss_path, $roots) = @_;
    require Slim::Music::Import;
    my @state;
    for my $item ([$lms_path, 0], ["$lms_path-wal", 1], [$bliss_path, 0], ["$bliss_path-wal", 1]) {
        my ($path, $optional) = @$item;
        my @stat = stat($path);
        die "Candidate database is unavailable" if !@stat && !$optional;
        push @state, @stat ? [@stat[0, 1, 7, 9, 10]] : undef;
    }
    my ($data_version) = Slim::Schema->dbh->selectrow_array('PRAGMA data_version');
    return Plugins::BlissLibrary::JsonCodec::canonical()->encode({files => \@state,
        scan => 0 + (Slim::Music::Import->lastScanTime() || 0), roots => $roots,
        lms_data_version => 0 + ($data_version || 0)});
}

sub prepare_async {
    my ($client, $id, $bliss_path, $callback) = @_;
    die 'Candidate snapshot callback is required' unless ref($callback) eq 'CODE';
    unless (defined($id) && length($id)) { $callback->(undef, undef); return 1 }
    require Slim::Music::VirtualLibraries;
    my $real = Slim::Music::VirtualLibraries->getRealId($id);
    unless (defined($real) && $real eq $id) {
        $callback->(undef, 'Selected virtual library is unavailable');
        return 1;
    }
    my $bundle = File::Spec->catdir(dirname(__FILE__), 'SharedInventory');
    local @INC = (File::Spec->catdir($bundle, 'lib'), @INC);
    require Plugins::BlissLibrary::BundleGuard;
    Plugins::BlissLibrary::BundleGuard::register($bundle);
    require Plugins::BlissLibrary::MixerClient;
    require Plugins::BlissLibrary::JsonCodec;
    require Plugins::BlissLibrary::SourceIdentity;
    Plugins::BlissLibrary::BundleGuard::register($bundle);
    require Slim::Utils::Prefs;
    require Slim::Utils::Timers;
    require Slim::Music::Import;
    my $rows = Slim::Schema->dbh->selectall_arrayref('PRAGMA database_list');
    my ($main) = grep { ($_->[1] || '') eq 'main' && length($_->[2] || '') } @$rows;
    die 'Could not resolve the Lyrion database path' unless $main;
    my $lms_path = $main->[2];
    my $roots = Slim::Utils::Misc::getMediaDirs('audio') || [];
    $roots = [@$roots];
    my $observer = Plugins::BlissLibrary::SourceIdentity::begin_session([$lms_path, $bliss_path]);
    my $initial = _source_state($lms_path, $bliss_path, $roots);
    my $memo_key = Plugins::BlissLibrary::JsonCodec::canonical()->encode({
        library => "$id", lyrion => $lms_path, bliss => $bliss_path, roots => $roots,
    });
    if ($fast_snapshot && $fast_snapshot->{key} eq $memo_key) {
        return 1 if _reuse_snapshot_async($fast_snapshot, $client, $id, $lms_path, $bliss_path, $roots, $callback);
        $fast_snapshot = undef;
    }
    my $cache_root = Slim::Utils::Prefs::preferences('server')->get('cachedir');
    die 'Lyrion cache directory is unavailable' unless defined($cache_root) && -d $cache_root;
    my $cache_dir = File::Spec->catdir($cache_root, 'bliss-library', 'candidate-inventory');
    make_path($cache_dir) unless -d $cache_dir;
    my $script = File::Spec->catfile($bundle, 'bin', 'build-inventory.pl');
    local $ENV{BLISS_LYRION_ROOT} = $ENV{BLISS_LYRION_ROOT} || $FindBin::Bin;
    my $job = Plugins::BlissLibrary::MixerClient->start(
        work_dir => $cache_dir, command => [$^X, $script],
        request => {schema => 'bliss-library-worker-request-v1', lyrion_path => $lms_path, bliss_path => $bliss_path,
            scope => {kind => 'library', id => "$id"}, verified_library_ids => ["$id"],
            media_roots => $roots, scan_generation => '' . (Slim::Music::Import->lastScanTime() || 0), cache_dir => $cache_dir},
        is_current => sub {
            my $current_id = Slim::Music::VirtualLibraries->getRealId($id);
            return 0 unless defined($current_id) && $current_id eq $id;
            local $Plugins::BlissLibrary::SourceIdentity::session = $observer;
            Plugins::BlissLibrary::SourceIdentity::_check_session($lms_path);
            Plugins::BlissLibrary::SourceIdentity::_check_session($bliss_path);
            my $current_roots = Slim::Utils::Misc::getMediaDirs('audio') || [];
            return _source_state($lms_path, $bliss_path, $current_roots) eq $initial;
        },
    );
    my $token = ++$next_foreground_job;
    my $entry = {cancel => sub { $job->cancel }};
    my $notified = 0;
    $entry->{finish} = sub {
        return if $notified++;
        $callback->(@_);
    };
    $foreground_jobs{$token} = $entry;
    my $poll;
    $poll = sub {
        my $result = eval { $job->poll };
        if (!$result) {
            my $error = $@ || 'Candidate worker failed';
            undef $poll;
            delete $foreground_jobs{$token};
            $entry->{finish}->(undef, $error);
            return;
        }
        if ($result->{state} eq 'running' || $result->{state} eq 'cancelling') {
            Slim::Utils::Timers::setTimer(undef, Time::HiRes::time() + 0.25, $poll);
            return;
        }
        undef $poll;
        delete $foreground_jobs{$token};
        return if $notified;
        if ($result->{state} eq 'completed') {
            eval { init_shared_refresh(); Plugins::BlissLibrary::LyrionRefresh::remember({kind => 'library', id => "$id"}) };
            $fast_snapshot = {key => $memo_key, id => "$id", observer => $observer, state => $initial,
                path => $result->{artifact}->{path}, sha256 => $result->{artifact}->{sha256}};
            $entry->{finish}->(bless({path => $result->{artifact}->{path}}, 'Plugins::BlissMixerLab::CandidateLibrarySnapshot::SharedFile'), undef);
        } else {
            $entry->{finish}->(undef, $result->{error} || 'Candidate worker failed');
        }
    };
    Slim::Utils::Timers::setTimer(undef, Time::HiRes::time() + 0.01, $poll);
    return 1;
}

package Plugins::BlissMixerLab::CandidateLibrarySnapshot::SharedFile;
sub filename { return $_[0]->{path} }

1;
