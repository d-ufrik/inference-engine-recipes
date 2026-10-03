# Ornith 1.5 35B A3B NVFP4 + DFlash on one DGX Spark

This recipe downloads the [NVFP4 target](https://huggingface.co/ornith-ai/Ornith-1.5-35B-A3B-NVFP4) and [DFlash draft](https://huggingface.co/ornith-ai/Ornith-1.5-35B-A3B-DFlash), pulls a vLLM image, starts an OpenAI-compatible server, and waits until `/health` responds. Run it **on the DGX Spark** with Docker, the NVIDIA container runtime, Python 3 with `venv`, and enough free disk for both checkpoints and the image. The included [.env](.env) has usable defaults; no fleet dispatcher or fixed `/AI` path is used.

The defaults match a working single-GB10 deployment observed on 2026-10-03: `vllm/vllm-openai:v0.27.1`, target NVFP4, DFlash draft, tensor parallelism 1, FP8 KV, 100,000-token context, GPU memory utilization `0.42`, and 8 speculative tokens. The target is a mixed-precision checkpoint: its experts use NVFP4 while attention and KV use FP8. On GB10, `gpu-memory-utilization` is a vLLM reservation target, not a hard whole-system RAM limit. Leave memory headroom for other workloads.

## Quick start

```bash
./start.sh --dry-run
./start.sh
```

You do not need to create or fill in a config file for the default setup. Read the `.env` section below if you want a different disk, already downloaded weights, or another port. The first real start creates a Python virtual environment under `DOWNLOAD_ROOT`, installs `huggingface_hub` into it, downloads both repositories to `MODEL_DIR` and `DRAFT_DIR`, pulls the image, and starts the server. Re-running `./start.sh` resumes incomplete downloads. When the container is already running, it waits for that container's health endpoint instead of creating another one. The default binds the API to `127.0.0.1:8000`; set `HOST=0.0.0.0` in `.env` to expose it on the network. Protect a public endpoint with your own network controls.

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

The committed [.env](.env) is ready to use as shipped. It is sourced as shell code; edit only values you intend to change and quote paths containing spaces. `MODEL_DIR`, `DRAFT_DIR`, and `HF_VENV` can be placed on separate disks. Relative paths resolve from this recipe directory. Model and draft paths are mounted read-only at `/models/target` and `/models/draft` inside the container.

| Setting | Shipped value | Change it when |
| --- | --- | --- |
| `DOWNLOAD_ROOT` | `$HOME/models/ornith-1.5-35b-a3b-dflash` | You want downloads on another disk. Its default child paths below follow this value. |
| `MODEL_DIR` | `$DOWNLOAD_ROOT/Ornith-1.5-35B-A3B-NVFP4` | You already have the target weights or want them elsewhere. |
| `DRAFT_DIR` | `$DOWNLOAD_ROOT/Ornith-1.5-35B-A3B-DFlash` | You already have the separate DFlash weights or want them elsewhere. |
| `HF_VENV` | `$DOWNLOAD_ROOT/.hf-venv` | You want the downloader's private Python environment elsewhere. |
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

For existing weights, edit `MODEL_DIR` and `DRAFT_DIR`, then set `AUTO_DOWNLOAD=0`. The script checks that each has `config.json` and all safetensors files named by its index (or at least one safetensors file without an index). A fresh target download is about 23.5 GB; check disk space before starting. Export `HF_TOKEN` in your shell if authentication is required; **never put it or other secrets in this tracked `.env`**. Review `git diff -- .env` before committing changes.

If you change `.env` after creating the container, stop and restart it to apply the new settings. Stopping removes only this recipe's named container; weights remain on disk.

For an agent-operated installation, follow [RUNBOOK.md](RUNBOOK.md). The draft model's [card](https://huggingface.co/ornith-ai/Ornith-1.5-35B-A3B-DFlash) describes DFlash and its 8-token vLLM configuration.
