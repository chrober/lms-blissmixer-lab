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
        'f25caefbea85a538ccfa05c851e78d10bfb7a4f8dbb0f9a01347931adffaf461',
    ],
    [
        'Plugins/BlissGuidance/SettingsModel.pm',
        'BlissMixerLab/Plugins/BlissGuidance/SettingsModel.pm',
        '83f9442e379b2707afe7a693eef02988093067e5aa3ad8a14a5cec40230d4952',
    ],
    [
        'HTML/settings/guidance-provider-controls.html',
        'BlissMixerLab/HTML/EN/plugins/BlissGuidance/settings/guidance-provider-controls.html',
        'd0b3dd3a4e03fe3f164de7b9e0a754d98a972a620d33ded045d6da481a0ca347',
    ],
    [
        'HTML/settings/guidance-provider-controls.js',
        'BlissMixerLab/HTML/EN/plugins/BlissGuidance/settings/guidance-provider-controls.js',
        '0957041d2ace48096e9ec101006a8f7185ade8e467b13a130170fb3488672c4e',
    ],
);

for my $asset (@assets) {
    my ($canonical, $vendored, $expected) = @$asset;
    SKIP: {
        skip "shared host checkout is not present in this standalone repository", 1
            unless -d $host;
        is(
            file_hash(File::Spec->catfile($host, split m{/}, $canonical)),
            $expected,
            "canonical $canonical remains the reviewed host contract",
        );
    }
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
like($template, qr/SET\s+guidance_ui\.available_token\s*=\s*"BLISSMIXERLAB_GUIDANCE_PROVIDER_AVAILABLE"/,
    'settings page supplies the established Lab labels for installed Settings.pm compatibility');

my $provider_controls_path = File::Spec->catfile(
    $repo, 'BlissMixerLab', 'HTML', 'EN', 'plugins', 'BlissGuidance',
    'settings', 'guidance-provider-controls.html',
);
open my $provider_controls_fh, '<', $provider_controls_path
    or die "cannot read $provider_controls_path: $!";
my $provider_controls = do { local $/; <$provider_controls_fh> };
like($provider_controls, qr/control\.enum_options/,
    'Lab uses descriptor enum options from the shared guidance renderer');
like($provider_controls, qr/option\.label_token\s*\|\s*string/,
    'Lab renders localized enum labels supplied by providers');
unlike($provider_controls, qr/control\.enum_values/,
    'Lab does not fall back to raw enum keys');

done_testing();
