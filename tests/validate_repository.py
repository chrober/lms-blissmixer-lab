from pathlib import Path
import json
import re
import sys
import xml.etree.ElementTree as ET


ROOT = Path(__file__).resolve().parents[1]
PLUGIN = ROOT / "BlissMixerLab"


def fail(message: str) -> None:
    print(f"ERROR: {message}", file=sys.stderr)
    raise SystemExit(1)


manifest = ET.parse(PLUGIN / "install.xml").getroot()
if manifest.findtext("module") != "Plugins::BlissMixerLab::Plugin":
    fail("install.xml must use the BlissMixerLab module namespace")
if manifest.findtext("name") != "BLISSMIXERLAB":
    fail("install.xml must use the BlissMixerLab name token")
if manifest.findtext("id") == "6979c1ee-0644-4ed1-a440-c5ff6869eae4":
    fail("install.xml reuses the upstream BlissMixer UUID")

plugin_source = (PLUGIN / "Plugin.pm").read_text(encoding="utf-8")
survey_source = (PLUGIN / "Survey.pm").read_text(encoding="utf-8")
lastfm_track_source = (PLUGIN / "LastFmTrackSimilarity.pm").read_text(encoding="utf-8")

required = {
    "separate preference namespace": "preferences('plugin.blissmixerlab')",
    "upstream preference reader": "preferences('plugin.blissmixer')",
    "separate DSTM handler": "BLISSMIXERLAB_DSTM",
    "separate mixer binary": "findbin('bliss-mixer-lab')",
    "canonical learner binary": "findbin('bliss-learner')",
    "loopback-only mixer": 'push @params, "127.0.0.1"',
    "automatic loopback port selection": "_availableMixerPort",
    "canonical learned matrix": "'learned_matrix.json'",
    "canonical training triplets": "'training_triplets.json'",
    "legacy data migration": "_migrateLearningFile",
    "sidecar learner notifications": '"--lms-command", "blissmixerlab"',
    "shared upstream candidate reranker": "Plugins::BlissMixer::CandidateSelection::selectCandidates",
    "upstream Last.fm artist lookup": "Plugins::BlissMixer::Plugin::_fetchSimilarArtistsForSeeds",
    "upstream play-count preference": "$prefs->get('playcount_influence')",
    "Last.fm similar-track lookup": "getSimilarTracks",
    "bounded Last.fm evidence deadline": "LASTFM_EVIDENCE_TIMEOUT",
    "Lab mix context action": "BLISSMIXERLAB_CREATE_MIX",
    "Lab similar-tracks context action": "BLISSMIXERLAB_SIMILAR_TRACKS",
    "adaptive similar-track request": "adaptiveweights => int($prefs->get('use_adaptive_weights') || 0)",
    "interactive action logging": "User action: $action",
    "interactive strategy logging": "Effective strategy: $strategy",
    "interactive result logging": "returned by bliss-mixer-lab",
    "interactive timing diagnostics": "Interactive Lab request timing:",
}
for description, needle in required.items():
    if needle not in plugin_source + survey_source + lastfm_track_source:
        fail(f"missing {description}: {needle}")

for selection_tier in (
    "bliss-only", "last.fm-endorsed (a)", "last.fm-endorsed (t)",
):
    if selection_tier not in plugin_source:
        fail(f"selection logging must retain the {selection_tier} evidence tier")
if "last.fm-endorsed (a+t)" not in plugin_source:
    fail("selection logging must distinguish combined artist and track evidence")
if "continuing mixes and deferring the database refresh" not in plugin_source:
    fail("DSTM must remain available while upstream analysis updates bliss.db")
if "temporarily unavailable" in plugin_source:
    fail("upstream analysis must not disable Bliss (Lab)")

for forbidden in (
    "Plugins::BlissMixerLab::Analyser",
    "Plugins::BlissMixerLab::Importer",
    "registerInfoProvider( blissmix =>",
    "registerInfoProvider( blisssimilarity =>",
    "registerInfoProvider( blisssimilaritybyartist =>",
    "registerHandler(\n        blissmixer =>",
    "$labprefs->get('playcount_influence')",
    "sub _fetchSimilarArtistsForSeeds",
    "sub _lastfmNormalizeArtist",
):
    if forbidden in plugin_source:
        fail(f"sidecar contains conflicting registration: {forbidden}")

