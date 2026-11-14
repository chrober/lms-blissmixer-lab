#!/usr/bin/env perl
use strict;
use warnings;
use FindBin;
use lib "$FindBin::Bin/../lib";
BEGIN {
    no strict 'refs';
    for my $name (qw(SCANNER RESIZER PERFMON DEBUGLOG INFOLOG STATISTICS SB1SLIMP3SYNC WEBUI NOMYSB LOCALFILE NOBROWSECACHE SLIM_SERVICE NOUPNP ISACTIVEPERL)) {
        *{"main::$name"} = sub () { 0 };
    }
    *main::ISWINDOWS = sub () { $^O =~ /^m?s?win/i ? 1 : 0 };
    *main::ISMAC = sub () { $^O =~ /darwin/i ? 1 : 0 };
    die "BLISS_LYRION_ROOT is required\n" unless defined($ENV{BLISS_LYRION_ROOT}) && -d $ENV{BLISS_LYRION_ROOT};
    require Slim::Utils::OSDetect;
    Slim::Utils::OSDetect::init($ENV{BLISS_LYRION_ROOT});
}
use JSON::PP ();
use Plugins::BlissLibrary::Builder;
use Plugins::BlissLibrary::CachedBuild;
use Plugins::BlissLibrary::FileIdentity;
use Plugins::BlissLibrary::MixerAdapter;
use Plugins::BlissLibrary::SourceIdentity;

my ($path) = @ARGV;
die "Expected one request file\n" unless @ARGV == 1 && defined($path) && -f $path;
die "Request file is too large\n" if -s $path > 1024 * 1024;
open my $fh, '<:raw', $path or die "Cannot open worker request: $!\n";
my $bytes = do { local $/; <$fh> };
close $fh or die "Cannot close worker request: $!\n";
my $request = JSON::PP->new->utf8->decode($bytes);
die "Unsupported worker request\n" unless ref($request) eq 'HASH'
    && ($request->{schema} || '') eq 'bliss-library-worker-request-v1';
die "Invalid scan generation\n" unless defined($request->{scan_generation})
    && !ref($request->{scan_generation}) && length($request->{scan_generation});
die "Invalid verified library IDs\n" unless ref($request->{verified_library_ids}) eq 'ARRAY';
my %verified;
for my $id (@{$request->{verified_library_ids}}) {
    die "Invalid verified library ID\n" unless defined($id) && !ref($id) && length($id);
    $verified{$id} = 1;
}
my $roots = $request->{media_roots};
my $root_identity = Plugins::BlissLibrary::SourceIdentity::media_roots_fingerprint($roots);
my $mapper = Plugins::BlissLibrary::FileIdentity::make_alias_mapper($roots);
eval { setpriority(0, 0, 10) } if $^O ne 'MSWin32';
my $scope = Plugins::BlissLibrary::CandidateInventory::_scope($request->{scope});
die "Selected library is unavailable\n" if $scope->{kind} eq 'library' && !$verified{$scope->{id}};
local $Plugins::BlissLibrary::SourceIdentity::session =
    Plugins::BlissLibrary::SourceIdentity::begin_session([$request->{lyrion_path}, $request->{bliss_path}]);
my $build = sub {
    return Plugins::BlissLibrary::Builder::build_verified(
        lyrion_path => $request->{lyrion_path}, bliss_path => $request->{bliss_path},
        scope => $scope, file_for_track => $mapper,
        library_exists => sub { $verified{$_[0]} ? 1 : 0 },
        source => {scan_generation => "$request->{scan_generation}", media_roots => $root_identity},
    );
};
my $inventory;
my $output_kind = $request->{output_kind};
die "Unsupported worker output kind\n" if defined($output_kind)
    && (ref($output_kind) || ($output_kind ne 'mixer-paths-v1' && $output_kind ne 'mixer-descriptor-v1'));
die "Mixer output requires a cache directory\n" if defined($output_kind) && !exists($request->{cache_dir});
if (exists($request->{cache_dir}) || exists($request->{expected_source})) {
    die "Cache requires a directory\n" unless defined($request->{cache_dir}) && !ref($request->{cache_dir});
    my $source;
    if (exists $request->{expected_source}) {
        $source = $request->{expected_source};
        die "Cache requires a valid frozen source identity\n" unless ref($source) eq 'HASH';
    } else {
        $source = Plugins::BlissLibrary::Builder::capture_source_verified(
            lyrion_path => $request->{lyrion_path}, bliss_path => $request->{bliss_path}, scope => $scope,
            source => {scan_generation => "$request->{scan_generation}", media_roots => $root_identity},
            library_exists => sub { $verified{$_[0]} ? 1 : 0 },
        );
    }
    my $result = Plugins::BlissLibrary::CachedBuild::run(
        dir => $request->{cache_dir}, scope => $scope, source => $source, build => $build,
        fresh => sub {
            return 0 unless ($source->{scan_generation} || '') eq "$request->{scan_generation}"
                && ($source->{media_roots} || '') eq $root_identity;
            return ($source->{lyrion_database} || '') eq Plugins::BlissLibrary::SourceIdentity::database_fingerprint($request->{lyrion_path})
                && ($source->{bliss_database} || '') eq Plugins::BlissLibrary::SourceIdentity::database_fingerprint($request->{bliss_path});
        },
    );
    if ($result->{state} eq 'busy') { print STDERR "cache=busy\n"; exit 75 }
    print STDERR "cache=$result->{state}\n";
    $inventory = $result->{inventory};
} else {
    $inventory = $build->();
}
binmode STDOUT, ':raw' or die "Cannot set output mode: $!\n";
my $result = $inventory;
if (defined $output_kind) {
    my $artifact = Plugins::BlissLibrary::MixerAdapter::native_artifact(
        dir => $request->{cache_dir}, scope => $scope, source => $inventory->{source},
        inventory => $inventory, bliss_path => $request->{bliss_path},
    );
    if ($artifact->{state} eq 'busy') { print STDERR "mixer-cache=busy\n"; exit 75 }
    my $descriptor = {path => $artifact->{path}, sha256 => $artifact->{sha256}};
    $result = $output_kind eq 'mixer-descriptor-v1'
        ? {schema => 'bliss-library-mixer-descriptor-v1', scope => $scope,
            source => $inventory->{source}, mixer_artifact => $descriptor}
        : {schema => 'bliss-library-mixer-result-v1', inventory => $inventory,
            mixer_artifact => $descriptor};
}
print JSON::PP->new->canonical->utf8->encode($result) or die "Cannot write worker result: $!\n";
