package Plugins::BlissLibrary::CandidateInventory;
use strict;
use warnings;
use Digest::SHA qw(sha256_hex);
use Plugins::BlissLibrary::JsonCodec;

our $VERSION = '0.1.0';
my $SCHEMA = 'bliss-candidate-inventory-v1';
my $BUILDER_REVISION = 3;
my @SOURCE_KEYS = qw(lyrion_database bliss_database scan_generation media_roots membership);

sub require_contract_version {
    my ($expected) = @_;
    die 'Expected candidate inventory version is required' unless defined($expected) && !ref($expected) && length($expected);
    die "Incompatible candidate inventory version: expected $expected, loaded $VERSION" unless $expected eq $VERSION;
    return 1;
}

sub _canonical {
    return Plugins::BlissLibrary::JsonCodec::canonical()->encode($_[0]);
}

sub _scope {
    my ($scope) = @_;
    die 'Scope must be an object' unless ref($scope) eq 'HASH';
    my $kind = $scope->{kind};
    die 'Unknown scope' unless defined($kind) && !ref($kind)
        && ($kind eq 'all' || $kind eq 'library');
    if ($kind eq 'all') {
        die 'Unrestricted scope must not have an ID' if exists $scope->{id};
        return {kind => 'all'};
    }
    my $id = $scope->{id};
    die 'Library scope requires an ID' unless defined($id) && !ref($id) && length($id);
    return {kind => 'library', id => "$id"};
}

sub _source {
    my ($source) = @_;
    die 'Source identity must be an object' unless ref($source) eq 'HASH';
    my %identity;
    for my $key (@SOURCE_KEYS) {
        my $value = $source->{$key};
        die "Missing source identity: $key" unless defined($value) && !ref($value) && length($value);
        $identity{$key} = "$value";
    }
    return \%identity;
}

sub _sorted_ids {
    my ($ids) = @_;
    die 'Row IDs must be an array' unless ref($ids) eq 'ARRAY';
    my %seen;
    my @ids;
    for my $item (@$ids) {
        my $id = $item;
        die 'Invalid row ID' unless defined($id) && !ref($id)
            && "$id" =~ /\A[1-9][0-9]{0,14}\z/;
        die 'Duplicate row ID' if $seen{"$id"}++;
        push @ids, 0 + $id;
    }
    return [sort { $a <=> $b } @ids];
}

sub membership_digest {
    my ($scope, $ids) = @_;
    return sha256_hex(_canonical({scope => _scope($scope), track_ids => _sorted_ids($ids)}));
}

sub membership_digest_ordered {
    my ($scope, $next) = @_;
    die 'Membership iterator is required' unless ref($next) eq 'CODE';
    my $sha = Digest::SHA->new(256);
    $sha->add('{"scope":', _canonical(_scope($scope)), ',"track_ids":[');
    my ($previous, $separator);
    while (defined(my $row = $next->())) {
        die 'Invalid membership iterator result' unless ref($row) eq 'ARRAY' && @$row == 1;
        my $id = $row->[0];
        die 'Invalid row ID' unless defined($id) && !ref($id) && "$id" =~ /\A[1-9][0-9]{0,14}\z/;
        die 'Membership IDs are not strictly increasing' if defined($previous) && $id <= $previous;
        $sha->add($separator || '', "$id");
        $separator = ',';
        $previous = $id;
    }
    $sha->add(']}');
    return $sha->hexdigest;
}

sub cache_key {
    my %args = @_;
    return sha256_hex(_canonical({schema => $SCHEMA, builder_revision => $BUILDER_REVISION,
        scope => _scope($args{scope}), source => _source($args{source})}));
}

sub make_inventory {
    my %args = @_;
    my $scope = _scope($args{scope});
    my $source = _source($args{source});
    my $ids = _sorted_ids($args{row_ids});
    my $body = {schema => $SCHEMA, scope => $scope, source => $source, row_ids => $ids};
    return {%$body, sha256 => sha256_hex(_canonical($body))};
}

sub validate_inventory {
    my ($inventory, %expected) = @_;
    return 0 unless ref($inventory) eq 'HASH';
    my $valid = eval {
        die 'Unknown schema' unless ($inventory->{schema} || '') eq $SCHEMA;
        my $actual = make_inventory(
            scope => $inventory->{scope}, source => $inventory->{source}, row_ids => $inventory->{row_ids},
        );
        die 'Wrong scope or source' unless _canonical($actual->{scope}) eq _canonical(_scope($expected{scope}))
            && _canonical($actual->{source}) eq _canonical(_source($expected{source}));
        die 'Noncanonical inventory or bad checksum' unless _canonical($inventory) eq _canonical($actual);
        1;
    };
    return $valid ? 1 : 0;
}
1;
