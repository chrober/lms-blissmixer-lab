package Plugins::BlissMixerLab::LocalLibrarySignals;

#
# Bliss Mixer Lab companion for Lyrion Music Server
#
# Licence: GPL v3
#

use strict;
use warnings;

use constant SECONDS_PER_DAY => 86400;
use constant DEFAULT_LAST_PLAYED_HORIZON_DAYS => 180;
use constant DEFAULT_LIBRARY_AGE_HORIZON_DAYS => 365;

# Build one bounded profile for the Bliss-derived candidate pool.  The caller
# may inject a lookup for tests; production uses Lyrion's attached persistent
# database to resolve only the supplied URLs.
sub prepare {
    my ($tracks, $lastPlayedInfluence, $libraryAgeInfluence, $lookup,
        $asOf, $lastPlayedHorizonDays, $libraryAgeHorizonDays) = @_;
    $lastPlayedInfluence = _signedInfluence($lastPlayedInfluence);
    $libraryAgeInfluence = _signedInfluence($libraryAgeInfluence);
    $asOf = time() unless defined $asOf && $asOf =~ /^\d+(?:\.\d+)?$/;
    $lastPlayedHorizonDays = _horizonDays(
        $lastPlayedHorizonDays, DEFAULT_LAST_PLAYED_HORIZON_DAYS
    );
    $libraryAgeHorizonDays = _horizonDays(
        $libraryAgeHorizonDays, DEFAULT_LIBRARY_AGE_HORIZON_DAYS
    );

    return {
        active => 0,
        by_url => {},
        known_last_played => 0,
        known_library_age => 0,
        as_of => 0 + $asOf,
        last_played_horizon_days => $lastPlayedHorizonDays,
        library_age_horizon_days => $libraryAgeHorizonDays,
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

    my (%lastPlayedSignals, %libraryAgeSignals);
    for my $url (keys %lastPlayed) {
        my $signal = _timeSignal(
            $lastPlayed{$url}, $asOf, $lastPlayedHorizonDays, 1
        );
        $lastPlayedSignals{$url} = $signal if defined $signal;
    }
    for my $url (keys %libraryAge) {
        my $signal = _timeSignal(
            $libraryAge{$url}, $asOf, $libraryAgeHorizonDays, 0
        );
        $libraryAgeSignals{$url} = $signal if defined $signal;
    }
    my $lastPlayedDistinct = _distinctCount(\%lastPlayedSignals);
    my $libraryAgeDistinct = _distinctCount(\%libraryAgeSignals);
    my %byUrl;

    for my $url (@urls) {
        my $lastPlayedWeight = exists $lastPlayedSignals{$url}
            && $lastPlayedDistinct > 1
            ? _weight($lastPlayedSignals{$url}, $lastPlayedInfluence)
            : 1;
        my $libraryAgeWeight = exists $libraryAgeSignals{$url}
            && $libraryAgeDistinct > 1
            ? _weight($libraryAgeSignals{$url}, $libraryAgeInfluence)
            : 1;
        $byUrl{$url} = {
            last_played => $lastPlayed{$url},
            added => $libraryAge{$url},
            last_played_signal => $lastPlayedSignals{$url},
            last_played_weight => $lastPlayedWeight,
            library_age_signal => $libraryAgeSignals{$url},
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
        as_of => 0 + $asOf,
        last_played_horizon_days => $lastPlayedHorizonDays,
        library_age_horizon_days => $libraryAgeHorizonDays,
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

sub _horizonDays {
    my ($horizon, $default) = @_;
    $horizon = int($horizon || $default);
    $horizon = 1 if $horizon < 1;
    $horizon = 3650 if $horizon > 3650;
    return $horizon;
}

sub _timeSignal {
    my ($timestamp, $asOf, $horizonDays, $zeroMeansNever) = @_;
    return undef unless defined $timestamp;
    return undef if !$zeroMeansNever && $timestamp <= 0;
    return -1 if $zeroMeansNever && $timestamp <= 0;

    my $ageDays = ($asOf - $timestamp) / SECONDS_PER_DAY;
    $ageDays = 0 if $ageDays < 0;
    my $remaining = exp(-$ageDays / $horizonDays);
    return (2 * $remaining) - 1;
}

sub _distinctCount {
    my $values = shift || {};
    my %distinct;
    $distinct{sprintf('%.12f', $_)} = 1 for values %$values;
    return scalar keys %distinct;
}

sub _weight {
    my ($percentile, $influence) = @_;
    return exp(log(10) * ($influence / 100) * $percentile);
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
