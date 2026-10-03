# Ornith 1.5 35B A3B NVFP4 + DFlash on one DGX Spark

This recipe downloads the [NVFP4 target](https://huggingface.co/ornith-ai/Ornith-1.5-35B-A3B-NVFP4) and [DFlash draft](https://huggingface.co/ornith-ai/Ornith-1.5-35B-A3B-DFlash), pulls a vLLM image, starts an OpenAI-compatible server, and waits until `/health` responds. Run it **on the DGX Spark** with Docker, the NVIDIA container runtime, Python 3 with `venv`, and enough free disk for both checkpoints and the image. The included [.env](.env) has usable defaults and configurable paths.

The defaults match a working single-GB10 deployment observed on 2026-10-03: `vllm/vllm-openai:v0.27.1`, target NVFP4, DFlash draft, tensor parallelism 1, FP8 KV, 100,000-token context, GPU memory utilization `0.42`, and 8 speculative tokens. The target is a mixed-precision checkpoint: its experts use NVFP4 while attention and KV use FP8. On GB10, `gpu-memory-utilization` is a vLLM reservation target, not a hard whole-system RAM limit. Leave memory headroom for other workloads.

## Quick start

```bash
./start.sh --dry-run
./start.sh
```

You do not need to create or fill in a config file for the default setup. Read the `.env` section below if you want a different cache, already downloaded weights, or another port. The first real start creates a private Python environment, downloads both repositories into the standard Hugging Face Hub cache, validates the checkpoints, pulls the image, checks GPU access, starts the server, and verifies `/health` and the served model ID. Re-running `./start.sh` resumes incomplete downloads. When the container is already running, it verifies that the container belongs to this recipe and waits for readiness. The default binds the API to `127.0.0.1:8000`; set `HOST=0.0.0.0` in `.env` to expose it on the network. Protect a public endpoint with your own network controls.

```bash
./start.sh download            # stage weights without launching
./start.sh status              # inspect container and health
./start.sh health              # require HTTP 200 from /health
./start.sh logs                # last 100 container log lines
./start.sh stop                # remove this recipe's container
./start.sh stop --dry-run      # show the stop command
```

Every action accepts `--dry-run`. Dry run prints the download, image pull, container launch, and health-wait steps without creating files, downloading, pulling, or changing containers. It does not prove that the model will boot; use a real start and wait for `READY`.

## The included `.env`

The committed [.env](.env) is ready to use as shipped. It is sourced as shell code; edit only values you intend to change and quote paths containing spaces. By default, `MODEL_DIR=auto` and `DRAFT_DIR=auto` resolve the two downloaded snapshots inside `HF_HUB_CACHE` (normally `$HOME/.cache/huggingface/hub`, vLLM's default download location). You can set either path to an existing checkpoint directory on any disk. Relative paths resolve from this recipe directory. The cache or local directories are mounted read-only in the container.

| Setting | Shipped value | Change it when |
| --- | --- | --- |
| `HF_HUB_CACHE` | `${HF_HUB_CACHE:-${HF_HOME:-${XDG_CACHE_HOME:-$HOME/.cache}/huggingface}/hub}` | You want the Hub cache on another disk. Existing `HF_HUB_CACHE`, `HF_HOME`, and `XDG_CACHE_HOME` environment settings are respected. |
| `MODEL_DIR` | `auto` | Set a local target checkpoint path if weights are already present outside the Hub cache. |
| `DRAFT_DIR` | `auto` | Set a local DFlash checkpoint path if weights are already present outside the Hub cache. |
| `HF_VENV` | `${XDG_CACHE_HOME:-$HOME/.cache}/ornith-1.5-35b-a3b-dflash/hf-venv` | You want the private downloader environment elsewhere. |
| `AUTO_DOWNLOAD` | `1` | Set `0` when both checkpoint directories are already complete. |
| `MODEL_REPO` | `ornith-ai/Ornith-1.5-35B-A3B-NVFP4` | You are serving a compatible target fork. |
| `DRAFT_REPO` | `ornith-ai/Ornith-1.5-35B-A3B-DFlash` | You are serving a compatible draft fork. |
| `IMAGE` | `vllm/vllm-openai:v0.27.1` | You have verified another image with this model and DFlash. |
| `CONTAINER_NAME` | `vllm-ornith-1.5-35b-a3b-dflash` | Another container already has this name. |
| `SERVED_MODEL_NAME` | `ornith-1.5-35b-a3b` | Clients need a different API model ID. |
| `HOST` | `127.0.0.1` | Set `0.0.0.0` to accept connections from other machines. |
| `PORT` | `8000` | Port 8000 is busy or clients need another port. |
| `GPU_MEMORY_UTILIZATION` | `0.42` | You have measured different memory headroom. This is a vLLM reservation target, not a whole-system RAM cap. |
| `MAX_MODEL_LEN` | `100000` | You need a different context limit that fits the available KV cache. |
| `MAX_NUM_SEQS` | `8` | You have tested a different concurrent-sequence limit. |
| `MAX_NUM_BATCHED_TOKENS` | `8192` | You have tested another prefill/scheduling budget. |
| `SPECULATIVE_TOKENS` | `8` | You have tested a different DFlash draft block size. |
| `STARTUP_TIMEOUT` | `900` seconds | Model loading takes longer on your host. |
| `MIN_AVAILABLE_GIB` | `55` GiB | You have measured a safe boot threshold for your host. |
| `MIN_FREE_TARGET_GIB` | `30` GiB | The target download needs a different free-space allowance. |
| `MIN_FREE_DRAFT_GIB` | `2` GiB | The draft download needs a different free-space allowance. |
| `MIN_FREE_IMAGE_GIB` | `12` GiB | The Docker image needs a different free-space allowance. |

For existing weights, edit `MODEL_DIR` and `DRAFT_DIR`, then set `AUTO_DOWNLOAD=0`. To use checkpoints already in the Hub cache without contacting the network, keep `auto` and set `AUTO_DOWNLOAD=0`. The script checks `config.json`, the target tokenizer, and the safetensors files and their headers. It checks memory, free disk where downloads are needed, architecture, Docker, GPU visibility, port availability, container ownership, and the served model ID. A fresh target download is about 23.5 GB; check disk space before starting. Export `HF_TOKEN` in your shell if authentication is required; **never put it or other secrets in this tracked `.env`**. Review `git diff -- .env` before committing changes.

If you change `.env` after creating the container, stop and restart it to apply the new settings. Stopping removes only this recipe's named container; weights remain on disk.

For an agent-operated installation, follow [RUNBOOK.md](RUNBOOK.md). The draft model's [card](https://huggingface.co/ornith-ai/Ornith-1.5-35B-A3B-DFlash) describes DFlash and its 8-token vLLM configuration.
