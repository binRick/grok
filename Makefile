# Grok Build — repo-local deployment wrapper.
# All targets operate on the copy of grok installed under ./.grok/ by install.sh.
# Nothing here touches your $HOME, PATH, or shell rc files.

SHELL := /bin/bash
REPO  := $(patsubst %/,%,$(dir $(abspath $(lastword $(MAKEFILE_LIST)))))
GROK  := $(REPO)/.grok/bin/grok

# Overridable:  make install VERSION=0.2.107 CHANNEL=alpha
CHANNEL ?= stable
VERSION ?=

.DEFAULT_GOAL := help

## install: download + install the grok binary into ./.grok/bin (idempotent)
install:
	@GROK_CHANNEL=$(CHANNEL) ./install.sh $(VERSION)

## update: re-fetch and install the latest version on $(CHANNEL)
update:
	@GROK_CHANNEL=$(CHANNEL) ./install.sh $(VERSION)

## run: launch the interactive Grok TUI in the current directory
run: guard
	@exec "$(GROK)"

## login: authenticate with your xAI account (opens a browser)
login: guard
	@"$(GROK)" login

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
	  | awk -F'|' '{printf "  \033[36m%-12s\033[0m %s\n", $$1, $$2}'; \
	echo; echo "Vars:  CHANNEL=stable|alpha   VERSION=X.Y.Z   (e.g. make install CHANNEL=alpha)"

.PHONY: install update run login version help-grok doctor uninstall clean guard help
