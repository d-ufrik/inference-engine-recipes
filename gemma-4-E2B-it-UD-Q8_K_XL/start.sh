#!/usr/bin/env bash
# Standalone llama-server recipe. All runtime files belong to this recipe.
set -Eeuo pipefail

RECIPE_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
cd "$RECIPE_DIR"
RECIPE_ID=gemma-4-e2b-it-ud-q8-k-xl
ACTION=start
DRY_RUN=0
ACTION_SET=0
for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY_RUN=1 ;;
    start|download|status|health|logs|stop)
      (( ACTION_SET == 0 )) || { echo "Only one action is allowed" >&2; exit 2; }
      ACTION="$arg"; ACTION_SET=1 ;;
    --help|-h) echo "Usage: ./start.sh [start|download|status|health|logs|stop] [--dry-run]"; exit 0 ;;
    *) echo "Unknown argument: $arg" >&2; exit 2 ;;
  esac
done
[[ -f .env ]] || { echo "Missing $RECIPE_DIR/.env" >&2; exit 1; }
# shellcheck disable=SC1091
source .env

HF_HUB_CACHE="${HF_HUB_CACHE:-${HF_HOME:-${XDG_CACHE_HOME:-$HOME/.cache}/huggingface}/hub}"
HF_VENV="${HF_VENV:-${XDG_CACHE_HOME:-$HOME/.cache}/$RECIPE_ID/hf-venv}"
MODEL_PATH="${MODEL_PATH:-auto}"
AUTO_DOWNLOAD="${AUTO_DOWNLOAD:-1}"
ENGINE_DIR="${ENGINE_DIR:-${XDG_CACHE_HOME:-$HOME/.cache}/$RECIPE_ID/engine}"
LLAMA_SERVER="${LLAMA_SERVER:-auto}"
STATE_DIR="${STATE_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/$RECIPE_ID}"
HOST="${HOST:-127.0.0.1}"
PORT="${PORT:-8002}"
SERVED_MODEL_NAME="${SERVED_MODEL_NAME:-gemma4-e2b-it}"
STARTUP_TIMEOUT="${STARTUP_TIMEOUT:-600}"

