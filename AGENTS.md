# AGENTS.md — setting up Grok Build on a local model

Instructions for an AI agent (or a person) bringing this repo up on a new
machine. Follow it top to bottom. Every command is safe to re-run.

## What you are building

A terminal coding agent — reads a codebase, edits files, runs shell commands —
running against a model **hosted on this machine**. No cloud API, no vendor
account, nothing leaves the host.

Two pieces:

| Piece | Role | Where it comes from |
|---|---|---|
| **Grok Build** (`grok`) | The agent: TUI, tools, sessions, permissions | xAI prebuilt binary, installed into `./.grok/bin/` |
| **Ollama** + **gemma4** | The model behind it | `ollama` daemon on `localhost:11434` |

They connect because Grok speaks OpenAI Chat Completions to any `base_url`, and
Ollama serves exactly that at `/v1`. `ollama.sh` generates the config that
points one at the other.

**End state:** typing `grok` in any project starts an agent driven by local
gemma4.

The `grok` version is pinned in the Makefile (`VERSION ?= 0.2.118`), so this
setup is reproducible — every machine that follows this file installs the same
binary. Do not replace the pin with "latest" to work around a problem; if a
newer build is needed, run `make update`, verify with `make ollama-test`, then
edit the pin and commit it.

## Do this first

```bash
make bootstrap
```

