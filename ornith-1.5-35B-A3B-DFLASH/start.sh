#!/usr/bin/env bash
# Self-contained single-GB10 Ornith NVFP4 + DFlash launcher.
set -Eeuo pipefail

RECIPE_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
cd "$RECIPE_DIR"
RECIPE_ID=ornith-1.5-35b-a3b-dflash
CONTAINER_CACHE=/root/.cache/huggingface/hub

ACTION=start
ACTION_SET=0
DRY_RUN=0
for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY_RUN=1 ;;
    start|download|status|health|logs|stop)
      if (( ACTION_SET )); then echo "Only one action may be specified" >&2; exit 2; fi
      ACTION="$arg"; ACTION_SET=1 ;;
    -h|--help) echo "Usage: ./start.sh [start|download|status|health|logs|stop] [--dry-run]"; exit 0 ;;
    *) echo "Unknown argument: $arg" >&2; exit 2 ;;
  esac
done

if [[ ! -f .env ]]; then echo "Missing the recipe's .env: $RECIPE_DIR/.env" >&2; exit 1; fi
# .env is committed with working defaults. Never add secrets to it.
set -a
# shellcheck disable=SC1091
source .env
set +a

HF_HUB_CACHE="${HF_HUB_CACHE:-${HF_HOME:-${XDG_CACHE_HOME:-$HOME/.cache}/huggingface}/hub}"
HF_VENV="${HF_VENV:-${XDG_CACHE_HOME:-$HOME/.cache}/$RECIPE_ID/hf-venv}"
MODEL_DIR="${MODEL_DIR:-auto}"
DRAFT_DIR="${DRAFT_DIR:-auto}"
MODEL_REPO="${MODEL_REPO:-ornith-ai/Ornith-1.5-35B-A3B-NVFP4}"
DRAFT_REPO="${DRAFT_REPO:-ornith-ai/Ornith-1.5-35B-A3B-DFlash}"
AUTO_DOWNLOAD="${AUTO_DOWNLOAD:-1}"
IMAGE="${IMAGE:-vllm/vllm-openai:v0.27.1}"
CONTAINER_NAME="${CONTAINER_NAME:-vllm-ornith-1.5-35b-a3b-dflash}"
SERVED_MODEL_NAME="${SERVED_MODEL_NAME:-ornith-1.5-35b-a3b}"
HOST="${HOST:-127.0.0.1}"
PORT="${PORT:-8000}"
GPU_MEMORY_UTILIZATION="${GPU_MEMORY_UTILIZATION:-0.42}"
MAX_MODEL_LEN="${MAX_MODEL_LEN:-100000}"
MAX_NUM_SEQS="${MAX_NUM_SEQS:-8}"
MAX_NUM_BATCHED_TOKENS="${MAX_NUM_BATCHED_TOKENS:-8192}"
SPECULATIVE_TOKENS="${SPECULATIVE_TOKENS:-8}"
STARTUP_TIMEOUT="${STARTUP_TIMEOUT:-900}"
MIN_AVAILABLE_GIB="${MIN_AVAILABLE_GIB:-55}"
MIN_FREE_TARGET_GIB="${MIN_FREE_TARGET_GIB:-30}"
MIN_FREE_DRAFT_GIB="${MIN_FREE_DRAFT_GIB:-2}"
MIN_FREE_IMAGE_GIB="${MIN_FREE_IMAGE_GIB:-12}"