for provider, anchor in (
    ("blissmixerlabmix", "blisssimilaritybyartist"),
    ("blissmixerlabsimilarity", "blissmixerlabmix"),
    ("blissmixerlabsimilaritybyartist", "blissmixerlabsimilarity"),
):
    if not re.search(
        rf"registerInfoProvider\( {provider} => \(\s*after\s*=>\s*'{anchor}'",
        plugin_source,
    ):
        fail(f"context-menu provider {provider} must appear after {anchor}")
if re.search(r"registerInfoProvider\( blissmixerlab\w+ => \(\s*above\s*=>", plugin_source):
    fail("TrackInfo placement must use Lyrion's after key, not ignored above")

if 'blissmixer-triplets-${ts}.zip' not in survey_source:
    fail("training-data backups must retain the established BlissMixer filename")

settings = (PLUGIN / "HTML/EN/plugins/BlissMixerLab/settings/blissmixerlab.html").read_text(encoding="utf-8")
for upstream_pref in re.findall(r'name="pref_([^"]+)"', settings):
    if upstream_pref not in {
        "learned_blend", "lastfm_track_guidance_percent",
        "triplets_backup_path",
    }:
        fail(f"settings page duplicates upstream preference: {upstream_pref}")
if 'name="pref_mixer_port"' in settings:
    fail("settings page must not expose the sidecar's internal mixer port")
if "sliderInput_0_100_1" not in settings:
    fail("learned matrix influence must use the LMS slider control")
if 'pref_playcount_influence' in settings:
    fail("play-count influence belongs to upstream Bliss Mixer, not the Lab settings")
if 'id="lastfm_track_guidance_percent"' not in settings:
    fail("settings page must expose Last.fm similar-track guidance")
for section in ("status-section", "mix-section", "learning-section"):
    if f'id="{section}-header"' not in settings or f'id="{section}"' not in settings:
        fail(f"settings page is missing the {section} grouping")
for section in ("status-section", "mix-section"):
    if not re.search(
        rf'<div id="{section}"[^>]*>.*?<hr[^>]+class="sub-sep"[^>]*/?>.*?</div>',
        settings,
        re.DOTALL,
    ):
        fail(f"the {section} separator must fold with its section")
if not re.search(
    r'<input type="text" class="stdedit selectFolder" '
    r'name="pref_triplets_backup_path" id="triplets_backup_path" '
    r'value="\[% prefs\.triplets_backup_path %\]" size="40">',
    settings,
):
    fail("backup folder must use the same persistent folder-picker contract as BlissMixer")
if '<input type="hidden" class="selectFile" id="restore_backup_path" value="">' not in settings:
    fail("restore must use the same icon-only file-picker contract as BlissMixer")
if 'id="restore_path"' in settings or '<button onclick="restoreBackup()"' in settings:
    fail("restore must not expose the old text field or manual restore button")
for behavior in (
    "setRestorePathFromBackupFolder",
    "watchRestorePathSelection",
    "restoreWatchInterval = setInterval(watchRestorePathSelection, 250)",
    "backupPath.addEventListener('change', updateBackupButtonState)",
):
    if behavior not in settings:
        fail(f"backup/restore picker is missing upstream behavior: {behavior}")

settings_source = (PLUGIN / "Settings.pm").read_text(encoding="utf-8")
if "protectName('BLISSMIXERLAB')" not in settings_source:
    fail("settings menu name must use the BLISSMIXERLAB localization token")
if "$paramRef->{host}" not in settings_source:
    fail("settings JSON-RPC URL must prefer the browser-facing LMS request host")
if "require Plugins::BlissMixer::CandidateSelection" not in settings_source:
    fail("settings compatibility must require upstream candidate-reranking support")

strings_path = PLUGIN / "strings.txt"
strings_source = strings_path.read_text(encoding="utf-8")
string_tokens: set[str] = set()
for line_number, line in enumerate(strings_source.splitlines(), start=1):
    if not line:
        continue
    if line[0].isspace():
        if not re.fullmatch(r"\t[A-Z]{2}\t\S.*", line):
            fail(f"strings.txt line {line_number} is not tab-delimited LMS string data")
        continue
    if not re.fullmatch(r"[A-Z][A-Z0-9_]*", line):
        fail(f"strings.txt line {line_number} is not a valid string token")
    string_tokens.add(line)

if "BLISSMIXERLAB\n\tEN\tBliss Mixer Lab" not in strings_source:
    fail("display name must be Bliss Mixer Lab")
