package Plugins::BlissLibrary::Builder;
use strict;
use warnings;
use DBI;
use Plugins::BlissLibrary::CandidateInventory;
use Plugins::BlissLibrary::SourceIdentity;

sub _file_identity {
    my ($path) = @_;
    my @stat = stat($path);
    die "Database is unavailable: $path" unless @stat && -f _;
    return join(':', @stat[0, 1, 7, 9, 10]);
}

sub _open_readonly {
    my ($path) = @_;
    _file_identity($path);
    my $dbh = DBI->connect("dbi:SQLite:dbname=$path", '', '', {
        RaiseError => 1, PrintError => 0, AutoCommit => 1,
        sqlite_unicode => 1, sqlite_open_flags => 1,
    }) or die "Cannot open database read-only: $path";
    return $dbh;
}

sub capture_source_verified {
    my %args = @_;
    die 'Member callback must be a callback' if exists($args{on_member}) && ref($args{on_member}) ne 'CODE';
    my $scope = Plugins::BlissLibrary::CandidateInventory::_scope($args{scope});
    die 'Source identity is required' unless ref($args{source}) eq 'HASH';
    if ($scope->{kind} eq 'library') {
        die 'Library existence check is required' unless ref($args{library_exists}) eq 'CODE';
        die 'Selected library is unavailable' unless $args{library_exists}->($scope->{id});
    }
    my $lyrion = Plugins::BlissLibrary::SourceIdentity::database_fingerprint($args{lyrion_path});
    my $bliss = Plugins::BlissLibrary::SourceIdentity::database_fingerprint($args{bliss_path});
    my $lms = _open_readonly($args{lyrion_path});
    my $membership = eval {
        $lms->begin_work;
        my $sth = $scope->{kind} eq 'library'
            ? $lms->prepare('SELECT track FROM library_track WHERE library = ? ORDER BY track')
            : $lms->prepare('SELECT id FROM tracks WHERE remote = 0 AND audio = 1 ORDER BY id');
        $scope->{kind} eq 'library' ? $sth->execute($scope->{id}) : $sth->execute;
        my $digest = Plugins::BlissLibrary::CandidateInventory::membership_digest_ordered($scope, sub {
            my $row = $sth->fetchrow_arrayref;
            $args{on_member}->($row->[0]) if $row && $args{on_member};
            return $row ? [$row->[0]] : undef;
        });
        $sth->finish;
        $lms->commit;
        $digest;
    };
    my $error = $@;
    eval { $lms->rollback unless $lms->{AutoCommit} };
    $lms->disconnect;
    die $error if $error;
    die 'Database changed during source capture'
        unless $lyrion eq Plugins::BlissLibrary::SourceIdentity::database_fingerprint($args{lyrion_path})
            && $bliss eq Plugins::BlissLibrary::SourceIdentity::database_fingerprint($args{bliss_path});
    my %source = (%{$args{source}}, lyrion_database => $lyrion, bliss_database => $bliss,
        membership => $membership);
    return Plugins::BlissLibrary::CandidateInventory::_source(\%source);
}

sub build_verified {
    my %args = @_;
    die 'Source identity is required' unless ref($args{source}) eq 'HASH';
    my $lyrion = Plugins::BlissLibrary::SourceIdentity::database_fingerprint($args{lyrion_path});
    my $bliss = Plugins::BlissLibrary::SourceIdentity::database_fingerprint($args{bliss_path});
    $args{source} = {%{$args{source}}, lyrion_database => $lyrion, bliss_database => $bliss};
    my $inventory = build(%args);
    die 'Database changed during verified inventory build'
        unless $lyrion eq Plugins::BlissLibrary::SourceIdentity::database_fingerprint($args{lyrion_path})
            && $bliss eq Plugins::BlissLibrary::SourceIdentity::database_fingerprint($args{bliss_path});
    return $inventory;
}

sub build {
    my %args = @_;
    my $scope = Plugins::BlissLibrary::CandidateInventory::_scope($args{scope});
    die 'Track identity mapper is required' unless ref($args{file_for_track}) eq 'CODE';
    if ($scope->{kind} eq 'library') {
        die 'Library existence check is required' unless ref($args{library_exists}) eq 'CODE';
        die 'Selected library is unavailable' unless $args{library_exists}->($scope->{id});
    }
    die 'Source identity is required' unless ref($args{source}) eq 'HASH';
    my $lms_identity = _file_identity($args{lyrion_path});
    my $bliss_identity = _file_identity($args{bliss_path});
    my $lms = _open_readonly($args{lyrion_path});
    my $bliss = _open_readonly($args{bliss_path});
    my $result = eval {
        my ($lms_version) = $lms->selectrow_array('PRAGMA data_version');
        my ($bliss_version) = $bliss->selectrow_array('PRAGMA data_version');
        $lms->begin_work;
        $bliss->begin_work;
        my @membership;
        if ($scope->{kind} eq 'library') {
            my $sth = $lms->prepare('SELECT track FROM library_track WHERE library = ? ORDER BY track');
            $sth->execute($scope->{id});
            while (my ($id) = $sth->fetchrow_array) { push @membership, $id }
            $sth->finish;
        }
        my %members = map { $_ => 1 } @membership;
        my (%files, %owners, %ambiguous);
        my $tracks = $lms->prepare('SELECT id, url, tracknum FROM tracks WHERE remote = 0 AND audio = 1');
        $tracks->execute;
        while (my ($id, $url, $tracknum) = $tracks->fetchrow_array) {
            push @membership, $id if $scope->{kind} eq 'all';
            my $mapped = $args{file_for_track}->($url, $tracknum);
            my @files = ref($mapped) eq 'ARRAY' ? @$mapped : ($mapped);
            for my $file (@files) {
                next unless defined($file) && !ref($file) && length($file);
                if (exists($owners{$file}) && $owners{$file} != $id) {
                    $ambiguous{$file} = [$owners{$file}, $id];
                } else {
                    $owners{$file} = $id;
                }
                $files{$file} = 1 if $scope->{kind} ne 'library' || $members{$id};
            }
        }
        $tracks->finish;
        my @row_ids;
        my $rows = $bliss->prepare('SELECT rowid, File, Ignore IS NOT 1 FROM TracksV2 ORDER BY rowid');
        $rows->execute;
        while (my ($rowid, $file, $eligible) = $rows->fetchrow_array) {
            die "Ambiguous media-root identity '$file' maps to local tracks $ambiguous{$file}[0] and $ambiguous{$file}[1]"
                if defined($file) && exists($ambiguous{$file});
            next unless $eligible;
            push @row_ids, $rowid if defined($file) && $files{$file};
        }
        $rows->finish;
        $lms->commit;
        $bliss->commit;
        my ($lms_after) = $lms->selectrow_array('PRAGMA data_version');
        my ($bliss_after) = $bliss->selectrow_array('PRAGMA data_version');
        die 'Database changed during inventory build' unless $lms_version == $lms_after
            && $bliss_version == $bliss_after
            && $lms_identity eq _file_identity($args{lyrion_path})
            && $bliss_identity eq _file_identity($args{bliss_path});
        my %source = (%{$args{source}}, membership =>
            Plugins::BlissLibrary::CandidateInventory::membership_digest($scope, \@membership));
        Plugins::BlissLibrary::CandidateInventory::make_inventory(
            scope => $scope, source => \%source, row_ids => \@row_ids,
        );
    };
    my $error = $@;
    eval { $lms->rollback unless $lms->{AutoCommit}; $bliss->rollback unless $bliss->{AutoCommit} };
    $lms->disconnect;
    $bliss->disconnect;
    die $error if $error;
    return $result;
}
1;
