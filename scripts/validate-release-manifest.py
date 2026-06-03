#!/usr/bin/env python3
"""Validate a byte-v-forge multi-repository release manifest."""

from __future__ import annotations

import argparse
import json
import pathlib
import re
import subprocess
import sys
from typing import Any


NAME_RE = re.compile(r"^[A-Za-z0-9._-]+$")


def git(repo: pathlib.Path, *args: str, check: bool = True) -> str:
    proc = subprocess.run(
        ["git", "-C", str(repo), *args],
        check=False,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
    )
    if check and proc.returncode != 0:
        raise RuntimeError(proc.stderr.strip() or "git command failed")
    if proc.returncode != 0:
        return ""
    return proc.stdout.strip()


def load_manifest(path: pathlib.Path) -> dict[str, Any]:
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except json.JSONDecodeError as exc:
        raise ValueError(f"{path}: invalid JSON: {exc}") from exc
    if not isinstance(data, dict):
        raise ValueError("manifest root must be an object")
    if data.get("version") != 1:
        raise ValueError("manifest version must be 1")
    if not isinstance(data.get("repos"), list) or not data["repos"]:
        raise ValueError("manifest repos must be a non-empty list")
    if not isinstance(data.get("allow_dirty", False), bool):
        raise ValueError("manifest allow_dirty must be boolean")
    if not isinstance(data.get("contract_migration", False), bool):
        raise ValueError("manifest contract_migration must be boolean")
    return data


def repo_entries(manifest: dict[str, Any]) -> dict[str, str]:
    entries: dict[str, str] = {}
    for index, raw_entry in enumerate(manifest["repos"], start=1):
        if not isinstance(raw_entry, dict):
            raise ValueError(f"repos[{index}] must be an object")
        name = raw_entry.get("name")
        revision = raw_entry.get("revision")
        if not isinstance(name, str) or not NAME_RE.fullmatch(name):
            raise ValueError(f"repos[{index}].name is invalid")
        if not isinstance(revision, str) or not revision.strip():
            raise ValueError(f"repos[{index}].revision is required")
        if name in entries:
            raise ValueError(f"duplicate repo in manifest: {name}")
        entries[name] = revision.strip()
    return entries


def selected_repos(value: str | None, entries: dict[str, str]) -> list[str]:
    if not value:
        return list(entries)
    repos = [item.strip() for item in value.split(",") if item.strip()]
    for repo in repos:
        if not NAME_RE.fullmatch(repo):
            raise ValueError(f"selected repo name is invalid: {repo}")
        if repo not in entries:
            raise ValueError(f"selected repo is missing from release manifest: {repo}")
    return repos


def validate_repo(source_root: pathlib.Path, name: str, revision: str, allow_dirty: bool) -> tuple[str, bool]:
    repo_path = source_root / name
    if not repo_path.is_dir() or not (repo_path / ".git").exists():
        raise ValueError(f"{name}: missing git repository at {repo_path}")
    expected = git(repo_path, "rev-parse", "--short=12", revision)
    current = git(repo_path, "rev-parse", "--short=12", "HEAD")
    if expected != current:
        raise ValueError(f"{name}: current HEAD {current} does not match manifest revision {expected}")
    dirty = bool(git(repo_path, "status", "--porcelain"))
    if dirty and not allow_dirty:
        raise ValueError(f"{name}: repository has uncommitted changes")
    return current, dirty


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--manifest", required=True)
    parser.add_argument("--source-root", required=True)
    parser.add_argument("--selected-repos", default="")
    parser.add_argument("--allow-dirty", action="store_true")
    parser.add_argument("--print-source-revision", action="store_true")
    args = parser.parse_args()

    try:
        manifest_path = pathlib.Path(args.manifest).expanduser().resolve()
        source_root = pathlib.Path(args.source_root).expanduser().resolve()
        manifest = load_manifest(manifest_path)
        entries = repo_entries(manifest)
        targets = selected_repos(args.selected_repos, entries)
        allow_dirty = bool(manifest.get("allow_dirty")) or args.allow_dirty
        revisions: list[str] = []
        for name in targets:
            current, dirty = validate_repo(source_root, name, entries[name], allow_dirty)
            suffix = "+dirty" if dirty else ""
            revisions.append(f"{name}:{current}{suffix}")
    except (RuntimeError, ValueError) as exc:
        print(f"release manifest validation failed: {exc}", file=sys.stderr)
        return 1

    if args.print_source_revision:
        print(",".join(revisions) or "unknown")
    else:
        print(f"release manifest validated: {manifest_path}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
