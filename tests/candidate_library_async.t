use strict;
use warnings;
use Test::More;
use DBI;
use File::Spec;
use File::Temp qw(tempdir);
use JSON::PP ();
use Config ();
use Time::HiRes qw(time sleep);

BEGIN {
    $INC{'JSON/XS/VersionOneAndTwo.pm'} = __FILE__;
    $INC{'Slim/Music/VirtualLibraries.pm'} = __FILE__;
    $INC{'Slim/Utils/Misc.pm'} = __FILE__;
    $INC{'Slim/Utils/Prefs.pm'} = __FILE__;
    $INC{'Slim/Utils/Timers.pm'} = __FILE__;
    $INC{'Slim/Music/Import.pm'} = __FILE__;
    $INC{'Slim/Utils/Log.pm'} = __FILE__;
    $INC{'Slim/Control/Request.pm'} = __FILE__;
    $INC{'Slim/Utils/OSDetect.pm'} = __FILE__;
    $INC{'Plugins/BlissMixerLab/RepeatIdentitySnapshot.pm'} = __FILE__;
}
{ package JSON::XS::VersionOneAndTwo; sub import { no strict 'refs'; *{caller() . '::to_json'} = \&JSON::PP::encode_json } }
{ package Slim::Music::VirtualLibraries; our $available = 1; sub getLibraryIdForClient { 'jazz' } sub getRealId { $available ? $_[1] : undef } }
{ package Slim::Utils::Misc; sub getMediaDirs { ['/music'] } }
{ package Slim::Utils::Prefs; our $cache; sub preferences { bless {}, 'TestPrefs' } sub dir { $cache } }
{ package Slim::Utils::OSDetect; sub dirsFor { $Slim::Utils::Prefs::cache } }
{ package Slim::Control::Request; our ($listener, $subscriptions); sub subscribe { $listener = $_[0]; $subscriptions++ } sub unsubscribe {} }
{ package TestPrefs; sub get { return $Slim::Utils::Prefs::cache } }
{ package Slim::Utils::Timers; our @pending; sub setTimer { push @pending, $_[2] } }
{ package Slim::Music::Import; our $scan = 42; sub lastScanTime { $scan } }
{ package Slim::Utils::Log; our @debug; sub logger { bless {}, 'TestDebugLog' } }
{ package TestDebugLog; sub is_debug { 1 } sub debug { push @Slim::Utils::Log::debug, $_[1] } sub warn {} }
{ package Slim::Schema; our $dbh; sub dbh { $dbh } }
{ package Plugins::BlissMixerLab::RepeatIdentitySnapshot; }

require './BlissMixerLab/CandidateLibrarySnapshot.pm';
my $dir = tempdir(CLEANUP => 1);
unless ($ENV{BLISS_USE_REAL_LMS}) {
    my $stub_dir = File::Spec->rel2abs(File::Spec->catdir('tests', 'shared_inventory_stubs'));
    $ENV{PERL5LIB} = join($Config::Config{path_sep}, $stub_dir, grep { defined($_) && length($_) } $ENV{PERL5LIB});
    $ENV{BLISS_LYRION_ROOT} ||= File::Spec->rel2abs('.');
}
$Slim::Utils::Prefs::cache = $dir;
my $lms = File::Spec->catfile($dir, 'library.db');
my $bliss = File::Spec->catfile($dir, 'bliss.db');
$Slim::Schema::dbh = DBI->connect("dbi:SQLite:dbname=$lms", '', '', {RaiseError => 1});
$Slim::Schema::dbh->do('CREATE TABLE tracks (id INTEGER PRIMARY KEY, url TEXT, tracknum INTEGER, remote INTEGER, audio INTEGER)');
$Slim::Schema::dbh->do('CREATE TABLE library_track (library TEXT, track INTEGER)');
$Slim::Schema::dbh->do(q{INSERT INTO tracks VALUES (1,'file:///music/inside.flac',0,0,1), (2,'file:///music/outside.flac',0,0,1)});
$Slim::Schema::dbh->do(q{INSERT INTO library_track VALUES ('jazz',1)});
my $db = DBI->connect("dbi:SQLite:dbname=$bliss", '', '', {RaiseError => 1});
$db->do('CREATE TABLE TracksV2 (File TEXT, Ignore INTEGER)');
$db->do(q{INSERT INTO TracksV2(rowid,File,Ignore) VALUES (11,'inside.flac',0), (12,'outside.flac',0)});
$db->disconnect;
my ($snapshot, $error, $called);
my $started = eval { Plugins::BlissMixerLab::CandidateLibrarySnapshot::prepare_async(undef, 'jazz', $bliss, sub { ($snapshot, $error) = @_; $called++ }); 1 };
ok($started, 'restricted library preparation can start asynchronously');
ok(!$called, 'preparation does not synchronously call the completion callback');
my $deadline = time + 30;
while (!$called && time < $deadline && @Slim::Utils::Timers::pending) {
    my $callback = shift @Slim::Utils::Timers::pending;
    $callback->(); sleep 0.02;
}
ok($called && !$error && $snapshot, 'background preparation returns a candidate snapshot');
like(join("\n", @Slim::Utils::Log::debug), qr/shared inventory: scope=jazz state=built key=[0-9a-f]{64}/,
    'debug output reports a shared inventory build and its key');
