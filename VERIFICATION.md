# VERIFICATION.md — what was actually tested, and what was not

This repo claims that Grok Build runs as a working coding agent against a
locally-hosted gemma4. This file is the evidence for that claim, written so a
reviewing agent can **check it rather than believe it**.

Read [AGENTS.md](AGENTS.md) for how to set the thing up. Read this file to
decide how much to trust it.

Everything below was run by hand. Where something was not tested, it says so —
those gaps are the most useful part of this document, because a locked-down work
machine is likely to land in one of them.

---

## The 90-second check

If you only do one thing, do this. It is the difference between "the config
looks right" and "the agent actually works".

```bash
make ollama-doctor     # endpoint up, managed block installed, model present
make ollama-test       # writes a file, asks the model to EDIT it, re-reads it off disk
```

A healthy `make ollama-doctor` looks like this — the `(up, vX.Y.Z)` is the
*server's* version, which is the one that matters:

```
ollama endpoint:  http://localhost:11434  (up, v0.32.5)
grok binary:      grok 0.2.118 (1e1687c1cf6a) [alpha]
grok config:      /Users/you/.grok/config.toml
managed block:    installed (9 model entries)
primary model:    grok-gemma4-12b-32k (from gemma4:12b, ctx 32768)
                  present
tool-capable:     grok-gemma4-12b-32k:latest gemma4:12b qwen3:8b ...
```

And a passing `make ollama-test`:

```
ok  gemma4 edited the file correctly through Grok's tools (190s)
```

