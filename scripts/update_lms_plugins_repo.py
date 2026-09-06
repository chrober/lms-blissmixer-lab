#!/usr/bin/env python3
"""Update the LMS plugin repository feed for BlissMixerLab."""

from __future__ import annotations

import argparse
import xml.etree.ElementTree as ET
from pathlib import Path

PLUGIN_NAME = "BlissMixerLab"
LEGACY_PLUGIN_NAMES = {"BlissMixerExt"}
PLUGIN_TITLE = "Bliss Mixer Lab"
PLUGIN_DESC = "Experimental and early-access extensions for Bliss Mixer"
PLUGIN_CREATOR = "Christoph O'Bermair"
PLUGIN_CATEGORY = "playlists"
PLUGIN_MIN_TARGET = "9.0"
PLUGIN_MAX_TARGET = "*"


def child(parent: ET.Element, tag: str, text: str, **attrs: str) -> ET.Element:
    element = ET.SubElement(parent, tag, attrs)
    element.text = text
    return element


def build_plugin(version: str, url: str, sha: str, target: str) -> ET.Element:
    plugin = ET.Element(
        "plugin",
        {
            "name": PLUGIN_NAME,
            "version": version,
            "minTarget": PLUGIN_MIN_TARGET,
            "maxTarget": PLUGIN_MAX_TARGET,
        },
    )
    child(plugin, "title", PLUGIN_TITLE, lang="EN")
    child(plugin, "desc", PLUGIN_DESC, lang="EN")
    child(plugin, "url", url)
    child(plugin, "sha", sha)
    child(plugin, "creator", PLUGIN_CREATOR)
    child(plugin, "category", PLUGIN_CATEGORY)
    child(plugin, "target", target)
    return plugin


def update(
    repo_xml: Path,
    version: str,
    packages: tuple[tuple[str, str, str], ...],
) -> None:
    tree = ET.parse(repo_xml)
    root = tree.getroot()
    plugins = root.find("plugins")
    if plugins is None:
        plugins = ET.SubElement(root, "plugins")

    replaced_names = {PLUGIN_NAME, *LEGACY_PLUGIN_NAMES}
    for existing in list(plugins.findall("plugin")):
        if existing.get("name") in replaced_names:
            plugins.remove(existing)

    for target, url, sha in packages:
        plugins.append(build_plugin(version, url, sha, target))

    ET.indent(tree, space="  ")
    tree.write(repo_xml, encoding="utf-8", xml_declaration=True)


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--repo-xml", type=Path, required=True)
    parser.add_argument("--version", required=True)
    for platform in ("linux", "mac", "windows"):
        parser.add_argument(f"--{platform}-url", required=True)
        parser.add_argument(f"--{platform}-sha", required=True)
    args = parser.parse_args()
    update(
        args.repo_xml,
        args.version,
        (
            ("unix", args.linux_url, args.linux_sha),
            ("mac", args.mac_url, args.mac_sha),
            ("windows", args.windows_url, args.windows_sha),
        ),
    )


if __name__ == "__main__":
    main()
