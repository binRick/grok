#!/usr/bin/env bash
#
# ollama.sh — wire Grok Build up to locally-hosted models served by Ollama.
#
# Grok speaks the OpenAI Chat Completions protocol to any `base_url` you give
# it, and Ollama serves exactly that on :11434/v1. This script does the three
# things that turns those two facts into a working local coding agent:
#
#   1. Pulls the model (default: gemma4:12b) and derives a variant of it with a
#      context window big enough for agentic work — Ollama's stock context is
#      far too small to hold Grok's system prompt plus a real conversation, and
#      that is not something Grok's config can fix from its side.
#   2. Generates ./ollama.toml — one [model.*] entry per *tool-capable* local
#      model. Models without tool calling are skipped: they cannot drive Grok's
#      agent loop (no file edits, no shell), so listing them would only offer a
#      broken choice in the model picker.
#   3. Installs that block into Grok's config (~/.grok/config.toml, or
#      $GROK_HOME) between managed markers, so plain `grok` in any project uses
#      the local model. Fully reversible with `./ollama.sh uninstall`.
#
# Usage:
#   ./ollama.sh                 # setup: preflight + pull + derive + install + verify
#   ./ollama.sh preflight       # check host readiness, with fixes for what is missing
#   ./ollama.sh generate        # regenerate ./ollama.toml from local models only
#   ./ollama.sh install         # install ./ollama.toml into the Grok config
#   ./ollama.sh uninstall       # remove the managed block from the Grok config
#   ./ollama.sh doctor          # health check
#   ./ollama.sh test [model]    # end-to-end agent test (tool call + file read)
#
# Env:
#   GROK_OLLAMA_MODEL   ollama model to use          (default: gemma4:12b)
#   GROK_OLLAMA_CTX     context window to derive     (default: 32768)
#   GROK_OLLAMA_ID      grok model id for it         (default: gemma4)
#   GROK_OLLAMA_DEFAULT set 0 to not make it Grok's default model
#   OLLAMA_HOST         ollama endpoint              (default: http://localhost:11434)
#   GROK_HOME           grok config dir              (default: ~/.grok)
#
set -euo pipefail

SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FRAGMENT="$SCRIPT_DIR/ollama.toml"

MODEL="${GROK_OLLAMA_MODEL:-gemma4:12b}"
CTX="${GROK_OLLAMA_CTX:-32768}"
MODEL_ID="${GROK_OLLAMA_ID:-gemma4}"
MAKE_DEFAULT="${GROK_OLLAMA_DEFAULT:-1}"

# gemma4 refuses to load on older runtimes ("requires a newer version of
# Ollama"), and the error arrives only after the pull. Check it up front.
MIN_OLLAMA="${GROK_OLLAMA_MIN_VERSION:-0.30.5}"

# Ollama's OpenAI-compatible surface. OLLAMA_HOST is often set bare (host:port),
# so normalise it to a URL.
HOST="${OLLAMA_HOST:-http://localhost:11434}"
case "$HOST" in http://*|https://*) ;; *) HOST="http://$HOST" ;; esac
HOST="${HOST%/}"

# What Ollama actually serves when a model doesn't pin num_ctx itself. This is
# NOT the context the model advertises: a model may claim 128K while the server
# hands out 32K, and Grok sizing auto-compaction off the advertised number would
# overflow the window instead of compacting. Only the derived primary model
# (which pins num_ctx) is trusted above this.
SERVER_CTX="${OLLAMA_CONTEXT_LENGTH:-32768}"

GROK_CFG_DIR="${GROK_HOME:-$HOME/.grok}"
GROK_CFG="$GROK_CFG_DIR/config.toml"
GROK_BIN="${GROK_BIN_DIR:-$SCRIPT_DIR/.grok/bin}/grok"

BEGIN_MARK="# >>> grok-ollama (managed by ollama.sh — do not edit inside) >>>"
END_MARK="# <<< grok-ollama <<<"

info() { printf '\033[36m==>\033[0m %s\n' "$*" >&2; }
ok()   { printf '\033[32m ok\033[0m %s\n' "$*" >&2; }
warn() { printf '\033[33mwarn:\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[31merror:\033[0m %s\n' "$*" >&2; exit 1; }

