package Plugins::BlissMixerLab::CandidateLibrarySnapshot;

use strict;
use File::Temp;
use JSON::XS::VersionOneAndTwo;
use Slim::Utils::Misc;
use Plugins::BlissMixerLab::RepeatIdentitySnapshot;

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

1;
