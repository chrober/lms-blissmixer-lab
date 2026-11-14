package Plugins::BlissLibrary::OptimizerAdapter;
use strict;
use warnings;
use Plugins::BlissLibrary::CandidateInventory;

sub make_payload {
    my %args = @_;
    my $inventory = $args{inventory};
    die 'Invalid or mismatched candidate inventory' unless
        Plugins::BlissLibrary::CandidateInventory::validate_inventory(
            $inventory, scope => $args{scope}, source => $args{source});
    my $metadata = $args{metadata};
    die 'Optimizer inventory metadata is required' unless ref($metadata) eq 'HASH';
    my $identity = $metadata->{database_cache_identity};
    die 'Optimizer database identity is invalid' unless defined($identity) && !ref($identity)
        && length($identity) && length($identity) <= 256;
    my %numbers;
    for my $key (qw(generated_at lms_scan_time lms_local_track_count usable_bliss_row_count)) {
        my $value = $metadata->{$key};
        die "Optimizer metadata $key is invalid" unless defined($value) && !ref($value)
            && "$value" =~ /\A(?:0|[1-9][0-9]{0,14})\z/;
        $numbers{$key} = 0 + $value;
    }
    return {schema_version => 1, schema_identity => 'lms-local-candidate-inventory-v1',
        %numbers, database_cache_identity => "$identity",
        allowed_row_ids => [map { 0 + $_ } @{$inventory->{row_ids}}]};
}
1;
