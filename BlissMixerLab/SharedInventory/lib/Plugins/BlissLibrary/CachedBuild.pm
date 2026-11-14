package Plugins::BlissLibrary::CachedBuild;
use strict;
use warnings;
use Plugins::BlissLibrary::BuildLock;
use Plugins::BlissLibrary::Cache;
use Plugins::BlissLibrary::CandidateInventory;

sub run {
    my %args = @_;
    die 'Freshness check is required' unless ref($args{fresh}) eq 'CODE';
    die 'Inventory builder is required' unless ref($args{build}) eq 'CODE';
    my %identity = (scope => $args{scope}, source => $args{source});
    my $lock = Plugins::BlissLibrary::BuildLock::try_acquire($args{dir}, %identity);
    return {state => 'busy'} unless $lock;
    die 'Inventory source is no longer current' unless $args{fresh}->();
    my $inventory = Plugins::BlissLibrary::Cache::get($args{dir}, %identity);
    my $state = 'cached';
    unless ($inventory) {
        Plugins::BlissLibrary::Cache::_recover_invalid($args{dir}, %identity);
        $inventory = $args{build}->();
        die 'Builder returned an inventory for a different generation' unless
            Plugins::BlissLibrary::CandidateInventory::validate_inventory($inventory, %identity);
        $state = 'built';
    }
    die 'Inventory source changed during retrieval or build' unless $args{fresh}->();
    if ($state eq 'built') {
        Plugins::BlissLibrary::Cache::_recover_orphan($args{dir}, $inventory);
        Plugins::BlissLibrary::Cache::put($args{dir}, $inventory);
    }
    $lock->release;
    return {state => $state, inventory => $inventory};
}
1;
