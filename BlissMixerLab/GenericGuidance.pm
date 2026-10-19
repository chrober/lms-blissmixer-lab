package Plugins::BlissMixerLab::GenericGuidance;

use strict;
use warnings;

use Plugins::BlissMixerLab::GuidanceProviderAdapter;

# SPI v2 is intentionally independent of the original provider names.
# Previously integrated providers retain their established selection and log
# formatters until parity has been demonstrated.
sub provider_channels {
    my $descriptor = shift || {};
    my $controls = $descriptor->{controls};
    return {} unless ref($controls) eq 'ARRAY';
    my %channels;
    for my $control (@$controls) {
        next unless ref($control) eq 'HASH';
        my $channel = $control->{guidance_channel};
        my $key = $control->{key};
        next unless defined $channel && $channel =~ /^[a-z][a-z0-9_]*$/;
        next unless defined $key && $key =~ /^[a-z][a-z0-9_]*$/;
        next if defined $control->{guidance_policy}
            && $control->{guidance_policy} ne 'bounded_influence';
        next unless ($control->{type} || '') eq 'integer'
            && defined $control->{minimum}
            && defined $control->{maximum}
            && $control->{minimum} <= 0
            && $control->{maximum} >= 0
            && $control->{minimum} >= -100
            && $control->{maximum} <= 100;
        $channels{$channel} = $key;
    }
    return \%channels;
}

sub has_influence {
    my $providers = shift || [];
    for my $entry (@$providers) {
        my $controls = provider_channels($entry->{provider}{descriptor});
        my $effective = $entry->{resolved}{effective} || {};
        for my $channel (keys %$controls) {
            return 1 if _influence($effective->{$controls->{$channel}});
        }
    }
    return 0;
}

sub score_enabled_providers {
    my ($providers, $seeds, $tracks, $operations) = @_;
    $providers = [] unless ref($providers) eq 'ARRAY';
    $seeds = [] unless ref($seeds) eq 'ARRAY';
    $tracks = [] unless ref($tracks) eq 'ARRAY';
    $operations = {} unless ref($operations) eq 'HASH';
    my $neutral = { active => 0, by_url => {}, providers => [], diagnostics => [] };
    return $neutral unless @$providers && @$tracks;

    my $native_config = $operations->{native_config};
    my $score_batch = $operations->{score_batch};
    return $neutral unless ref($native_config) eq 'CODE'
        && ref($score_batch) eq 'CODE';

    my $identity = $operations->{database_file};
    my @candidates = grep { defined $_ } map {
        Plugins::BlissMixerLab::GuidanceProviderAdapter::candidate_identity_for_track($_, $identity)
    } @$tracks;
    my %admitted = map { $_->{candidate_id} => 1 } @candidates;
    my @anchors;
    my @context_ids;
    for my $index (0 .. $#$seeds) {
        my $anchor = Plugins::BlissMixerLab::GuidanceProviderAdapter::candidate_identity_for_track(
            $seeds->[$index], $identity
        );
        next unless $anchor;
        my $anchor_id = 'seed-' . ($index + 1);
        push @anchors, { anchor_id => $anchor_id, %$anchor };
        push @context_ids, $anchor_id;
    }

    my %combined;
    my @details;
    for my $entry (@$providers) {
        next unless ref($entry) eq 'HASH';
        my $provider = $entry->{provider};
        my $resolved = $entry->{resolved};
        next unless ref($provider) eq 'HASH' && ref($resolved) eq 'HASH'
            && $resolved->{valid} && $resolved->{enabled}
            && $provider->{available};
        my $channels = provider_channels($provider->{descriptor});
        my $effective = $resolved->{effective} || {};
        my %weights_by_channel;
        for my $channel (keys %$channels) {
            my $influence = _influence($effective->{$channels->{$channel}});
            $weights_by_channel{$channel} = $influence if $influence;
        }
        next unless %weights_by_channel;

        my $provider_id = $provider->{provider_id} || '';
        next unless $provider_id =~ /^[A-Za-z0-9._-]+$/;
        my $result = eval {
            my $config = $native_config->($provider, $effective, {});
            $score_batch->($config, {
                job_id => 'blissmixerlab',
                request_id => 'dstm-candidate-pool',
                deadline_ms => 500,
                anchors => \@anchors,
                context => {
                    scope => 'global',
                    left_anchor_id => undef,
                    right_anchor_id => undef,
                    context_track_ids => \@context_ids,
                },
                candidates => \@candidates,
            }, $effective, $provider);
        };
        unless (ref($result) eq 'HASH' && $result->{valid}
            && ref($result->{signals}) eq 'ARRAY') {
            push @details, { provider_id => $provider_id, status => 'neutral' };
            next;
        }
        my (%latest, %variation);
        for my $signal (@{$result->{signals}}) {
            next unless ref($signal) eq 'HASH';
            my $id = $signal->{candidate_id};
            my $channel = $signal->{channel};
            next unless defined $id && $admitted{$id};
            next unless defined $channel && exists $weights_by_channel{$channel};
            my $value = $signal->{score};
            next unless _valid_score($value);
            $value = _bounded_score($value);
            $latest{$id}{$channel} = $value;
        }

        # Score uniformity within a head is not evidence to rerank by it.
        for my $channel (keys %weights_by_channel) {
            my %distinct;
            for my $id (keys %latest) {
                next unless exists $latest{$id}{$channel};
                $distinct{sprintf('%.12f', $latest{$id}{$channel})} = 1;
            }
            $variation{$channel} = keys(%distinct) > 1 ? 1 : 0;
        }

        my $used = 0;
        for my $id (keys %latest) {
            for my $channel (keys %{$latest{$id}}) {
                next unless $variation{$channel};
                $combined{$id} ||= 1;
                $combined{$id} *= exp(
                    log(10) * ($weights_by_channel{$channel} / 100)
                    * $latest{$id}{$channel}
                );
                $used++;
            }
        }
        push @details, {
            provider_id => $provider_id, status => $used ? 'active' : 'neutral',
            signals_used => $used,
        };
    }

    return {
        active => scalar(keys %combined) ? 1 : 0,
        by_url => { map { $_ => { combined_weight => $combined{$_} } } keys %combined },
        providers => [map { $_->{provider_id} } grep { $_->{status} eq 'active' } @details],
        diagnostics => \@details,
    };
}

sub _valid_score {
    my $value = shift;
    return defined $value && !ref($value)
        && $value =~ /^-?(?:\d+(?:\.\d*)?|\.\d+)$/;
}

sub _bounded_score {
    my $value = 0 + shift;
    return -1 if $value < -1;
    return 1 if $value > 1;
    return $value;
}

sub _influence {
    my $value = shift;
    return 0 unless defined $value && !ref($value)
        && $value =~ /^-?\d+$/;
    $value = 0 + $value;
    return -100 if $value < -100;
    return 100 if $value > 100;
    return $value;
}

1;
