# Grok Build — TUI deployment

A small, self-contained deployment of **[Grok Build](https://github.com/xai-org/grok-build)** (`grok`) — SpaceXAI's terminal AI coding agent. It runs as a full-screen TUI that reads your codebase, edits files, runs shell commands, searches the web, and manages long-running tasks.

This repo is a **wrapper**, not a fork. It downloads xAI's official prebuilt `grok` binary and installs it *inside this folder* (`./.grok/bin/`). It never touches your `$HOME`, your `PATH`, or your shell rc files — so a deployment is reproducible and `make uninstall` removes every trace.

![Grok Build TUI](https://media.x.ai/v1/website/universe-tui-screenshot-6f7a0837.png)

---

## Quick start

```bash
make install      # download + install the grok binary into ./.grok/bin (~120 MB)
make login        # sign in with your xAI account (opens a browser)
make run          # launch the interactive TUI
```

No `make`? The same two steps:

```bash
./install.sh      # install
./bin/grok        # run
```

---

## Requirements

- **macOS** or **Linux**, `x86_64` or `arm64`. (Windows: use xAI's official installer — see [below](#alternative-system-wide-install).)
- `curl` and `bash`.
- An **xAI account** (Grok subscription or API access) to sign in on first run — *or* [Ollama](#local-models-with-ollama) for a fully local setup with no account at all.
- ~150 MB of free disk for the binary.

For the local-model path you also need `python3` (ships with macOS and most Linux distros), a recent **Ollama**, and enough RAM and disk for the model itself — see [Sizing it to your machine](#sizing-it-to-your-machine).

Building from source is **not** needed here — this uses the signed prebuilt binary. (If you ever do want a source build, that's the upstream repo's `cargo build -p xai-grok-pager-bin --release` path.)

---

## Installing

`make install` drops the binary at `./.grok/bin/grok`. It's idempotent — re-run it any time.

The version is **pinned in the Makefile** (`VERSION ?= 0.2.118`) rather than tracking "latest", so a clone made months from now installs the same binary this repo was tested against. If the installed binary has drifted, `make install` puts the pinned one back.

| Command | What it does |
|---|---|
| `make install` | The pinned version |
| `make install VERSION=0.2.107` | A specific version, this once |
| `make update` | The newest build, ignoring the pin |
| `make install CHANNEL=alpha` | Track the faster **alpha** channel |
| `GROK_BIN_DIR=/somewhere ./install.sh` | Install the symlinks elsewhere |

`./install.sh` reads the same pin, so the no-`make` path installs the same build. `GROK_VERSION= ./install.sh` opts out and tracks the channel's latest.

The binary and its download cache live under `./.grok/` (git-ignored). Nothing is written outside this repo.

### Run it from anywhere

`make run` launches grok in *this* repo's directory. To use grok as your everyday agent in **other** projects, either:

```bash
# A) point it at another project without leaving this repo
./bin/grok --cwd ~/code/my-project

# B) put it on your PATH once, then just type `grok` anywhere
ln -s "$(pwd)/bin/grok" ~/.local/bin/grok    # ensure ~/.local/bin is on PATH
cd ~/code/my-project && grok
```

### Alternative: system-wide install

If you'd rather have xAI's installer manage grok globally (adds `~/.grok/bin` to your `PATH` and shell rc), use the official one instead of this wrapper:

```bash
curl -fsSL https://x.ai/cli/install.sh | bash    # macOS / Linux / Git Bash
irm https://x.ai/cli/install.ps1 | iex           # Windows PowerShell
```

---

## Authenticating

Grok needs to know who you are before it can talk to a model.

- **Interactive (default):** `make login` (or just run `grok` and follow the welcome screen). It opens your browser to sign in at grok.com and saves credentials to `~/.grok/auth.json`, refreshed automatically.
- **Headless / remote / SSH:** `./bin/grok login --device-auth` — prints a code to enter on another device.
- **API key (CI, no browser):** export a key instead of signing in:
  ```bash
  export XAI_API_KEY="xai-..."
  ./bin/grok -p "summarize this repo"
  ```
- **Enterprise deployment key:** set `GROK_DEPLOYMENT_KEY` (also unlocks managed config).

Check status any time with `make doctor`.

Prefer to skip the account entirely? See [Local models with Ollama](#local-models-with-ollama) — grok runs fully offline against a model on your own machine.

---

## Local models with Ollama

Grok talks to any OpenAI-compatible endpoint, and [Ollama](https://ollama.com) serves one at `:11434/v1`. That's enough to run the whole agent — file edits, shell commands, todos, sessions — against a model hosted on your own hardware. No xAI account, no API key, nothing leaving the machine.

```bash
make bootstrap    # fresh clone → working local agent (checks the host first)
make run          # …and you're driving a local model
```

`make bootstrap` is the whole path: it preflights the machine, installs the grok binary, pulls the model, wires it up, and verifies. If the host isn't ready it stops **before installing anything** and tells you exactly what to fix. Check readiness alone with `make preflight`.

Already have the binary? `make ollama` does just the model half.

> Setting this up on another machine — or handing it to a coding agent to set up — is covered step by step in **[AGENTS.md](AGENTS.md)**, including verification, restricted networks, and offline installs. Grok itself loads that file as project rules, so the local agent knows how its own setup works.

`make ollama` is idempotent, and it verifies rather than assumes: the last step runs an actual agentic turn (the model must use its tools to read a file and report what's inside) and fails loudly if the model can't.

### What `make ollama` actually does

1. **Pulls the model** — `gemma4:12b` by default (7.6 GB), and refuses to continue if the model lacks **tool calling**. This matters more than it sounds: without tools the model can chat but cannot edit a file or run a command, so the agent loop is dead on arrival. `gemma3`, for instance, has no tool support in Ollama.
2. **Derives a big-context build** — Ollama serves a small default context that Grok's system prompt plus a real conversation blows straight through, and no Grok-side setting can fix that. So the script creates `grok-gemma4-12b-32k` with `num_ctx=32768`. It's a thin layer over the same weights — **no extra disk**.
3. **Generates [`ollama.toml`](ollama.toml)** — one `[model.*]` entry per tool-capable local model, then installs that block into `~/.grok/config.toml` between managed markers. That's what makes plain `grok` in *any* project default to the local model, and it's why the block is fenced: `make ollama-uninstall` removes it cleanly and backs up your original first.

### Choosing a different model

```bash
GROK_OLLAMA_MODEL=qwen3:14b make ollama          # any tool-capable model
GROK_OLLAMA_CTX=65536       make ollama          # bigger context (more RAM)
GROK_OLLAMA_MODEL=gemma4:26b GROK_OLLAMA_ID=big make ollama
```

Every other tool-capable model you have locally is added to the picker too — press `Ctrl+M` in the TUI, or `/model qwen3-14b`. Refresh the list after pulling something new:

```bash
ollama pull qwen3:30b-a3b && make ollama-models
```

| Command | What it does |
|---|---|
| `make ollama` | Pull + wire up + verify (the one you want) |
| `make ollama-models` | Re-scan local models and refresh grok's config |
| `make ollama-test` | Re-run the end-to-end agent test |
| `make ollama-doctor` | Endpoint, config block, and tool-capable model list |
| `make ollama-uninstall` | Unwire it from grok's config (models are kept) |

### Sizing it to your machine

A 12B model at `q4` needs roughly 8 GB of RAM for weights, plus context. `num_ctx=32768` is a deliberate middle ground: enough for genuine multi-file work, small enough to leave room on a 16–32 GB machine. Push `GROK_OLLAMA_CTX` up if you have headroom, down if the model starts swapping.

### What to expect

A local 12B model is not grok-4.5, and it's fair to know that going in. Expect it to handle focused, well-scoped tasks — read these files, make this edit, explain this function — and to struggle with long autonomous multi-step runs where a frontier model would keep its footing. Plan mode (`Shift+Tab`) and smaller asks go a long way. What you get in exchange is an agent that runs on a plane, costs nothing per token, and never sends your code anywhere.

**Read the diffs.** In testing, `gemma4:12b` was asked to make one coordinated change in three places in this repo's own `ollama.sh` (add a subcommand, wire it into the dispatcher, document it). It got the new function exactly right — and made both other edits by *overwriting the adjacent line* rather than inserting, silently deleting an existing subcommand. It then reported all three as done. The script still passed `bash -n`, so nothing announced the breakage.

That's the characteristic local-model failure: not gibberish, but a confident summary that doesn't match the diff. Treat its report as a claim, not a result. `git diff` after every task, prefer `--permission-mode default` (the one that asks) over `auto` on code you care about, and keep changes small enough to eyeball.

**You want a GPU.** The same 12B model on the same one-line editing task: ~200s on an M4's GPU and correct; ~900s on a 10-core CPU with no GPU, where it announced "I have updated the file" and had changed nothing. On CPU the slowness and the wrongness arrive together. If `ollama ps` says `100% CPU`, drop to a ~4B model (`GROK_OLLAMA_MODEL=gemma4:e4b-it-qat make ollama`) — usable for narrow tasks in a way a 12B is not. `make ollama-test` warns you when a run is slow enough to mean this.

Mixing is fine, and often the right call: the local models sit alongside xAI's in the same picker, so `Ctrl+M` switches between offline and frontier mid-session.

---

## Using the TUI

Launch with `make run`, type a request, and press **Enter**. Grok plans, edits files, runs commands (asking approval by default), and streams its work into the scrollback. Give it an initial prompt directly:

```bash
./bin/grok "add tests for the auth module"
./bin/grok -c                       # continue the most recent session here
./bin/grok -w feat "build feature"  # work inside a fresh git worktree named "feat"
```

### Essential keys

Full cheatsheet: press `Ctrl+X` (or `Ctrl+.`) inside grok. The high-value ones:

| Key | Action |
|---|---|
| `Enter` | Send prompt (while a turn runs, **queues** a follow-up) |
| `Ctrl+C` | Cancel the current turn (press again on empty prompt to escalate) |
| `Shift+Tab` | Cycle mode: Normal → Plan → Always-approve |
| `Ctrl+P` / `?` | Command palette |
| `Ctrl+M` | Model picker (or toggle multiline when the prompt is focused) |
| `Ctrl+O` | Toggle always-approve ("YOLO") mode |
| `Ctrl+S` | Session picker (resume a previous session) |
| `Ctrl+T` / `Ctrl+B` | Toggle the todos / tasks pane |
| `Ctrl+G` | Send the current task to the background |
| `!` | Shell mode — run a shell command from the prompt |
| `Esc Esc` | Clear the prompt, or open the rewind picker when it's empty |
| `Ctrl+Q` | Quit (double-press to confirm) |

### Handy slash commands

Type `/` in the prompt for the full menu. Common ones:

| Command | Action |
|---|---|
| `/model <name>` | Switch model (e.g. `/model grok-build`) |
| `/effort <level>` | Set reasoning effort |
| `/plan` | Toggle plan mode (propose before acting) |
| `/compact [note]` | Compress history to reclaim context |
| `/context` | Show context-window usage |
| `/resume` · `/fork` · `/rewind` | Load / branch / roll back a session |
| `/copy` · `/export` | Copy last reply / export the transcript |
| `/mcps` · `/plugins` · `/skills` | Manage MCP servers, plugins, skills |
| `/usage` | Show account usage |
| `/quit` | Exit |

---

## Headless & scripting

Grok runs without the UI for CI, pipelines, and automation:

```bash
# One-shot: print the answer and exit
./bin/grok -p "what does src/main.rs do?"

# Structured JSON output
./bin/grok -p "list the top 3 risks" --output-format json

# Constrain output to a schema
./bin/grok -p "extract the version" \
  --json-schema '{"type":"object","properties":{"version":{"type":"string"}}}'

# Fully non-interactive agent (auto-approve tools) — use with care
./bin/grok -p "fix the failing test" --permission-mode auto --max-turns 20

# Sandbox filesystem/network access
./bin/grok -p "..." --sandbox <profile>

# Long-form agent runners (stdio / websocket / server)
./bin/grok agent --help
```

Permission modes: `default`, `acceptEdits`, `auto`, `dontAsk`, `bypassPermissions`, `plan`.

---

## Configuration

Grok reads `~/.grok/config.toml`. See what it resolves for the current directory:

```bash
./bin/grok inspect
```

Common knobs (under `[ui]`, `[session]`, etc.): `vim_mode`, `screen_mode = "minimal"`, `auto_compact_threshold_percent`, model defaults, MCP servers, project rules (`GROK.md`), themes, and hooks. The upstream user guide documents all of them (linked below).

---

## Updating

```bash
make update                 # install the newest stable, ignoring the pin
make update CHANNEL=alpha   # newest on the alpha channel
make version                # what's installed now
```

`make update` deliberately ignores the pin and installs the newest build, then prints the version number to paste into the Makefile if you want to keep it. Until you do, the next `make install` restores the pinned version — the pin is the source of truth, not whatever happens to be on disk.

So moving to a new version is two steps, on purpose:

```bash
make update                 # try it
make ollama-test            # verify the agent still works on it
# then edit VERSION in the Makefile, and commit
```

`make update` re-runs the installer, so this wrapper always stays in control of the binary. (grok's own `grok update` also works, but it would replace the binary behind the pin's back — for this repo-local layout prefer `make update`.)

---

## Uninstalling

```bash
make uninstall     # deletes ./.grok — removes the binary and cache
```

Because the wrapper is non-invasive, that's all there is to remove. If you also ran xAI's **official** system-wide installer, clean that up separately: `rm -rf ~/.grok` and delete the `# >>> grok installer >>>` block from your shell rc (`~/.zshrc` / `~/.bashrc`).

---

## Repo layout

```
.
├── install.sh     # repo-local, non-invasive installer (also handles updates)
├── ollama.sh      # preflight, model pull, config generation, verification
├── ollama.toml    # generated: the [model.*] block installed into grok's config
├── bin/grok       # launcher shim → runs the installed binary
├── Makefile       # make bootstrap / install / run / ollama / doctor / uninstall
├── AGENTS.md      # setup guide for another machine or a coding agent
├── README.md      # this file
└── .grok/         # (git-ignored) the downloaded binary + cache
```

One caveat to the non-invasive promise: `make ollama` is the single part of this repo that writes outside it, because grok reads its model config from `~/.grok/config.toml` and that's what makes local models work in *every* project rather than just this one. It writes only between managed markers, backs up your config first, and `make ollama-uninstall` reverses it. To keep even that inside the repo, point grok's whole config directory here:

```bash
GROK_HOME="$(pwd)/.grok/home" make ollama    # nothing touches $HOME
GROK_HOME="$(pwd)/.grok/home" ./bin/grok
```

### Make targets

| Target | Description |
|---|---|
| `make bootstrap` | Fresh clone → working local agent (preflight + install + wire up + verify) |
| `make preflight` | Check the host is ready (installs nothing) |
| `make install` | Install the pinned grok version into `./.grok/bin` |
| `make update` | Install the newest version, ignoring the pin |
| `make run` | Launch the interactive TUI |
| `make login` | Authenticate (opens a browser) |
| `make ollama` | Run grok on a local model via Ollama (pull + wire up + verify) |
| `make ollama-models` | Re-scan local models and refresh grok's config |
| `make ollama-test` | End-to-end agent test against the local model |
| `make ollama-doctor` | Health check for the Ollama integration |
| `make ollama-uninstall` | Unwire Ollama from grok's config |
| `make version` | Print the installed version |
| `make help-grok` | grok's own CLI help (all subcommands) |
| `make doctor` | Health check: binary, version, auth status |
| `make uninstall` | Remove `./.grok` |
| `make help` | List targets |

---

## Troubleshooting

- **`grok is not installed yet`** → run `make install`.
- **`make run` opens on the wrong project** → run grok *from* your project dir, or pass `--cwd`, or symlink `bin/grok` onto your PATH (see [Run it from anywhere](#run-it-from-anywhere)).
- **Download fails from `x.ai`** → the installer automatically falls back to Google Cloud Storage; if both fail, check your network/proxy.
- **Not signed in** → `make login` (or `grok login --device-auth` over SSH; or set `XAI_API_KEY`).
- **Keys like `Ctrl+.` or `Ctrl+Enter` don't register** → terminal keyboard-protocol quirk; run `/terminal-setup` inside grok, or use the documented alternates (`Ctrl+X`, `Ctrl+I`).

### Local models

- **`requires a newer version of Ollama`** → `brew upgrade ollama && brew services restart ollama` (or reinstall from [ollama.com/download](https://ollama.com/download)). New models regularly need a newer runtime than you have.
- **`This version requires zstd for extraction`** (Linux) → Ollama's installer needs `zstd`, which minimal images don't ship: `sudo apt-get install -y zstd`, then re-run the installer.
- **`cannot reach Ollama`** → start it: `ollama serve`, or `brew services start ollama`. Non-default host? `OLLAMA_HOST=host:port make ollama`.
- **`does not support tool calling`** → that model can't drive the agent. Check with `ollama show <model>` and look for `tools` under Capabilities, then pick one that has it.
- **The model rambles, loops, or ignores your files** → usually context exhaustion. Raise it (`GROK_OLLAMA_CTX=65536 make ollama`), `/compact` more often, or move to a larger model.
- **Everything is very slow** → check the model fits in RAM with `ollama ps`; if it spilled to CPU, drop to a smaller model or a lower `GROK_OLLAMA_CTX`.
- **Want your xAI models back as the default** → `make ollama-uninstall`, or just `/model grok-4.5` for the session.

---

## Documentation & license

- Grok Build docs: **[docs.x.ai/build/overview](https://docs.x.ai/build/overview)** · product page: **[x.ai/cli](https://x.ai/cli)**
- Full user guide (keyboard shortcuts, slash commands, MCP, skills, plugins, hooks, headless, sandbox, sessions): in the upstream repo under [`crates/codegen/xai-grok-pager/docs/user-guide/`](https://github.com/xai-org/grok-build/tree/main/crates/codegen/xai-grok-pager/docs/user-guide)

The `grok` binary is xAI's software, distributed under the terms at [github.com/xai-org/grok-build](https://github.com/xai-org/grok-build) (first-party code: Apache-2.0). This wrapper (the scripts and this README) just deploys it and is provided as-is.