if (
    "BLISSMIXERLAB_DESC\n"
    "\tEN\tExperimental and early-access extensions for Bliss Mixer"
    not in strings_source
):
    fail("plugin description must identify experimental and early-access extensions")
if "BLISSMIXERLAB_DSTM\n\tEN\tBliss (Lab)" not in strings_source:
    fail("the Bliss (Lab) DSTM provider display name must remain stable")
for token, label in {
    "BLISSMIXERLAB_CREATE_MIX": "Create bliss mix (Lab)",
    "BLISSMIXERLAB_SIMILAR_TRACKS": "Similar tracks (Lab)",
    "BLISSMIXERLAB_SIMILAR_TRACKS_BY_ARTIST": "Similar tracks by artist (Lab)",
}.items():
    if f"{token}\n\tEN\t{label}" not in strings_source:
        fail(f"missing Lab context-menu label: {label}")
for implementation_detail in (
    "larger candidate pool",
    "share the same pool",
):
    if implementation_detail in strings_source:
        fail(f"play-count help must omit implementation detail: {implementation_detail}")
if "BLISSMIXERLAB_PLAYCOUNT" in strings_source:
    fail("Lab strings must not expose the upstream play-count feature")

referenced_tokens = {
    manifest.findtext("name"),
    manifest.findtext("description"),
    *re.findall(r'"(BLISSMIXERLAB(?:_[A-Z0-9_]+)?)"\s*\|\s*string', settings),
    *re.findall(r'(?:title|desc)="(BLISSMIXERLAB(?:_[A-Z0-9_]+)?)"', settings),
}
for token in referenced_tokens:
    if token and token not in string_tokens:
        fail(f"missing localized string token: {token}")

for learner_status_contract in (
    "learning_start_text",
    "learning_duration_text",
    "learning_status_text",
    "learning_failed_text",
    "setLearningInterval(1000)",
):
    if learner_status_contract not in settings + settings_source:
        fail(f"settings page is missing live learner status: {learner_status_contract}")

release_workflow = (ROOT / ".github/workflows/release.yml").read_text(encoding="utf-8")
for requirement in (
    "chrober/bliss-mixer",
    "chrober/bliss-learner",
    "sha256sum -c *.sha256",
    "lms-blissmixer-lab-linux-",
    "lms-blissmixer-lab-mac-",
    "lms-blissmixer-lab-windows-",
    "scripts/update_lms_plugins_repo.py",
):
    if requirement not in release_workflow:
        fail(f"release workflow is missing: {requirement}")

drift_config = json.loads((ROOT / "compat/dstm-drift.json").read_text(encoding="utf-8"))
if drift_config.get("upstream_repository") != "CDrummond/lms-blissmixer":
    fail("DSTM drift check must follow the original BlissMixer repository")
if not re.fullmatch(r"[0-9a-f]{40}", drift_config.get("reviewed_upstream_commit", "")):
    fail("DSTM drift check must pin a full reviewed upstream commit")
if "_dstmMix" not in drift_config.get("adapted_from_upstream", []):
    fail("DSTM drift check must track the adapted _dstmMix routine")
if "_getMixData" not in drift_config.get("adapted_from_upstream", []):
    fail("DSTM drift check must track the adapted _getMixData routine")
for routine in ("initPlugin", "_cliCommand", "_callApi", "_objectInfoHandler", "_trackSimilarityHandler", "_getListData"):
    if routine not in drift_config.get("adapted_from_upstream", []):
        fail(f"DSTM drift check must track the adapted {routine} routine")

drift_workflow = (ROOT / ".github/workflows/dstm-drift.yml").read_text(encoding="utf-8")
for requirement in (
    "schedule:",
    "scripts/check_dstm_drift.py",
    "upstream-blissmixer",
    "dstm-drift-report.md",
    "Create or update scheduled drift issue",
    "Enforce drift result",
):
    if requirement not in drift_workflow:
        fail(f"DSTM drift workflow is missing: {requirement}")

source_manifest = (PLUGIN / "Bin/SOURCE.md").read_text(encoding="utf-8")
for label in ("Mixer release", "Mixer commit", "Learner release", "Learner commit"):
    if not re.search(rf"{label}:\s*`[^`]+`", source_manifest):
        fail(f"binary provenance is missing {label}")

print("BlissMixerLab repository validation passed")
