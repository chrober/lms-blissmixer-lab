package Plugins::BlissLibrary::BundleGuard;
use strict;
use warnings;
use Digest::SHA ();
use File::Spec;
use Plugins::BlissLibrary::CandidateInventory;

my $registered;
my @modules = qw(Builder BuildLock BundleGuard Cache CachedBuild CandidateInventory Coordinator FileIdentity JsonCodec LyrionRefresh MixerAdapter MixerClient OptimizerAdapter RefreshQueue RefreshRuntime ScopeRegistry SourceIdentity Store Worker);

sub _digest {
    my ($path) = @_;
    open my $fh, '<:raw', $path or die "Shared inventory bundle file is unavailable: $path";
    my $sha = Digest::SHA->new(256);
    $sha->addfile($fh);
    close $fh or die "Cannot close shared inventory bundle file: $path";
    return $sha->hexdigest;
}

sub register {
    my ($root) = @_;
    die 'Shared inventory bundle directory is unavailable' unless defined($root) && -d $root;
    Plugins::BlissLibrary::CandidateInventory::require_contract_version('0.1.0');
    my @digests;
    for my $module (@modules) {
        my $relative = "Plugins/BlissLibrary/$module.pm";
        my $path = File::Spec->catfile($root, 'lib', 'Plugins', 'BlissLibrary', "$module.pm");
        my $digest = _digest($path);
        if (exists $INC{$relative}) {
            die "Loaded shared inventory module cannot be verified: $relative" if !defined($INC{$relative}) || ref($INC{$relative});
            die "Loaded shared inventory module differs from this bundle: $relative" unless _digest($INC{$relative}) eq $digest;
        }
        push @digests, "$relative:$digest";
    }
    push @digests, 'worker:' . _digest(File::Spec->catfile($root, 'bin', 'build-inventory.pl'));
    my $identity = Digest::SHA::sha256_hex(join("\n", @digests));
    die 'Incompatible shared inventory bundles are loaded' if defined($registered) && $registered ne $identity;
    $registered = $identity;
    return 1;
}
1;