need() { command -v "$1" >/dev/null 2>&1 || die "$1 is required but not installed."; }

# Scratch paths are registered here rather than cleaned by per-function traps: a
# RETURN/EXIT trap that closes over a `local` fires after that local is gone.
SCRATCH=()
scratch() { SCRATCH+=("$1"); printf '%s' "$1"; }
cleanup() { [ ${#SCRATCH[@]} -eq 0 ] || rm -rf "${SCRATCH[@]}"; }
trap cleanup EXIT

# The derived model: same weights, bigger context. Ollama reuses the parent's
# blobs, so this costs no extra disk.
derived_name() { printf 'grok-%s-%sk' "$(printf '%s' "$MODEL" | tr ':/' '--')" "$((CTX / 1024))"; }

ollama_up() {
  curl -fsS -m 5 "$HOST/api/version" >/dev/null 2>&1
}

require_ollama() {
  need curl
  need python3
  ollama_up || die "cannot reach Ollama at $HOST
       Start it with:  ollama serve      (or)   brew services start ollama
       Full diagnosis:  ./ollama.sh preflight"
}

# --- 0. preflight --------------------------------------------------------------

# Everything below reports what to DO about a failure, not just that it failed —
# this is the script a fresh machine (or an agent driving one) hits first.

os_name() { case "$(uname -s)" in Darwin) echo macos ;; Linux) echo linux ;; *) echo other ;; esac; }

# Pure-awk semver compare so this works before we have confirmed python3.
version_ge() {
  awk -v a="$1" -v b="$2" 'BEGIN {
    na = split(a, x, "."); nb = split(b, y, ".")
    n = (na > nb) ? na : nb
    for (i = 1; i <= n; i++) {
      xi = (i <= na) ? x[i] + 0 : 0; yi = (i <= nb) ? y[i] + 0 : 0
      if (xi > yi) exit 0
      if (xi < yi) exit 1
    }
    exit 0
  }'
}

install_ollama_hint() {
  case "$(os_name)" in
    macos) printf '  brew install ollama && brew services start ollama\n  (or download the app: https://ollama.com/download)\n' ;;
    linux) printf '  curl -fsSL https://ollama.com/install.sh | sh\n  (offline/restricted networks: grab the tarball from https://github.com/ollama/ollama/releases)\n' ;;
    *)     printf '  https://ollama.com/download\n' ;;
  esac
}

upgrade_ollama_hint() {
  case "$(os_name)" in
    macos) printf '  brew upgrade ollama && brew services restart ollama\n' ;;
    linux) printf '  curl -fsSL https://ollama.com/install.sh | sh && sudo systemctl restart ollama\n' ;;
    *)     printf '  https://ollama.com/download\n' ;;
  esac
}

free_disk_gb() { df -Pk "$SCRIPT_DIR" 2>/dev/null | awk 'NR==2 {printf "%.0f", $4/1024/1024}'; }

total_ram_gb() {
  case "$(os_name)" in
    macos) awk -v b="$(sysctl -n hw.memsize 2>/dev/null || echo 0)" 'BEGIN {printf "%.0f", b/1024/1024/1024}' ;;
    linux) awk '/MemTotal/ {printf "%.0f", $2/1024/1024}' /proc/meminfo 2>/dev/null ;;
    *)     echo 0 ;;
  esac
}

