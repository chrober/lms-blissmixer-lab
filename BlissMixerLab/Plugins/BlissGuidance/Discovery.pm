package Plugins::BlissGuidance::Discovery;

use strict;
use warnings;
use Slim::Utils::PluginManager;

use constant DESCRIPTOR_PROTOCOL_VERSION => 1;
use constant NATIVE_SPI_VERSION => 2;
use constant NATIVE_PROTOCOL => 'bliss-guidance-jsonl-v2';

sub discover {
    my @entries;
    for my $module (sort Slim::Utils::PluginManager->enabledPlugins()) {
        next unless $module && $module->can('guidance_provider_descriptor_v1');
        my ($descriptor, $error);
        eval { $descriptor = $module->guidance_provider_descriptor_v1(); };
        $error = $@;
        my $validation = $error ? "descriptor call failed: $error"
            : _validate_descriptor($descriptor);
        my $entry = {
            module => $module,
            provider_id => ref($descriptor) eq 'HASH' ? ($descriptor->{provider_id} || '') : '',
            descriptor => $descriptor,
            available => $validation ? 0 : 1,
            diagnostic => $validation || '',
            defaults => {},
            status => {},
        };
        _load_runtime($entry) unless $validation;
        push @entries, $entry;
    }

    my %by_provider_id;
    push @{$by_provider_id{$_->{provider_id}}}, $_
        for grep { $_->{provider_id} ne '' } @entries;
    for my $provider_id (keys %by_provider_id) {
        my $matches = $by_provider_id{$provider_id};
        next unless @$matches > 1;
        for my $entry (@$matches) {
            $entry->{available} = 0;
            $entry->{diagnostic} = "duplicate guidance provider ID '$provider_id'";
        }
    }

    @entries = sort {
        ($a->{provider_id} || '~') cmp ($b->{provider_id} || '~')
            || $a->{module} cmp $b->{module}
    } @entries;
    return { providers => \@entries };
}

sub native_spi_config {
    my ($provider, $resolved_policy, $trusted_context) = @_;
    die 'guidance provider is unavailable'
        unless ref($provider) eq 'HASH' && $provider->{available};
    my $module = $provider->{module} || '';
    die 'guidance provider has no native SPI factory'
        unless $module && $module->can('guidance_provider_native_spi_config_v1');
    my $config = $module->guidance_provider_native_spi_config_v1(
        $resolved_policy, $trusted_context,
    );
    my $error = _validate_native_config($provider->{descriptor}, $config);
    die "invalid native SPI configuration: $error" if $error;
    return $config;
}

sub process_environment {
    my ($provider, $resolved_policy, $trusted_context) = @_;
    die 'guidance provider is unavailable'
        unless ref($provider) eq 'HASH' && $provider->{available};
    my $module = $provider->{module} || '';
    return {} unless $module && $module->can('guidance_provider_process_environment_v1');

    my ($environment, $call_error);
    eval {
        $environment = $module->guidance_provider_process_environment_v1(
            $resolved_policy, $trusted_context,
        );
    };
    $call_error = $@;
    die 'invalid provider process environment' if $call_error;
    my $error = _validate_process_environment($environment);
    die 'invalid provider process environment' if $error;
    return { %$environment };
}

sub acquire_artifacts {
    my ($provider, $resolved_policy, $trusted_context, $callback) = @_;
    die 'guidance provider is unavailable'
        unless ref($provider) eq 'HASH' && $provider->{available};
    die 'provider acquisition callback is required' unless ref($callback) eq 'CODE';
    my $module = $provider->{module} || '';
    return $callback->({ available => 1, artifacts => [], diagnostic => '' })
        unless $module && $module->can('guidance_provider_acquire_artifacts_v1');

    my $delivered = 0;
    my $deliver = sub {
        return if $delivered++;
        my $result = shift;
        return $callback->({
            available => 0,
            artifacts => [],
            diagnostic => 'provider artifact acquisition returned an invalid result',
        }) if _validate_acquisition_result($result);
        return $callback->({
            available => $result->{available} ? 1 : 0,
            artifacts => [ @{$result->{artifacts}} ],
            diagnostic => defined $result->{diagnostic} ? $result->{diagnostic} : '',
        });
    };
    my $call_error;
    eval {
        $module->guidance_provider_acquire_artifacts_v1(
            $resolved_policy, $trusted_context, $deliver,
        );
        1;
    } or $call_error = $@;
    return $deliver->({
        available => 0,
        artifacts => [],
        diagnostic => 'provider artifact acquisition failed',
    }) if $call_error;
    return;
}

