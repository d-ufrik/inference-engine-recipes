# Nemotron 3.5 Lightning 30B A3B UD-Q8_K_XL on DGX Spark

This independent recipe downloads the [Unsloth GGUF](https://huggingface.co/unsloth/NVIDIA-Nemotron-3.5-Lightning-30B-A3B-GGUF), fetches the official [llama.cpp b11149 CUDA 13.4 arm64 release](https://github.com/ggml-org/llama.cpp/releases/tag/b11149), starts a native `llama-server`, and waits for `/health` and the model ID in `/v1/models`. Run it on a Linux aarch64 DGX Spark with an NVIDIA GPU, Python 3 with `venv`, `curl`, `tar`, `sha256sum`, and `flock`. No Docker, shared recipe helper, site-specific path, or inference dispatcher is required.

The serving flags match a healthy deployment observed on 2026-10-03 with llama.cpp build 11149: 480,000 context tokens, 4 parallel slots, `draft-mtp` with 2 speculative tokens, Q8 KV, Flash Attention, and `--fit off`. The live service answered `/health` and advertised `nemotron-3.5-lightning-ud-q8`. The portable launcher has been syntax and dry-run checked; a fresh full launch has not been verified because the observed host already runs this large model. Memory needs depend on context and other services.

## Quick start

```bash
./start.sh --dry-run
./start.sh
./start.sh health
```

The shipped [.env](.env) works without an initial edit on a DGX Spark with enough storage and RAM. Defaults bind only to `127.0.0.1:8003`; choose another port if occupied. The first start downloads a 38.6 GB GGUF into the standard Hugging Face Hub cache, downloads and SHA-256 checks the engine and CUDA runtime archives, validates the GGUF, then launches and waits up to 900 seconds. Later starts recognize the recorded process. Files, logs, and PID are scoped to this recipe.

Other commands: `./start.sh download` stages the GGUF and engine; `status` checks process and endpoint; `logs` shows recent output; `stop` terminates only the recorded process. All commands accept `--dry-run`, which prints the plan without downloading or modifying files. The script fails on invalid settings, missing or wrong-size weights, insufficient free space or memory, a busy port, an incompatible binary, a stopped process, or an unhealthy endpoint.

## The included `.env`

The committed [.env](.env) is sourced as shell code. Quote paths containing spaces. Relative paths resolve from this recipe directory. `MODEL_PATH=auto` finds the named GGUF in `HF_HUB_CACHE`, normally `$HOME/.cache/huggingface/hub`. To use an existing file or a directory containing it, set `MODEL_PATH` to that path and `AUTO_DOWNLOAD=0`. Set `LLAMA_SERVER` to a compatible local binary to skip the engine download. Keep `HF_TOKEN` in your shell, never in the tracked `.env`.

| Setting | Shipped value | Purpose or when to change |
| --- | --- | --- |
| `HF_HUB_CACHE` | Existing `HF_HUB_CACHE`, otherwise `${HF_HOME:-${XDG_CACHE_HOME:-$HOME/.cache}/huggingface}/hub` | Model cache location. |
| `HF_VENV` | `${XDG_CACHE_HOME:-$HOME/.cache}/nemotron-3.5-lightning-30b-a3b-ud-q8-k-xl/hf-venv` | Private Hugging Face downloader environment. |
| `MODEL_REPO` | `unsloth/NVIDIA-Nemotron-3.5-Lightning-30B-A3B-GGUF` | Hub model source. |
| `MODEL_FILE` | `NVIDIA-Nemotron-3.5-Lightning-30B-A3B-UD-Q8_K_XL.gguf` | Exact GGUF filename. |
| `MODEL_PATH` | `auto` | Set to an existing GGUF file or containing directory. |
| `EXPECTED_MODEL_BYTES` | `38615380032` | Exact size check; set to `0` only for a verified alternate GGUF. |
| `AUTO_DOWNLOAD` | `1` | Set `0` for an existing local file or a complete cached snapshot. |
| `ENGINE_DIR` | `${XDG_CACHE_HOME:-$HOME/.cache}/nemotron-3.5-lightning-30b-a3b-ud-q8-k-xl/engine` | Per-recipe binary/archive directory. |
| `LLAMA_SERVER` | `auto` | Set to an existing compatible executable to skip engine archives. |
| `ENGINE_URL`, `ENGINE_SHA256` | Official b11149 CUDA 13.4 arm64 binary URL and SHA-256 in `.env` | Change together for another verified build. |
| `CUDART_URL`, `CUDART_SHA256` | Matching b11149 CUDA runtime URL and SHA-256 in `.env` | Change together with the engine. |
| `STATE_DIR` | `${XDG_STATE_HOME:-$HOME/.local/state}/nemotron-3.5-lightning-30b-a3b-ud-q8-k-xl` | PID, config hash, lock, and log directory. |
| `HOST`, `PORT` | `127.0.0.1`, `8003` | Bind address and API port; `0.0.0.0` exposes it to the network. |
| `SERVED_MODEL_NAME` | `nemotron-3.5-lightning-ud-q8` | OpenAI API model ID. |
| `CTX_SIZE`, `PARALLEL`, `N_GPU_LAYERS` | `480000`, `4`, `99` | Context, simultaneous slots, GPU offload. |
| `SPEC_DRAFT_N_MAX` | `2` | Native MTP speculative-token limit; there is no separate draft download. |
| `TEMP`, `TOP_P`, `MIN_P` | `0.6`, `0.95`, `0.01` | Server sampling defaults. |
| `STARTUP_TIMEOUT` | `900` seconds | Maximum wait for health and model ID. |
| `MIN_AVAILABLE_GIB` | `48` GiB | Conservative available-RAM preflight, not a hard server limit. |
| `MIN_FREE_MODEL_GIB`, `MIN_FREE_ENGINE_GIB` | `43`, `3` GiB | Minimum free space before model and engine downloads. |

The default engine archive is a CUDA 13.x build. NVIDIA documents [CUDA 13 minor-version compatibility](https://docs.nvidia.com/cuda/cuda-toolkit-release-notes/index.html) for driver branch 580 or newer, subject to feature limits. The script checks whether the binary starts and supports the required flags; if it cannot, set `LLAMA_SERVER` to a compatible local build. `stop` keeps the weights and downloaded engine. Follow [RUNBOOK.md](RUNBOOK.md) for an agent-operated installation.