absolute_path() { case "$1" in /*) printf '%s' "$1" ;; *) printf '%s/%s' "$RECIPE_DIR" "$1" ;; esac; }
HF_HUB_CACHE="$(absolute_path "$HF_HUB_CACHE")"
HF_VENV="$(absolute_path "$HF_VENV")"
ENGINE_DIR="$(absolute_path "$ENGINE_DIR")"
STATE_DIR="$(absolute_path "$STATE_DIR")"
if [[ "$MODEL_PATH" != auto ]]; then MODEL_PATH="$(absolute_path "$MODEL_PATH")"; fi
if [[ "$LLAMA_SERVER" != auto ]]; then LLAMA_SERVER="$(absolute_path "$LLAMA_SERVER")"; fi

error() { echo "ERROR: $*" >&2; exit 1; }
need() { command -v "$1" >/dev/null || error "Missing required command: $1"; }
show_cmd() { printf ' +'; printf ' %q' "$@"; printf '\n'; }

validate_config() {
  need python3
  [[ "$AUTO_DOWNLOAD" == 0 || "$AUTO_DOWNLOAD" == 1 ]] || error "AUTO_DOWNLOAD must be 0 or 1"
  [[ "$MODEL_REPO" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || error "Invalid MODEL_REPO"
  [[ "$MODEL_FILE" =~ ^[A-Za-z0-9_.-]+\.gguf$ ]] || error "Invalid MODEL_FILE"
  [[ -n "$SERVED_MODEL_NAME" ]] || error "SERVED_MODEL_NAME is empty"
  local name value
  for name in PORT STARTUP_TIMEOUT MIN_AVAILABLE_GIB MIN_FREE_MODEL_GIB MIN_FREE_ENGINE_GIB CTX_SIZE PARALLEL N_GPU_LAYERS TOP_K REPEAT_LAST_N; do
    value="${!name}"
    [[ "$value" =~ ^[1-9][0-9]*$ ]] || error "$name must be a positive integer"
  done
  [[ "$EXPECTED_MODEL_BYTES" =~ ^[0-9]+$ ]] || error "EXPECTED_MODEL_BYTES must be a nonnegative integer"
  (( PORT <= 65535 )) || error "PORT must be <= 65535"
  [[ "$ENGINE_SHA256" =~ ^[a-f0-9]{64}$ && "$CUDART_SHA256" =~ ^[a-f0-9]{64}$ ]] || error "Engine SHA-256 checksums are invalid"
  [[ "$ENGINE_URL" == https://* && "$CUDART_URL" == https://* ]] || error "Engine URLs must use HTTPS"
  for value in "$HF_HUB_CACHE" "$HF_VENV" "$ENGINE_DIR" "$STATE_DIR" "$MODEL_PATH" "$LLAMA_SERVER"; do
    [[ "$value" != *$'\n'* && "$value" != *:* ]] || error "Path contains a newline or colon: $value"
  done
  python3 - "$HOST" "$TEMP" "$TOP_P" "$REPEAT_PENALTY" <<'PY'
import ipaddress, sys
from decimal import Decimal, InvalidOperation
try:
    ipaddress.IPv4Address(sys.argv[1])
    temp, top_p, penalty = (Decimal(x) for x in sys.argv[2:])
    assert 0 <= temp <= 2 and 0 < top_p <= 1 and 0 < penalty <= 2
except (ValueError, InvalidOperation, AssertionError):
    sys.exit("Invalid HOST, TEMP, TOP_P, or REPEAT_PENALTY")
PY
}
validate_config

HEALTH_HOST="$HOST"
[[ "$HOST" != 0.0.0.0 ]] || HEALTH_HOST=127.0.0.1
HEALTH_URL="http://$HEALTH_HOST:$PORT/health"
MODELS_URL="http://$HEALTH_HOST:$PORT/v1/models"
PID_FILE="$STATE_DIR/server.pid"
HASH_FILE="$STATE_DIR/config.sha256"
IDENTITY_FILE="$STATE_DIR/process.json"
LOG_FILE="$STATE_DIR/server.log"
CONFIG_HASH="$(python3 - "$MODEL_REPO" "$MODEL_FILE" "$MODEL_PATH" "$EXPECTED_MODEL_BYTES" "$LLAMA_SERVER" "$ENGINE_SHA256" "$HOST" "$PORT" "$SERVED_MODEL_NAME" "$CTX_SIZE" "$PARALLEL" "$N_GPU_LAYERS" "$TOP_K" "$REPEAT_LAST_N" "$TEMP" "$TOP_P" "$REPEAT_PENALTY" <<'PY'
import hashlib, json, sys
print(hashlib.sha256(json.dumps(sys.argv[1:], separators=(',', ':')).encode()).hexdigest())
PY
)"

check_disk() {
  python3 - "$1" "$2" "$3" <<'PY'
from pathlib import Path
from shutil import disk_usage
import sys
path = Path(sys.argv[1])
while not path.exists():
    if path == path.parent:
        sys.exit(f"Could not find filesystem for {sys.argv[3]}")
    path = path.parent
free = disk_usage(path).free
if free < int(sys.argv[2]) * 1024**3:
    sys.exit(f"Need {sys.argv[2]} GiB free for {sys.argv[3]} at {path}; found {free / 1024**3:.1f} GiB")
PY
}

check_host() {
  need curl; need sha256sum; need tar
  [[ "$(uname -m)" == aarch64 ]] || error "This recipe targets Linux aarch64 DGX Spark"
}

check_runtime_resources() {
  need nvidia-smi
  [[ -n "$(nvidia-smi -L)" ]] || error "No NVIDIA GPU detected"
  local available
  available="$(awk '/^MemAvailable:/ {print $2}' /proc/meminfo)"
  [[ "$available" =~ ^[0-9]+$ ]] || error "Cannot read MemAvailable"
  (( available >= MIN_AVAILABLE_GIB * 1024 * 1024 )) || error "Need $MIN_AVAILABLE_GIB GiB available RAM; found $((available / 1024 / 1024)) GiB"
}

check_port() {
  python3 - "$HOST" "$PORT" <<'PY'
import socket, sys
with socket.socket() as sock:
    try:
        sock.bind((sys.argv[1], int(sys.argv[2])))
    except OSError as exc:
        sys.exit(f"Configured address/port is unavailable: {exc}")
PY
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

resolve_model() {
  local interpreter=python3
  local -a args=(--repo "$MODEL_REPO" --filename "$MODEL_FILE" --cache "$HF_HUB_CACHE" --local "$MODEL_PATH" --expected-bytes "$EXPECTED_MODEL_BYTES")
  if [[ "$MODEL_PATH" == auto && "$AUTO_DOWNLOAD" == 1 ]]; then
    if ! python3 weights.py "${args[@]}" >/dev/null 2>&1; then check_disk "$HF_HUB_CACHE" "$MIN_FREE_MODEL_GIB" "model download"; fi
    hub_python
    interpreter="$HF_VENV/bin/python"
    args+=(--download)
  fi
  MODEL_FILE_PATH="$($interpreter "$RECIPE_DIR/weights.py" "${args[@]}")" || error "Model download or validation failed"
  echo "Model: $MODEL_FILE_PATH"
}

download_archive() {
  local url="$1" hash="$2" path="$3"
  if [[ -f "$path" ]] && echo "$hash  $path" | sha256sum -c - >/dev/null 2>&1; then return; fi
  if [[ -f "$path.partial" ]] && echo "$hash  $path.partial" | sha256sum -c - >/dev/null 2>&1; then
    mv "$path.partial" "$path"
    return
  fi
  if ! curl --fail --location --retry 5 --retry-all-errors --continue-at - --output "$path.partial" "$url"; then
    rm -f "$path.partial"
    curl --fail --location --retry 5 --retry-all-errors --output "$path.partial" "$url" || error "Download failed: $url"
  fi
  echo "$hash  $path.partial" | sha256sum -c - >/dev/null || error "Checksum mismatch: $path.partial"
  mv "$path.partial" "$path"
}

find_engine() { find "$ENGINE_DIR/release" \( -type f -o -type l \) -name llama-server -print -quit 2>/dev/null; }

resolve_engine() {
  if [[ "$LLAMA_SERVER" != auto ]]; then
    [[ -x "$LLAMA_SERVER" ]] || error "LLAMA_SERVER is not executable: $LLAMA_SERVER"
    ENGINE_BIN="$LLAMA_SERVER"
    ENGINE_LIB_PATH="${LD_LIBRARY_PATH:-}"
    return
  fi
  ENGINE_BIN="$(find_engine)"
  if [[ -z "$ENGINE_BIN" ]]; then
    [[ ! -e "$ENGINE_DIR/release" ]] || error "Incomplete engine directory: $ENGINE_DIR/release; choose a new ENGINE_DIR"
    check_disk "$ENGINE_DIR" "$MIN_FREE_ENGINE_GIB" "llama-server release"
    mkdir -p "$ENGINE_DIR"
    local engine_archive="$ENGINE_DIR/${ENGINE_URL##*/}"
    local cudart_archive="$ENGINE_DIR/${CUDART_URL##*/}"
    download_archive "$ENGINE_URL" "$ENGINE_SHA256" "$engine_archive"
    download_archive "$CUDART_URL" "$CUDART_SHA256" "$cudart_archive"
    local stage
    stage="$(mktemp -d "$ENGINE_DIR/.extract.XXXXXX")"
    tar -xzf "$engine_archive" -C "$stage" || error "Engine archive extraction failed"
    tar -xzf "$cudart_archive" -C "$stage" || error "CUDA runtime archive extraction failed"
    [[ -n "$(find "$stage" \( -type f -o -type l \) -name llama-server -print -quit)" ]] || error "Downloaded release has no llama-server"
    mv "$stage" "$ENGINE_DIR/release"
    ENGINE_BIN="$(find_engine)"
  fi
  [[ -x "$ENGINE_BIN" ]] || error "Downloaded llama-server is not executable: $ENGINE_BIN"
  ENGINE_LIB_PATH="$(python3 - "$ENGINE_DIR/release" <<'PY'
