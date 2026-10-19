package Plugins::BlissMixerLab::GuidanceProviderAdapter;

use strict;
use warnings;

use Digest::SHA qw(sha256_hex);
use File::Temp qw(tempdir);
use File::Spec;
use JSON::PP qw(encode_json);

sub write_candidate_identity_artifact {
    my ($tracks, $directory) = @_;
    die 'candidate identity artifact directory is required'
        unless defined $directory && length $directory;
    $tracks = [] unless ref($tracks) eq 'ARRAY';
    my @candidates;
    for my $track (@$tracks) {
        my $candidate_id = eval { $track->url };
        my $urlmd5 = eval { $track->urlmd5 };
        next unless defined $candidate_id && length $candidate_id;
        next unless defined $urlmd5 && $urlmd5 =~ /^[a-f0-9]+$/i;
        push @candidates, {
            candidate_id => "$candidate_id",
            lms_urlmd5 => "$urlmd5",
        };
    }
    my $payload = encode_json({
        schema_version => 1,
        schema_identity => 'eligible-candidate-identities-v1',
        candidates => \@candidates,
    });
    my $path = File::Spec->catfile($directory, 'eligible-candidate-identities.json');
    open my $fh, '>', $path or die "cannot write candidate identity artifact: $!";
    print {$fh} $payload or die "cannot write candidate identity artifact: $!";
    close $fh or die "cannot close candidate identity artifact: $!";
    return {
        kind => 'eligible-candidate-identities-v1',
        path => $path,
        sha256 => sha256_hex($payload),
    };
}

sub profile_from_provider {
    my ($tracks, $provider, $resolved_policy, $as_of, $operations) = @_;
    $tracks = [] unless ref($tracks) eq 'ARRAY';
    $resolved_policy = {} unless ref($resolved_policy) eq 'HASH';
    $operations = {} unless ref($operations) eq 'HASH';
    my $effective = ref($resolved_policy->{effective}) eq 'HASH'
        ? $resolved_policy->{effective} : {};
    my $neutral = sub { return profile_from_signals($tracks, $effective, [], $as_of); };
    return $neutral->()
        unless $resolved_policy->{valid} && $resolved_policy->{enabled}
            && ref($provider) eq 'HASH';
    my $native_config = $operations->{native_config};
    my $score_batch = $operations->{score_batch};
    return $neutral->()
        unless ref($native_config) eq 'CODE' && ref($score_batch) eq 'CODE';

    my $directory = tempdir(CLEANUP => 1);
    my $artifact;
    my $config;
    my $result;
    eval {
        $artifact = write_candidate_identity_artifact($tracks, $directory);
        $config = $native_config->($provider, $effective, {
            candidate_identity_artifact => $artifact,
            as_of_unix_seconds => int($as_of),
        });
        my @candidates = map {
            my $candidate_id = eval { $_->url };
            my $urlmd5 = eval { $_->urlmd5 };
            defined($candidate_id) && length($candidate_id)
                && defined($urlmd5) && $urlmd5 =~ /^[a-f0-9]+$/i
                ? ({ candidate_id => "$candidate_id", lms_urlmd5 => "$urlmd5" }) : ()
        } @$tracks;
        $result = $score_batch->($config, {
            job_id => 'blissmixerlab',
            request_id => 'dstm-candidate-pool',
            deadline_ms => 500,
            context => {
                scope => 'global',
                left_anchor_id => undef,
                right_anchor_id => undef,
                context_track_ids => [],
            },
            candidates => \@candidates,
        });
    };
    return profile_from_native_result($tracks, $effective, $result, $as_of);
}

