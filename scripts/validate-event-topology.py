#!/usr/bin/env python3
"""Validate deploy-owned event channel, outbox and consumer topology."""

from __future__ import annotations

import argparse
import json
import os
import pathlib
import re
import sys
from typing import Any


EVENT_RE = re.compile(r"^[a-z0-9]+(\.[a-z0-9_]+)+$")
SUBJECT_RE = re.compile(r"^(byte\.v\.forge|mailbox)\.[A-Za-z0-9_.>*-]+$")
TRANSPORTS = {"nats_jetstream", "nats_core"}
DELIVERY = {"at_least_once", "best_effort"}
ALLOW_MIGRATION_DEBT = os.environ.get("ALLOW_MIGRATION_DEBT") == "1"


def load_json(path: pathlib.Path) -> dict[str, Any]:
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except json.JSONDecodeError as exc:
        raise ValueError(f"{path}: invalid JSON: {exc}") from exc
    if not isinstance(data, dict):
        raise ValueError("event topology root must be an object")
    if data.get("version") != 1:
        raise ValueError("event topology version must be 1")
    return data


def text(entry: dict[str, Any], field: str, label: str) -> str:
    value = entry.get(field)
    if not isinstance(value, str) or not value.strip():
        raise ValueError(f"{label}: {field} is required")
    return value.strip()


def source_path(source_root: pathlib.Path, value: str, label: str) -> pathlib.Path:
    path = pathlib.PurePosixPath(value)
    if path.is_absolute() or ".." in path.parts:
        raise ValueError(f"{label}: path must be a safe relative path: {value}")
    full_path = source_root / pathlib.Path(path)
    if not full_path.exists():
        raise ValueError(f"{label}: path does not exist: {full_path}")
    return full_path


def validate_events(values: Any, label: str) -> list[str]:
    if not isinstance(values, list) or not values:
        raise ValueError(f"{label}: events must be a non-empty list")
    events: list[str] = []
    for value in values:
        if not isinstance(value, str) or not EVENT_RE.fullmatch(value.strip()):
            raise ValueError(f"{label}: invalid event name: {value!r}")
        events.append(value.strip())
    if len(set(events)) != len(events):
        raise ValueError(f"{label}: events must be unique")
    return events


def validate_channels(data: dict[str, Any]) -> dict[str, dict[str, Any]]:
    raw_channels = data.get("channels")
    if not isinstance(raw_channels, list) or not raw_channels:
        raise ValueError("channels must be a non-empty list")
    channels: dict[str, dict[str, Any]] = {}
    for index, channel in enumerate(raw_channels, start=1):
        if not isinstance(channel, dict):
            raise ValueError(f"channels[{index}] must be an object")
        label = f"channel {index}"
        channel_id = text(channel, "id", label)
        if channel_id in channels:
            raise ValueError(f"duplicate channel id: {channel_id}")
        transport = text(channel, "transport", channel_id)
        if transport not in TRANSPORTS:
            raise ValueError(f"{channel_id}: invalid transport: {transport}")
        delivery = text(channel, "delivery_semantics", channel_id)
        if delivery not in DELIVERY:
            raise ValueError(f"{channel_id}: invalid delivery_semantics")
        subjects = channel.get("subjects")
        if not isinstance(subjects, list) or not subjects:
            raise ValueError(f"{channel_id}: subjects must be a non-empty list")
        for subject in subjects:
            if not isinstance(subject, str) or not SUBJECT_RE.fullmatch(subject.strip()):
                raise ValueError(f"{channel_id}: invalid subject: {subject!r}")
        if transport == "nats_jetstream":
            if not text(channel, "stream_name", channel_id):
                raise ValueError(f"{channel_id}: stream_name is required")
            if channel.get("ack_policy") != "explicit":
                raise ValueError(f"{channel_id}: JetStream channel must use explicit ack")
            if channel.get("idempotency_required") is not True:
                raise ValueError(f"{channel_id}: JetStream channel requires idempotency")
            if not isinstance(channel.get("retention_days"), int) or channel["retention_days"] <= 0:
                raise ValueError(f"{channel_id}: JetStream channel requires positive retention_days")
        if transport == "nats_core":
            if channel.get("ack_policy") != "none":
                raise ValueError(f"{channel_id}: NATS core channel must use ack_policy=none")
            if channel.get("retention_days") not in (0, None):
                raise ValueError(f"{channel_id}: NATS core channel must not declare retention")
        channels[channel_id] = channel
    return channels


