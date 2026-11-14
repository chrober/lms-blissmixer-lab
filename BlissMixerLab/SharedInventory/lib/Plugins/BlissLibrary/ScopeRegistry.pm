package Plugins::BlissLibrary::ScopeRegistry;
use strict;
use warnings;
use Digest::SHA qw(sha256_hex);
use File::Spec;
use File::Temp qw(tempfile);
use Plugins::BlissLibrary::CandidateInventory;
use Plugins::BlissLibrary::JsonCodec;

sub _read {
    my ($path) = @_;
    return unless -f $path && !-l $path && -s $path <= 8192;
    open my $fh, '<:raw', $path or return;
    my $bytes = do { local $/; <$fh> };
    close $fh or return;
    return $bytes;
}

sub remember {
    my ($dir, $value) = @_;
    die 'Scope registry directory is unavailable' unless defined($dir) && -d $dir;
    my $scope = Plugins::BlissLibrary::CandidateInventory::_scope($value);
    my $bytes = Plugins::BlissLibrary::JsonCodec::canonical()->encode($scope);
    die 'Scope record is too large' if length($bytes) > 8192;
    my $path = File::Spec->catfile($dir, 'scope-' . sha256_hex($bytes) . '.json');
    if (-e $path || -l $path) {
        my $existing = _read($path);
        die 'Existing scope record is corrupt' unless defined($existing) && $existing eq $bytes;
        return $path;
    }
    my ($fh, $temporary) = tempfile('scope-tmp-XXXXXXXX', DIR => $dir, UNLINK => 1);
    binmode $fh, ':raw' or die "Cannot set scope record binary mode: $!";
    print {$fh} $bytes or die "Cannot write scope record: $!";
    close $fh or die "Cannot close scope record: $!";
    if (!link($temporary, $path)) {
        my $existing = _read($path);
        die "Cannot publish scope record: $!" unless defined($existing) && $existing eq $bytes;
    }
    return $path;
}

sub load {
    my ($dir) = @_;
    die 'Scope registry directory is unavailable' unless defined($dir) && -d $dir;
    opendir my $dh, $dir or die "Cannot open scope registry: $!";
    my @names = grep { /\Ascope-[0-9a-f]{64}\.json\z/ } readdir $dh;
    closedir $dh or die "Cannot close scope registry: $!";
    my (@scopes, $invalid);
    my $json = Plugins::BlissLibrary::JsonCodec::canonical();
    for my $name (@names) {
        my ($digest) = $name =~ /\Ascope-([0-9a-f]{64})\.json\z/;
        my $bytes = _read(File::Spec->catfile($dir, $name));
        my $scope = defined($bytes) && sha256_hex($bytes) eq $digest
            ? eval { Plugins::BlissLibrary::CandidateInventory::_scope($json->decode($bytes)) } : undef;
        if (!$scope || $json->encode($scope) ne ($bytes || '')) { $invalid++; next }
        push @scopes, $scope;
    }
    @scopes = sort { $a->{kind} cmp $b->{kind} || ($a->{id} || '') cmp ($b->{id} || '') } @scopes;
    return {scopes => \@scopes, invalid => 0 + ($invalid || 0)};
}
1;
