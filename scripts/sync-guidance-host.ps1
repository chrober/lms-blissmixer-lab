param(
    [string]$SourceRoot = 'D:\LMS\lms-bliss-guidance-host'
)

$source = Join-Path $SourceRoot 'Plugins\BlissGuidance'
$destination = Join-Path $PSScriptRoot '..\BlissMixerLab\Plugins\BlissGuidance'

if (!(Test-Path (Join-Path $source 'Discovery.pm'))) {
    throw "Guidance host source is incomplete: $source"
}

New-Item -ItemType Directory -Force -Path $destination | Out-Null
Copy-Item -Path (Join-Path $source '*') -Destination $destination -Force
