#!/usr/bin/env python3
"""Validate deploy-owned dashboard module composition metadata."""

from __future__ import annotations

import argparse
import json
import pathlib
import re
import sys
from typing import Any


SAFE_ID_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]*$")
REMOTE_NAME_RE = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*$")
NAV_SECTIONS = {"main", "infrastructure", "lab"}


def load_json(path: pathlib.Path) -> dict[str, Any]:
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except json.JSONDecodeError as exc:
        raise ValueError(f"{path}: invalid JSON: {exc}") from exc
    if not isinstance(data, dict):
        raise ValueError("dashboard catalog root must be an object")
    return data


def require_text(entry: dict[str, Any], field: str, module_id: str) -> str:
    value = entry.get(field)
    if not isinstance(value, str) or not value.strip():
        raise ValueError(f"module {module_id}: {field} is required")
    return value.strip()


def require_bool(entry: dict[str, Any], field: str, module_id: str) -> bool:
    value = entry.get(field)
    if not isinstance(value, bool):
        raise ValueError(f"module {module_id}: {field} must be boolean")
    return value


def source_file(source_root: pathlib.Path, value: str, field: str, module_id: str) -> pathlib.Path:
    path = pathlib.PurePosixPath(value)
    if path.is_absolute() or ".." in path.parts:
        raise ValueError(f"module {module_id}: {field} must be a safe relative path")
    full_path = source_root / pathlib.Path(path)
    if not full_path.exists():
        raise ValueError(f"module {module_id}: {field} does not exist: {full_path}")
    return full_path


def ensure_unique(seen: dict[str, str], key: str, value: str, module_id: str) -> None:
    if value in seen:
        raise ValueError(f"module {module_id}: {key} duplicates module {seen[value]}: {value}")
    seen[value] = module_id


def validate_module(source_root: pathlib.Path, services: set[str], module: dict[str, Any], index: int, seen: dict[str, dict[str, str]]) -> None:
    module_id = require_text(module, "id", f"#{index}")
    if not SAFE_ID_RE.fullmatch(module_id):
        raise ValueError(f"module {module_id}: id is invalid")
    ensure_unique(seen["id"], "id", module_id, module_id)

    enabled = require_bool(module, "enabled", module_id)
    if not enabled:
        return

    remote_name = require_text(module, "remoteName", module_id)
    if not REMOTE_NAME_RE.fullmatch(remote_name):
        raise ValueError(f"module {module_id}: remoteName is invalid")
    ensure_unique(seen["remoteName"], "remoteName", remote_name, module_id)

    exposed = require_text(module, "exposedModule", module_id)
    if not exposed.startswith("./"):
        raise ValueError(f"module {module_id}: exposedModule must start with ./")

    mf_prefix = require_text(module, "mfPrefix", module_id).rstrip("/")
    remote_entry = require_text(module, "remoteEntry", module_id)
    if remote_entry != f"{mf_prefix}/remoteEntry.js":
        raise ValueError(f"module {module_id}: remoteEntry must equal mfPrefix + /remoteEntry.js")
    ensure_unique(seen["mfPrefix"], "mfPrefix", mf_prefix, module_id)

    api_base = require_text(module, "apiBase", module_id).rstrip("/")
    api_prefix = require_text(module, "apiPrefix", module_id).rstrip("/")
    if api_base != api_prefix:
        raise ValueError(f"module {module_id}: apiBase and apiPrefix must match")
    ensure_unique(seen["apiPrefix"], "apiPrefix", api_prefix, module_id)

    service = require_text(module, "service", module_id)
    if service not in services:
        raise ValueError(f"module {module_id}: service is not listed in catalog services: {service}")

    required_services = module.get("requiredServices")
    if not isinstance(required_services, list) or not required_services:
        raise ValueError(f"module {module_id}: requiredServices must be a non-empty list")
    for value in required_services:
        if not isinstance(value, str) or value.strip() not in services:
            raise ValueError(f"module {module_id}: invalid required service: {value!r}")

    nav_key = require_text(module, "navKey", module_id)
    nav_section = require_text(module, "navSection", module_id).lower()
    if nav_section not in NAV_SECTIONS:
        raise ValueError(f"module {module_id}: invalid navSection: {nav_section}")
    ensure_unique(seen["navKey"], "navKey", nav_key, module_id)
    require_text(module, "navLabel", module_id)
    require_text(module, "navIcon", module_id)
    if not isinstance(module.get("navOrder"), int):
        raise ValueError(f"module {module_id}: navOrder must be integer")

    owner_repo = require_text(module, "ownerRepo", module_id)
    if owner_repo == "webui":
        raise ValueError(f"module {module_id}: business modules must not be owned by webui")
    owner_path = source_file(source_root, owner_repo, "ownerRepo", module_id)
    if not owner_path.is_dir():
        raise ValueError(f"module {module_id}: ownerRepo is not a directory: {owner_repo}")

    source_dir = source_file(source_root, require_text(module, "sourceDir", module_id), "sourceDir", module_id)
    if not source_dir.is_dir():
        raise ValueError(f"module {module_id}: sourceDir is not a directory")
    manifest_path = source_file(source_root, require_text(module, "sourceManifest", module_id), "sourceManifest", module_id)
    if not manifest_path.is_file():
        raise ValueError(f"module {module_id}: sourceManifest is not a file")

    vite_config = source_dir / "vite.config.ts"
    if not vite_config.is_file():
        raise ValueError(f"module {module_id}: sourceDir must contain vite.config.ts")
    vite_text = vite_config.read_text(encoding="utf-8", errors="ignore")
    if exposed not in vite_text:
        raise ValueError(f"module {module_id}: vite.config.ts does not expose {exposed}")
    manifest_rel = manifest_path.relative_to(source_dir).as_posix()
    if manifest_rel not in vite_text:
        raise ValueError(f"module {module_id}: vite.config.ts does not reference sourceManifest")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--catalog", required=True)
    parser.add_argument("--source-root", required=True)
    args = parser.parse_args()

    try:
        catalog = load_json(pathlib.Path(args.catalog).resolve())
        source_root = pathlib.Path(args.source_root).resolve()
        services = catalog.get("services")
        modules = catalog.get("modules")
        if not isinstance(services, list) or not services:
            raise ValueError("dashboard catalog services must be a non-empty list")
        service_set = {str(value).strip() for value in services if str(value).strip()}
        if len(service_set) != len(services):
            raise ValueError("dashboard catalog services must be unique non-empty strings")
        if not isinstance(modules, list) or not modules:
            raise ValueError("dashboard catalog modules must be a non-empty list")

        seen = {key: {} for key in ("id", "remoteName", "mfPrefix", "apiPrefix", "navKey")}
        for index, module in enumerate(modules, start=1):
            if not isinstance(module, dict):
                raise ValueError(f"modules[{index}] must be an object")
            validate_module(source_root, service_set, module, index, seen)
    except ValueError as exc:
        print(f"dashboard catalog validation failed: {exc}", file=sys.stderr)
        return 1

    print("dashboard catalog validated")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
