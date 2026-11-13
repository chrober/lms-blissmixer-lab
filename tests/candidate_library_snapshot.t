use strict;
use warnings;
use Test::More tests => 4;
use DBI;
use JSON::XS::VersionOneAndTwo;

BEGIN {
    $INC{'Slim/Music/VirtualLibraries.pm'} = __FILE__;
    $INC{'Slim/Utils/Misc.pm'} = __FILE__;
    $INC{'Plugins/BlissMixerLab/RepeatIdentitySnapshot.pm'} = __FILE__;
}

{ package Slim::Music::VirtualLibraries;
  our $id = '';
  sub getLibraryIdForClient { $id }
  sub getRealId { $_[1] eq 'missing' ? undef : $_[1] }
}
{ package Slim::Utils::Misc; sub getMediaDirs { ['/music'] } }
{ package Plugins::BlissMixerLab::RepeatIdentitySnapshot;
  sub _database_file_for_url {
      my ($url) = @_;
      return unless $url =~ m{^file:///music/(.+)$};
      return $1;
  }
}
{ package Slim::Schema; our $dbh; sub dbh { $dbh } }

require './BlissMixerLab/CandidateLibrarySnapshot.pm';
$Slim::Schema::dbh = DBI->connect('dbi:SQLite:dbname=:memory:', '', '', { RaiseError => 1 });
$Slim::Schema::dbh->do('CREATE TABLE tracks (id INTEGER, url TEXT, tracknum INTEGER, remote INTEGER, audio INTEGER)');
$Slim::Schema::dbh->do('CREATE TABLE library_track (library TEXT, track INTEGER)');
$Slim::Schema::dbh->do(q{INSERT INTO tracks VALUES (1, 'file:///music/inside.flac', 1, 0, 1), (2, 'file:///music/outside.flac', 1, 0, 1), (3, 'http://radio', 1, 1, 1)});
$Slim::Schema::dbh->do(q{INSERT INTO library_track VALUES ('jazz', 1), ('rock', 2), ('jazz', 3)});
ok(!defined Plugins::BlissMixerLab::CandidateLibrarySnapshot::prepare(undef), 'all tracks does not need a snapshot');
$Slim::Music::VirtualLibraries::id = 'jazz';
my $snapshot = Plugins::BlissMixerLab::CandidateLibrarySnapshot::prepare(undef);
ok($snapshot && -r $snapshot->filename, 'selected library produces a readable snapshot');
open my $fh, '<', $snapshot->filename or die $!;
local $/;
is_deeply(from_json(<$fh>), ['inside.flac'], 'snapshot contains only local audio members');
close $fh;
$Slim::Music::VirtualLibraries::id = 'missing';
eval { Plugins::BlissMixerLab::CandidateLibrarySnapshot::prepare(undef) };
like($@, qr/unavailable/, 'missing library fails closed');
