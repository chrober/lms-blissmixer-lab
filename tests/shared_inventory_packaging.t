use strict;
use warnings;
use Test::More;

open my $fh, '<', '.github/workflows/release.yml' or die $!;
my $workflow = do { local $/; <$fh> };
close $fh;
like($workflow, qr{unzip -p .*BlissMixerLab/SharedInventory/bin/build-inventory\.pl}, 'release verifies the shared worker is packaged');
like($workflow, qr{unzip -p .*BlissMixerLab/SharedInventory/lib/Plugins/BlissLibrary/BundleGuard\.pm}, 'release verifies the shared module bundle is packaged');
done_testing();