That runs preflight, installs the `grok` binary, pulls the model, wires it up,
and finishes with a real agentic test. If it prints `Ready.`, you are done —
skip to [Verify](#verify).

If preflight fails it stops **before installing anything** and prints the exact
fix for each problem. Apply the fixes, re-run `make bootstrap`.

## Prerequisites

`make bootstrap` checks all of these and tells you what to do. Listed here so
you can prepare the host up front.

| Requirement | Why | If missing |
|---|---|---|
| `curl`, `bash`, `python3`, `awk` | Install + config generation | System package manager |
| **Ollama ≥ 0.30.5** | Older runtimes **cannot load gemma4** | See below |
| ~13 GB free disk | 7.6 GB model + headroom | `ollama rm <unused-model>` |
| ~12 GB RAM | Model weights + 32K context | Use a smaller model (below) |
| Network access on first run | Downloads binary + model | See [Restricted networks](#restricted-networks) |

Installing Ollama:

```bash
# macOS
brew install ollama && brew services start ollama

# Linux
curl -fsSL https://ollama.com/install.sh | sh && sudo systemctl start ollama
```

Upgrading it (the **server** version is what matters, so restart it after):

```bash
brew upgrade ollama && brew services restart ollama          # macOS
curl -fsSL https://ollama.com/install.sh | sh && sudo systemctl restart ollama   # Linux
```

Check the host without installing anything:

```bash
make preflight
```

## Verify

Do not report success without running these. The first two are automated; the
third is the one that actually proves the agent works.

**1. Configuration is in place**

```bash
make ollama-doctor
```

Expect `ollama endpoint: ... (up, vX.Y.Z)`, `managed block: installed`, and the
primary model marked `present`.

**2. The agent loop works end to end**

```bash
make ollama-test
```

This writes a temp file and asks the model to read it **using its tools**.
Expect: `ok gemma4 read the file through Grok's tools and answered correctly`.
This is the check that catches a model which talks but cannot act.

**3. It edits real files**

```bash
mkdir -p /tmp/grokcheck && printf 'def add(a, b):\n    return a - b\n' > /tmp/grokcheck/calc.py
./bin/grok --cwd /tmp/grokcheck -m gemma4 --permission-mode auto --max-turns 12 \
  -p 'calc.py has a bug: add() subtracts instead of adds. Fix it.'
cat /tmp/grokcheck/calc.py    # must now read: return a + b
```

Check the file, not the model's summary. See [Reading the
output](#reading-the-output).

**4. Confirm it is really local**

While a turn is running:

```bash
ollama ps      # expect grok-gemma4-12b-32k loaded, CONTEXT 32768
```

Definitive proof: disconnect from the network and run a turn. It still works.

## Using it

```bash
make run                                  # TUI in the current directory
./bin/grok --cwd ~/some-project           # TUI elsewhere
./bin/grok -p "explain src/main.rs"       # headless, one-shot
```

Inside the TUI: `Ctrl+M` switches model, `Shift+Tab` cycles permission mode,
`Ctrl+P` opens the command palette, `/model gemma4` selects the local model
explicitly.

To use `grok` from anywhere, put the shim on `PATH`:

```bash
ln -s "$(pwd)/bin/grok" ~/.local/bin/grok
```

### Reading the output

**A local model's summary is a claim, not a result.** In testing, gemma4 was
asked to make one change in three places in `ollama.sh`. It got the new function
right, made the other two edits by *overwriting adjacent lines* instead of
inserting — silently deleting a working subcommand — and then reported all three
as done. The file still passed `bash -n`, so nothing flagged it.

Therefore:

- Run `git diff` after every task. Judge the diff, never the summary.
- Use `--permission-mode default` (asks before each edit) on code you care
  about. `--permission-mode auto` is for throwaway directories and tests.
- Keep tasks small. One coordinated change across three sites is at the edge of
  what a 12B model does reliably; three separate small tasks work far better.

This is a limitation of the model, not of the setup. Larger local models do
better; see below.

## Choosing a different model

```bash
GROK_OLLAMA_MODEL=gemma4:26b       make ollama   # stronger, needs ~18 GB disk + ~24 GB RAM
GROK_OLLAMA_MODEL=gemma4:e4b-it-qat make ollama  # lighter, ~6 GB
GROK_OLLAMA_MODEL=qwen3:14b        make ollama   # non-gemma alternative
GROK_OLLAMA_CTX=65536              make ollama   # larger context, more RAM
```

**The model must support tool calling.** Verify before choosing:

```bash
ollama show <model> | grep -A6 Capabilities     # must list: tools
```

`gemma3` does **not** have it and cannot drive this agent. `gemma4` does.

After pulling anything new, refresh the picker:

```bash
make ollama-models
```

## Constraints — do not "fix" these

Two behaviours look like bugs and are not. Both were deliberate, and both
failure modes are silent.

**1. Models without tool calling are rejected and excluded from the config.**
Not conservatism. Grok's agent loop needs tools to edit files or run commands;
without them the model produces conversation and the task quietly does nothing.

**2. `context_window` is set to what Ollama *serves*, not what the model
advertises.** gemma4:12b advertises 262144; the server hands out 32768. Grok
sizes auto-compaction off this number, so raising it to the advertised value
does not gain context — it overflows the window instead of compacting, and the
session degrades mid-task. The primary model pins its context with
`PARAMETER num_ctx` in a derived build (`grok-gemma4-12b-32k`), which shares the
parent's weight blobs and costs no extra disk. To genuinely increase context,
raise `GROK_OLLAMA_CTX` and re-run — do not hand-edit `context_window`.

Related: `ollama create` cannot read a Modelfile from stdin (`-f -` fails
silently-ish with "no Modelfile found"); it needs a real file path.

## What gets written where

| Path | What | Reversible |
|---|---|---|
| `./.grok/bin/` | The `grok` binary (~120 MB, git-ignored) | `make uninstall` |
| `./ollama.toml` | Generated `[model.*]` config, tracked in git | Regenerate anytime |
| `~/.grok/config.toml` | The generated block, between managed markers | `make ollama-uninstall` |
| `~/.ollama/models/` | Model weights | `ollama rm <model>` |

`~/.grok/config.toml` is backed up to `config.toml.pre-ollama.bak` before the
first write, and only the region between the `# >>> grok-ollama` markers is ever
touched.

To keep everything inside the repo and write nothing to `$HOME`:

```bash
GROK_HOME="$(pwd)/.grok/home" make ollama
GROK_HOME="$(pwd)/.grok/home" ./bin/grok
```

## Restricted networks

First run needs outbound access to:

- `x.ai` (falls back automatically to `storage.googleapis.com`) — the binary
- `registry.ollama.ai` / `ollama.com` — the model

After that the setup runs fully offline. If those hosts are blocked, stage both
artifacts on a connected machine and copy them across.

**The grok binary.** Use the pinned version — `grep '^VERSION' Makefile` — so the
offline install matches everyone else's. Download it on the connected machine
from `https://x.ai/cli/grok-<version>-<platform>`, where platform is one of
`macos-aarch64`, `macos-x86_64`, `linux-aarch64`, `linux-x86_64`
(`https://storage.googleapis.com/grok-build-public-artifacts/cli/...` serves the
same files). Then, on the target machine:

```bash
VERSION=0.2.118 PLATFORM=linux-x86_64          # VERSION must match the Makefile pin
mkdir -p .grok/downloads .grok/bin
cp /path/to/grok-$VERSION-$PLATFORM .grok/downloads/grok-$PLATFORM
chmod +x .grok/downloads/grok-$PLATFORM
ln -sf "$PWD/.grok/downloads/grok-$PLATFORM" .grok/bin/grok
ln -sf "$PWD/.grok/downloads/grok-$PLATFORM" .grok/bin/agent
echo "$VERSION" > .grok/version                # matches the pin -> install.sh no-ops
./bin/grok --version                           # confirm it runs
```

If the stamp does not match the Makefile pin, the next `make install` will try
to download the pinned version — which fails on an air-gapped host. Keep the two
in agreement.

**The model.** Ollama has no export command, so copy its store directly. On the
connected machine run the full `make ollama` first — that creates the derived
big-context build as well, so it travels with everything else — then transfer
the blobs and manifests (content-addressed, so this is safe to copy):

```bash
rsync -a ~/.ollama/models/ target-host:~/.ollama/models/
```

On the target, restart Ollama, confirm with `ollama list`, then run the normal
setup. It detects both models are already present and skips every download, so
this works with no network at all:

```bash
make ollama
```

Note that `grok` may attempt to reach xAI for its model catalog and telemetry
even when running locally. To keep it quiet, add to `~/.grok/config.toml`:

```toml
[features]
telemetry = false

[cli]
auto_update = false
```

## Troubleshooting

| Symptom | Cause and fix |
|---|---|
| `requires a newer version of Ollama` | Upgrade Ollama **and restart the server** (see above) |
| `cannot reach Ollama` | `ollama serve`, or `brew services start ollama` / `systemctl start ollama` |
| `does not support tool calling` | Pick a model whose `ollama show` lists `tools` |
| `grok is not installed yet` | `make install` |
| Model answers but never edits files | No tool calling, or `--max-turns` too low |
| Rambles, loops, forgets files | Context exhausted — `GROK_OLLAMA_CTX=65536 make ollama`, or `/compact` |
| Very slow, fans spin up | Spilled to CPU — check `ollama ps` shows `100% GPU`; use a smaller model or context |
| Config changes ignored | Wrong config dir — `make ollama-doctor` prints the one in use (`GROK_HOME` overrides it) |
| Want the setup gone | `make ollama-uninstall` (config) and `make uninstall` (binary) |

Full diagnosis at any time:

```bash
make preflight        # host readiness
make ollama-doctor    # endpoint, config, models
```

## Repo map

```
bootstrap →  make bootstrap    one command, fresh clone to working agent
             install.sh        downloads the grok binary into ./.grok/bin
             ollama.sh         preflight, model pull, config generation, verification
             ollama.toml       generated [model.*] block (tracked)
             bin/grok          launcher shim
             Makefile          all entry points — `make help` lists them
             README.md         human-facing documentation
```
