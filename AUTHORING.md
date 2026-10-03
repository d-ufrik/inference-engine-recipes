# Authoring a portable inference recipe

Use this process to turn a deployment that already works into a recipe other people can run on their own hardware. Add every finished recipe to **this repository**, in one directory at the repository root. The [Ornith NVFP4 + DFlash kit](ornith-1.5-35B-A3B-DFLASH/README.md) is the reference implementation for the file layout and command interface. Adapt its model flags to the new deployment; do not copy Ornith-specific values blindly.

**Isolation is a hard requirement:** each recipe owns everything it needs inside its own directory. Its scripts must not read, source, import, symlink to, or execute files from another recipe directory or a shared repository helper. Keep each recipe's `.env`, downloader environment, default model directory, logs, caches, container names, and other generated artifacts distinct. Copy and adapt a helper into the new recipe if necessary, so either recipe can be copied out and run by itself. The repository root contains navigation and authoring documentation only; no recipe has a runtime dependency on it.

## 1. Capture the working deployment

Inspect the running deployment without changing it. Record the target checkpoint and revision, any separate draft or adapter checkpoint, inference engine and image version or digest, architecture and GPU count, launch command, environment, Docker mounts, ports, memory settings, health endpoint, and startup time. Use the running process/container configuration and logs as evidence; old plans may describe an earlier launch. Confirm the deployed endpoint actually responds before treating it as a baseline.

Make a small translation table while inspecting:

| Observed on our host | Portable recipe decision |
| --- | --- |
| Model ID, quantization, engine flags, image, parser and speculative settings | Keep as documented defaults when verified and compatible with the stated hardware. |
| Weight or cache path, checkout path, Unix user, hostname, IP, port, container name | Expose as configuration; choose a home-directory or recipe-relative default. |
| Fleet dispatcher, private wrapper, existing service unit | Replace with commands implemented by this recipe's launcher. |
| Extra model files, patches, or private images | Fetch from a distributable source or include the required build steps and licensed files in this repository. |
| Secrets and authentication | Read from the environment or the user's credential store; never commit them. |

State the tested hardware and observation date in the recipe README. Separate verified facts from assumptions and explain any changes made to the working configuration. If a deploy depends on a draft model, document its compatibility with the target and fetch both. If a model has no separate draft, omit draft settings entirely. Multi-node recipes may need more configuration and per-node checks, but use the same user-facing command interface below.

## 2. Create the kit in this repository

Use a descriptive, stable directory name such as `model-quant-engine-topology/`. Keep the kit self-contained:

```text
model-quant-engine-topology/
  .env           # committed, ready-to-run defaults; no secrets
  .gitignore     # downloaded weights, logs, caches, private files
  start.sh       # executable preparation, launch, health, lifecycle commands
  README.md      # quick start, requirements, defaults, configuration
  RUNBOOK.md     # complete procedure for another agent
```

Add a `Dockerfile`, patches, or helper scripts inside **that recipe directory** only when the model needs them. The launcher must run those build or preparation steps; the README must not leave essential manual work for the user. Add an entry linking the kit from the repository [README](README.md). A recipe must still work if its directory is the only part of this repository copied to a DGX Spark.

### Configuration contract

Commit a real `.env` containing complete, usable defaults. `start.sh` loads it directly; a fresh checkout must support `./start.sh --dry-run` and `./start.sh` without copying or filling in a template. Use portable defaults such as `$HOME/models/<recipe-name>` and make the download root and **each** checkpoint's host path independently configurable. Accept absolute paths and document how relative paths resolve. A user with complete local weights must be able to set their paths and disable downloading.

Use clear names for the applicable settings: `DOWNLOAD_ROOT`, `MODEL_REPO`, `MODEL_DIR`, `AUTO_DOWNLOAD`, `IMAGE`, `HOST`, `PORT`, `CONTAINER_NAME`, `SERVED_MODEL_NAME`, and any engine-specific memory/context/parallelism values. Add `DRAFT_REPO` and `DRAFT_DIR` only when a separate draft is required. For a multi-node recipe, expose node addresses, users, model paths, and transport choices. Pin a known-working image or source revision and explain how to change it. Put no tokens, passwords, private host details, or user-specific paths in the committed `.env`; read secrets from the environment or a credential store.

