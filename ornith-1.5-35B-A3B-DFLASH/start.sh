#!/usr/bin/env bash
# Single DGX Spark Ornith NVFP4 + DFlash recipe. Run on the GPU host.
set -Eeuo pipefail

RECIPE_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
cd "$RECIPE_DIR"

DRY_RUN=0
ACTION=start
ACTION_SET=0
for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY_RUN=1 ;;
    start|download|status|health|logs|stop)
      if (( ACTION_SET )); then echo "Only one action may be specified" >&2; exit 2; fi
      ACTION="$arg"; ACTION_SET=1 ;;
    -h|--help)
      echo "Usage: ./start.sh [start|download|status|health|logs|stop] [--dry-run]"
      exit 0 ;;
    *) echo "Unknown argument: $arg" >&2; exit 2 ;;
  esac
done

# The committed .env has ready-to-use defaults; local edits are shell code.
if [[ -f .env ]]; then
  set -a
  # shellcheck disable=SC1091
  source .env
  set +a
fi

DOWNLOAD_ROOT="${DOWNLOAD_ROOT:-$HOME/models/ornith-1.5-35b-a3b-dflash}"
MODEL_DIR="${MODEL_DIR:-$DOWNLOAD_ROOT/Ornith-1.5-35B-A3B-NVFP4}"
DRAFT_DIR="${DRAFT_DIR:-$DOWNLOAD_ROOT/Ornith-1.5-35B-A3B-DFlash}"
AUTO_DOWNLOAD="${AUTO_DOWNLOAD:-1}"
MODEL_REPO="${MODEL_REPO:-ornith-ai/Ornith-1.5-35B-A3B-NVFP4}"
DRAFT_REPO="${DRAFT_REPO:-ornith-ai/Ornith-1.5-35B-A3B-DFlash}"
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

