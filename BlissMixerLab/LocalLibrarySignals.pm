package Plugins::BlissMixerLab::LocalLibrarySignals;

#
# Bliss Mixer Lab companion for Lyrion Music Server
#
# Licence: GPL v3
#

use strict;
use warnings;

# Build one bounded profile for the Bliss-derived candidate pool.  The caller
# may inject a lookup for tests; production uses Lyrion's attached persistent
# database to resolve only the supplied URLs.
sub prepare {
    my ($tracks, $lastPlayedInfluence, $libraryAgeInfluence, $lookup) = @_;
    $lastPlayedInfluence = _signedInfluence($lastPlayedInfluence);
    $libraryAgeInfluence = _signedInfluence($libraryAgeInfluence);

    return {
        active => 0,
        by_url => {},
        known_last_played => 0,
        known_library_age => 0,
    } unless $lastPlayedInfluence || $libraryAgeInfluence;

    my @urls = grep { defined && length } map {
        eval { $_->url };
    } @{ $tracks || [] };
    my %unique = map { $_ => 1 } @urls;
    @urls = sort keys %unique;

    my $rows = $lookup ? eval { $lookup->(\@urls) } : _persistentRows(\@urls);
    $rows = {} unless $rows && ref $rows eq 'HASH';

    my (%lastPlayed, %libraryAge);
    for my $url (@urls) {
        my $row = $rows->{$url};
        next unless $row && ref $row eq 'HASH';
        $lastPlayed{$url} = 0 + $row->{lastPlayed}
            if defined $row->{lastPlayed} && $row->{lastPlayed} =~ /^-?\d+(?:\.\d+)?$/;
        $libraryAge{$url} = 0 + $row->{added}
            if defined $row->{added} && $row->{added} =~ /^-?\d+(?:\.\d+)?$/;
    }

    my ($lastPlayedPercentiles, $lastPlayedDistinct) = _percentiles(\%lastPlayed);
    my ($libraryAgePercentiles, $libraryAgeDistinct) = _percentiles(\%libraryAge);
    my %byUrl;

    for my $url (@urls) {
        my $lastPlayedWeight = exists $lastPlayedPercentiles->{$url}
            && $lastPlayedDistinct > 1
            ? _weight($lastPlayedPercentiles->{$url}, $lastPlayedInfluence)
            : 1;
        my $libraryAgeWeight = exists $libraryAgePercentiles->{$url}
            && $libraryAgeDistinct > 1
            ? _weight($libraryAgePercentiles->{$url}, $libraryAgeInfluence)
            : 1;
        $byUrl{$url} = {
            last_played_percentile => $lastPlayedPercentiles->{$url},
            last_played_weight => $lastPlayedWeight,
            library_age_percentile => $libraryAgePercentiles->{$url},
            library_age_weight => $libraryAgeWeight,
            combined_weight => $lastPlayedWeight * $libraryAgeWeight,
        };
    }

    return {
        active => ($lastPlayedDistinct > 1 && $lastPlayedInfluence)
            || ($libraryAgeDistinct > 1 && $libraryAgeInfluence) ? 1 : 0,
        by_url => \%byUrl,
        last_played_influence => $lastPlayedInfluence,
        library_age_influence => $libraryAgeInfluence,
        known_last_played => scalar keys %lastPlayed,
        known_library_age => scalar keys %libraryAge,
        distinct_last_played => $lastPlayedDistinct,
        distinct_library_age => $libraryAgeDistinct,
    };
}

sub forTrack {
    my ($profile, $track) = @_;
    my $url = eval { $track->url };
    return {} unless defined $url && $profile && ref $profile eq 'HASH';
    return $profile->{by_url}{$url} || {};
}

sub _signedInfluence {
    my $influence = int($_[0] || 0);
    $influence = -100 if $influence < -100;
    $influence = 100 if $influence > 100;
    return $influence;
}

sub _weight {
    my ($percentile, $influence) = @_;
    return exp(log(10) * ($influence / 100) * $percentile);
}

sub _percentiles {
    my $values = shift;
    my @ordered = sort {
        $values->{$a} <=> $values->{$b} || $a cmp $b;
    } keys %{ $values || {} };
    return ({}, 0) unless @ordered;

    my (%percentiles, $distinct, $position);
    $position = 0;
    while ($position < @ordered) {
        my $end = $position;
        $end++ while $end + 1 < @ordered
            && $values->{$ordered[$end + 1]} == $values->{$ordered[$position]};
        my $average = ($position + $end) / 2;
        my $percentile = @ordered > 1 ? (2 * $average / $#ordered) - 1 : 0;
        $percentiles{$_} = $percentile for @ordered[$position .. $end];
        $distinct++;
        $position = $end + 1;
    }
    return (\%percentiles, $distinct);
}

sub _persistentRows {
    my $urls = shift;
    return {} unless $urls && @$urls;
    return {} unless eval { require Slim::Schema; 1 };
    my $dbh = eval { Slim::Schema->dbh };
    return {} unless $dbh;

    my %rows;
    my @remaining = @$urls;
    while (@remaining) {
        my @chunk = splice @remaining, 0, 900;
        my $placeholders = join ',', ('?') x @chunk;
        my $sth = eval {
            $dbh->prepare(
                "SELECT tracks.url, persistentdb.tracks_persistent.lastPlayed, "
                . "persistentdb.tracks_persistent.added "
                . "FROM tracks LEFT JOIN persistentdb.tracks_persistent "
                . "ON tracks.urlmd5 = persistentdb.tracks_persistent.urlmd5 "
                . "WHERE tracks.url IN ($placeholders)"
            );
        };
        next unless $sth && eval { $sth->execute(@chunk); 1 };
        while (my $row = $sth->fetchrow_hashref) {
            $rows{$row->{url}} = {
                lastPlayed => $row->{lastPlayed},
                added => $row->{added},
            };
        }
    }
    return \%rows;
}

1;
