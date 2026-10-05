PKG := $(shell sed -n 's/^packages = \["src\/\(.*\)"\]/\1/p' pyproject.toml)
CONFIGS ?= $(wildcard experiments/*.yml)

.PHONY: setup check

setup:
	test -f uv.lock || uv lock
	uv sync
	@# --git-path resolves hooks for worktrees and core.hooksPath too
	@if h=$$(git rev-parse --git-path hooks 2>/dev/null); then mkdir -p "$$h" && printf '#!/bin/sh\nexec make check\n' > "$$h/pre-push" && chmod +x "$$h/pre-push" && echo "installed $$h/pre-push"; fi

check:
	uv run ruff check .
	uv run ruff format --check .
	uv run pyright
	uv run pytest -q
	for c in $(CONFIGS); do echo "smoke $$c"; uv run python -m $(PKG) --config $$c --smoke || exit 1; done