sub lastfm_evidence_from_provider {
    my ($seeds, $tracks, $provider, $resolved_policy, $operations) = @_;
    $seeds = [] unless ref($seeds) eq 'ARRAY';
    $tracks = [] unless ref($tracks) eq 'ARRAY';
    $resolved_policy = {} unless ref($resolved_policy) eq 'HASH';
    $operations = {} unless ref($operations) eq 'HASH';
    my $neutral = {
        valid => 0,
        artist_candidates => {},
        track_candidates => {},
        diagnostics => {},
    };
    return $neutral
        unless $resolved_policy->{valid} && $resolved_policy->{enabled}
            && ref($provider) eq 'HASH';
    my $native_config = $operations->{native_config};
    my $score_batch = $operations->{score_batch};
    return $neutral
        unless ref($native_config) eq 'CODE' && ref($score_batch) eq 'CODE';

    my ($config, $result);
    eval {
        my $effective = ref($resolved_policy->{effective}) eq 'HASH'
            ? $resolved_policy->{effective} : {};
        my $trusted_context = ref($operations->{trusted_context}) eq 'HASH'
            ? $operations->{trusted_context} : {};
        $config = $native_config->($provider, $effective, $trusted_context);
        my @anchors;
        my @context_ids;
        for my $index (0 .. $#$seeds) {
            my $candidate = _candidate_for_track($seeds->[$index]);
            next unless $candidate;
            my $anchor_id = 'seed-' . ($index + 1);
            push @context_ids, $anchor_id;
            push @anchors, { anchor_id => $anchor_id, %$candidate };
        }
        my @candidates = grep { defined $_ }
            map { _candidate_for_track($_) } @$tracks;
        $result = $score_batch->($config, {
            job_id => 'blissmixerlab',
            request_id => 'dstm-candidate-pool',
            context => {
                scope => 'global',
                left_anchor_id => undef,
                right_anchor_id => undef,
                context_track_ids => \@context_ids,
            },
            anchors => \@anchors,
            candidates => \@candidates,
        });
    };
    return $neutral
        unless ref($result) eq 'HASH' && $result->{valid}
            && ref($result->{signals}) eq 'ARRAY';

    my (%artist_candidates, %track_candidates);
    for my $signal (@{$result->{signals}}) {
        next unless ref($signal) eq 'HASH';
        my $candidate_id = $signal->{candidate_id};
        my $channel = $signal->{channel};
        my $score = $signal->{score};
        next unless defined $candidate_id && length $candidate_id;
        next unless defined $score && $score =~ /^(?:\d+(?:\.\d*)?|\.\d+)$/;
        $score = _bounded_positive_score($score);
        next unless $score > 0;
        if (($channel || '') eq 'lastfm_artist') {
            $artist_candidates{$candidate_id} = $score
                if !defined $artist_candidates{$candidate_id}
                    || $score > $artist_candidates{$candidate_id};
        }
        elsif (($channel || '') eq 'lastfm_track') {
            $track_candidates{$candidate_id} = $score
                if !defined $track_candidates{$candidate_id}
                    || $score > $track_candidates{$candidate_id};
        }
    }
    return {
        valid => 1,
        artist_candidates => \%artist_candidates,
        track_candidates => \%track_candidates,
        diagnostics => ref($result->{diagnostics}) eq 'HASH'
            ? $result->{diagnostics} : {},
    };
}

sub profile_from_native_result {
    my ($tracks, $effective, $result, $as_of) = @_;
    $tracks = [] unless ref($tracks) eq 'ARRAY';
    $effective = {} unless ref($effective) eq 'HASH';
    my $neutral = sub { return profile_from_signals($tracks, $effective, [], $as_of); };
    return $neutral->()
        unless ref($result) eq 'HASH' && $result->{valid};

    # A native host supplies data only. It must never supply rendered LMS log
    # text; the existing Lab selection formatter remains authoritative.
    my $trace = $result->{selection_trace};
    return $neutral->()
        if defined $trace && (
            ref($trace) ne 'HASH'
            || ($trace->{trace_version} || '') ne 'selection_trace_v1'
            || ref($trace->{candidates}) ne 'ARRAY'
        );
    my $profile = profile_from_signals($tracks, $effective, $result->{signals}, $as_of);
    my $details = ref($result->{diagnostics}) eq 'HASH'
        && ref($result->{diagnostics}->{details}) eq 'HASH'
        ? $result->{diagnostics}->{details} : {};
    my $sources = ref($details->{source_by_channel}) eq 'HASH'
        ? $details->{source_by_channel} : {};
    my $provider_id = ref($trace) eq 'HASH' ? ($trace->{provider_id} || '') : '';
    if ($provider_id =~ /^[A-Za-z0-9._-]+$/
        && _valid_source($sources->{playcount})
        && _valid_source($sources->{last_played})
        && _valid_source($sources->{library_age})) {
        $profile->{guidance_source_provenance} = {
            provider_id => $provider_id,
            source_by_channel => {
                playcount => $sources->{playcount},
                last_played => $sources->{last_played},
                library_age => $sources->{library_age},
            },
        };
    }
    return $profile;
}

