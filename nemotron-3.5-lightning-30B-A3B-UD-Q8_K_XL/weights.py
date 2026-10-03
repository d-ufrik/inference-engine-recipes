#!/usr/bin/env python3
"""Download one GGUF to the standard Hub cache or validate a local GGUF."""

import argparse
import sys
from pathlib import Path


def validate(path: Path, expected_bytes: int) -> Path:
    path = path.expanduser().resolve()
    if not path.is_file():
        raise ValueError(f"Model file is missing: {path}")
    size = path.stat().st_size
    if expected_bytes and size != expected_bytes:
        raise ValueError(f"Incorrect GGUF size at {path}: {size} bytes; expected {expected_bytes}")
    if size < 1024:
        raise ValueError(f"GGUF file is too small: {path}")
    with path.open("rb") as stream:
        header = stream.read(24)
    if header[:4] != b"GGUF" or int.from_bytes(header[4:8], "little") not in (2, 3):
        raise ValueError(f"Invalid GGUF header: {path}")
    if int.from_bytes(header[8:16], "little") == 0:
        raise ValueError(f"GGUF contains no tensors: {path}")
    return path


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repo", required=True)
    parser.add_argument("--filename", required=True)
    parser.add_argument("--cache", required=True)
    parser.add_argument("--local", default="auto")
    parser.add_argument("--expected-bytes", required=True, type=int)
    parser.add_argument("--download", action="store_true")
    args = parser.parse_args()
    if args.expected_bytes < 0:
        raise ValueError("--expected-bytes must be nonnegative")
    if args.local != "auto":
        path = Path(args.local)
        if path.is_dir():
            path /= args.filename
    elif args.download:
        from huggingface_hub import hf_hub_download
        path = Path(hf_hub_download(repo_id=args.repo, filename=args.filename, cache_dir=args.cache))
    else:
        namespace, name = args.repo.split("/", 1)
        repo_cache = Path(args.cache) / f"models--{namespace}--{name}"
        ref = repo_cache / "refs" / "main"
        if not ref.is_file():
            raise ValueError(f"No cached main revision of {args.repo}; enable AUTO_DOWNLOAD or set MODEL_PATH")
        revision = ref.read_text().strip()
        if not revision or "/" in revision or ".." in revision:
            raise ValueError(f"Invalid cached revision: {revision!r}")
        path = repo_cache / "snapshots" / revision / args.filename
    path = validate(path, args.expected_bytes)
    print(f"Validated GGUF: {path}", file=sys.stderr)
    print(path)


if __name__ == "__main__":
    try:
        main()
    except (ImportError, OSError, ValueError, RuntimeError) as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        sys.exit(1)
