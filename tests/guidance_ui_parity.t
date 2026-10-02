use strict;
use warnings;
use Digest::SHA qw(sha256_hex);
use File::Spec;
use FindBin;
use Test::More;

my $repo = File::Spec->catdir($FindBin::Bin, '..');
my $host = File::Spec->catdir($repo, '..', 'lms-bliss-guidance-host');

sub file_hash {
    my ($path) = @_;
    return 'missing' unless -f $path;
    open my $fh, '<:raw', $path or die "cannot read $path: $!";
    return sha256_hex(do { local $/; <$fh> });
}

my @assets = (
    [
        'Plugins/BlissGuidance/Policy.pm',
        'BlissMixerLab/Plugins/BlissGuidance/Policy.pm',
        'b8e5a91ad0014cfb2a2ab1ed4dc7227bc77c23a9e605bd55fff3a593c7ec3790',
    ],
    [
        'Plugins/BlissGuidance/SettingsModel.pm',
        'BlissMixerLab/Plugins/BlissGuidance/SettingsModel.pm',
        'a049ec77985627e022d6d7599e814b72604919b29227c3bfb74fffdb05be6ffc',
    ],
    [
        'HTML/settings/guidance-provider-controls.html',
        'BlissMixerLab/HTML/EN/plugins/BlissGuidance/settings/guidance-provider-controls.html',
        '6e1e58263d0313f8a0a85aca0e8da3fd1848c40d132668d5afe8ff083c2dfb24',
    ],
    [
        'HTML/settings/guidance-provider-controls.js',
        'BlissMixerLab/HTML/EN/plugins/BlissGuidance/settings/guidance-provider-controls.js',
        'cdcb46a952ffc48d83948bb295312e6a0b07ed42a5bf5af7dffdb7118c247c2c',
    ],
);

for my $asset (@assets) {
    my ($canonical, $vendored, $expected) = @$asset;
    is(
        file_hash(File::Spec->catfile($host, split m{/}, $canonical)),
        $expected,
        "canonical $canonical remains the reviewed host contract",
    );
    is(
        file_hash(File::Spec->catfile($repo, split m{/}, $vendored)),
        $expected,
        "Lab vendors canonical $canonical byte-for-byte",
    );
}

my $settings_path = File::Spec->catfile($repo, 'BlissMixerLab', 'Settings.pm');
open my $settings_fh, '<', $settings_path or die "cannot read $settings_path: $!";
my $settings = do { local $/; <$settings_fh> };
like($settings, qr/use\s+Plugins::BlissGuidance::SettingsModel;/,
    'Lab builds provider sections through the canonical settings model');
like($settings, qr/Plugins::BlissGuidance::SettingsModel::provider_sections/,
    'Lab delegates descriptor rendering state to the canonical model');

my $template_path = File::Spec->catfile(
    $repo, 'BlissMixerLab', 'HTML', 'EN', 'plugins', 'BlissMixerLab',
    'settings', 'blissmixerlab.html',
);
open my $template_fh, '<', $template_path or die "cannot read $template_path: $!";
my $template = do { local $/; <$template_fh> };
like($template, qr/PROCESS\s+"plugins\/BlissGuidance\/settings\/guidance-provider-controls\.html"/,
    'Lab settings page renders canonical provider controls');
like($template, qr/PROCESS\s+"plugins\/BlissGuidance\/settings\/guidance-provider-controls\.js"/,
    'Lab settings page loads canonical provider-control behavior');
unlike($template, qr/function\s+copyGuidanceInheritedDefault\s*\(/,
    'Lab no longer carries a divergent inherited-default handler');
unlike($template, qr/function\s+updateGuidanceProviderControls\s*\(/,
    'Lab no longer carries a divergent provider-toggle handler');

done_testing();