import os, sys
paths = []
for root, _, files in os.walk(sys.argv[1]):
    if any('.so' in name for name in files):
        paths.append(root)
print(':'.join(paths))
PY
)"
  ENGINE_LIB_PATH="${ENGINE_LIB_PATH}${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
}

check_engine_flags() {
  local help_text
  help_text="$(LD_LIBRARY_PATH="$ENGINE_LIB_PATH" "$ENGINE_BIN" --help 2>&1)" || error "llama-server cannot run; inspect its libraries and CUDA compatibility"
  local flag
  for flag in --spec-default --spec-type --ctx-size --parallel --n-gpu-layers --jinja --metrics --fit --cache-type-k --cache-type-v --top-k --repeat-penalty --repeat-last-n; do
    [[ "$help_text" == *"$flag"* ]] || error "llama-server lacks required flag $flag; use a compatible release"
  done
}

server_args() {
  SERVER_ARGS=(-m "$MODEL_FILE_PATH" --alias "$SERVED_MODEL_NAME" --host "$HOST" --port "$PORT"
    --spec-default --spec-type ngram-simple
    --ctx-size "$CTX_SIZE" --parallel "$PARALLEL" --n-gpu-layers "$N_GPU_LAYERS"
    -fa on --jinja --metrics --cache-type-k q8_0 --cache-type-v q8_0
    --fit off --temp "$TEMP" --top-p "$TOP_P" --top-k "$TOP_K"
    --repeat-penalty "$REPEAT_PENALTY" --repeat-last-n "$REPEAT_LAST_N")
}

