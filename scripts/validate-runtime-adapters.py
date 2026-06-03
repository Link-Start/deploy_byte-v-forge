#!/usr/bin/env python3
"""Validate runtime/provider adapter registry ownership."""

from __future__ import annotations

import argparse
import json
import os
import pathlib
import re
import sys
from typing import Any


ID_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._:-]*$")
STATUSES = {"spi", "legacy_inline_registry"}
ALLOW_MIGRATION_DEBT = os.environ.get("ALLOW_MIGRATION_DEBT") == "1"


def load_json(path: pathlib.Path) -> dict[str, Any]:
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except json.JSONDecodeError as exc:
        raise ValueError(f"{path}: invalid JSON: {exc}") from exc
    if not isinstance(data, dict):
        raise ValueError("runtime adapter catalog root must be an object")
    if data.get("version") != 1:
        raise ValueError("runtime adapter catalog version must be 1")
    return data


def text(entry: dict[str, Any], field: str, label: str) -> str:
    value = entry.get(field)
    if not isinstance(value, str) or not value.strip():
        raise ValueError(f"{label}: {field} is required")
    return value.strip()


def source_file(source_root: pathlib.Path, value: str, label: str) -> pathlib.Path:
    path = pathlib.PurePosixPath(value)
    if path.is_absolute() or ".." in path.parts:
        raise ValueError(f"{label}: path must be a safe relative path: {value}")
    full_path = source_root / pathlib.Path(path)
    if not full_path.exists():
        raise ValueError(f"{label}: path does not exist: {full_path}")
    return full_path


def source_text(source_root: pathlib.Path, value: str, label: str) -> str:
    path = source_file(source_root, value, label)
    if not path.is_file():
        raise ValueError(f"{label}: path is not a file: {value}")
    return path.read_text(encoding="utf-8", errors="ignore")


def validate_adapter(source_root: pathlib.Path, registry_text: str, adapter: dict[str, Any], domain_id: str, seen: set[str]) -> None:
    adapter_id = text(adapter, "id", domain_id)
    if not ID_RE.fullmatch(adapter_id):
        raise ValueError(f"{domain_id}: invalid adapter id: {adapter_id}")
    if adapter_id in seen:
        raise ValueError(f"{domain_id}: duplicate adapter id: {adapter_id}")
    seen.add(adapter_id)

    source = text(adapter, "source", f"{domain_id}.{adapter_id}")
    adapter_text = source_text(source_root, source, f"{domain_id}.{adapter_id}.source")
    symbol = text(adapter, "symbol", f"{domain_id}.{adapter_id}")
    if symbol not in adapter_text:
        raise ValueError(f"{domain_id}.{adapter_id}: source does not contain symbol {symbol}")
    registry_ref = text(adapter, "registry_ref", f"{domain_id}.{adapter_id}")
    if registry_ref not in registry_text:
        raise ValueError(f"{domain_id}.{adapter_id}: registry does not reference {registry_ref}")


def validate_domain(source_root: pathlib.Path, domain: dict[str, Any], seen_domains: set[str]) -> None:
    domain_id = text(domain, "id", "domain")
    if not ID_RE.fullmatch(domain_id):
        raise ValueError(f"{domain_id}: invalid domain id")
    if domain_id in seen_domains:
        raise ValueError(f"duplicate domain id: {domain_id}")
    seen_domains.add(domain_id)

    owner_repo = text(domain, "owner_repo", domain_id)
    if owner_repo == "common-lib":
        raise ValueError(f"{domain_id}: runtime/provider adapters must stay out of common-lib")
    owner_path = source_file(source_root, owner_repo, f"{domain_id}.owner_repo")
    if not owner_path.is_dir():
        raise ValueError(f"{domain_id}: owner_repo is not a directory")

    status = text(domain, "status", domain_id)
    if status not in STATUSES:
        raise ValueError(f"{domain_id}: invalid status {status}")
    migration_debt = domain.get("migration_debt", "")
    if migration_debt:
        if not isinstance(migration_debt, str):
            raise ValueError(f"{domain_id}: migration_debt must be a string")
        if not ALLOW_MIGRATION_DEBT:
            raise ValueError(f"{domain_id}: migration_debt is blocked by default; set ALLOW_MIGRATION_DEBT=1 only for an explicit debt migration window")
    if status == "legacy_inline_registry" and not ALLOW_MIGRATION_DEBT:
        raise ValueError(f"{domain_id}: legacy_inline_registry is blocked by default; set ALLOW_MIGRATION_DEBT=1 only for an explicit debt migration window")
    if status == "legacy_inline_registry" and not text(domain, "migration_debt", domain_id):
        raise ValueError(f"{domain_id}: legacy inline registry must declare migration_debt")

    source_file(source_root, text(domain, "spi", domain_id), f"{domain_id}.spi")
    registry_path = text(domain, "registry", domain_id)
    registry_text = source_text(source_root, registry_path, f"{domain_id}.registry")
    adapters = domain.get("adapters")
    if not isinstance(adapters, list) or not adapters:
        raise ValueError(f"{domain_id}: adapters must be a non-empty list")
    seen_adapters: set[str] = set()
    for adapter in adapters:
        if not isinstance(adapter, dict):
            raise ValueError(f"{domain_id}: adapter entries must be objects")
        validate_adapter(source_root, registry_text, adapter, domain_id, seen_adapters)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--catalog", required=True)
    parser.add_argument("--source-root", required=True)
    args = parser.parse_args()

    try:
        source_root = pathlib.Path(args.source_root).resolve()
        catalog = load_json(pathlib.Path(args.catalog).resolve())
        domains = catalog.get("domains")
        if not isinstance(domains, list) or not domains:
            raise ValueError("runtime adapter catalog domains must be a non-empty list")
        seen_domains: set[str] = set()
        for domain in domains:
            if not isinstance(domain, dict):
                raise ValueError("domain entries must be objects")
            validate_domain(source_root, domain, seen_domains)
    except ValueError as exc:
        print(f"runtime adapter catalog validation failed: {exc}", file=sys.stderr)
        return 1

    print("runtime adapter catalog validated")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
