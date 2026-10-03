package Plugins::BlissGuidance::SettingsModel;

use strict;
use warnings;

use Plugins::BlissGuidance::Policy;

sub provider_sections {
    my ($discovery, $all_host_state, $host_identity) = @_;
    $discovery = {} unless ref($discovery) eq 'HASH';
    $all_host_state = {} unless ref($all_host_state) eq 'HASH';
    $host_identity = {} unless ref($host_identity) eq 'HASH';

    my @providers = sort {
        ($a->{provider_id} || '~') cmp ($b->{provider_id} || '~')
    } grep { ref($_) eq 'HASH' } @{$discovery->{providers} || []};

    return [ map {
        _section($_, $all_host_state, $host_identity)
    } @providers ];
}

sub _section {
    my ($provider, $all_host_state, $host_identity) = @_;
    my $provider_id = $provider->{provider_id} || '';
    my $descriptor = ref($provider->{descriptor}) eq 'HASH' ? $provider->{descriptor} : {};
    my $defaults = ref($provider->{defaults}) eq 'HASH' ? $provider->{defaults} : {};
    my $host_state = Plugins::BlissGuidance::Policy::host_state(
        $all_host_state, $provider_id,
    );
    my $resolved = Plugins::BlissGuidance::Policy::resolve(
        $provider, $host_state, {},
    );
    my $labels = ref($host_identity->{source_labels}) eq 'HASH'
        ? $host_identity->{source_labels} : {};
    my $ui_labels = ref($host_identity->{ui_labels}) eq 'HASH'
        ? $host_identity->{ui_labels} : {};
    my $field_names = ref($host_identity->{field_names}) eq 'HASH'
        ? $host_identity->{field_names} : {};
    my $origin_label_token = ref($host_identity->{origin_label_token}) eq 'CODE'
        ? $host_identity->{origin_label_token} : undef;
    my $enabled_field = _field_name(
        $field_names->{enabled}, "pref_guidance_${provider_id}_enabled", $provider_id,
    );
    my @controls;

    for my $control (@{$descriptor->{controls} || []}) {
        next unless ref($control) eq 'HASH' && $control->{key};
        my $key = $control->{key};
        my $origin = $resolved->{origins}->{$key} || 'factory_default';
        my $field_name = _field_name(
            $field_names->{control}, "pref_guidance_${provider_id}_${key}", $provider_id, $key,
        );
        my $inherit_field_name = _field_name(
            $field_names->{inherit}, "inherit_guidance_${provider_id}_${key}", $provider_id, $key,
        );
        my $dirty_field_name = _field_name(
            $field_names->{dirty}, "dirty_guidance_${provider_id}_${key}", $provider_id, $key,
        );
        my $inherited_is_provider = exists $defaults->{$key};
        push @controls, {
            %$control,
            key => $key,
            label => $control->{label} || $key,
            help => $control->{help} || '',
            type => $control->{type} || '',
            render_as => $control->{render_as} || '',
            minimum => $control->{minimum},
            maximum => $control->{maximum},
            step => defined $control->{step} ? $control->{step} : 1,
            factory_default => $control->{factory_default},
            inherited_value => _inherited_value($provider, $control),
            effective_value => $resolved->{effective}->{$key},
            effective => $resolved->{effective}->{$key},
            origin => $origin,
            origin_label => $labels->{$origin} || $origin,
            origin_label_token => $origin_label_token
                ? $origin_label_token->($origin) : undef,
            host_overridable => $control->{host_overridable} ? 1 : 0,
            show_reset => $origin eq 'host_override' ? 1 : 0,
            field_name => $field_name,
            inherit_field_name => $inherit_field_name,
            dirty_field_name => $dirty_field_name,
            inherited => _inherited_value($provider, $control),
            inherited_origin => $inherited_is_provider
                ? 'provider_default' : 'factory_default',
            inherited_origin_label_token => $origin_label_token
                ? $origin_label_token->($inherited_is_provider
                    ? 'provider_default' : 'factory_default') : undef,
            origin_prefix_label => _ui_label(
                $ui_labels, 'origin_prefix', 'Effective value source:',
            ),
            host_origin_label => _ui_label(
                $ui_labels, 'host_origin', $labels->{host_override} || 'Host setting',
            ),
            origin_pending_label => _ui_label(
                $ui_labels, 'origin_pending', '(will apply when saved)',
            ),
            reset_label => _ui_label(
                $ui_labels, 'reset', 'Use inherited default',
            ),
            enum_values => ref($control->{values}) eq 'ARRAY'
                ? $control->{values} : [],
            form_id => "guidance_${provider_id}_${key}",
            marker_id => "guidance_${provider_id}_${key}_origin",
        };
    }

    my $display_name = $descriptor->{display_name} || $provider_id;
    return {
        provider_id => $provider_id,
        display_name => $display_name,
        available => $provider->{available} ? 1 : 0,
        diagnostic => $provider->{diagnostic} || '',
        enabled => $resolved->{enabled} ? 1 : 0,
        policy_valid => $resolved->{valid} ? 1 : 0,
        policy_diagnostic => $resolved->{diagnostic} || '',
        enable_field_name => $enabled_field,
        settings_uri => $descriptor->{settings_uri} || '',
        available_label => _ui_label(
            $ui_labels, 'available', 'Provider backend is available.', $provider->{diagnostic} || '',
        ),
        unavailable_label => _ui_label(
            $ui_labels, 'unavailable', 'Provider backend is unavailable.', $provider->{diagnostic} || '',
        ),
        settings_link_label => _ui_label(
            $ui_labels, 'settings', "Open $display_name settings", $display_name,
        ),
        enabled_label => _ui_label(
            $ui_labels, 'enabled', 'Use this provider',
        ),
        enabled_desc => _ui_label(
            $ui_labels, 'enabled_desc', '',
        ),
        controls => \@controls,
    };
}

sub _ui_label {
    my ($labels, $name, $fallback, @args) = @_;
    my $label = $labels->{$name};
    return $label->(@args) if ref($label) eq 'CODE';
    return $label if defined $label;
    return $fallback;
}

sub _field_name {
    my ($builder, $fallback, @args) = @_;
    return $builder->(@args) if ref($builder) eq 'CODE';
    return $fallback;
}

sub _inherited_value {
    my ($provider, $control) = @_;
    my $defaults = ref($provider->{defaults}) eq 'HASH' ? $provider->{defaults} : {};
    my $key = $control->{key};
    return exists $defaults->{$key}
        ? $defaults->{$key} : $control->{factory_default};
}

1;