def validate_outboxes(data: dict[str, Any], channels: dict[str, dict[str, Any]], source_root: pathlib.Path) -> None:
    raw_outboxes = data.get("outboxes", [])
    if not isinstance(raw_outboxes, list):
        raise ValueError("outboxes must be a list")
    tables: set[str] = set()
    for index, outbox in enumerate(raw_outboxes, start=1):
        if not isinstance(outbox, dict):
            raise ValueError(f"outboxes[{index}] must be an object")
        label = f"outbox {index}"
        owner = text(outbox, "owner_repo", label)
        source_path(source_root, owner, f"{label}.owner_repo")
        table = text(outbox, "table", label)
        if table in tables:
            raise ValueError(f"{label}: duplicate outbox table: {table}")
        tables.add(table)
        channel = text(outbox, "channel", label)
        if channel not in channels:
            raise ValueError(f"{label}: unknown channel {channel}")
        if channels[channel]["transport"] != "nats_jetstream":
            raise ValueError(f"{label}: outbox must publish to a replayable JetStream channel")
        source_path(source_root, text(outbox, "source_file", label), f"{label}.source_file")
        source_path(source_root, text(outbox, "worker_file", label), f"{label}.worker_file")
        validate_events(outbox.get("publishes"), label)


def validate_consumers(data: dict[str, Any], channels: dict[str, dict[str, Any]], source_root: pathlib.Path) -> None:
    raw_consumers = data.get("consumers", [])
    if not isinstance(raw_consumers, list):
        raise ValueError("consumers must be a list")
    durables: set[tuple[str, str]] = set()
    common_catalog = source_path(source_root, "common-lib/eventcatalog/catalog.go", "event catalog").read_text(encoding="utf-8", errors="ignore")
    for index, consumer in enumerate(raw_consumers, start=1):
        if not isinstance(consumer, dict):
            raise ValueError(f"consumers[{index}] must be an object")
        label = f"consumer {index}"
        owner = text(consumer, "owner_repo", label)
        source_path(source_root, owner, f"{label}.owner_repo")
        channel = text(consumer, "channel", label)
        if channel not in channels:
            raise ValueError(f"{label}: unknown channel {channel}")
        durable = text(consumer, "durable", label)
        durable_key = (channel, durable)
        if durable_key in durables:
            raise ValueError(f"{label}: duplicate durable on channel {channel}: {durable}")
        durables.add(durable_key)
        source_file = text(consumer, "source_file", label)
        source_text = source_path(source_root, source_file, f"{label}.source_file").read_text(encoding="utf-8", errors="ignore")
        catalog_file = consumer.get("catalog_file")
        catalog_text = ""
        if catalog_file is not None:
            if not isinstance(catalog_file, str) or not catalog_file.strip():
                raise ValueError(f"{label}: catalog_file must be a non-empty string when provided")
            catalog_text = source_path(source_root, catalog_file, f"{label}.catalog_file").read_text(encoding="utf-8", errors="ignore")
        constructed = '"gpt-" + channel + "-otp-resume"' in source_text and durable.startswith("gpt-") and durable.endswith("-otp-resume")
        if durable not in source_text and durable not in catalog_text and durable not in common_catalog and not constructed:
            raise ValueError(f"{label}: durable {durable} is not referenced by source_file, catalog_file or common event catalog")
        validate_events(consumer.get("events"), label)
        if channels[channel]["transport"] == "nats_jetstream" and not durable:
            raise ValueError(f"{label}: JetStream consumer requires durable")


def validate_debt(data: dict[str, Any], source_root: pathlib.Path) -> None:
    raw_debt = data.get("migration_debt", [])
    if not isinstance(raw_debt, list):
        raise ValueError("migration_debt must be a list")
    if raw_debt and not ALLOW_MIGRATION_DEBT:
        raise ValueError("migration_debt is blocked by default; set ALLOW_MIGRATION_DEBT=1 only for an explicit debt migration window")
    debt_ids: set[str] = set()
    for index, item in enumerate(raw_debt, start=1):
        if not isinstance(item, dict):
            raise ValueError(f"migration_debt[{index}] must be an object")
        debt_id = text(item, "id", f"migration_debt {index}")
        if debt_id in debt_ids:
            raise ValueError(f"duplicate migration debt id: {debt_id}")
        debt_ids.add(debt_id)
        source_path(source_root, text(item, "owner_repo", debt_id), f"{debt_id}.owner_repo")
        text(item, "reason", debt_id)
        validate_events(item.get("events"), debt_id)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--manifest", required=True)
    parser.add_argument("--source-root", required=True)
    args = parser.parse_args()

    try:
        source_root = pathlib.Path(args.source_root).resolve()
        topology = load_json(pathlib.Path(args.manifest).resolve())
        channels = validate_channels(topology)
        validate_outboxes(topology, channels, source_root)
        validate_consumers(topology, channels, source_root)
        validate_debt(topology, source_root)
    except ValueError as exc:
        print(f"event topology validation failed: {exc}", file=sys.stderr)
        return 1

    print("event topology validated")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
