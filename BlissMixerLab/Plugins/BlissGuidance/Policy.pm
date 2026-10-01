package Plugins::BlissGuidance::Policy;

use strict;
use warnings;

sub resolve {
    my ($provider, $host_state, $job_overrides) = @_;
    $host_state = {} unless ref($host_state) eq 'HASH';
    $job_overrides = {} unless ref($job_overrides) eq 'HASH';
    my $descriptor = ref($provider) eq 'HASH' && ref($provider->{descriptor}) eq 'HASH'
        ? $provider->{descriptor} : {};
    my $defaults = ref($provider) eq 'HASH' && ref($provider->{defaults}) eq 'HASH'
        ? $provider->{defaults} : {};
    my $host_values = ref($host_state->{overrides}) eq 'HASH'
        ? $host_state->{overrides} : {};
    my $job_values = ref($job_overrides->{overrides}) eq 'HASH'
        ? $job_overrides->{overrides} : {};
    my (%effective, %origins);

    for my $control (@{$descriptor->{controls} || []}) {
        next unless ref($control) eq 'HASH' && $control->{key};
        my $key = $control->{key};
        my ($value, $origin);
        if (exists $job_values->{$key}) {
            ($value, $origin) = ($job_values->{$key}, 'job_override');
        } elsif (exists $host_values->{$key}) {
            ($value, $origin) = ($host_values->{$key}, 'host_override');
        } elsif (exists $defaults->{$key}) {
            ($value, $origin) = ($defaults->{$key}, 'provider_default');
        } else {
            ($value, $origin) = ($control->{factory_default}, 'factory_default');
        }
        my $error = _validate_value($control, $value);
        return _invalid($provider, $error, $key) if $error;
        $effective{$key} = _normalize_value($control, $value);
        $origins{$key} = $origin;
    }

    my $enabled = exists $job_overrides->{enabled}
        ? _boolean($job_overrides->{enabled})
        : exists $host_state->{enabled}
            ? _boolean($host_state->{enabled}) : 0;
    return {
        valid => 1,
        enabled => $enabled,
        effective => \%effective,
        origins => \%origins,
        provider_revision => int($defaults->{settings_revision} || 0),
        descriptor_version => int($descriptor->{settings_schema_version} || 0),
        diagnostic => '',
    };
}

sub host_state {
    my ($all_state, $provider_id) = @_;
    $all_state = {} unless ref($all_state) eq 'HASH';
    my $providers = ref($all_state->{providers}) eq 'HASH'
        ? $all_state->{providers} : {};
    my $state = ref($providers->{$provider_id}) eq 'HASH'
        ? $providers->{$provider_id} : {};
    return {
        enabled => $state->{enabled} ? 1 : 0,
        overrides => ref($state->{overrides}) eq 'HASH'
            ? { %{$state->{overrides}} } : {},
    };
}

sub replace_host_state {
    my ($all_state, $provider_id, $state) = @_;
    $all_state = {} unless ref($all_state) eq 'HASH';
    $state = {} unless ref($state) eq 'HASH';
    my %copy = %$all_state;
    $copy{schema_version} = 1;
    $copy{providers} = {
        %{ref($all_state->{providers}) eq 'HASH' ? $all_state->{providers} : {}},
        $provider_id => {
            enabled => $state->{enabled} ? 1 : 0,
            overrides => ref($state->{overrides}) eq 'HASH'
                ? { %{$state->{overrides}} } : {},
        },
    };
    return \%copy;
}

sub _invalid {
    my ($provider, $error, $key) = @_;
    my $defaults = ref($provider) eq 'HASH' && ref($provider->{defaults}) eq 'HASH'
        ? $provider->{defaults} : {};
    my $descriptor = ref($provider) eq 'HASH' && ref($provider->{descriptor}) eq 'HASH'
        ? $provider->{descriptor} : {};
    return {
        valid => 0,
        enabled => 0,
        effective => {},
        origins => {},
        provider_revision => int($defaults->{settings_revision} || 0),
        descriptor_version => int($descriptor->{settings_schema_version} || 0),
        diagnostic => "invalid '$key': $error",
    };
}

sub _boolean { return $_[0] ? 1 : 0; }

sub _normalize_value {
    my ($control, $value) = @_;
    return int($value) if $control->{type} eq 'integer';
    return _boolean($value) if $control->{type} eq 'boolean';
    return "$value";
}

sub _validate_value {
    my ($control, $value) = @_;
    return 'missing value' unless defined $value;
    if ($control->{type} eq 'integer') {
        return 'must be an integer' unless $value =~ /^-?\d+$/;
        return 'is below its minimum' if $value < $control->{minimum};
        return 'is above its maximum' if $value > $control->{maximum};
        return '';
    }
    if ($control->{type} eq 'boolean') {
        return 'must be boolean' unless $value =~ /^(?:0|1)$/;
        return '';
    }
    if ($control->{type} eq 'enum') {
        my %allowed = map { $_ => 1 } @{$control->{values} || []};
        return 'is not an allowed option' unless $allowed{$value};
        return '';
    }
    return 'has an unsupported type';
}

1;