sub _load_runtime {
    my $entry = shift;
    my $module = $entry->{module};
    for my $method (qw(guidance_provider_defaults_v1 guidance_provider_status_v1)) {
        unless ($module->can($method)) {
            $entry->{available} = 0;
            $entry->{diagnostic} = "provider does not implement $method";
            return;
        }
    }
    my ($defaults, $status, $error);
    eval {
        $defaults = $module->guidance_provider_defaults_v1();
        $status = $module->guidance_provider_status_v1();
    };
    $error = $@;
    if ($error || ref($defaults) ne 'HASH' || ref($status) ne 'HASH') {
        $entry->{available} = 0;
        $entry->{diagnostic} = $error ? "provider runtime call failed: $error"
            : 'provider defaults or status is not an object';
        return;
    }
    my $validation = _validate_defaults($entry->{descriptor}, $defaults);
    if ($validation) {
        $entry->{available} = 0;
        $entry->{diagnostic} = "invalid provider defaults: $validation";
        return;
    }
    $entry->{defaults} = $defaults;
    $entry->{status} = $status;
    unless ($status->{available}) {
        $entry->{available} = 0;
        $entry->{diagnostic} = $status->{reason} || 'provider backend is unavailable';
    }
}

sub _validate_descriptor {
    my $descriptor = shift;
    return 'descriptor is not an object' unless ref($descriptor) eq 'HASH';
    return 'protocol_version must be 1'
        unless ($descriptor->{protocol_version} || 0) == DESCRIPTOR_PROTOCOL_VERSION;
    return 'provider_id is invalid'
        unless ($descriptor->{provider_id} || '') =~ /^[a-z][a-z0-9-]{1,63}$/;
    return 'display_name is required'
        unless defined $descriptor->{display_name} && length $descriptor->{display_name};
    return 'settings_uri is invalid'
        if exists $descriptor->{settings_uri} && $descriptor->{settings_uri}
            !~ m{^plugins/[A-Za-z0-9]+/settings/[A-Za-z0-9_-]+\.html$};
    return 'capabilities must be a non-empty array'
        unless ref($descriptor->{capabilities}) eq 'ARRAY' && @{$descriptor->{capabilities}};
    return 'scopes must be a non-empty array'
        unless ref($descriptor->{scopes}) eq 'ARRAY' && @{$descriptor->{scopes}};
    return 'settings_schema_version must be a positive integer'
        unless ($descriptor->{settings_schema_version} || 0) =~ /^\d+$/
            && $descriptor->{settings_schema_version} > 0;
    my $controls = $descriptor->{controls};
    return 'controls must be an array' unless ref($controls) eq 'ARRAY';
    my %keys;
    for my $control (@$controls) {
        return 'control is not an object' unless ref($control) eq 'HASH';
        return 'control key is invalid'
            unless ($control->{key} || '') =~ /^[a-z][a-z0-9_]{1,63}$/ && !$keys{$control->{key}}++;
        return 'control type is invalid'
            unless ($control->{type} || '') =~ /^(?:integer|boolean|enum)$/;
        return 'control host_overridable must be boolean'
            unless defined $control->{host_overridable} && $control->{host_overridable} =~ /^(?:0|1)$/;
        return 'control render_as is invalid'
            if exists $control->{render_as}
                && ($control->{type} ne 'integer' || $control->{render_as} !~ /^(?:slider|number)$/);
        if (exists $control->{option_labels}) {
            return 'control option_labels is invalid'
                unless $control->{type} eq 'enum'
                    && ref($control->{option_labels}) eq 'HASH';
            my %allowed = map { $_ => 1 } @{ref($control->{values}) eq 'ARRAY'
                ? $control->{values} : []};
            for my $value (keys %{$control->{option_labels}}) {
                return 'control option_labels contains an unknown option'
                    unless $allowed{$value};
                return 'control option_labels value is invalid'
                    unless defined $control->{option_labels}->{$value}
                        && length $control->{option_labels}->{$value};
            }
        }
        if ($control->{type} eq 'integer') {
            return 'integer control bounds/default are invalid'
                unless defined $control->{minimum} && defined $control->{maximum}
                    && defined $control->{factory_default}
                    && $control->{minimum} =~ /^-?\d+$/
                    && $control->{maximum} =~ /^-?\d+$/
                    && $control->{factory_default} =~ /^-?\d+$/
                    && $control->{minimum} <= $control->{factory_default}
                    && $control->{factory_default} <= $control->{maximum};
        }
        return 'control guidance_channel is invalid'
            if exists $control->{guidance_channel}
                && $control->{guidance_channel} !~ /^[a-z][a-z0-9_]{1,63}$/;
    }
    my $native = $descriptor->{native_spi};
    return 'native_spi is not an object' unless ref($native) eq 'HASH';
    return 'native provider ID is invalid'
        unless ($native->{provider_id} || '') =~ /^[a-z][a-z0-9-]{1,63}$/;
    return 'native SPI version is unsupported'
        unless ($native->{spi_version} || 0) == NATIVE_SPI_VERSION;
    return 'native protocol is unsupported'
        unless ($native->{protocol} || '') eq NATIVE_PROTOCOL;
    return 'native channel mapping is missing'
        unless ref($native->{channels}) eq 'HASH' && keys %{$native->{channels}};
    my %native_channels = map { $native->{channels}->{$_} => 1 } keys %{$native->{channels}};
    for my $control (@$controls) {
        next unless exists $control->{guidance_channel};
        return 'control guidance_channel is not declared by native_spi'
            unless $native_channels{$control->{guidance_channel}};
    }
    for my $kind (qw(artifact_kinds resource_kinds)) {
        return "$kind must be an array" unless ref($native->{$kind}) eq 'ARRAY';
    }
    return '';
}