owned_process() {
  [[ -f "$PID_FILE" && -f "$IDENTITY_FILE" ]] || return 1
  local pid
  pid="$(cat "$PID_FILE")"
  [[ "$pid" =~ ^[1-9][0-9]*$ ]] || return 1
  python3 - "$pid" "$IDENTITY_FILE" "$SERVED_MODEL_NAME" "$PORT" <<'PY'
import json
from pathlib import Path
import sys
pid, identity_file, alias, port = sys.argv[1:]
try:
    identity = json.loads(Path(identity_file).read_text())
    words = Path(f'/proc/{pid}/cmdline').read_bytes().split(b'\0')
    words = [word.decode() for word in words if word]
    same_engine = Path(f'/proc/{pid}/exe').samefile(identity['engine'])
except (OSError, UnicodeDecodeError, ValueError, KeyError):
    sys.exit(1)
if not same_engine or not all(x in words for x in ('--alias', alias, '--port', port, '-m', identity['model'])):
    sys.exit(1)
PY
}

check_api() {
  need curl
  owned_process || return 1
  curl --noproxy '*' -fsS --max-time 5 -o /dev/null "$HEALTH_URL" || return 1
  curl --noproxy '*' -fsS --max-time 5 "$MODELS_URL" | python3 -c 'import json,sys; data=json.load(sys.stdin)["data"]; assert any(item.get("id")==sys.argv[1] for item in data)' "$SERVED_MODEL_NAME"
}

wait_ready() {
  local deadline=$((SECONDS + STARTUP_TIMEOUT))
  while (( SECONDS <= deadline )); do
    if ! owned_process; then tail -80 "$LOG_FILE" >&2 || true; error "llama-server stopped before becoming ready"; fi
    if check_api >/dev/null 2>&1; then echo "READY: $HEALTH_URL ($SERVED_MODEL_NAME)"; return; fi
    (( SECONDS < deadline )) || break
    sleep 5
  done
  tail -80 "$LOG_FILE" >&2 || true
  error "Timed out after ${STARTUP_TIMEOUT}s waiting for /health and /v1/models"
}