sub profile_from_signals {
    my ($tracks, $policy, $signals, $as_of) = @_;
    $tracks = [] unless ref($tracks) eq 'ARRAY';
    $policy = {} unless ref($policy) eq 'HASH';
    $signals = [] unless ref($signals) eq 'ARRAY';
    $as_of = time() unless defined $as_of && $as_of =~ /^\d+(?:\.\d+)?$/;

    my %by_id;
    for my $signal (@$signals) {
        next unless ref($signal) eq 'HASH';
        my $candidate_id = $signal->{candidate_id};
        my $channel = $signal->{channel};
        next unless defined $candidate_id && length $candidate_id;
        next unless defined $channel && $channel =~ /^(?:playcount|last_played|library_age)$/;
        next unless defined $signal->{score} && $signal->{score} =~ /^-?(?:\d+(?:\.\d*)?|\.\d+)$/;
        $by_id{$candidate_id}{$channel} = {
            score => _bounded_score($signal->{score}),
            observation => ref($signal->{observation}) eq 'HASH'
                ? $signal->{observation} : {},
        };
    }

    my %channel_scores;
    my (%by_url, %known);
    for my $track (@$tracks) {
        my $url = eval { $track->url };
        next unless defined $url && length $url;
        my $source = $by_id{$url} || {};
        my $entry = {};
        for my $channel (qw(playcount last_played library_age)) {
            my $signal = $source->{$channel} || next;
            push @{$channel_scores{$channel}}, $signal->{score};
            $known{$channel}++;
            my $weight = _weight(
                $signal->{score}, _influence($policy, $channel)
            );
            if ($channel eq 'playcount') {
                $entry->{playcount_signal} = $signal->{score};
                $entry->{playcount_weight} = $weight;
                $entry->{playcount} = _integer($signal->{observation}->{playcount})
                    if exists $signal->{observation}->{playcount};
            } elsif ($channel eq 'last_played') {
                $entry->{last_played_signal} = $signal->{score};
                $entry->{last_played_weight} = $weight;
                $entry->{last_played} = _integer($signal->{observation}->{last_played})
                    if exists $signal->{observation}->{last_played};
            } else {
                $entry->{library_age_signal} = $signal->{score};
                $entry->{library_age_weight} = $weight;
                $entry->{added} = _integer($signal->{observation}->{added})
                    if exists $signal->{observation}->{added};
            }
        }
        $entry->{playcount_weight} ||= 1;
        $entry->{last_played_weight} ||= 1;
        $entry->{library_age_weight} ||= 1;
        $entry->{combined_weight} = $entry->{playcount_weight}
            * $entry->{last_played_weight} * $entry->{library_age_weight};
        $by_url{$url} = $entry;
    }

    my $playcount_influence = _influence($policy, 'playcount');
    my $last_played_influence = _influence($policy, 'last_played');
    my $library_age_influence = _influence($policy, 'library_age');
    my $playcount_distinct = _distinct_count($channel_scores{playcount});
    my $last_played_distinct = _distinct_count($channel_scores{last_played});
    my $library_age_distinct = _distinct_count($channel_scores{library_age});
    my $active = ($playcount_influence && $playcount_distinct > 1)
        || ($last_played_influence && $last_played_distinct > 1)
        || ($library_age_influence && $library_age_distinct > 1);

    return {
        active => $active ? 1 : 0,
        by_url => \%by_url,
        playcount_influence => $playcount_influence,
        last_played_influence => $last_played_influence,
        library_age_influence => $library_age_influence,
        known_playcount => $known{playcount} || 0,
        known_last_played => $known{last_played} || 0,
        known_library_age => $known{library_age} || 0,
        distinct_playcount => $playcount_distinct,
        distinct_last_played => $last_played_distinct,
        distinct_library_age => $library_age_distinct,
        as_of => 0 + $as_of,
        last_played_horizon_days => _horizon($policy->{last_played_horizon_days}, 180, 1825),
        library_age_horizon_days => _horizon($policy->{library_age_horizon_days}, 365, 3650),
    };
}

