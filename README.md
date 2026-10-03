# Inference engine recipes

Portable model-serving kits for DGX Spark. Each recipe lives in its own
self-contained directory with its own launcher, ready-to-use `.env`, and agent runbook.
Recipes do not depend on files or runtime artifacts from other recipes.

- [Ornith 1.5 35B A3B NVFP4 + DFlash](ornith-1.5-35B-A3B-DFLASH/README.md) — one GB10, vLLM, separate DFlash draft, configurable model paths, dry run, and `/health` wait.
- [Nemotron 3.5 Lightning 30B A3B UD-Q8_K_XL](nemotron-3.5-lightning-30B-A3B-UD-Q8_K_XL/README.md) — one GB10, native llama-server with MTP speculation and configurable GGUF and engine paths.
- [Gemma 4 E2B it UD-Q8_K_XL](gemma-4-E2B-it-UD-Q8_K_XL/README.md) — one GB10, native llama-server with ngram speculation and configurable GGUF and engine paths.
