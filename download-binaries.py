#!/usr/bin/env python3
"""Download and verify the native releases pinned for BlissMixerLab."""

from __future__ import annotations

import hashlib
import os
import re
import stat
from pathlib import Path

import requests

ROOT = Path(__file__).resolve().parent
PLUGIN = ROOT / "BlissMixerLab"
SOURCE = PLUGIN / "Bin" / "SOURCE.md"

COMPONENTS = {
    "mixer": {
        "repo": "chrober/bliss-mixer",
        "label": "Mixer release",
        "assets": {
            "bliss-mixer-x86_64-linux": "x86_64-linux/bliss-mixer-lab",
            "bliss-mixer-aarch64-linux": "aarch64-linux/bliss-mixer-lab",
            "bliss-mixer-armhf-linux": "armhf-linux/bliss-mixer-lab",
            "bliss-mixer-mac": "mac/bliss-mixer-lab",
            "bliss-mixer-windows.exe": "windows/bliss-mixer-lab.exe",
        },
    },
    "learner": {
        "repo": "chrober/bliss-learner",
        "label": "Learner release",
        "assets": {
            "bliss-learner-x86_64-linux": "x86_64-linux/bliss-learner",
            "bliss-learner-aarch64-linux": "aarch64-linux/bliss-learner",
            "bliss-learner-armhf-linux": "armhf-linux/bliss-learner",
            "bliss-learner-mac": "mac/bliss-learner",
            "bliss-learner-windows.exe": "windows/bliss-learner.exe",
        },
    },
}


def pinned_release(label: str) -> str:
    text = SOURCE.read_text(encoding="utf-8")
    match = re.search(rf"{re.escape(label)}:\s*`([^`]+)`", text)
    if not match:
        raise RuntimeError(f"Could not find {label} in {SOURCE}")
    return match.group(1)


def session() -> requests.Session:
    client = requests.Session()
    client.headers["Accept"] = "application/vnd.github+json"
    token = os.environ.get("GITHUB_TOKEN") or os.environ.get("GH_TOKEN")
    if token:
        client.headers["Authorization"] = f"Bearer {token}"
    return client


def download_component(client: requests.Session, component: dict[str, object]) -> None:
    repo = str(component["repo"])
    tag = pinned_release(str(component["label"]))
    response = client.get(f"https://api.github.com/repos/{repo}/releases/tags/{tag}", timeout=30)
    response.raise_for_status()
    urls = {asset["name"]: asset["browser_download_url"] for asset in response.json()["assets"]}

    assets = component["assets"]
    assert isinstance(assets, dict)
    for asset_name, relative_destination in assets.items():
        checksum_name = f"{asset_name}.sha256"
        if asset_name not in urls or checksum_name not in urls:
            raise RuntimeError(f"Release {repo}@{tag} is missing {asset_name} or its checksum")

        checksum_response = client.get(urls[checksum_name], timeout=30)
        checksum_response.raise_for_status()
        expected = checksum_response.text.split()[0].lower()

        binary_response = client.get(urls[asset_name], timeout=120)
        binary_response.raise_for_status()
        content = binary_response.content
        actual = hashlib.sha256(content).hexdigest()
        if actual != expected:
            raise RuntimeError(f"SHA-256 mismatch for {asset_name}: {actual} != {expected}")

        destination = PLUGIN / "Bin" / str(relative_destination)
        if destination.exists() and hashlib.sha256(destination.read_bytes()).hexdigest() == actual:
            print(f"unchanged {destination.relative_to(ROOT)}")
            continue
        destination.parent.mkdir(parents=True, exist_ok=True)
        destination.write_bytes(content)
        if destination.suffix.lower() != ".exe":
            destination.chmod(destination.stat().st_mode | stat.S_IXUSR | stat.S_IXGRP | stat.S_IXOTH)
        print(f"installed {destination.relative_to(ROOT)}")


def main() -> None:
    client = session()
    for component in COMPONENTS.values():
        download_component(client, component)


if __name__ == "__main__":
    main()