print_plan() {
  echo " + validate Linux aarch64, GPU, RAM, disk, port, and llama-server flags"
  if [[ "$MODEL_PATH" == auto ]]; then
    show_cmd "${HF_VENV}/bin/python" weights.py --repo "$MODEL_REPO" --filename "$MODEL_FILE" --cache "$HF_HUB_CACHE" --expected-bytes "$EXPECTED_MODEL_BYTES" $([[ "$AUTO_DOWNLOAD" == 1 ]] && echo --download)
  else
    show_cmd python3 weights.py --local "$MODEL_PATH" --filename "$MODEL_FILE" --expected-bytes "$EXPECTED_MODEL_BYTES"
  fi
  if [[ "$LLAMA_SERVER" == auto ]]; then
    echo " + download and SHA-256 verify $ENGINE_URL"
    echo " + download and SHA-256 verify $CUDART_URL"
    echo " + extract llama-server and CUDA libraries under $ENGINE_DIR"
  else echo " + use $LLAMA_SERVER"; fi
  [[ "$ACTION" != download ]] || return
  MODEL_FILE_PATH="$MODEL_PATH"
  [[ "$MODEL_FILE_PATH" != auto ]] || MODEL_FILE_PATH="<resolved-cache-file:$MODEL_FILE>"
  server_args
  show_cmd "${LLAMA_SERVER/auto/<downloaded-llama-server>}" "${SERVER_ARGS[@]}"
  echo " + log and PID under $STATE_DIR"
  echo " + wait up to ${STARTUP_TIMEOUT}s for $HEALTH_URL and $SERVED_MODEL_NAME in /v1/models"
}

if (( DRY_RUN )); then
  case "$ACTION" in
    start|download) print_plan ;;
    status|health) echo " + verify PID and engine/model ownership using $IDENTITY_FILE"; show_cmd curl --noproxy '*' -fsS "$HEALTH_URL"; show_cmd curl --noproxy '*' -fsS "$MODELS_URL" ;;
    logs) show_cmd tail -100 "$LOG_FILE" ;;
    stop) echo " + verify PID ownership and stop only the llama-server recorded in $PID_FILE" ;;
  esac
  exit 0
fi

case "$ACTION" in
  start|download)
    mkdir -p "$STATE_DIR"
    need flock
    exec 9>"$STATE_DIR/lock"
    flock -n 9 || error "Another command for this recipe is running"
    if [[ "$ACTION" == start && -f "$PID_FILE" ]]; then
      if owned_process; then
        [[ "$(cat "$HASH_FILE" 2>/dev/null)" == "$CONFIG_HASH" ]] || error "Running service uses different settings; stop it before restarting"
        wait_ready
        exit 0
      fi
      error "Stale or foreign PID file at $PID_FILE; inspect it before removal"
    fi
    check_host
    if [[ "$ACTION" == start ]]; then check_runtime_resources; check_port; fi
    resolve_model
    resolve_engine
    check_engine_flags
    if [[ "$ACTION" == download ]]; then echo "Artifacts ready"; exit 0; fi
    check_port
    server_args
    nohup env LD_LIBRARY_PATH="$ENGINE_LIB_PATH" "$ENGINE_BIN" "${SERVER_ARGS[@]}" >"$LOG_FILE" 2>&1 </dev/null 9>&- &
    pid=$!
    echo "$pid" >"$PID_FILE"
    echo "$CONFIG_HASH" >"$HASH_FILE"
    python3 - "$ENGINE_BIN" "$MODEL_FILE_PATH" "$IDENTITY_FILE" <<'PY'
import json, sys
from pathlib import Path
Path(sys.argv[3]).write_text(json.dumps({'engine': sys.argv[1], 'model': sys.argv[2]}))
PY
    wait_ready ;;
  health) check_api && echo "OK: $HEALTH_URL ($SERVED_MODEL_NAME)" ;;
  status)
    if owned_process; then echo "running PID $(cat "$PID_FILE")"; check_api && echo "health: OK"
    else echo "not running"; exit 1; fi ;;
  logs) [[ -f "$LOG_FILE" ]] || error "No log file at $LOG_FILE"; tail -100 "$LOG_FILE" ;;
  stop)
    [[ -f "$PID_FILE" ]] || { echo "Service is not running"; exit 0; }
    exec 9>"$STATE_DIR/lock"
    flock -n 9 || error "Another command for this recipe is running"
    owned_process || error "PID file does not identify this recipe's llama-server; leaving process untouched"
    pid="$(cat "$PID_FILE")"
    kill "$pid"
    for _ in {1..30}; do if ! kill -0 "$pid" 2>/dev/null; then break; fi; sleep 1; done
    kill -0 "$pid" 2>/dev/null && error "Server did not stop after SIGTERM; inspect PID $pid"
    rm "$PID_FILE" "$HASH_FILE" "$IDENTITY_FILE"
    echo "Stopped PID $pid" ;;
esac
