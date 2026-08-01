# Grok Build — repo-local deployment wrapper.
# All targets operate on the copy of grok installed under ./.grok/ by install.sh.
# Nothing here touches your $HOME, PATH, or shell rc files.

SHELL := /bin/bash
REPO  := $(patsubst %/,%,$(dir $(abspath $(lastword $(MAKEFILE_LIST)))))
GROK  := $(REPO)/.grok/bin/grok

# The grok version this deployment installs. Pinned rather than tracking
# "latest" so that a clone made months from now gets the same binary this repo
# was tested against — upstream moves, and `make bootstrap` should be
# reproducible on a new machine.
#
# Moving the pin is a deliberate edit: `make update` installs the newest build
# and prints the number to paste in here.
#
# Overridable per-invocation:  make install VERSION=0.2.107 CHANNEL=alpha
CHANNEL ?= stable
VERSION ?= 0.2.118

.DEFAULT_GOAL := help

## bootstrap: fresh clone -> working local agent (preflight + grok + gemma4 + verify)
bootstrap:
	@GROK_OLLAMA_BOOTSTRAP=1 ./ollama.sh preflight || { \
	  echo ""; \
	  echo "Fix the items above first. Nothing has been installed."; \
	  exit 1; \
	}
	@echo ""
	@$(MAKE) --no-print-directory install
	@echo ""
	@GROK_OLLAMA_BOOTSTRAP=1 ./ollama.sh setup
	@echo ""
	@echo "Ready. Start the agent with:  make run"

## preflight: check this host can run the local setup (installs nothing)
preflight:
	@./ollama.sh preflight

## install: download + install the grok binary into ./.grok/bin (idempotent)
install:
	@GROK_CHANNEL=$(CHANNEL) ./install.sh $(VERSION)

## update: install the newest build on $(CHANNEL), ignoring the version pin
update:
	@GROK_CHANNEL=$(CHANNEL) GROK_VERSION= ./install.sh
	@echo ""
	@echo "Installed $$(cat "$(REPO)/.grok/version" 2>/dev/null), but the Makefile still pins $(VERSION)."
	@echo "The next 'make install' would put $(VERSION) back. To keep this version,"
	@echo "set VERSION in the Makefile to:  $$(cat "$(REPO)/.grok/version" 2>/dev/null)"
	@echo "Then re-verify with:  make ollama-test"

## run: launch the interactive Grok TUI in the current directory
run: guard
	@exec "$(GROK)"

## login: authenticate with your xAI account (opens a browser)
login: guard
	@"$(GROK)" login

## ollama: run grok on a local model via Ollama (pull + wire up + verify)
ollama: guard
	@./ollama.sh setup

## ollama-models: refresh the local model list in grok's config
ollama-models:
	@./ollama.sh install

## ollama-test: end-to-end agent test against the local model
ollama-test: guard
	@./ollama.sh test

## ollama-doctor: health check for the local Ollama integration
ollama-doctor:
	@./ollama.sh doctor

## ollama-uninstall: unwire Ollama from grok's config (models are kept)
ollama-uninstall:
	@./ollama.sh uninstall

## version: print the installed grok version
version: guard
	@"$(GROK)" --version

## help-grok: show grok's own CLI help (all subcommands + flags)
help-grok: guard
	@"$(GROK)" --help

## doctor: quick health check of this deployment
doctor:
	@echo "repo:      $(REPO)"; \
	if [ -x "$(GROK)" ]; then \
	  echo "binary:    $(GROK)"; \
	  echo "version:   $$($(GROK) --version 2>/dev/null)"; \
	  echo "auth:      $$([ -f $$HOME/.grok/auth.json ] && echo 'logged in (~/.grok/auth.json)' || echo 'not logged in — run: make login')"; \
	  echo "local:     $$(grep -qs 'grok-ollama' $${GROK_HOME:-$$HOME/.grok}/config.toml && echo 'Ollama models wired in — see: make ollama-doctor' || echo 'no local models — run: make ollama')"; \
	else \
	  echo "binary:    NOT INSTALLED — run: make install"; \
	fi

## uninstall: remove the installed binary (deletes ./.grok)
uninstall:
	@rm -rf "$(REPO)/.grok" && echo "Removed $(REPO)/.grok"

## clean: alias for uninstall
clean: uninstall

# Internal: fail early with a friendly message if grok isn't installed.
guard:
	@if [ ! -x "$(GROK)" ]; then \
	  echo "grok is not installed. Run: make install"; exit 1; \
	fi

## help: list available targets
help:
	@echo "Grok Build deployment — make targets:"; echo; \
	grep -hE '^## [a-z]' $(MAKEFILE_LIST) \
	  | sed -E 's/^## ([a-z-]+): /\1|/' \
	  | awk -F'|' '{printf "  \033[36m%-16s\033[0m %s\n", $$1, $$2}'; \
	echo; echo "Vars:  VERSION=$(VERSION) (pinned in this Makefile)   CHANNEL=$(CHANNEL)"; \
	echo "       GROK_OLLAMA_MODEL=gemma4:12b  GROK_OLLAMA_CTX=32768   (for make ollama)"

.PHONY: bootstrap preflight install update run login version help-grok doctor \
        uninstall clean guard help \
        ollama ollama-models ollama-test ollama-doctor ollama-uninstall
