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
| `curl`, `bash`, `python3`, `awk`, `make` | Install + config generation | System package manager |
| `zstd` (Linux only) | Ollama's own installer needs it | `apt-get install -y zstd` |
| **Ollama ≥ 0.30.5** | Older runtimes **cannot load gemma4** | See below |
| ~13 GB free disk | 7.6 GB model + headroom | `ollama rm <unused-model>` |
| ~12 GB RAM | Model weights + 32K context | Use a smaller model (below) |
| **A GPU** (or Apple Silicon) | A 12B model on CPU is ~5x slower and unreliable | See [CPU-only hosts](#cpu-only-hosts) |
| Network access on first run | Downloads binary + model | See [Restricted networks](#restricted-networks) |

Installing Ollama:

```bash
# macOS
brew install ollama && brew services start ollama

# Linux — install zstd first, the Ollama installer requires it and stops without it
sudo apt-get install -y zstd                # dnf install zstd / pacman -S zstd
curl -fsSL https://ollama.com/install.sh | sh && sudo systemctl start ollama
```

A minimal Linux image (a slim container, a fresh VM) will not have `zstd`, and
the installer fails with `ERROR: This version requires zstd for extraction`
rather than anything about Ollama. Verified on `debian:12-slim`.

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

This writes a temp file, asks the model to **edit** it, and then reads the file
back off disk to decide whether it passed. It deliberately does not grade the
model's reply — a local model will report an edit it never made, so grading the
reply passes in exactly the case that matters. Expect:
`ok gemma4 edited the file correctly through Grok's tools (Ns)`.

If it took more than ~7 minutes the test also warns that the host is too slow to
work on comfortably. See [CPU-only hosts](#cpu-only-hosts).

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

## CPU-only hosts

A plain VM with no GPU — which many managed and compliance-controlled
environments are — will run this, but slowly. Measured on the same one-line
editing task, 10 CPU cores, no GPU:

| Host | Model | Time |
|---|---|---|
| Apple M4, GPU | gemma4:12b | ~200 s |
| Apple M4, GPU | qwen3:8b | ~152 s |
| 10-core CPU | gemma4:12b | 640–900 s |

Roughly 1–6 tokens/sec, and it compounds: every turn of a multi-step task pays
it again.

**The thing that actually breaks on CPU is a timeout, not the model.** Grok
abandons a turn after 600 s without receiving a chunk, which assumes cloud
latency. On a CPU host that elapses during prompt processing, before the model
has emitted anything, and the turn dies with:

```
Internal error: "inference idle timeout after 600s with no chunks"
```

On a CPU-only box this hit every single turn, including the one inside
`make bootstrap`, which failed. A *smaller* model did not help — what matters is
the length of the silence, not the tokens per second.

The generated config therefore sets `inference_idle_timeout_secs = 1800` on
every model. Raise it further on a very slow host:

```bash
GROK_OLLAMA_IDLE_TIMEOUT=3600 make ollama
```

With that in place a CPU host works — slowly. To make it lighter, change the
model rather than shrinking the one you have; see the table below for which ones
actually work.

One CPU run also reported an edit it had not made — but the same failure has
been seen on GPU, so treat it as the model being unreliable rather than as
something CPU causes. It is why `make ollama-test` checks the file, not the
reply.

## Which models actually work

Advertised tool support is not the same as usable tool support. Every model
below lists `tools` in `ollama show`, yet most of them will not drive the agent.
Measured with `make ollama-test` (edit a file, verified on disk):

| Model | Size | Works? |
|---|---|---|
| `qwen3:8b` | 5.2 GB | **Yes** — 152 s, the best small option |
| `gemma4:12b` | 7.6 GB | **Yes** — 200 s, the default |
| `qwen3:14b` | 9.3 GB | Yes |
| `gemma4:e4b-it-qat` | 6.1 GB | **No** — asks you to paste the file instead of reading it |
| `llama3.2:3b` | 2.0 GB | No |
| `qwen2.5-coder:3b` | 1.9 GB | No |

The failures are not marginal. Asked to edit a file, `gemma4:e4b-it-qat`
replied: *"Could you please provide the current content of opts.toml?"* — it had
a read tool and asked the user to do it instead. That is the same on GPU as on
CPU, so it is the model, not the hardware.

**Roughly 8B is the floor** for driving this agent at all. Below that, models
answer in prose about the edit they would make. If you need something smaller
than `qwen3:8b`, test it before trusting it:

```bash
ollama pull <model> && make ollama-models && ./ollama.sh test ollama-<model-slug>
```

## Choosing a different model

```bash
GROK_OLLAMA_MODEL=gemma4:26b       make ollama   # stronger, needs ~18 GB disk + ~24 GB RAM
GROK_OLLAMA_MODEL=qwen3:8b          make ollama  # lighter (5.2 GB) and faster
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
| `This version requires zstd for extraction` | Ollama's Linux installer — `sudo apt-get install -y zstd`, then re-run it |
| `inference idle timeout after 600s with no chunks` | Host too slow for the default timeout — `GROK_OLLAMA_IDLE_TIMEOUT=3600 make ollama`. See [CPU-only hosts](#cpu-only-hosts) |
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
