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
- An **xAI account** (Grok subscription or API access) to sign in on first run.
- ~150 MB of free disk for the binary.

Building from source is **not** needed here — this uses the signed prebuilt binary. (If you ever do want a source build, that's the upstream repo's `cargo build -p xai-grok-pager-bin --release` path.)

---

## Installing

`make install` fetches the latest **stable** release and drops it at `./.grok/bin/grok`. It's idempotent — re-run it any time to upgrade.

| Command | What it does |
|---|---|
| `make install` | Latest stable |
| `make install VERSION=0.2.106` | Pin a specific version |
| `make install CHANNEL=alpha` | Track the faster **alpha** channel |
| `GROK_BIN_DIR=/somewhere ./install.sh` | Install the symlinks elsewhere |

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
make update                 # re-fetch the latest stable and swap it in
make update CHANNEL=alpha   # move to the alpha channel
make version                # what's installed now
```

`make update` re-runs the installer, so this wrapper always stays in control of the binary. (grok's own `grok update` also works, but for this repo-local layout prefer `make update`.)

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
├── bin/grok       # launcher shim → runs the installed binary
├── Makefile       # make install / login / run / update / doctor / uninstall
├── README.md      # this file
└── .grok/         # (git-ignored) the downloaded binary + cache
```

### Make targets

| Target | Description |
|---|---|
| `make install` | Download + install grok into `./.grok/bin` |
| `make update` | Re-fetch and install the latest version |
| `make run` | Launch the interactive TUI |
| `make login` | Authenticate (opens a browser) |
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

---

## Documentation & license

- Grok Build docs: **[docs.x.ai/build/overview](https://docs.x.ai/build/overview)** · product page: **[x.ai/cli](https://x.ai/cli)**
- Full user guide (keyboard shortcuts, slash commands, MCP, skills, plugins, hooks, headless, sandbox, sessions): in the upstream repo under [`crates/codegen/xai-grok-pager/docs/user-guide/`](https://github.com/xai-org/grok-build/tree/main/crates/codegen/xai-grok-pager/docs/user-guide)

The `grok` binary is xAI's software, distributed under the terms at [github.com/xai-org/grok-build](https://github.com/xai-org/grok-build) (first-party code: Apache-2.0). This wrapper (the scripts and this README) just deploys it and is provided as-is.
