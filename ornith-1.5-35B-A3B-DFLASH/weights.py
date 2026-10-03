#!/usr/bin/env python3
"""Resolve and validate a target or DFlash checkpoint without copying weights."""

import argparse
import json
import re
import struct
import sys
from pathlib import Path


def fail(message: str) -> None:
    raise ValueError(message)


def cached_snapshot(cache: Path, repo: str) -> Path:
    namespace, name = repo.split("/", 1)
    repo_cache = cache / f"models--{namespace}--{name}"
    ref = repo_cache / "refs" / "main"
    if not ref.is_file():
        fail(f"No cached main revision for {repo} under {cache}; enable AUTO_DOWNLOAD or set a local path")
    revision = ref.read_text().strip()
    if not revision or "/" in revision or ".." in revision:
        fail(f"Invalid cached revision for {repo}: {revision!r}")
    snapshot = repo_cache / "snapshots" / revision
    if not snapshot.is_dir():
        fail(f"Cached snapshot is missing for {repo}: {snapshot}")
    return snapshot


def check_safetensors(path: Path) -> None:
    size = path.stat().st_size
    with path.open("rb") as stream:
        length_bytes = stream.read(8)
        if len(length_bytes) != 8:
            fail(f"Truncated safetensors file: {path}")
        header_size = struct.unpack("<Q", length_bytes)[0]
        if header_size == 0 or header_size > 256 * 1024 * 1024 or 8 + header_size > size:
            fail(f"Invalid safetensors header size: {path}")
        try:
            header = json.loads(stream.read(header_size))
        except (UnicodeDecodeError, json.JSONDecodeError) as exc:
            fail(f"Invalid safetensors header: {path}: {exc}")
    if not isinstance(header, dict):
        fail(f"Safetensors header is not a JSON object: {path}")
    offsets = []
    for name, tensor in header.items():
        if name == "__metadata__":
            continue
        pair = tensor.get("data_offsets") if isinstance(tensor, dict) else None
        if not isinstance(pair, list) or len(pair) != 2 or not all(isinstance(x, int) for x in pair):
            fail(f"Invalid tensor offset in {path}: {name}")
        start, end = pair
        if start < 0 or end < start:
            fail(f"Invalid tensor range in {path}: {name}")
        offsets.append(end)
    if not offsets or size != 8 + header_size + max(offsets):
        fail(f"Truncated or malformed safetensors data: {path}")


def validate(path: Path, role: str) -> None:
    if not path.is_dir():
        fail(f"{role} checkpoint directory is missing: {path}")
    config = path / "config.json"
    if not config.is_file():
        fail(f"{role} checkpoint is missing config.json: {path}")
    try:
        config_data = json.loads(config.read_text())
    except (UnicodeDecodeError, json.JSONDecodeError) as exc:
        fail(f"{role} config.json is invalid: {exc}")
    if not isinstance(config_data, dict) or not config_data:
        fail(f"{role} config.json must be a nonempty JSON object")
    if role == "target" and not any((path / name).is_file() for name in ("tokenizer.json", "tokenizer.model")):
        fail(f"Target checkpoint is missing its tokenizer: {path}")
    if role == "target" and (path / "tokenizer.json").is_file():
        try:
            tokenizer = json.loads((path / "tokenizer.json").read_text())
        except (UnicodeDecodeError, json.JSONDecodeError) as exc:
            fail(f"Target tokenizer.json is invalid: {exc}")
        if not isinstance(tokenizer, dict) or not tokenizer:
            fail("Target tokenizer.json must be a nonempty JSON object")
    index = path / "model.safetensors.index.json"
    if index.is_file():
        try:
            weight_map = json.loads(index.read_text())["weight_map"]
        except (UnicodeDecodeError, json.JSONDecodeError, KeyError, TypeError) as exc:
            fail(f"Invalid safetensors index: {index}: {exc}")
        if not isinstance(weight_map, dict) or not weight_map:
            fail(f"Empty safetensors index: {index}")
        names = set(weight_map.values())
    else:
        names = {entry.name for entry in path.glob("*.safetensors")}
        numbered = [re.fullmatch(r"model-(\d+)-of-(\d+)\.safetensors", name) for name in names]
        if any(numbered):
            if not all(numbered):
                fail(f"Mixed numbered and unnumbered safetensors without an index: {path}")
            totals = {int(match.group(2)) for match in numbered if match}
            numbers = {int(match.group(1)) for match in numbered if match}
            if len(totals) != 1 or numbers != set(range(1, next(iter(totals)) + 1)):
                fail(f"Incomplete numbered safetensors shards without an index: {path}")
    if not names or not all(
        isinstance(name, str)
        and name.endswith(".safetensors")
        and Path(name).name == name
        for name in names
    ):
        fail(f"{role} checkpoint has no valid safetensors list: {path}")
    for name in sorted(names):
        shard = path / name
        if not shard.is_file():
            fail(f"Missing {role} shard: {shard}")
        check_safetensors(shard)
    print(f"Validated {role}: {len(names)} safetensors file(s) in {path}", file=sys.stderr)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--role", required=True, choices=("target", "draft"))
    parser.add_argument("--repo", required=True)
    parser.add_argument("--cache", required=True)
    parser.add_argument("--local", default="auto")
    parser.add_argument("--download", action="store_true")
    args = parser.parse_args()

    if args.local != "auto":
        path = Path(args.local).expanduser().resolve()
    elif args.download:
        try:
            from huggingface_hub import snapshot_download
        except ImportError as exc:
            fail(f"huggingface_hub is needed to download {args.repo}: {exc}")
        path = Path(snapshot_download(repo_id=args.repo, cache_dir=args.cache)).resolve()
    else:
        path = cached_snapshot(Path(args.cache).expanduser().resolve(), args.repo).resolve()
    validate(path, args.role)
    print(path)


if __name__ == "__main__":
    try:
        main()
    except (OSError, ValueError, RuntimeError) as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        sys.exit(1)
