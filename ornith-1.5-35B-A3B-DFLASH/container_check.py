#!/usr/bin/env python3
"""Check that a Docker container belongs to this recipe and matches .env."""

import argparse
import json
import subprocess
import sys
from pathlib import Path

OWNER_LABEL = "io.inference-engine-recipes.recipe"
CONFIG_LABEL = "io.inference-engine-recipes.config-sha256"


def fail(message: str) -> None:
    print(f"ERROR: {message}", file=sys.stderr)
    sys.exit(1)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--name", required=True)
    parser.add_argument("--recipe", required=True)
    parser.add_argument("--mode", choices=("owner", "config"), required=True)
    parser.add_argument("--hash")
    parser.add_argument("--image")
    parser.add_argument("--host")
    parser.add_argument("--port")
    parser.add_argument("--cache")
    parser.add_argument("--model-local")
    parser.add_argument("--draft-local")
    args = parser.parse_args()
    result = subprocess.run(["docker", "inspect", args.name], capture_output=True, text=True)
    if result.returncode:
        fail(f"Container {args.name} does not exist or Docker is unavailable")
    try:
        container = json.loads(result.stdout)[0]
    except (ValueError, IndexError) as exc:
        fail(f"Could not parse Docker inspection for {args.name}: {exc}")
    labels = container["Config"].get("Labels") or {}
    if labels.get(OWNER_LABEL) != args.recipe:
        fail(f"Container {args.name} is not owned by this recipe; leaving it untouched")
    if args.mode == "owner":
        return
    if labels.get(CONFIG_LABEL) != args.hash:
        fail(f"Container {args.name} was launched with different settings; stop it before restarting")
    if container["Config"]["Image"] != args.image:
        fail(f"Container {args.name} uses a different image")
    if not container["State"]["Running"]:
        fail(f"Container {args.name} is stopped; run ./start.sh stop, then ./start.sh")
    bindings = (container["HostConfig"].get("PortBindings") or {}).get("8000/tcp") or []
    if len(bindings) != 1 or bindings[0].get("HostIp", "") not in (args.host, "" if args.host == "0.0.0.0" else args.host) or bindings[0].get("HostPort") != args.port:
        fail(f"Container {args.name} does not publish the configured address and port")
    mounts = {mount["Destination"]: mount for mount in container.get("Mounts", [])}
    expected = {}
    if args.cache:
        expected["/root/.cache/huggingface/hub"] = args.cache
    if args.model_local:
        expected["/models/target"] = args.model_local
    if args.draft_local:
        expected["/models/draft"] = args.draft_local
    for destination, source in expected.items():
        mount = mounts.get(destination)
        if not mount or Path(mount["Source"]).resolve() != Path(source).resolve() or mount["RW"]:
            fail(f"Container {args.name} has a missing, changed, or writable mount at {destination}")
    if container["Config"].get("Entrypoint") != ["vllm"]:
        fail(f"Container {args.name} has an unexpected entrypoint")


if __name__ == "__main__":
    main()