**That second test is the whole claim in one command.** It deliberately ignores
what the model *says* and greps the file on disk, because the failure mode that
matters is a model reporting an edit it never made. See [False
passes](#false-passes) — doctor passing tells you almost nothing on its own.

---

## Test environments

Only two hosts were ever used. Both are Apple Silicon; see [What was not
tested](#what-was-not-tested) before assuming this generalises.

| ID | Host | Inference | Notes |
|---|---|---|---|
| **A** | Apple M4, 10 cores, 32 GB, macOS 26.5.1, arm64 | GPU (Metal) | Ollama 0.32.5 via Homebrew |
| **B** | `debian:12-slim` container, linux/arm64, on host A | **CPU only** | No GPU passthrough — this is what made it a useful proxy for a plain VM |

Host B is a container, not a separate machine. It is a fair test of *Linux
packaging and CPU speed*, and not a test of a real datacentre VM.

---

## What was run

| # | Test | Host | Result |
|---|---|---|---|
| 1 | `make bootstrap` from a **fresh clone** | A | Pass |
| 2 | Bootstrap with **no gemma4 pre-pulled** — isolated model store (`OLLAMA_MODELS` + separate port) so the 7.6 GB pull really happened | A | Pass |
| 3 | Preflight + `install.sh` on **minimal Linux** | B | **Failed first** → found the `zstd` gap → fixed, then passed |
| 4 | Full **7.6 GB model pull + setup inside Linux** | B | Pass |
| 5 | `gemma4:e4b-it-qat` on a **CPU-only** host | B | **Failed** → found two separate defects, below |
| 6 | Model comparison via the edit test | A | See [Measurements](#measurements) |
| 7 | `version_ge()` semver comparison unit tests | A | 11/11, including the `0.9.0 < 0.30.5` string-compare trap |

Tests 2–5 each exist because the previous round was not sufficient. Test 1
passing did not mean test 2 would, and so on down the list.

---

## Defects this testing found

This is the real evidence that the testing happened. Each of these was found by
running the thing, not by reading the code, and each one shipped as a fix.

| Commit | Defect | Why it mattered |
|---|---|---|
| `a221126` | **The test only checked reading, so it passed while a real edit silently failed** | The test was grading the model's reply. Local models describe edits they did not make, so it passed in exactly the case it existed to catch. Rewritten to grep the file on disk. |
| `34de439` | **The model this repo recommended for small hosts cannot use tools** | `gemma4:e4b-it-qat` answered *"Could you please provide the current content of opts.toml?"* — it had a read tool and asked the user to paste the file. Identical on GPU, so it is the model, not the hardware. Replaced with `qwen3:8b`. |
| `b385083` | **`inference idle timeout after 600s with no chunks` killed every turn on CPU** | Grok assumes cloud latency; a CPU host spends longer than that in prompt processing before emitting a first token. It failed `make bootstrap` itself. Now `inference_idle_timeout_secs = 1800` on every generated model. |
| `ca27a16` | **Ollama's Linux installer fails on a minimal image** | `ERROR: This version requires zstd for extraction` — an error about neither Ollama nor Grok. Now checked in preflight and documented. |
| `304f3dc` | **An overclaim in this repo's own docs** | Docs said CPU-only "produces wrong results", generalised from one run. A second CPU run succeeded in 643 s. Corrected: the slowness reproduces, the wrongness does not — that is model unreliability, seen on GPU too. |
| `c785385` | Bootstrap ran preflight twice and warned about the binary it was about to install | Cosmetic, but it made a working run look broken. |

Defects found and fixed before the first commit, kept here because they are the
non-obvious ones most likely to bite again:

- **Upgrading Ollama does not upgrade the running server.** `brew upgrade
  ollama` moved the binary to 0.32.5 while the *server* stayed on 0.20.0 and
  kept rejecting gemma4 with "requires a newer version of Ollama". `brew
  services restart ollama` is mandatory. The server version is the one that
  matters.
- **`ollama create -f -` (Modelfile on stdin) fails**, reporting "no Modelfile
  or safetensors files found". It needs a real file path.
- **`supports_images` is not a valid Grok config key** — checked against the
  binary's strings. Only `supports_backend_search` and
  `supports_reasoning_effort` exist. Unknown keys are silently ignored, so this
  looked like it worked.
- **`ollama save` does not exist.** An earlier draft of the offline procedure
  used it. Replaced with an `rsync` of `~/.ollama/models/`.
- **Advertised context ≠ served context.** Models advertised 131072–262144;
  Ollama serves 32768. Grok sizes auto-compaction off `context_window`, so the
  advertised number causes overflow instead of compaction, mid-session.

---

## Measurements

One-line edit task (`make ollama-test`), wall clock, warm model:

| Model | Size | Host A (GPU) | Host B (CPU) |
|---|---|---|---|
| `qwen3:8b` | 5.2 GB | **152 s** | not run |
| `gemma4:12b` | 7.6 GB | 190–224 s | 643–900 s |
| `qwen3:14b` | 9.3 GB | 389 s | not run |

The CPU number is the honest reason to want a GPU: roughly 1–6 tokens/sec, paid
again on every turn of a multi-step task.

### Model support

Tool calling is the gate. Every model below advertises `tools` in `ollama show`;
most still cannot drive the agent.

| Model | Size | Edit test | Evidence |
|---|---|---|---|
| `qwen3:8b` | 5.2 GB | **Pass** | 152 s, host A |
| `gemma4:12b` | 7.6 GB | **Pass** | 190 s / 224 s host A, 643 s host B |
| `qwen3:14b` | 9.3 GB | **Pass** | 389 s, host A — bigger is not faster |
| `gemma4:e4b-it-qat` | 6.1 GB | **Fail** | Asked the user to paste the file. Same on GPU and CPU. |
| `llama3.2:3b` | 2.0 GB | **Fail** | Did not edit |
| `qwen2.5-coder:3b` | 1.9 GB | **Fail** | Did not edit |

**~8B is the floor.** Below it, models write prose about the edit they would
make. `gemma4:26b` is offered in the docs as a stronger option but **was never
run** — no host here has the RAM for it.

Test any model yourself before trusting it:

```bash
ollama pull <model> && make ollama-models && ./ollama.sh test ollama-<model-slug>
```

---

## What was not tested

Ranked by how likely a work machine is to hit it.

| Gap | Risk | What to do about it |
|---|---|---|
| **x86_64 Linux** | Low–medium. All Linux testing was arm64 containers on Apple Silicon, so `install.sh`'s `linux-x86_64` path was never *executed*. The artifact it would fetch does exist though — all four platform builds of the pinned version were confirmed present on both the primary and fallback host (see below). | Run `make preflight`, then `./bin/grok --version`. If the binary runs, the platform selection was right. |
| **Corporate proxy / TLS inspection** | **High** for a managed environment. Never tested. `curl` and `ollama pull` both need to traverse it. | Export `HTTPS_PROXY`/`HTTP_PROXY` before `make bootstrap`. If the CA is intercepted, Ollama may need its own trust config. Fall back to [Restricted networks](AGENTS.md#restricted-networks). |
| **No root / no sudo** | **High.** Ollama's installer wants root and a systemd unit. Never tested without it. | Ollama can be extracted to a user directory and run as a plain `ollama serve` process, but that path is **unverified here**. |
| **A real air-gapped install** | Medium. The offline procedure in AGENTS.md was written and reasoned through but **never executed end to end**. | Treat it as a starting point, not a tested recipe. The `rsync` of `~/.ollama/models/` is the part most likely to be right (content-addressed store); the binary staging is the part to check. |
| **NVIDIA / CUDA GPU** | Low. Only Apple Metal was used. | Should be better, not worse. Confirm with `ollama ps` showing `100% GPU`. |
| **Windows / WSL** | Low — out of scope. | Use xAI's official installer. |
| **`gemma4:26b`** | Low. Documented, never run. | Verify with the edit test before relying on it. |
| **Shared / multi-user Ollama** | Low. Single user throughout. | `num_ctx` on the derived model is per-model, so a shared server is probably fine. Unverified. |

Confirming the pinned binary exists for a platform before you get to that
machine — all four returned `200` from both hosts at the time of writing:

```bash
VER=$(sed -n 's/^VERSION *?= *//p' Makefile)
for p in linux-x86_64 linux-aarch64 macos-aarch64 macos-x86_64; do
  printf '%-16s %s\n' "$p" \
    "$(curl -sIL -o /dev/null -w '%{http_code}' "https://x.ai/cli/grok-$VER-$p")"
done
```
| **Long sessions and auto-compaction** | Medium. Tests were single-turn or few-turn. Compaction behaviour at the 32K boundary was reasoned about, not observed. | Watch for the model forgetting files mid-task; raise `GROK_OLLAMA_CTX`. |

---

## False passes

Three ways this setup can look like it works when it does not. All three were
hit during testing.

**1. The model reports an edit it did not make.** Asked to make one change in
three places in `ollama.sh`, gemma4 got the first right, made the other two by
*overwriting adjacent lines* instead of inserting — deleting a working
subcommand — and reported all three as done. The file still passed `bash -n`.

> Judge `git diff`, never the summary. Use `--permission-mode default` on code
> you care about; `auto` is for throwaway directories.

**2. The config is installed and the model cannot use tools.** `make
ollama-doctor` passes, the model appears in the picker, the model answers
questions — and no file is ever edited. This is what `gemma4:e4b-it-qat` does.

> `make ollama-test` is the only check that catches this. Doctor cannot.

**3. The wrong Ollama is answering.** The client binary and the running server
have separate versions, and the server is the one that loads models. A
successful `ollama --version` says nothing about it.

> `make ollama-doctor` reports the endpoint's own version — trust that one.

---

## Re-verifying from scratch

To confirm the whole claim on a new machine, in order:

```bash
make preflight        # 1. host is capable — installs nothing
make bootstrap        # 2. install + pull + wire + self-test
make ollama-doctor    # 3. endpoint up, config installed, model present
make ollama-test      # 4. the agent actually edits a file (the real test)
```

Then the one that cannot be faked — a real edit in a real directory:

```bash
mkdir -p /tmp/grokcheck && printf 'def add(a, b):\n    return a - b\n' > /tmp/grokcheck/calc.py
./bin/grok --cwd /tmp/grokcheck -m gemma4 --permission-mode auto --max-turns 12 \
  -p 'calc.py has a bug: add() subtracts instead of adds. Fix it.'
cat /tmp/grokcheck/calc.py    # must read: return a + b
```

And the proof that it is local: **disconnect from the network and run a turn.**
It still works. Nothing else is as convincing.

---

## Provenance

- Repo state at time of writing: `34de439`, clean tree.
- Grok binary: `0.2.118`, pinned in the Makefile — which was the current
  `stable` at the time of writing (`curl -fsSL https://x.ai/cli/stable`).
  Note that `grok --version` prints `0.2.118 (1e1687c1cf6a) [alpha]`: the
  `[alpha]` is a build tag baked into the binary, **not** a sign that the wrong
  channel was installed. It is not a discrepancy — do not "fix" it.
- Ollama: `0.32.5` (server and client, host A).
- The setup, verification and troubleshooting commands in AGENTS.md and
  README.md were executed at least once on host A.
- Two sections are **written but not executed**, and say so in place:
  [Restricted networks](AGENTS.md#restricted-networks) and [Managed and
  locked-down hosts](AGENTS.md#managed-and-locked-down-hosts). The download URLs
  in them were confirmed to resolve; the procedures around them were not run.