my ($built_key) = join("\n", @Slim::Utils::Log::debug) =~ /shared inventory: scope=jazz state=built key=([0-9a-f]{64})/;
diag("snapshot error: " . ($error || 'none')) if !$snapshot;
my $paths;
if ($snapshot) {
    open my $fh, '<:raw', $snapshot->filename or die $!;
    $paths = JSON::PP->new->utf8->decode(do { local $/; <$fh> });
    close $fh;
}
is_deeply($paths, ['inside.flac'], 'snapshot restricts the native mixer to the selected library');
ok($Slim::Control::Request::listener, 'a completed library snapshot registers scan refresh');
my @scope_records = glob File::Spec->catfile($dir, 'bliss-library', 'candidate-inventory', 'scope-*.json');
is(scalar @scope_records, 1, 'successful selected library is remembered for future refresh');
{
    no warnings 'redefine';
    local *Plugins::BlissLibrary::MixerClient::start = sub { die 'unexpected warm worker' };
    my ($warm_snapshot, $warm_error, $warm_done);
    my $started = eval {
        Plugins::BlissMixerLab::CandidateLibrarySnapshot::prepare_async(undef, 'jazz', $bliss,
            sub { ($warm_snapshot, $warm_error) = @_; $warm_done = 1 });
        1;
    };
    my $until = time + 5;
    while ($started && !$warm_done && time < $until && @Slim::Utils::Timers::pending) {
        my $timer = shift @Slim::Utils::Timers::pending;
        $timer->(); sleep 0.02;
    }
    ok($started && $warm_done && !$warm_error && $warm_snapshot,
        'unchanged DSTM scope reuses the verified snapshot without another worker or membership scan');
    like(join("\n", @Slim::Utils::Log::debug), qr/shared inventory: scope=jazz state=memory key=[0-9a-f]{64}/,
        'debug output reports in-process reuse with the same key');
    my ($warm_key) = join("\n", @Slim::Utils::Log::debug) =~ /shared inventory: scope=jazz state=memory key=([0-9a-f]{64})/;
    is($warm_key, $built_key, 'warm reuse logs the original shared inventory key');
}
{
    local $Slim::Music::VirtualLibraries::available = 0;
    my ($unavailable, $unavailable_error, $unavailable_done);
    Plugins::BlissMixerLab::CandidateLibrarySnapshot::prepare_async(undef, 'jazz', $bliss,
        sub { ($unavailable, $unavailable_error) = @_; $unavailable_done = 1 });
    my $until = time + 30;
    while (!$unavailable_done && time < $until && @Slim::Utils::Timers::pending) {
        my $timer = shift @Slim::Utils::Timers::pending;
        $timer->(); sleep 0.02;
    }
    ok($unavailable_done && $unavailable_error && !$unavailable,
        'a deleted virtual library cannot reuse a warm DSTM snapshot');
}
{
    open my $fh, '>:raw', $snapshot->filename or die $!;
    print {$fh} '["outside.flac"]'; close $fh;
    my ($repaired, $repair_error, $repair_done);
    Plugins::BlissMixerLab::CandidateLibrarySnapshot::prepare_async(undef, 'jazz', $bliss,
        sub { ($repaired, $repair_error) = @_; $repair_done = 1 });
    my $until = time + 30;
    while (!$repair_done && time < $until && @Slim::Utils::Timers::pending) {
        my $timer = shift @Slim::Utils::Timers::pending;
        $timer->(); sleep 0.02;
    }
    my $contents;
    if ($repaired) {
        open my $check, '<:raw', $repaired->filename or die $!;
        $contents = JSON::PP->new->utf8->decode(do { local $/; <$check> });
        close $check;
    }
    is_deeply($contents, ['inside.flac'], 'a corrupt warm artifact is rebuilt before use');
    diag($repair_error) if $repair_error;
}
my @before_refresh = glob File::Spec->catfile($dir, 'bliss-library', 'candidate-inventory', 'index-*.txt');
$Slim::Schema::dbh->do(q{UPDATE library_track SET track = 2 WHERE library = 'jazz'});
$Slim::Music::Import::scan = 43;
$Slim::Control::Request::listener->();
my $refresh_deadline = time + 25;
my @after_refresh;
while (time < $refresh_deadline) {
    my $timer = shift @Slim::Utils::Timers::pending;
    $timer->() if $timer;
    @after_refresh = glob File::Spec->catfile($dir, 'bliss-library', 'candidate-inventory', 'index-*.txt');
    last if @after_refresh > @before_refresh && !@Slim::Utils::Timers::pending;
    sleep 0.05;
}
cmp_ok(scalar(@after_refresh), '>', scalar(@before_refresh), 'scan completion refreshes the previously used library in a worker');
($snapshot, $error, $called) = (undef, undef, 0);
my $second = eval { Plugins::BlissMixerLab::CandidateLibrarySnapshot::prepare_async(undef, 'jazz', $bliss, sub { ($snapshot, $error) = @_; $called++ }); 1 };
$Slim::Music::Import::scan = 44;
$deadline = time + 30;
while ($second && !$called && time < $deadline && @Slim::Utils::Timers::pending) {
    my $callback = shift @Slim::Utils::Timers::pending;
    $callback->(); sleep 0.02;
}
ok($called && $error && !$snapshot, 'changed scan generation rejects an in-flight result');
{
    no warnings 'redefine';
    local *Plugins::BlissMixerLab::CandidateLibrarySnapshot::_source_state = sub { 'unchanged-stat-fixture' };
    ($snapshot, $error, $called) = (undef, undef, 0);
    Plugins::BlissMixerLab::CandidateLibrarySnapshot::prepare_async(undef, 'jazz', $bliss,
        sub { ($snapshot, $error) = @_; $called++ });
    $Slim::Schema::dbh->do(q{UPDATE library_track SET track = 1 WHERE library = 'jazz'});
    my $until = time + 30;
    while (!$called && time < $until && @Slim::Utils::Timers::pending) {
        my $timer = shift @Slim::Utils::Timers::pending;
        $timer->(); sleep 0.02;
    }
    ok($called && $error && !$snapshot, 'same-connection membership changes reject an in-flight snapshot even if file metadata appears unchanged');
}
{
    my ($primed, $prime_error, $prime_done);
    Plugins::BlissMixerLab::CandidateLibrarySnapshot::prepare_async(undef, 'jazz', $bliss,
        sub { ($primed, $prime_error) = @_; $prime_done = 1 });
    my $until = time + 30;
    while (!$prime_done && time < $until && @Slim::Utils::Timers::pending) {
        my $timer = shift @Slim::Utils::Timers::pending;
        $timer->(); sleep 0.02;
    }
    $Slim::Schema::dbh->do(q{UPDATE library_track SET track = 2 WHERE library = 'jazz'});
    my ($fresh, $fresh_error, $fresh_done);
    Plugins::BlissMixerLab::CandidateLibrarySnapshot::prepare_async(undef, 'jazz', $bliss,
        sub { ($fresh, $fresh_error) = @_; $fresh_done = 1 });
    $until = time + 30;
    while (!$fresh_done && time < $until && @Slim::Utils::Timers::pending) {
        my $timer = shift @Slim::Utils::Timers::pending;
        $timer->(); sleep 0.02;
    }
    my $contents;
    if ($fresh) {
        open my $fh, '<:raw', $fresh->filename or die $!;
        $contents = JSON::PP->new->utf8->decode(do { local $/; <$fh> });
        close $fh;
    }
    is_deeply($contents, ['outside.flac'], 'same-connection writes invalidate the in-process warm DSTM snapshot');
    diag($prime_error || $fresh_error) if $prime_error || $fresh_error;
}
($snapshot, $error, $called) = (undef, undef, 0);
Plugins::BlissMixerLab::CandidateLibrarySnapshot::prepare_async(undef, 'jazz', $bliss,
    sub { ($snapshot, $error) = @_; $called++ });
Plugins::BlissMixerLab::CandidateLibrarySnapshot::shutdown_shared_refresh();
ok($called == 1 && $error && !$snapshot, 'shutdown cancels a foreground snapshot and reports it immediately');
my $cancel_deadline = time + 10;
while (@Slim::Utils::Timers::pending && time < $cancel_deadline) {
    my $timer = shift @Slim::Utils::Timers::pending;
    $timer->(); sleep 0.02;
}
is($called, 1, 'a cancelled foreground worker never calls its completion callback twice');
done_testing();