# Download size straight from the registry, so the disk check is about the model
# actually requested rather than a guess. Empty when it cannot be determined.
model_size_gb() {
  case "$MODEL" in */*) return ;; esac          # non-library models: unknown path
  local name="${MODEL%%:*}" tag="${MODEL#*:}"
  [ "$tag" = "$MODEL" ] && tag=latest
  curl -fsS -m 15 "https://registry.ollama.ai/v2/library/$name/manifests/$tag" 2>/dev/null \
    | python3 -c 'import json,sys
try:
    d = json.load(sys.stdin)
    print("%.1f" % (sum(l["size"] for l in d["layers"]) / 1e9))
except Exception:
    pass' 2>/dev/null || true
}

cmd_preflight() {
  local fail=0 warned=0
  printf 'platform:         %s/%s\n' "$(os_name)" "$(uname -m)"

  # --- required tooling ---
  for t in curl python3 awk; do
    if command -v "$t" >/dev/null 2>&1; then
      printf '%-17s ok\n' "$t:"
    else
      printf '%-17s \033[31mMISSING\033[0m — install it with your package manager\n' "$t:"
      fail=1
    fi
  done

  # --- ollama binary ---
  if command -v ollama >/dev/null 2>&1; then
    # `ollama --version` also emits a connection warning when the server is
    # down, so pull the version out rather than echoing the first line.
    local cv
    cv="$(ollama --version 2>/dev/null | awk '/version is/ {print $NF; exit}')"
    printf '%-17s ok (client %s)\n' "ollama binary:" "${cv:-unknown}"
  else
    printf '%-17s \033[31mMISSING\033[0m — install it:\n' "ollama binary:"
    install_ollama_hint
    fail=1
  fi

  # --- ollama server + version (the server's version is the one that matters) ---
  if ollama_up; then
    local sv
    sv="$(curl -fsS -m 5 "$HOST/api/version" | python3 -c 'import json,sys; print(json.load(sys.stdin)["version"])' 2>/dev/null || echo 0)"
    if version_ge "$sv" "$MIN_OLLAMA"; then
      printf '%-17s ok (v%s at %s)\n' "ollama server:" "$sv" "$HOST"
    else
      printf '%-17s \033[31mv%s is too old\033[0m — %s needs >= %s. Upgrade:\n' "ollama server:" "$sv" "$MODEL" "$MIN_OLLAMA"
      upgrade_ollama_hint
      fail=1
    fi
  else
    printf '%-17s \033[31mUNREACHABLE\033[0m at %s — start it:\n' "ollama server:" "$HOST"
    case "$(os_name)" in
      macos) printf '  brew services start ollama    (or)   ollama serve\n' ;;
      linux) printf '  sudo systemctl start ollama   (or)   ollama serve\n' ;;
      *)     printf '  ollama serve\n' ;;
    esac
    fail=1
  fi

  # --- capacity ---
  local need_gb disk ram
  need_gb="$(model_size_gb)"
  disk="$(free_disk_gb)"; ram="$(total_ram_gb)"

  # Already downloaded? Then its size is not a constraint any more, and on an
  # air-gapped host the registry lookup will not work anyway.
  local have_model=0
  ollama_up && curl -fsS -m 10 "$HOST/api/show" -d "{\"model\":\"$MODEL\"}" >/dev/null 2>&1 && have_model=1

  if [ -z "$need_gb" ] || [ "$have_model" -eq 1 ]; then
    # Unknown size: report the numbers plainly instead of silently skipping the
    # check, so a restricted-network host still gets the information.
    local note="size of $MODEL unknown, registry unreachable — check manually"
    [ "$have_model" -eq 1 ] && note="$MODEL is already downloaded"
    printf '%-17s %s GB free — %s\n' "disk:" "${disk:-?}" "$note"
    printf '%-17s %s GB\n' "memory:" "${ram:-?}"
  else
    # Headroom for the derived manifest, the KV cache spilling to disk, and
    # simply not wedging the machine at 100% full.
    local want
    want="$(awk -v n="$need_gb" 'BEGIN {printf "%.0f", n + 5}')"
    if [ "${disk:-0}" -ge "$want" ] 2>/dev/null; then
      printf '%-17s ok (%s GB free; %s needs ~%s GB)\n' "disk:" "$disk" "$MODEL" "$need_gb"
    else
      printf '%-17s \033[33m%s GB free\033[0m — %s needs ~%s GB plus headroom.\n' "disk:" "$disk" "$MODEL" "$need_gb"
      printf '  Free space, or pick a smaller model:  GROK_OLLAMA_MODEL=gemma4:e4b-it-qat make ollama\n'
      printf '  Reclaim from Ollama:  ollama list   then   ollama rm <model>\n'
      warned=1
    fi

    local want_ram
    want_ram="$(awk -v n="$need_gb" 'BEGIN {printf "%.0f", n + 4}')"
    if [ "${ram:-0}" -eq 0 ] 2>/dev/null; then
      printf '%-17s unknown\n' "memory:"
    elif [ "$ram" -ge "$want_ram" ] 2>/dev/null; then
      printf '%-17s ok (%s GB)\n' "memory:" "$ram"
    else
      printf '%-17s \033[33m%s GB\033[0m — %s wants ~%s GB with a %sK context.\n' "memory:" "$ram" "$MODEL" "$want_ram" "$((CTX / 1024))"
      printf '  It will still run, but may spill to CPU and get slow. Smaller model or\n'
      printf '  smaller context:  GROK_OLLAMA_CTX=8192 make ollama\n'
      warned=1
    fi
  fi

  # --- grok itself ---
  if [ -x "$GROK_BIN" ]; then
    printf '%-17s ok (%s)\n' "grok binary:" "$("$GROK_BIN" --version 2>/dev/null)"
  elif [ "${GROK_OLLAMA_BOOTSTRAP:-0}" = "1" ]; then
    # `make bootstrap` installs it in the very next step, so its absence here is
    # the expected starting state, not something to warn a new user about.
    printf '%-17s not installed yet — bootstrap installs it next\n' "grok binary:"
  else
    printf '%-17s \033[33mnot installed\033[0m — run: make install\n' "grok binary:"
    warned=1
  fi

  echo
  if [ "$fail" -ne 0 ]; then
    die "preflight failed — fix the items above, then re-run: ./ollama.sh preflight"
  fi
  if [ "$warned" -ne 0 ]; then
    warn "preflight passed, with the warnings above — setup will run, but read them first"
  else
    ok "preflight passed"
  fi
}

# --- model list + capabilities -------------------------------------------------

# Prints: <name>\t<capabilities csv>\t<context_length>  for every local model.
local_models() {
  local names
  names="$(curl -fsS -m 10 "$HOST/api/tags" \
    | python3 -c 'import json,sys; [print(m["name"]) for m in json.load(sys.stdin).get("models",[])]')"
  local n
  for n in $names; do
    curl -fsS -m 15 "$HOST/api/show" -d "{\"model\":\"$n\"}" 2>/dev/null | python3 -c '
import json, sys
d = json.load(sys.stdin)
caps = ",".join(d.get("capabilities") or [])
info = d.get("model_info") or {}
ctx = next((v for k, v in info.items() if k.endswith(".context_length")), 0)
print("%s\t%s\t%s" % ('"\"$n\""', caps, ctx))
' || true
  done
}

# --- 1. pull + derive ----------------------------------------------------------

cmd_pull() {
  require_ollama
  need ollama

  if curl -fsS -m 10 "$HOST/api/show" -d "{\"model\":\"$MODEL\"}" >/dev/null 2>&1; then
    ok "$MODEL is already pulled"
  else
    info "Pulling $MODEL (this can take a while)"
    ollama pull "$MODEL" || die "failed to pull $MODEL.
       If Ollama says a newer version is required, upgrade it:  brew upgrade ollama"
  fi

  # Refuse early if the model can't call tools — the agent loop needs them.
  local caps
  caps="$(curl -fsS -m 15 "$HOST/api/show" -d "{\"model\":\"$MODEL\"}" \
    | python3 -c 'import json,sys; print(",".join(json.load(sys.stdin).get("capabilities") or []))')"
  case ",$caps," in
    *,tools,*) ;;
    *) die "$MODEL does not support tool calling (capabilities: ${caps:-none}).
       Grok's agent cannot edit files or run commands without it. Pick a
       tool-capable model, e.g.  GROK_OLLAMA_MODEL=qwen3:14b ./ollama.sh" ;;
  esac

  local derived
  derived="$(derived_name)"
  if curl -fsS -m 10 "$HOST/api/show" -d "{\"model\":\"$derived\"}" >/dev/null 2>&1; then
    ok "$derived already exists (context $CTX)"
  else
    info "Deriving $derived from $MODEL with num_ctx=$CTX"
    # Shares the parent's weight blobs — no extra disk for the weights.
    # `ollama create` needs a real file; it does not read a Modelfile on stdin.
    local mfdir
    mfdir="$(scratch "$(mktemp -d)")"
    printf 'FROM %s\nPARAMETER num_ctx %s\n' "$MODEL" "$CTX" > "$mfdir/Modelfile"
    ollama create "$derived" -f "$mfdir/Modelfile" >/dev/null \
      || die "failed to create $derived"
    ok "created $derived"
  fi
}

# --- 2. generate ./ollama.toml -------------------------------------------------

cmd_generate() {
  require_ollama
  local derived
  derived="$(derived_name)"

  info "Scanning local models on $HOST"
  local rows
  rows="$(local_models)"
  [ -n "$rows" ] || die "no models found on $HOST — pull one first (ollama pull $MODEL)"

  MODEL="$MODEL" DERIVED="$derived" MODEL_ID="$MODEL_ID" CTX="$CTX" HOST="$HOST" \
  MAKE_DEFAULT="$MAKE_DEFAULT" BEGIN_MARK="$BEGIN_MARK" END_MARK="$END_MARK" \
  SERVER_CTX="$SERVER_CTX" \
  python3 -c '
import os, re, sys

rows = [l.split("\t") for l in sys.stdin.read().splitlines() if l.strip()]
primary  = os.environ["DERIVED"]
model_id = os.environ["MODEL_ID"]
ctx      = int(os.environ["CTX"])
serve    = int(os.environ["SERVER_CTX"])
host     = os.environ["HOST"]
base_url = host + "/v1"

def slug(name):
    return "ollama-" + re.sub(r"[^a-z0-9]+", "-", name.lower()).strip("-")

def pretty(name):
    return name.replace(":", " ").replace("-", " ").title()

out = [os.environ["BEGIN_MARK"], "#",
       "# Local models served by Ollama at %s" % host,
       "# Regenerate with:  ./ollama.sh generate",
       "#",
       "# Only tool-capable models are listed — Grok needs tool calling to edit",
       "# files and run commands. context_window is what Ollama actually serves",
       "# (%dK), not what the model advertises, so auto-compaction fires before" % (serve // 1024),
       "# the real window overflows.",
       ""]

agentic = [(n, c, x) for n, c, x in rows if "tools" in c.split(",")]
skipped = [n for n, c, x in rows if "tools" not in c.split(",")]

if os.environ.get("MAKE_DEFAULT") == "1":
    out += ["[models]", "default = \"%s\"" % model_id, ""]

def entry(gid, oname, caps, window, display, desc):
    extra = [c for c in ("vision", "thinking") if c in caps.split(",")]
    if extra:
        desc += " (%s)" % ", ".join(extra)
    return ["[model.%s]" % gid,
            "model = \"%s\"" % oname,
            "base_url = \"%s\"" % base_url,
            "name = \"%s\"" % display,
            "description = \"%s\"" % desc,
            # Ollama ignores the key, but Grok wants a credential for a
            # non-first-party endpoint. Any non-empty value works.
            "api_key = \"ollama\"",
            "api_backend = \"chat_completions\"",
            "context_window = %d" % window,
            ""]

# The primary: the derived big-context build of the requested model.
prim = next((r for r in rows if r[0].split(":")[0] == primary.split(":")[0]
             or r[0] == primary or r[0] == primary + ":latest"), None)
prim_caps = prim[1] if prim else "completion,tools"
out += entry(model_id, primary, prim_caps, ctx,
             "%s (local)" % pretty(os.environ["MODEL"]),
             "Locally hosted via Ollama, %dK context" % (ctx // 1024))

# Everything else tool-capable, so the Ctrl+M picker can reach it.
for name, caps, window in agentic:
    if name == primary or name.startswith(primary + ":"):
        continue
    gid = slug(name)
    if gid == model_id:
        continue
    # These models do not pin num_ctx, so the server default is the real ceiling.
    try:
        w = min(int(window), serve)
    except ValueError:
        w = serve
    out += entry(gid, name, caps, w, "%s (Ollama)" % pretty(name),
                 "Locally hosted via Ollama")

if skipped:
    out += ["# Skipped (no tool-calling support, cannot drive the agent loop):"]
    out += ["#   %s" % n for n in skipped]
    out += [""]

out.append(os.environ["END_MARK"])
print("\n".join(out))
' <<<"$rows" > "$FRAGMENT"

  ok "wrote $FRAGMENT"
  grep -c '^\[model\.' "$FRAGMENT" | xargs -I{} printf '    %s model entries\n' {} >&2
}

# --- 3. install into the grok config ------------------------------------------

cmd_install() {
  [ -f "$FRAGMENT" ] || die "$FRAGMENT not found — run: ./ollama.sh generate"
  mkdir -p "$GROK_CFG_DIR"
  touch "$GROK_CFG"

  # What actually gets merged. Kept separate from $FRAGMENT so installing never
  # rewrites the tracked file.
  local body
  body="$(scratch "$(mktemp)")"
  cp "$FRAGMENT" "$body"

  # Declaring [models] twice in one file is invalid TOML, and the user's own
  # table wins — a default model is theirs to choose, not ours to overwrite.
  if grep -q '^\[models\]' "$body" && \
     awk -v b="$BEGIN_MARK" -v e="$END_MARK" '
       $0==b {inb=1} $0==e {inb=0; next} !inb && /^\[models\]/ {found=1} END {exit !found}
     ' "$GROK_CFG"; then
    warn "$GROK_CFG already has its own [models] section."
    warn "Leaving your default model alone; select the local one with:  /model $MODEL_ID"
    python3 - "$body" <<'PY'
import re, sys
p = sys.argv[1]
s = open(p).read()
s = re.sub(r"^\[models\]\n(?:default = .*\n)?\n?", "", s, flags=re.M)
open(p, "w").write(s)
PY
  fi

  if grep -qF "$BEGIN_MARK" "$GROK_CFG"; then
    info "Updating the managed block in $GROK_CFG"
  else
    info "Adding the managed block to $GROK_CFG"
    cp "$GROK_CFG" "$GROK_CFG.pre-ollama.bak" 2>/dev/null || true
    [ -s "$GROK_CFG.pre-ollama.bak" ] && info "Backed up your config to $GROK_CFG.pre-ollama.bak"
  fi

  python3 - "$GROK_CFG" "$body" "$BEGIN_MARK" "$END_MARK" <<'PY'
import sys
cfg, frag, begin, end = sys.argv[1:5]
body = open(frag).read().rstrip("\n")
cur = open(cfg).read()
if begin in cur and end in cur:
    head, rest = cur.split(begin, 1)
    _, tail = rest.split(end, 1)
    out = head + body + tail
else:
    sep = "" if cur == "" or cur.endswith("\n\n") else ("\n" if cur.endswith("\n") else "\n\n")
    out = cur + sep + body + "\n"
open(cfg, "w").write(out)
PY

  ok "installed into $GROK_CFG"
}

cmd_uninstall() {
  [ -f "$GROK_CFG" ] || { ok "nothing to remove ($GROK_CFG does not exist)"; return; }
  grep -qF "$BEGIN_MARK" "$GROK_CFG" || { ok "no managed block in $GROK_CFG"; return; }
  python3 - "$GROK_CFG" "$BEGIN_MARK" "$END_MARK" <<'PY'
import sys
cfg, begin, end = sys.argv[1:4]
s = open(cfg).read()
head, rest = s.split(begin, 1)
_, tail = rest.split(end, 1)
open(cfg, "w").write((head.rstrip("\n") + "\n" + tail.lstrip("\n")).strip("\n") + "\n")
PY
  ok "removed the managed block from $GROK_CFG"
  info "The Ollama models themselves are untouched."
  if ollama_up; then
    local derived_models
    derived_models="$(curl -fsS -m 10 "$HOST/api/tags" 2>/dev/null \
      | python3 -c 'import json,sys; [print(m["name"]) for m in json.load(sys.stdin).get("models",[]) if m["name"].startswith("grok-")]' 2>/dev/null || true)"
    if [ -n "$derived_models" ]; then
      info "Drop the big-context builds this script created with:"
      printf '%s\n' "$derived_models" | while read -r m; do info "  ollama rm $m"; done
    fi
  fi
}

# --- verification --------------------------------------------------------------

cmd_test() {
  local id="${1:-$MODEL_ID}"
  [ -x "$GROK_BIN" ] || die "grok is not installed yet. Run: make install"
  require_ollama

  local tmp
  tmp="$(scratch "$(mktemp -d)")"
  printf 'the answer is 4711\n' > "$tmp/answer.txt"

  info "Agent test: asking $id to read a file with its tools (may take a minute)"
  local out
  out="$("$GROK_BIN" --cwd "$tmp" -m "$id" --permission-mode auto --max-turns 6 \
        -p 'Read the file answer.txt in this directory and reply with only the number it contains.' 2>&1)" \
        || { printf '%s\n' "$out" >&2; die "grok exited non-zero"; }

  if printf '%s' "$out" | grep -q '4711'; then
    ok "$id read the file through Grok's tools and answered correctly"
  else
    printf '%s\n' "$out" >&2
    die "$id did not return the expected value — it may be too small to drive the agent loop"
  fi
}

cmd_doctor() {
  printf 'ollama endpoint:  %s' "$HOST"
  if ollama_up; then
    printf '  (up, v%s)\n' "$(curl -fsS -m 5 "$HOST/api/version" | python3 -c 'import json,sys; print(json.load(sys.stdin)["version"])')"
  else
    printf '  \033[31mUNREACHABLE\033[0m\n'
  fi

  printf 'grok binary:      %s\n' "$([ -x "$GROK_BIN" ] && "$GROK_BIN" --version 2>/dev/null || echo 'NOT INSTALLED — run: make install')"
  printf 'grok config:      %s\n' "$GROK_CFG"
  if [ -f "$GROK_CFG" ] && grep -qF "$BEGIN_MARK" "$GROK_CFG"; then
    printf 'managed block:    installed (%s model entries)\n' \
      "$(awk -v b="$BEGIN_MARK" -v e="$END_MARK" '$0==b{i=1} i&&/^\[model\./{n++} $0==e{i=0} END{print n+0}' "$GROK_CFG")"
  else
    printf 'managed block:    \033[33mnot installed\033[0m — run: ./ollama.sh install\n'
  fi

  printf 'primary model:    %s (from %s, ctx %s)\n' "$(derived_name)" "$MODEL" "$CTX"
  if ollama_up; then
    if curl -fsS -m 10 "$HOST/api/show" -d "{\"model\":\"$(derived_name)\"}" >/dev/null 2>&1; then
      printf '                  present\n'
    else
      printf '                  \033[33mmissing\033[0m — run: ./ollama.sh\n'
    fi
    printf 'tool-capable:     %s\n' "$(local_models | awk -F'\t' '$2 ~ /tools/ {print $1}' | paste -sd' ' -)"
  fi
}

cmd_setup() {
  # `make bootstrap` preflights before installing anything, so running it again
  # here would just repeat the same report back at the user.
  if [ "${GROK_OLLAMA_BOOTSTRAP:-0}" != "1" ]; then
    cmd_preflight
    echo >&2
  fi
  cmd_pull
  cmd_generate
  cmd_install
  cmd_test "$MODEL_ID"
  echo >&2
  ok "Grok Build is wired to local Ollama."
  info "Run it anywhere:   ./bin/grok            (or)   make run"
  info "Switch models in the TUI with Ctrl+M, or:  /model $MODEL_ID"
}

case "${1:-setup}" in
  setup|"")   cmd_setup ;;
  preflight)  cmd_preflight ;;
  pull)       cmd_pull ;;
  generate)   cmd_generate ;;
  install)    cmd_generate; cmd_install ;;
  uninstall)  cmd_uninstall ;;
  doctor)     cmd_doctor ;;
  test)       shift; cmd_test "${1:-$MODEL_ID}" ;;
  -h|--help|help)
    sed -n '2,45p' "$0" | sed 's/^# \{0,1\}//' ;;
  *) die "unknown command: $1
       try: setup, preflight, pull, generate, install, uninstall, doctor, test" ;;
esac
