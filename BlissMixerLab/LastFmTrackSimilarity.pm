package Plugins::BlissMixerLab::LastFmTrackSimilarity;

#
# Bliss Mixer Lab companion for Lyrion Music Server
#
# Licence: GPL v3
#

use strict;

use Slim::Utils::Log;

use constant MAX_SIMILAR_RESULTS => 25;

my $log = Slim::Utils::Log::logger('plugin.blissmixerlab');

sub _normalizeText {
    my $value = lc(shift // '');
    $value =~ s/^\s+|\s+$//g;
    $value =~ s/\s+/ /g;
    return $value;
}

sub _validMbid {
    my $value = shift // '';
    return $value =~ /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i
        ? lc($value) : undef;
}

sub _nameKey {
    my ($artist, $title) = @_;
    my $artistKey = _normalizeText($artist);
    my $titleKey = _normalizeText($title);
    return '' unless length $artistKey && length $titleKey;
    return $artistKey . '|' . $titleKey;
}

sub _serviceWideError {
    my $code = shift;
    return defined $code && "$code" =~ /^(?:11|16|29)$/;
}

sub _storeMaximum {
    my ($hash, $key, $value) = @_;
    return unless defined $key && length $key;
    $hash->{$key} = $value
        if !defined $hash->{$key} || $value > $hash->{$key};
}

sub candidateSupport {
    my ($track, $matches) = @_;
    return 0 unless $track && ref($matches) eq 'HASH';

    my $support = 0;
    my $mbid = _validMbid(eval { $track->musicbrainz_id });
    $support = $matches->{mbid}->{$mbid}
        if $mbid && ref($matches->{mbid}) eq 'HASH'
        && defined $matches->{mbid}->{$mbid};

    my $nameKey = _nameKey(
        eval { $track->artistName },
        eval { $track->title },
    );
    my $nameSupport = ref($matches->{name}) eq 'HASH'
        ? $matches->{name}->{$nameKey} : undef;
    $support = $nameSupport
        if defined $nameSupport && $nameSupport > $support;
    return $support;
}

sub collect {
    my ($seeds, $callback, $matches, $stats) = @_;
    my (%seen, @requests);

    for my $seed (@{$seeds || []}) {
        my $artist = eval { $seed->artistName } // '';
        my $title = eval { $seed->title } // '';
        my $nameKey = _nameKey($artist, $title);
        next unless length $nameKey;
        my $mbid = _validMbid(eval { $seed->musicbrainz_id });
        my $requestKey = $mbid ? "mbid:$mbid" : "name:$nameKey";
        next if $seen{$requestKey}++;
        push @requests, {
            artist => $artist,
            title => $title,
            mbid => $mbid,
        };
    }

    $matches ||= {mbid => {}, name => {}};
    $matches->{mbid} ||= {};
    $matches->{name} ||= {};
    $stats ||= {succeeded => 0, failed => 0, error_codes => []};
    $stats->{succeeded} ||= 0;
    $stats->{failed} ||= 0;
    $stats->{error_codes} ||= [];
    my %seenErrors;
    my $next;
    $next = sub {
        unless (@requests) {
            $callback->($matches, $stats);
            return;
        }

        my $seed = shift @requests;
        my $label = $seed->{artist} . ' - ' . $seed->{title};
        main::DEBUGLOG && $log->debug(
            "Last.fm: getSimilarTracks for \"$label\""
        );

        my $dispatched = eval {
            Plugins::LastMix::LFM->getSimilarTracks(sub {
                my $results = shift;
                if (!$results || ref($results) ne 'HASH' || $results->{error}) {
                    my $code = ref($results) eq 'HASH' ? $results->{error} : undef;
                    my $errorKey = defined $code ? "LASTFM_$code" : 'LASTFM_NO_RESULT';
                    push @{$stats->{error_codes}}, $errorKey unless $seenErrors{$errorKey}++;
                    $stats->{failed}++;
                    my $message = ref($results) eq 'HASH' && $results->{message}
                        ? $results->{message} : $errorKey;
                    $log->warn("Last.fm track error for \"$label\": $message");
                    @requests = () if _serviceWideError($code);
                    $next->();
                    return;
                }

                $stats->{succeeded}++;
                my $tracks = ref($results->{similartracks}) eq 'HASH'
                    ? $results->{similartracks}->{track} : undef;
                $tracks = [$tracks] if ref($tracks) eq 'HASH';
                $tracks = [] unless ref($tracks) eq 'ARRAY';
                my $rank = 0;
                my $retained = 0;
                for my $result (@$tracks) {
                    next unless ref($result) eq 'HASH' && $result->{name};
                    my $artist = ref($result->{artist}) eq 'HASH'
                        ? $result->{artist}->{name} : undef;
                    next unless defined $artist && length $artist;
                    last if $retained >= MAX_SIMILAR_RESULTS;
                    $rank++;
                    $retained++;
                    my $score = defined $result->{match}
                        && "$result->{match}" =~ /^\d+(?:\.\d+)?$/
                        ? 0 + $result->{match}
                        : 1 / (1 + (($rank - 1) / 10));
                    $score = 0 if $score < 0;
                    $score = 1 if $score > 1;
                    my $resultMbid = _validMbid($result->{mbid});
                    _storeMaximum($matches->{mbid}, $resultMbid, $score)
                        if $resultMbid;
                    _storeMaximum(
                        $matches->{name},
                        _nameKey($artist, $result->{name}),
                        $score * 0.85,
                    );
                }
                main::INFOLOG && $log->info(
                    "Last.fm: got $retained similar tracks for \"$label\""
                );
                $next->();
            }, {
                artist => $seed->{artist},
                title => $seed->{title},
                mbid => $seed->{mbid},
            });
            1;
        };
        unless ($dispatched) {
            my $message = $@ || 'LastMix request failed before dispatch';
            $message =~ s/\s+/ /g;
            my $errorKey = 'LASTMIX_DISPATCH_FAILED';
            push @{$stats->{error_codes}}, $errorKey unless $seenErrors{$errorKey}++;
            $stats->{failed}++;
            $log->warn("Last.fm track dispatch error for \"$label\": $message");
            $next->();
        }
    };
    $next->();
}

1;

__END__