Give `.env` its own section in the recipe README. For **every** setting, show the shipped value, what it controls, and when a user should change it. Say clearly that the defaults need no initial edit. Explain which paths must change for preloaded weights, how `AUTO_DOWNLOAD` affects downloads, whether the API binds to loopback or the network, and which memory values are estimates rather than hard caps. Keep the README and `.env` in sync when defaults change.

**No public recipe may require our `/AI` tree, inference script, hostnames, SSH aliases, private registry, or another site-specific service.** Internal container mount points are fine; the host-side source paths must be configurable. Do not copy fleet-only restart rules or memory assumptions without checking their effect on a clean host.

### Launcher contract

`./start.sh` defaults to `start` and supports `download`, `status`, `health`, `logs`, and `stop`. Every action accepts `--dry-run`. Use the same names even when the engine is not vLLM or Docker; explain any necessary difference in the recipe README.

- `start` performs the work needed on the target machine: check prerequisites, download or verify every required checkpoint, fetch or build the runtime image, launch the engine, and wait for its health endpoint. Exit nonzero on failure, timeout, or a stopped process. A repeat start should not create duplicate services.
- `download` stages all required artifacts without launching. Downloads should resume after interruption, verify expected files, and preserve user-supplied weights.
- `status`, `health`, and `logs` give an operator enough information to diagnose startup. `health` exits nonzero until the real serving endpoint is ready. `stop` targets only this kit's service and does not delete weights.
- `--dry-run` prints resolved paths and the preparation, download, image, launch, and health steps for the chosen action. It must make no downloads, directories, containers, service changes, or network mutations. It must not depend on the target GPU or Docker daemon just to render the plan.

Quote shell paths and arguments. Reject invalid numeric values, missing weights when auto-download is disabled, insufficient resources, and occupied ports before launching. Do not silently stop an unrelated model. Bind to loopback by default unless the recipe's purpose requires network access, and make the bind address configurable. Keep a bounded health wait and print useful logs if it fails.

## 3. Write the two user guides

`README.md` is for the human operator. Include prerequisites, target and optional draft sources, tested hardware, verified serving defaults, storage and RAM expectations, quick start (dry run, real start), all supported actions, the `.env` setting table, how to use existing weights, and links to model or engine sources. Explain any material limitation of the tested deployment.

`RUNBOOK.md` is an executable handoff to another agent. Give it the full sequence: read-only host inspection; disk/GPU/Docker/port checks; editing `.env`; dry run review; launch; repeated `/health` polling until success or timeout; `/v1/models` or the engine's equivalent; and what evidence to report. Include recovery steps for download interruption, image or engine failure, configuration changes, and cleanup. The agent should not need our internal documentation or an undocumented inference script.

## 4. Validate the kit

Run `bash -n` on shell scripts and review the rendered dry run from a fresh checkout with the committed `.env`, then with custom paths and port (including a path containing spaces). Check that dry run leaves no files or containers behind. Test local-weight validation with both a complete and an incomplete checkpoint. Check that the committed `.env` has usable values and no secrets or personal paths, and that credentials, downloaded weights, and caches are ignored by Git. Compare every `.env` key and default with its README table before publishing.

On a suitable target host, perform a real launch using the runbook. Wait until the script reports readiness and `health` returns success, then confirm the served model ID and make a small inference request when the engine supports one. Check logs for the intended quantization, draft/speculation mode, and actual memory footprint. Record what was tested in the recipe README. If a clean launch cannot be run, say so explicitly; a healthy existing deployment validates the extracted settings, not the new launcher end to end. Do not replace an unrelated live service just to test a kit.

## 5. Commit and publish

From the root of **this** repository, review the changed files and stage only the new kit and its index entry. Check the staged diff, then commit and push to the configured remote:

```bash
git status --short --branch
git diff --check
git add README.md model-quant-engine-topology
git diff --cached --check
git diff --cached --stat
git commit -m "Add portable model quant engine recipe"
git push origin main
git status --short --branch
git rev-parse HEAD origin/main
```

Replace the example directory and commit message with the actual recipe. If the repository uses a review branch, push that branch and link its pull request instead of pushing `main`. Verify the remote commit and share the GitHub link. Do not claim publication after only a local commit or a failed push. Keep fleet notes in their own repository; this public repository contains the portable kit and its documentation.
