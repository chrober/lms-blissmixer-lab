#!/usr/bin/env python3
"""Detect meaningful drift between upstream and BlissMixerLab DSTM code."""

from __future__ import annotations

import argparse
import difflib
import json
import re
import subprocess
import sys
from dataclasses import dataclass
from pathlib import Path


SUB_START = re.compile(r"(?m)^sub\s+([A-Za-z_][A-Za-z0-9_]*)\b")


@dataclass(frozen=True)
class Drift:
    category: str
    function: str
    old_source: str
    new_source: str
    explanation: str = ""


def extract_subroutines(source: str) -> dict[str, str]:
    """Return top-level named Perl subroutines, including leading `sub NAME`."""
    matches = list(SUB_START.finditer(source))
    routines: dict[str, str] = {}
    for index, match in enumerate(matches):
        end = matches[index + 1].start() if index + 1 < len(matches) else len(source)
        routines[match.group(1)] = source[match.start() : end].rstrip() + "\n"
    return routines


def strip_perl_comments_and_space(source: str) -> str:
    """Compact Perl while retaining quoted content and escaped characters.

    This intentionally is not a Perl parser. DSTM routines use ordinary quoted
    strings, and top-level routine extraction is independent of brace parsing.
    The scanner preserves whitespace and `#` characters inside strings while
    ignoring layout and comments elsewhere.
    """
    output: list[str] = []
    quote: str | None = None
    escaped = False
    index = 0
    while index < len(source):
        char = source[index]
        if quote is not None:
            output.append(char)
            if escaped:
                escaped = False
            elif char == "\\":
                escaped = True
            elif char == quote:
                quote = None
            index += 1
            continue

        if char in ("'", '"'):
            quote = char
            output.append(char)
            index += 1
            continue
        if char == "#":
            newline = source.find("\n", index)
            index = len(source) if newline < 0 else newline + 1
            continue
        if char.isspace():
            index += 1
            continue
        output.append(char)
        index += 1
    return "".join(output)


def canonicalize(source: str, replacements: list[list[str]]) -> str:
    for old, new in replacements:
        source = source.replace(old, new)
    return strip_perl_comments_and_space(source)


def git_output(repository: Path, *arguments: str) -> str:
    completed = subprocess.run(
        ["git", "-C", str(repository), *arguments],
        check=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        encoding="utf-8",
    )
    return completed.stdout


def source_at_commit(repository: Path, commit: str, relative_path: str) -> str:
    return git_output(repository, "show", f"{commit}:{relative_path}")


def require_routine(routines: dict[str, str], name: str, label: str) -> str:
    try:
        return routines[name]
    except KeyError as error:
        raise ValueError(f"{label} does not define tracked routine {name}") from error


def analyse(
    config: dict,
    reviewed_upstream: str,
    current_upstream: str,
    current_extension: str,
) -> list[Drift]:
    reviewed = extract_subroutines(reviewed_upstream)
    upstream = extract_subroutines(current_upstream)
    extension = extract_subroutines(current_extension)
    replacements = config.get("identity_normalizations", [])
    drift: list[Drift] = []

    for name in config["direct_mirrors"]:
        upstream_source = require_routine(upstream, name, "current upstream")
        extension_source = require_routine(extension, name, "extension")
        if canonicalize(upstream_source, replacements) != canonicalize(
            extension_source, replacements
        ):
            drift.append(
                Drift(
                    "direct mirror differs",
                    name,
                    upstream_source,
                    extension_source,
                    "This routine is expected to remain a direct upstream mirror.",
                )
            )

    explanations = config.get("intentional_adaptations", {})
    for name in config["adapted_from_upstream"]:
        reviewed_source = require_routine(reviewed, name, "reviewed upstream")
        upstream_source = require_routine(upstream, name, "current upstream")
        if canonicalize(reviewed_source, []) != canonicalize(upstream_source, []):
            drift.append(
                Drift(
                    "adapted upstream routine changed",
                    name,
                    reviewed_source,
                    upstream_source,
                    explanations.get(name, ""),
                )
            )
    return drift


def diff_block(item: Drift, limit: int = 160) -> str:
    lines = list(
        difflib.unified_diff(
            item.old_source.splitlines(),
            item.new_source.splitlines(),
            fromfile=f"before/{item.function}",
            tofile=f"after/{item.function}",
            lineterm="",
        )
    )
    truncated = len(lines) > limit
    lines = lines[:limit]
    if truncated:
        lines.append(f"... diff truncated after {limit} lines ...")
    return "\n".join(lines)


def render_report(
    config: dict,
    upstream_head: str,
    drift: list[Drift],
) -> str:
    reviewed = config["reviewed_upstream_commit"]
    lines = [
        "# BlissMixer DSTM drift report",
        "",
        f"- Upstream: `{config['upstream_repository']}@{upstream_head}`",
        f"- Last reviewed upstream commit: `{reviewed}`",
        f"- Direct mirror routines: {len(config['direct_mirrors'])}",
        f"- Intentionally adapted routines: {len(config['adapted_from_upstream'])}",
        "",
    ]
    if not drift:
        lines.extend(
            [
                "## Result: no significant drift",
                "",
                "All direct mirrors are token-equivalent after identity normalization, "
                "and no intentionally adapted upstream routine changed after the reviewed commit.",
                "",
            ]
        )
        return "\n".join(lines)

    lines.extend(
        [
            f"## Result: review required ({len(drift)} routine(s))",
            "",
            "Do not update the reviewed commit merely to make this check pass. Review each "
            "change and either port it, adapt it, or document why it does not apply.",
            "",
        ]
    )
    for item in drift:
        lines.extend(
            [
                f"### `{item.function}` — {item.category}",
                "",
                item.explanation,
                "" if item.explanation else "",
                "```diff",
                diff_block(item),
                "```",
                "",
            ]
        )
    return "\n".join(lines)


def parse_args(argv: list[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--config", type=Path, default=Path("compat/dstm-drift.json"))
    parser.add_argument("--upstream-dir", type=Path, required=True)
    parser.add_argument(
        "--extension-file", type=Path, default=Path("BlissMixerLab/Plugin.pm")
    )
    parser.add_argument("--report", type=Path, default=Path("dstm-drift-report.md"))
    return parser.parse_args(argv)


def main(argv: list[str] | None = None) -> int:
    args = parse_args(argv or sys.argv[1:])
    config = json.loads(args.config.read_text(encoding="utf-8"))
    upstream_path = args.upstream_dir / config["upstream_plugin_path"]

    try:
        reviewed_upstream = source_at_commit(
            args.upstream_dir,
            config["reviewed_upstream_commit"],
            config["upstream_plugin_path"],
        )
        current_upstream = upstream_path.read_text(encoding="utf-8")
        current_extension = args.extension_file.read_text(encoding="utf-8")
        upstream_head = git_output(args.upstream_dir, "rev-parse", "HEAD").strip()
        drift = analyse(config, reviewed_upstream, current_upstream, current_extension)
        report = render_report(config, upstream_head, drift)
    except (OSError, subprocess.CalledProcessError, ValueError, KeyError) as error:
        report = "# BlissMixer DSTM drift report\n\n## Check failed\n\n" + str(error) + "\n"
        drift = [Drift("check failed", "configuration", "", "", str(error))]

    args.report.write_text(report, encoding="utf-8", newline="\n")
    print(report)
    return 1 if drift else 0


if __name__ == "__main__":
    raise SystemExit(main())