sub _validate_defaults {
    my ($descriptor, $defaults) = @_;
    for my $control (@{$descriptor->{controls} || []}) {
        my $key = $control->{key};
        my $value = exists $defaults->{$key} ? $defaults->{$key} : $control->{factory_default};
        return "missing default '$key'" unless defined $value;
        if ($control->{type} eq 'integer') {
            return "default '$key' is invalid" unless $value =~ /^-?\d+$/
                && $value >= $control->{minimum} && $value <= $control->{maximum};
        }
    }
    return '';
}

sub _validate_native_config {
    my ($descriptor, $config) = @_;
    return 'configuration is not an object' unless ref($config) eq 'HASH';
    return 'configuration ID does not match descriptor'
        unless ($config->{id} || '') eq $descriptor->{native_spi}->{provider_id};
    return 'configuration program is missing' unless $config->{program};
    return 'configuration options is not an object' unless ref($config->{options}) eq 'HASH';
    return 'configuration artifacts is not an array' unless ref($config->{artifacts}) eq 'ARRAY';
    return 'configuration resources is not an array' unless ref($config->{resources}) eq 'ARRAY';
    return '';
}

sub _validate_process_environment {
    my $environment = shift;
    return 'environment is not an object' unless ref($environment) eq 'HASH';
    for my $name (keys %$environment) {
        return 'environment variable name is invalid'
            unless defined $name && $name =~ /^[A-Za-z_][A-Za-z0-9_]*$/;
        return 'environment variable value is invalid'
            unless defined $environment->{$name} && !ref($environment->{$name});
    }
    return '';
}

sub _validate_acquisition_result {
    my $result = shift;
    return 'result is not an object' unless ref($result) eq 'HASH';
    return 'available is invalid'
        unless defined $result->{available} && $result->{available} =~ /^(?:0|1)$/;
    return 'artifacts is not an array' unless ref($result->{artifacts}) eq 'ARRAY';
    return 'diagnostic is invalid'
        if exists $result->{diagnostic} && (!defined $result->{diagnostic} || ref($result->{diagnostic}));
    for my $artifact (@{$result->{artifacts}}) {
        return 'artifact is not an object' unless ref($artifact) eq 'HASH';
        return 'artifact kind is invalid'
            unless ($artifact->{kind} || '') =~ /^[a-z][a-z0-9-]{1,63}$/;
        return 'artifact path is invalid'
            unless defined $artifact->{path} && length $artifact->{path} && !ref($artifact->{path});
    }
    return '';
}

1;