absolute_path() {
  case "$1" in
    /*) printf '%s' "$1" ;;
    *) printf '%s/%s' "$RECIPE_DIR" "$1" ;;
  esac
}
DOWNLOAD_ROOT="$(absolute_path "$DOWNLOAD_ROOT")"
MODEL_DIR="$(absolute_path "$MODEL_DIR")"
DRAFT_DIR="$(absolute_path "$DRAFT_DIR")"
HF_VENV="$(absolute_path "${HF_VENV:-$DOWNLOAD_ROOT/.hf-venv}")"

for numeric in PORT MAX_MODEL_LEN MAX_NUM_SEQS MAX_NUM_BATCHED_TOKENS SPECULATIVE_TOKENS STARTUP_TIMEOUT MIN_AVAILABLE_GIB; do
  value="${!numeric}"
  if ! [[ "$value" =~ ^[0-9]+$ ]] || (( value < 1 )); then
    echo "$numeric must be a positive integer" >&2; exit 2
  fi
done
if (( PORT > 65535 )); then echo "PORT must be <= 65535" >&2; exit 2; fi
if [[ "$AUTO_DOWNLOAD" != 0 && "$AUTO_DOWNLOAD" != 1 ]]; then
  echo "AUTO_DOWNLOAD must be 0 or 1" >&2; exit 2
fi
if ! [[ "$GPU_MEMORY_UTILIZATION" =~ ^0\.[0-9]*[1-9][0-9]*$|^1(\.0+)?$ ]]; then
  echo "GPU_MEMORY_UTILIZATION must be between 0 and 1" >&2; exit 2
fi
if [[ "$MODEL_DIR" == "$DRAFT_DIR" ]]; then
  echo "MODEL_DIR and DRAFT_DIR must be different" >&2; exit 2
fi

show_cmd() { printf ' +'; printf ' %q' "$@"; printf '\n'; }
run_cmd() {
  if (( DRY_RUN )); then show_cmd "$@"; else "$@"; fi
}
need() { command -v "$1" >/dev/null || { echo "Missing required command: $1" >&2; exit 1; }; }
HEALTH_HOST="$HOST"
if [[ "$HEALTH_HOST" == "0.0.0.0" ]]; then HEALTH_HOST=127.0.0.1; fi
health_url="http://$HEALTH_HOST:$PORT/health"

snapshot() {
  local repo="$1" dest="$2"
  if (( DRY_RUN )); then
    show_cmd "$HF_VENV/bin/python" -c 'from huggingface_hub import snapshot_download; import sys; snapshot_download(repo_id=sys.argv[1], local_dir=sys.argv[2])' "$repo" "$dest"
  else
    "$HF_VENV/bin/python" -c 'from huggingface_hub import snapshot_download; import sys; snapshot_download(repo_id=sys.argv[1], local_dir=sys.argv[2])' "$repo" "$dest"
  fi
}

download_weights() {
  if [[ "$AUTO_DOWNLOAD" == 0 ]]; then
    echo "AUTO_DOWNLOAD=0: using existing MODEL_DIR and DRAFT_DIR"
    return
  fi
  if (( DRY_RUN )); then
    show_cmd mkdir -p "$DOWNLOAD_ROOT"
    show_cmd python3 -m venv "$HF_VENV"
    show_cmd "$HF_VENV/bin/python" -m pip install -U huggingface_hub
  else
    need python3
    mkdir -p "$DOWNLOAD_ROOT"
    if [[ ! -x "$HF_VENV/bin/python" ]]; then python3 -m venv "$HF_VENV"; fi
    "$HF_VENV/bin/python" -m pip install -U huggingface_hub
  fi
  snapshot "$MODEL_REPO" "$MODEL_DIR"
  snapshot "$DRAFT_REPO" "$DRAFT_DIR"
}

verify_weights() {
  if (( DRY_RUN )); then
    echo " + verify complete target and draft checkpoints at:"
    echo "   MODEL_DIR=$MODEL_DIR"
    echo "   DRAFT_DIR=$DRAFT_DIR"
    return
  fi
  need python3
  python3 - "$MODEL_DIR" "$DRAFT_DIR" <<'PY'
import json, pathlib, sys
target, draft = map(pathlib.Path, sys.argv[1:])
for label, path in (("target", target), ("draft", draft)):
    if not path.is_dir() or not (path / "config.json").is_file():
        sys.exit(f"Incomplete {label} checkpoint: {path} (missing config.json)")
    index = path / "model.safetensors.index.json"
    if index.is_file():
        names = set(json.loads(index.read_text())["weight_map"].values())
    else:
        names = {p.name for p in path.glob("*.safetensors")}
    if not names or any(not (path / name).is_file() or (path / name).stat().st_size == 0 for name in names):
        sys.exit(f"Incomplete {label} checkpoint: {path} (missing safetensors shard)")
    print(f"{label}: {len(names)} safetensors file(s) present in {path}")
PY
}

container_exists() { docker container inspect "$CONTAINER_NAME" >/dev/null 2>&1; }
container_running() { [[ "$(docker inspect -f '{{.State.Running}}' "$CONTAINER_NAME" 2>/dev/null || true)" == true ]]; }
healthy() { curl -fsS --max-time 5 -o /dev/null "$health_url"; }

wait_ready() {
  local elapsed=0
  while (( elapsed < STARTUP_TIMEOUT )); do
    if healthy; then
      echo "READY: $health_url"
      return 0
    fi
    if ! container_running; then
      echo "Container stopped before /health became ready" >&2
      docker logs --tail 80 "$CONTAINER_NAME" >&2 || true
      return 1
    fi
    sleep 10
    elapsed=$((elapsed + 10))
  done
  echo "Timed out after ${STARTUP_TIMEOUT}s waiting for $health_url" >&2
  docker logs --tail 80 "$CONTAINER_NAME" >&2 || true
  return 1
}

start_server() {
  if (( ! DRY_RUN )); then
    need docker; need curl; need nvidia-smi; need python3
    docker info >/dev/null
    nvidia-smi -L >/dev/null
    if container_exists; then
      if container_running; then
        echo "$CONTAINER_NAME already running; checking /health. Use stop before changing configuration."
        wait_ready
        return
      fi
      echo "Stopped container $CONTAINER_NAME exists. Run ./start.sh stop before recreating it." >&2
      return 1
    fi
    if [[ -n "$(docker ps --filter "publish=$PORT" --format '{{.Names}}')" ]]; then
      echo "Host port $PORT is published by another container" >&2; return 1
    fi
    if command -v ss >/dev/null && ss -ltn "( sport = :$PORT )" | tail -n +2 | grep -q .; then
      echo "Host port $PORT is already listening" >&2; return 1
    fi
    local available_kib
    available_kib="$(awk '/^MemAvailable:/ {print $2}' /proc/meminfo)"
    if (( available_kib < MIN_AVAILABLE_GIB * 1024 * 1024 )); then
      echo "Need at least $MIN_AVAILABLE_GIB GiB MemAvailable before launch" >&2; return 1
    fi
  fi

  download_weights
  verify_weights
  run_cmd docker pull "$IMAGE"

  local spec
  spec="$(python3 -c 'import json,sys; print(json.dumps({"method":"dflash","model":"/models/draft","num_speculative_tokens":int(sys.argv[1])}))' "$SPECULATIVE_TOKENS")"
  local -a docker_args=(
    docker run -d --name "$CONTAINER_NAME" --gpus all --ipc host
    --ulimit memlock=-1 --ulimit stack=67108864 --restart unless-stopped
    --entrypoint vllm -p "$HOST:$PORT:8000"
    -v "$MODEL_DIR:/models/target:ro" -v "$DRAFT_DIR:/models/draft:ro"
    "$IMAGE" serve /models/target
    --served-model-name "$SERVED_MODEL_NAME"
    --trust-remote-code --host 0.0.0.0 --port 8000
    --kv-cache-dtype fp8
    --gpu-memory-utilization "$GPU_MEMORY_UTILIZATION"
    --max-model-len "$MAX_MODEL_LEN"
    --max-num-seqs "$MAX_NUM_SEQS"
    --max-num-batched-tokens "$MAX_NUM_BATCHED_TOKENS"
    --enable-chunked-prefill --async-scheduling --enable-prefix-caching
    --load-format fastsafetensors --attention-backend flashinfer
    --reasoning-parser qwen3 --tool-call-parser qwen3_coder
    --enable-auto-tool-choice --speculative-config "$spec"
  )
  run_cmd "${docker_args[@]}"
  if (( DRY_RUN )); then
    echo " + wait up to ${STARTUP_TIMEOUT}s for $health_url"
  else
    wait_ready
  fi
}

case "$ACTION" in
  start) start_server ;;
  download) download_weights; verify_weights ;;
  health) if (( DRY_RUN )); then show_cmd curl -fsS "$health_url"; else need curl; curl -fsS "$health_url"; fi ;;
  status)
    if (( DRY_RUN )); then show_cmd docker ps -a --filter "name=^/${CONTAINER_NAME}$"; show_cmd curl -fsS "$health_url"
    else need docker; docker ps -a --filter "name=^/${CONTAINER_NAME}$"; if healthy; then echo "health: OK"; else echo "health: unavailable"; fi; fi ;;
  logs) run_cmd docker logs --tail 100 "$CONTAINER_NAME" ;;
  stop)
    if (( DRY_RUN )); then show_cmd docker rm -f "$CONTAINER_NAME"
    else need docker; if container_exists; then docker rm -f "$CONTAINER_NAME"; else echo "Container does not exist: $CONTAINER_NAME"; fi; fi ;;
esac