absolute_path() {
  case "$1" in /*) printf '%s' "$1" ;; *) printf '%s/%s' "$RECIPE_DIR" "$1" ;; esac
}
HF_HUB_CACHE="$(absolute_path "$HF_HUB_CACHE")"
HF_HUB_CACHE="$(python3 -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' "$HF_HUB_CACHE")"
HF_VENV="$(absolute_path "$HF_VENV")"
if [[ "$MODEL_DIR" != auto ]]; then MODEL_DIR="$(absolute_path "$MODEL_DIR")"; fi
if [[ "$DRAFT_DIR" != auto ]]; then DRAFT_DIR="$(absolute_path "$DRAFT_DIR")"; fi

need() { command -v "$1" >/dev/null || { echo "Missing required command: $1" >&2; exit 1; }; }
show_cmd() { printf ' +'; printf ' %q' "$@"; printf '\n'; }
error() { echo "ERROR: $*" >&2; exit 1; }

validate_config() {
  need python3
  local name value
  for name in PORT MAX_MODEL_LEN MAX_NUM_SEQS MAX_NUM_BATCHED_TOKENS SPECULATIVE_TOKENS STARTUP_TIMEOUT MIN_AVAILABLE_GIB MIN_FREE_TARGET_GIB MIN_FREE_DRAFT_GIB MIN_FREE_IMAGE_GIB; do
    value="${!name}"
    [[ "$value" =~ ^[1-9][0-9]*$ ]] || error "$name must be a positive decimal integer"
  done
  (( PORT <= 65535 )) || error "PORT must be <= 65535"
  [[ "$AUTO_DOWNLOAD" == 0 || "$AUTO_DOWNLOAD" == 1 ]] || error "AUTO_DOWNLOAD must be 0 or 1"
  [[ "$MODEL_REPO" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || error "Invalid MODEL_REPO"
  [[ "$DRAFT_REPO" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || error "Invalid DRAFT_REPO"
  [[ "$CONTAINER_NAME" =~ ^[A-Za-z0-9][A-Za-z0-9_.-]*$ ]] || error "Invalid CONTAINER_NAME"
  [[ -n "$IMAGE" && -n "$SERVED_MODEL_NAME" ]] || error "IMAGE and SERVED_MODEL_NAME are required"
  [[ "$MODEL_DIR" != "$DRAFT_DIR" || "$MODEL_DIR" == auto ]] || error "MODEL_DIR and DRAFT_DIR must differ"
  local path
  for path in "$HF_HUB_CACHE" "$HF_VENV" "$MODEL_DIR" "$DRAFT_DIR"; do
    [[ "$path" != *:* && "$path" != *$'\n'* ]] || error "Paths cannot contain a colon or newline: $path"
  done
  python3 - "$HOST" "$GPU_MEMORY_UTILIZATION" <<'PY'
import ipaddress, sys
from decimal import Decimal, InvalidOperation
try:
    ipaddress.IPv4Address(sys.argv[1])
    value = Decimal(sys.argv[2])
    assert 0 < value < 1
except (ValueError, InvalidOperation, AssertionError):
    sys.exit("HOST must be an IPv4 address and GPU_MEMORY_UTILIZATION must be between 0 and 1")
PY
}
validate_config

HEALTH_HOST="$HOST"
if [[ "$HOST" == 0.0.0.0 ]]; then HEALTH_HOST=127.0.0.1; fi
HEALTH_URL="http://$HEALTH_HOST:$PORT/health"
MODELS_URL="http://$HEALTH_HOST:$PORT/v1/models"
CONFIG_HASH="$(python3 - "$IMAGE" "$CONTAINER_NAME" "$SERVED_MODEL_NAME" "$HOST" "$PORT" "$HF_HUB_CACHE" "$MODEL_DIR" "$DRAFT_DIR" "$MODEL_REPO" "$DRAFT_REPO" "$GPU_MEMORY_UTILIZATION" "$MAX_MODEL_LEN" "$MAX_NUM_SEQS" "$MAX_NUM_BATCHED_TOKENS" "$SPECULATIVE_TOKENS" <<'PY'
import hashlib, json, sys
print(hashlib.sha256(json.dumps(sys.argv[1:], separators=(',', ':')).encode()).hexdigest())
PY
)"

cache_needed() { [[ "$MODEL_DIR" == auto || "$DRAFT_DIR" == auto ]]; }

check_disk() {
  local location="$1" minimum="$2" label="$3"
  python3 - "$location" "$minimum" "$label" <<'PY'
from pathlib import Path
from shutil import disk_usage
import sys
path = Path(sys.argv[1])
while not path.exists():
    if path == path.parent:
        sys.exit(f"Cannot locate a filesystem for {sys.argv[3]}")
    path = path.parent
free = disk_usage(path).free
minimum = int(sys.argv[2]) * 1024**3
if free < minimum:
    sys.exit(f"Need at least {sys.argv[2]} GiB free for {sys.argv[3]} at {path}; only {free / 1024**3:.1f} GiB available")
PY
}

check_memory() {
  local available_kib
  available_kib="$(awk '/^MemAvailable:/ {print $2}' /proc/meminfo)"
  [[ "$available_kib" =~ ^[0-9]+$ ]] || error "Could not read MemAvailable"
  (( available_kib >= MIN_AVAILABLE_GIB * 1024 * 1024 )) || error "Need $MIN_AVAILABLE_GIB GiB MemAvailable; found $((available_kib / 1024 / 1024)) GiB"
}

check_host() {
  need docker; need curl; need nvidia-smi
  [[ "$(uname -m)" == aarch64 ]] || error "This kit targets a Linux aarch64 DGX Spark"
  docker info >/dev/null || error "Docker daemon is unavailable"
  [[ -n "$(nvidia-smi -L)" ]] || error "No NVIDIA GPU detected"
}

check_port() {
  python3 - "$HOST" "$PORT" <<'PY'
import socket, sys
sock = socket.socket()
try:
    sock.bind((sys.argv[1], int(sys.argv[2])))
except OSError as exc:
    sys.exit(f"Configured address/port is unavailable: {exc}")
finally:
    sock.close()
PY
  [[ -z "$(docker ps --filter "publish=$PORT" --format '{{.Names}}')" ]] || error "Port $PORT is published by another container"
}

hub_python() {
  if [[ ! -x "$HF_VENV/bin/python" ]]; then
    mkdir -p "$(dirname "$HF_VENV")"
    python3 -m venv "$HF_VENV" || error "Could not create Python venv; install python3-venv"
  fi
  if ! "$HF_VENV/bin/python" -c 'import huggingface_hub' >/dev/null 2>&1; then
    "$HF_VENV/bin/python" -m pip install --disable-pip-version-check 'huggingface_hub>=0.32,<2' || error "Could not install huggingface_hub"
  fi
}

resolve_one() {
  local role="$1" repo="$2" local_dir="$3" interpreter=python3
  local -a flags=(--role "$role" --repo "$repo" --cache "$HF_HUB_CACHE" --local "$local_dir")
  if [[ "$local_dir" == auto && "$AUTO_DOWNLOAD" == 1 ]]; then
    interpreter="$HF_VENV/bin/python"
    flags+=(--download)
  fi
  "$interpreter" "$RECIPE_DIR/weights.py" "${flags[@]}"
}

prepare_weights() {
  if [[ "$MODEL_DIR" == auto && "$AUTO_DOWNLOAD" == 1 ]] && ! python3 weights.py --role target --repo "$MODEL_REPO" --cache "$HF_HUB_CACHE" >/dev/null 2>&1; then
    check_disk "$HF_HUB_CACHE" "$MIN_FREE_TARGET_GIB" "target model download"
  fi
  if [[ "$DRAFT_DIR" == auto && "$AUTO_DOWNLOAD" == 1 ]] && ! python3 weights.py --role draft --repo "$DRAFT_REPO" --cache "$HF_HUB_CACHE" >/dev/null 2>&1; then
    check_disk "$HF_HUB_CACHE" "$MIN_FREE_DRAFT_GIB" "draft model download"
  fi
  if [[ "$AUTO_DOWNLOAD" == 1 ]] && cache_needed; then hub_python; fi
  MODEL_HOST_PATH="$(resolve_one target "$MODEL_REPO" "$MODEL_DIR")" || error "Target download or validation failed"
  DRAFT_HOST_PATH="$(resolve_one draft "$DRAFT_REPO" "$DRAFT_DIR")" || error "Draft download or validation failed"
  if [[ "$MODEL_DIR" == auto ]]; then
    [[ "$MODEL_HOST_PATH" == "$HF_HUB_CACHE"/* ]] || error "Target snapshot escaped HF_HUB_CACHE"
    MODEL_CONTAINER_PATH="$CONTAINER_CACHE/${MODEL_HOST_PATH#"$HF_HUB_CACHE"/}"
  else MODEL_CONTAINER_PATH=/models/target; fi
  if [[ "$DRAFT_DIR" == auto ]]; then
    [[ "$DRAFT_HOST_PATH" == "$HF_HUB_CACHE"/* ]] || error "Draft snapshot escaped HF_HUB_CACHE"
    DRAFT_CONTAINER_PATH="$CONTAINER_CACHE/${DRAFT_HOST_PATH#"$HF_HUB_CACHE"/}"
  else DRAFT_CONTAINER_PATH=/models/draft; fi
  echo "Target: $MODEL_HOST_PATH"
  echo "Draft:  $DRAFT_HOST_PATH"
}

prepare_image() {
  if ! docker image inspect "$IMAGE" >/dev/null 2>&1; then
    local docker_root
    docker_root="$(docker info --format '{{.DockerRootDir}}')"
    check_disk "$docker_root" "$MIN_FREE_IMAGE_GIB" "Docker image"
  fi
  if ! docker pull "$IMAGE"; then
    docker image inspect "$IMAGE" >/dev/null 2>&1 || error "Image pull failed and no local copy exists: $IMAGE"
    echo "WARN: using existing local image because pull failed" >&2
  fi
  [[ "$(docker image inspect "$IMAGE" --format '{{.Architecture}}')" == arm64 ]] || error "Image is not linux/arm64: $IMAGE"
  docker run --rm --gpus all --entrypoint nvidia-smi "$IMAGE" -L >/dev/null || error "Image cannot access the NVIDIA GPU"
}

container_exists() { docker inspect "$CONTAINER_NAME" >/dev/null 2>&1; }
check_container() {
  local mode="$1"
  local -a args=(--name "$CONTAINER_NAME" --recipe "$RECIPE_ID" --mode "$mode")
  if [[ "$mode" == config ]]; then
    args+=(--hash "$CONFIG_HASH" --image "$IMAGE" --host "$HOST" --port "$PORT")
    if cache_needed; then args+=(--cache "$HF_HUB_CACHE"); fi
    if [[ "$MODEL_DIR" != auto ]]; then args+=(--model-local "$MODEL_DIR"); fi
    if [[ "$DRAFT_DIR" != auto ]]; then args+=(--draft-local "$DRAFT_DIR"); fi
  fi
  python3 "$RECIPE_DIR/container_check.py" "${args[@]}"
}

check_api() {
  check_container config || return 1
  curl --noproxy '*' -fsS --max-time 5 -o /dev/null "$HEALTH_URL" || return 1
  curl --noproxy '*' -fsS --max-time 5 "$MODELS_URL" | python3 -c 'import json,sys; expected=sys.argv[1]; data=json.load(sys.stdin)["data"]; assert any(x.get("id")==expected for x in data), "served model ID mismatch"' "$SERVED_MODEL_NAME"
}

wait_ready() {
  local deadline=$((SECONDS + STARTUP_TIMEOUT))
  while (( SECONDS <= deadline )); do
    if ! check_container config; then
      docker logs --tail 80 "$CONTAINER_NAME" >&2 || true
      return 1
    fi
    if check_api >/dev/null 2>&1; then echo "READY: $HEALTH_URL ($SERVED_MODEL_NAME)"; return 0; fi
    if (( SECONDS >= deadline )); then break; fi
    sleep 5
  done
  echo "Timed out after ${STARTUP_TIMEOUT}s waiting for $HEALTH_URL and $SERVED_MODEL_NAME" >&2
  docker logs --tail 80 "$CONTAINER_NAME" >&2 || true
  return 1
}

print_plan() {
  echo " + validate Linux aarch64, GPU, Docker, memory, disk, and port prerequisites"
  if [[ "$MODEL_DIR" == auto ]]; then
    if [[ "$AUTO_DOWNLOAD" == 1 ]]; then show_cmd "$HF_VENV/bin/python" weights.py --role target --repo "$MODEL_REPO" --cache "$HF_HUB_CACHE" --download
    else show_cmd python3 weights.py --role target --repo "$MODEL_REPO" --cache "$HF_HUB_CACHE"; fi
    model_plan="$CONTAINER_CACHE/models--${MODEL_REPO//\//--}/snapshots/<resolved-main>"
  else
    show_cmd python3 weights.py --role target --local "$MODEL_DIR"
    model_plan=/models/target
  fi
  if [[ "$DRAFT_DIR" == auto ]]; then
    if [[ "$AUTO_DOWNLOAD" == 1 ]]; then show_cmd "$HF_VENV/bin/python" weights.py --role draft --repo "$DRAFT_REPO" --cache "$HF_HUB_CACHE" --download
    else show_cmd python3 weights.py --role draft --repo "$DRAFT_REPO" --cache "$HF_HUB_CACHE"; fi
    draft_plan="$CONTAINER_CACHE/models--${DRAFT_REPO//\//--}/snapshots/<resolved-main>"
  else
    show_cmd python3 weights.py --role draft --local "$DRAFT_DIR"
    draft_plan=/models/draft
  fi
  echo " + validate target and draft safetensors files in the resolved snapshots"
  if [[ "$ACTION" == download ]]; then return; fi
  show_cmd docker pull "$IMAGE"
  show_cmd docker run --rm --gpus all --entrypoint nvidia-smi "$IMAGE" -L
  local spec
  spec="$(python3 -c 'import json,sys; print(json.dumps({"method":"dflash","model":sys.argv[1],"num_speculative_tokens":int(sys.argv[2])}))' "$draft_plan" "$SPECULATIVE_TOKENS")"
  local -a mounts=()
  if cache_needed; then mounts+=(-v "$HF_HUB_CACHE:$CONTAINER_CACHE:ro"); fi
  if [[ "$MODEL_DIR" != auto ]]; then mounts+=(-v "$MODEL_DIR:/models/target:ro"); fi
  if [[ "$DRAFT_DIR" != auto ]]; then mounts+=(-v "$DRAFT_DIR:/models/draft:ro"); fi
  show_cmd docker run -d --name "$CONTAINER_NAME" --gpus all --ipc host --restart unless-stopped \
    --label "io.inference-engine-recipes.recipe=$RECIPE_ID" --label "io.inference-engine-recipes.config-sha256=$CONFIG_HASH" \
    --ulimit memlock=-1 --ulimit stack=67108864 --entrypoint vllm -p "$HOST:$PORT:8000" \
    "${mounts[@]}" -e HF_HUB_CACHE="$CONTAINER_CACHE" -e HF_HUB_OFFLINE=1 "$IMAGE" serve "$model_plan" \
    --served-model-name "$SERVED_MODEL_NAME" --trust-remote-code --host 0.0.0.0 --port 8000 \
    --kv-cache-dtype fp8 --gpu-memory-utilization "$GPU_MEMORY_UTILIZATION" \
    --max-model-len "$MAX_MODEL_LEN" --max-num-seqs "$MAX_NUM_SEQS" --max-num-batched-tokens "$MAX_NUM_BATCHED_TOKENS" \
    --enable-chunked-prefill --async-scheduling --enable-prefix-caching --load-format fastsafetensors \
    --attention-backend flashinfer --reasoning-parser qwen3 --tool-call-parser qwen3_coder \
    --enable-auto-tool-choice --speculative-config "$spec"
  echo " + wait up to ${STARTUP_TIMEOUT}s for $HEALTH_URL and $SERVED_MODEL_NAME in /v1/models"
}

start_server() {
  check_host
  if container_exists; then
    check_container config || return 1
    echo "$CONTAINER_NAME already running with matching settings; waiting for readiness"
    wait_ready
    return
  fi
  check_port
  check_memory
  prepare_weights
  check_memory
  prepare_image
  check_port
  local spec
  spec="$(python3 -c 'import json,sys; print(json.dumps({"method":"dflash","model":sys.argv[1],"num_speculative_tokens":int(sys.argv[2])}))' "$DRAFT_CONTAINER_PATH" "$SPECULATIVE_TOKENS")"
  local -a mounts=()
  if cache_needed; then mounts+=(-v "$HF_HUB_CACHE:$CONTAINER_CACHE:ro"); fi
  if [[ "$MODEL_DIR" != auto ]]; then mounts+=(-v "$MODEL_HOST_PATH:/models/target:ro"); fi
  if [[ "$DRAFT_DIR" != auto ]]; then mounts+=(-v "$DRAFT_HOST_PATH:/models/draft:ro"); fi
  docker run -d --name "$CONTAINER_NAME" --gpus all --ipc host --restart unless-stopped \
    --label "io.inference-engine-recipes.recipe=$RECIPE_ID" --label "io.inference-engine-recipes.config-sha256=$CONFIG_HASH" \
    --ulimit memlock=-1 --ulimit stack=67108864 --entrypoint vllm -p "$HOST:$PORT:8000" \
    "${mounts[@]}" -e HF_HUB_CACHE="$CONTAINER_CACHE" -e HF_HUB_OFFLINE=1 "$IMAGE" serve "$MODEL_CONTAINER_PATH" \
    --served-model-name "$SERVED_MODEL_NAME" --trust-remote-code --host 0.0.0.0 --port 8000 \
    --kv-cache-dtype fp8 --gpu-memory-utilization "$GPU_MEMORY_UTILIZATION" \
    --max-model-len "$MAX_MODEL_LEN" --max-num-seqs "$MAX_NUM_SEQS" --max-num-batched-tokens "$MAX_NUM_BATCHED_TOKENS" \
    --enable-chunked-prefill --async-scheduling --enable-prefix-caching --load-format fastsafetensors \
    --attention-backend flashinfer --reasoning-parser qwen3 --tool-call-parser qwen3_coder \
    --enable-auto-tool-choice --speculative-config "$spec"
  wait_ready
}

if (( DRY_RUN )); then
  case "$ACTION" in
    start|download) print_plan ;;
    status|health) show_cmd python3 container_check.py --name "$CONTAINER_NAME" --mode config; show_cmd curl --noproxy '*' -fsS "$HEALTH_URL"; show_cmd curl --noproxy '*' -fsS "$MODELS_URL" ;;
    logs) show_cmd python3 container_check.py --name "$CONTAINER_NAME" --recipe "$RECIPE_ID" --mode owner; show_cmd docker logs --tail 100 "$CONTAINER_NAME" ;;
    stop) show_cmd python3 container_check.py --name "$CONTAINER_NAME" --mode owner; show_cmd docker rm -f "$CONTAINER_NAME" ;;
  esac
  exit 0
fi

case "$ACTION" in
  start) start_server ;;
  download) prepare_weights ;;
  health) check_api && echo "OK: $HEALTH_URL ($SERVED_MODEL_NAME)" ;;
  status)
    need docker; docker ps -a --filter "name=^/${CONTAINER_NAME}$"
    check_api && echo "health: OK" ;;
  logs) need docker; check_container owner; docker logs --tail 100 "$CONTAINER_NAME" ;;
  stop)
    need docker
    if container_exists; then check_container owner; docker rm -f "$CONTAINER_NAME"; else echo "Container not present: $CONTAINER_NAME"; fi ;;
esac
