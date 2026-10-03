# Ornith 1.5 35B A3B NVFP4 + DFlash on one DGX Spark

This recipe downloads the [NVFP4 target](https://huggingface.co/ornith-ai/Ornith-1.5-35B-A3B-NVFP4) and [DFlash draft](https://huggingface.co/ornith-ai/Ornith-1.5-35B-A3B-DFlash), pulls a vLLM image, starts an OpenAI-compatible server, and waits until `/health` responds. Run it **on the DGX Spark** with Docker, the NVIDIA container runtime, Python 3 with `venv`, and enough free disk for both checkpoints and the image. No fleet dispatcher or fixed `/AI` path is used.

The defaults match a working single-GB10 deployment observed on 2026-10-03: `vllm/vllm-openai:v0.27.1`, target NVFP4, DFlash draft, tensor parallelism 1, FP8 KV, 100,000-token context, GPU memory utilization `0.42`, and 8 speculative tokens. The target is a mixed-precision checkpoint: its experts use NVFP4 while attention and KV use FP8. On GB10, `gpu-memory-utilization` is a vLLM reservation target, not a hard whole-system RAM limit. Leave memory headroom for other workloads.

## Quick start

```bash
cp .env.example .env
# Edit .env if your download location or port differs.
./start.sh --dry-run
./start.sh
```

The first real start creates a Python virtual environment under `DOWNLOAD_ROOT`, installs `huggingface_hub` into it, downloads both repositories to `MODEL_DIR` and `DRAFT_DIR`, pulls the image, and starts the server. Re-running `./start.sh` resumes incomplete downloads. When the container is already running, it waits for that container's health endpoint instead of creating another one. The default binds the API to `127.0.0.1:8000`; set `HOST=0.0.0.0` in `.env` to expose it on the network. Protect a public endpoint with your own network controls.

```bash
./start.sh download            # stage weights without launching
./start.sh status              # inspect container and health
./start.sh health              # require HTTP 200 from /health
./start.sh logs                # last 100 container log lines
./start.sh stop                # remove this recipe's container
./start.sh stop --dry-run      # show the stop command
```

Every action accepts `--dry-run`. Dry run prints the download, image pull, container launch, and health-wait steps without creating files, downloading, pulling, or changing containers. It does not prove that the model will boot; use a real start and wait for `READY`.

## Paths and configuration

Edit `.env` after copying `.env.example`. It is sourced as shell code, so keep it private and only use trusted content. `DOWNLOAD_ROOT` defaults to `$HOME/models/ornith-1.5-35b-a3b-dflash`. `MODEL_DIR` and `DRAFT_DIR` may point anywhere on the host, including separate disks; relative paths are resolved from this recipe directory. Both are mounted read-only at `/models/target` and `/models/draft` inside the container. `HF_VENV` can move the downloader environment to another path.

For checkpoints you already have, set `MODEL_DIR`, `DRAFT_DIR`, and `AUTO_DOWNLOAD=0`. The script checks that each has `config.json` and all safetensors files named by its index (or at least one safetensors file without an index). `MODEL_REPO` and `DRAFT_REPO` can be changed to a compatible fork. Export `HF_TOKEN` in your shell if Hugging Face requires authentication. A downloaded target is about 23.5 GB; check disk space before starting.

The other useful settings are `IMAGE`, `PORT`, `HOST`, `CONTAINER_NAME`, `SERVED_MODEL_NAME`, `GPU_MEMORY_UTILIZATION`, `MAX_MODEL_LEN`, `MAX_NUM_SEQS`, `MAX_NUM_BATCHED_TOKENS`, `SPECULATIVE_TOKENS`, `STARTUP_TIMEOUT`, and `MIN_AVAILABLE_GIB`. The default RAM preflight is 55 GiB available. If the container exists with old settings, stop it first and then start it to apply changed settings. Stopping removes only this recipe's named container; weights remain on disk.

For an agent-operated installation, follow [RUNBOOK.md](RUNBOOK.md). The draft model's [card](https://huggingface.co/ornith-ai/Ornith-1.5-35B-A3B-DFlash) describes DFlash and its 8-token vLLM configuration.
