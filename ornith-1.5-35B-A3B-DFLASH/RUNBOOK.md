# Agent runbook: Ornith NVFP4 + DFlash on one DGX Spark

Run these steps **on the target DGX Spark**. The script is self-contained; do not use a site-specific inference dispatcher, model directory, or service manager. Your completion condition is an HTTP 200 response from `http://127.0.0.1:<PORT>/health` and `READY` from `./start.sh`.

## 1. Inspect the host and choose locations

From this recipe directory, check `uname -m` (expect `aarch64` for DGX Spark), `nvidia-smi -L`, `docker info`, `docker info --format '{{json .Runtimes}}'`, `python3 --version`, `python3 -m venv --help`, `df -h`, and `free -h`. Confirm Docker has NVIDIA GPU support and that the chosen disk has room for roughly 24 GB of target weights, the draft, the Docker image, and download overhead. Check whether port 8000 is free using `ss -ltn` and `docker ps --format '{{.Names}} {{.Ports}}'`. Do not stop unrelated containers to claim the port; select another `PORT` if needed.

Copy `.env.example` to `.env`. Edit `DOWNLOAD_ROOT`, `MODEL_DIR`, `DRAFT_DIR`, `PORT`, and `HOST` as needed. Keep the default model and image settings unless the host requires a documented change. If both checkpoints are already present, point the two paths at them and set `AUTO_DOWNLOAD=0`. The draft is a **separate** repository from the target. If authentication is needed, export `HF_TOKEN` in the current shell; do not put it in `.env` or a transcript.

## 2. Review the plan without changing the host

```bash
./start.sh --dry-run
```

Read the rendered target and draft paths, Hub repository names, image tag, Docker mounts, bind address, port, and `--speculative-config`. The dry run has no download or Docker side effects. Resolve any wrong path or port in `.env` and rerun dry run. This step is also the safe way to inspect a proposed `download`, `stop`, or `status` action: `./start.sh <action> --dry-run`.

## 3. Download and launch

```bash
./start.sh
```

The script installs a private Hugging Face downloader environment, downloads both checkpoints, verifies files, pulls the pinned image, starts vLLM, and polls `/health` for up to `STARTUP_TIMEOUT` seconds (default 900). It exits nonzero and prints recent container logs if the container dies or the deadline expires. Downloads are resumable: rerun the command after a network interruption. If the image pull or boot fails, check `./start.sh logs`, available RAM, disk space, and the Docker/NVIDIA setup before changing settings.

The default serving configuration matches the observed working single-GB10 setup: `vllm/vllm-openai:v0.27.1`, target NVFP4, DFlash 8 tokens, GPU memory utilization 0.42, context 100000, FP8 KV, FlashInfer, reasoning parser `qwen3`, tool parser `qwen3_coder`, and served name `ornith-1.5-35b-a3b`.

## 4. Verify and report

```bash
./start.sh health
./start.sh status
curl -fsS http://127.0.0.1:8000/v1/models
```

Substitute the configured port. If `HOST` is a specific local address, use that address for the curl request. If `HOST=0.0.0.0`, use `127.0.0.1` for local checks. Confirm `/v1/models` includes `SERVED_MODEL_NAME`. Report the health result, model ID, bind address, and paths used. A healthy endpoint proves the server finished loading; a full request can be added if the user asks for functional output validation.

If you change `.env` after creating the container, run `./start.sh stop --dry-run` to review which container is targeted, then `./start.sh stop` and `./start.sh` to recreate it. The stop command does not delete downloaded weights. Do not run the real start on a host with an unrelated service occupying the chosen port.
