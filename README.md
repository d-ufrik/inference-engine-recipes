# Inference engine recipes

Portable model-serving kits for DGX Spark. Each recipe lives in its own
self-contained directory with its own launcher, ready-to-use `.env`, and agent runbook.
Recipes do not depend on files or runtime artifacts from other recipes.

To turn a working deployment into a new kit, follow the [recipe authoring methodology](AUTHORING.md).

- [Ornith 1.5 35B A3B NVFP4 + DFlash](ornith-1.5-35B-A3B-DFLASH/README.md) — one GB10, vLLM, separate DFlash draft, configurable model paths, dry run, and `/health` wait.