sub for_track {
    my ($profile, $track) = @_;
    my $url = eval { $track->url };
    return {} unless defined $url && ref($profile) eq 'HASH';
    return $profile->{by_url}{$url} || {};
}

sub _influence {
    my ($policy, $channel) = @_;
    my $key = $channel eq 'playcount' ? 'playcount_influence'
        : $channel eq 'last_played' ? 'last_played_influence'
        : 'library_age_influence';
    my $value = int($policy->{$key} || 0);
    $value = -100 if $value < -100;
    $value = 100 if $value > 100;
    return $value;
}

sub _horizon {
    my ($value, $default, $maximum) = @_;
    $value = int($value || $default);
    $value = 30 if $value < 30;
    $value = $maximum if $value > $maximum;
    return $value;
}

sub _weight {
    my ($signal, $influence) = @_;
    return exp(log(10) * ($influence / 100) * $signal);
}

sub _bounded_score {
    my $value = 0 + $_[0];
    $value = -1 if $value < -1;
    $value = 1 if $value > 1;
    return $value;
}

sub _bounded_positive_score {
    my $value = 0 + $_[0];
    $value = 0 if $value < 0;
    $value = 1 if $value > 1;
    return $value;
}

# Generic SPI track identity: expose existing LMS data with optional, host-
# resolved database_file. Never infer keys from titles, URLs, or MBIDs.
sub candidate_identity_for_track {
    my ($track, $resolve_database_file) = @_;
    return undef unless $track;
    my $candidate_id = eval { $track->url };
    return undef unless defined $candidate_id && length $candidate_id;
    my $urlmd5 = eval { $track->urlmd5 };
    my $database_file;
    if (ref($resolve_database_file) eq 'CODE') {
        $database_file = eval { $resolve_database_file->($track) };
        $database_file = undef if !defined $database_file || ref($database_file)
            || !length($database_file) || $database_file =~ /\0/;
    }
    my $recording_mbid = eval { $track->musicbrainz_id };
    my $artist_mbid = eval {
        $track->artist ? $track->artist->musicbrainz_id : undef
    };
    return {
        candidate_id => "$candidate_id",
        (defined $urlmd5 && length $urlmd5 ? (lms_urlmd5 => "$urlmd5") : ()),
        database_file => $database_file,
        title => eval { $track->title } || undef,
        artist => eval { $track->artistName } || undef,
        album => eval { $track->albumname } || undef,
        recording_mbid => defined $recording_mbid && length $recording_mbid
            ? "$recording_mbid" : undef,
        artist_mbids => defined $artist_mbid && length $artist_mbid
            ? ["$artist_mbid"] : [],
    };
}

# Compatibility wrapper used by existing Last.fm and Library Signals paths.
sub _candidate_for_track {
    return candidate_identity_for_track($_[0]);
}

sub _valid_source {
    my $value = shift;
    return defined $value && $value =~ /^(?:lyrion|alternative_play_count)$/;
}

sub _integer {
    return undef unless defined $_[0] && $_[0] =~ /^-?\d+$/;
    return 0 + $_[0];
}

sub _distinct_count {
    my $values = shift || [];
    my %distinct;
    $distinct{sprintf('%.12f', $_)} = 1 for @$values;
    return scalar keys %distinct;
}

1;
