package Plugins::BlissMixerLab::BlissFileIdentity;

use strict;
use warnings;
use DBI;

# Read-only bridge from LMS file tracks to an *existing* exact TracksV2.File key.
# Mapping is not inferred from artist/title, URL MD5 or Bliss rowid.
# All failures are neutral. No SQLite database is ever created or modified.
sub open {
    my ($class, $database, $media_roots) = @_;
    return unless defined $database && -f $database;
    return unless ref($media_roots) eq 'ARRAY' && @$media_roots;

    my $dbh = eval {
        DBI->connect('dbi:SQLite:dbname=' . $database, '', '', {
            RaiseError => 1, PrintError => 0,
            AutoCommit => 1, sqlite_unicode => 1,
            sqlite_open_flags => 1, # SQLITE_OPEN_READONLY (not CREATE)
        });
    };
    return unless $dbh;
    my $sth = eval {
        $dbh->do('PRAGMA query_only=ON');
        $dbh->prepare(
            'SELECT File FROM TracksV2
             WHERE File = ? COLLATE BINARY AND Ignore IS NOT 1
             LIMIT 2'
        );
    };
    unless ($sth) {
        eval { $dbh->disconnect };
        return;
    }
    return bless {
        dbh => $dbh,
        find_file => $sth,
        media_roots => [@$media_roots],
    }, $class;
}

sub resolve {
    my ($self, $track, $path_to_key) = @_;
    return unless $self && $track && ref($path_to_key) eq 'CODE';

    my $url = eval { $track->url };
    return unless defined $url && $url =~ m{^file:}i;
    my $track_path = eval { $track->path };
    return unless defined $track_path && length $track_path;

    my %verified;
    for my $root (@{$self->{media_roots}}) {
        next unless _is_within_root($track_path, $root);
        # Reuse the host's established _trackToPath conversion for CUE and
        # LMS locale decoding. Never guess or normalize DB keys here.
        my $key = eval { $path_to_key->($root, $track) };
        next unless defined $key && length $key && !ref($key) && $key !~ /\0/;

        my $rows = eval {
            $self->{find_file}->execute($key);
            $self->{find_file}->fetchall_arrayref();
        };
        next unless ref($rows) eq 'ARRAY' && @$rows == 1
            && $rows->[0][0] eq $key;
        $verified{$key} = 1;
    }
    my @keys = keys %verified;
    # Multiple roots with competing valid Bliss keys must not be guessed.
    return @keys == 1 ? $keys[0] : undef;
}

sub _is_within_root {
    my ($path, $root) = @_;
    return 0 unless defined $path && defined $root && length $root;
    my $windows_path = $path =~ m{\\} || $root =~ m{\\};
    $path =~ s{\\}{/}g;
    $root =~ s{\\}{/}g;
    $root =~ s{/+$}{} unless $root eq '/';
    return 0 unless length $root;
    my ($comparison_path, $comparison_root) = $windows_path
        ? (lc($path), lc($root))
        : ($path, $root);
    return 0 unless index($comparison_path, $comparison_root) == 0;
    return 1 if $comparison_root eq '/';
    return length($comparison_path) > length($comparison_root)
        && substr($comparison_path, length($comparison_root), 1) eq '/';
}

sub close {
    my $self = shift;
    return unless $self;
    eval { $self->{find_file}->finish if $self->{find_file}; };
    eval { $self->{dbh}->disconnect if $self->{dbh}; };
    delete $self->{find_file};
    delete $self->{dbh};
    return 1;
}

sub DESTROY { shift->close() }

1;
