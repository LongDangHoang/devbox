PKG := $(shell sed -n 's/^packages = \["src\/\(.*\)"\]/\1/p' pyproject.toml)
CONFIGS ?= $(wildcard experiments/*.yml)

.PHONY: setup check

setup:
	test -f uv.lock || uv lock
	uv sync
	@if [ -d .git ]; then printf '#!/bin/sh\nexec make check\n' > .git/hooks/pre-push && chmod +x .git/hooks/pre-push && echo "installed pre-push hook"; fi

check:
	uv run ruff check .
	uv run ruff format --check .
	uv run pyright
	uv run pytest -q
	for c in $(CONFIGS); do echo "smoke $$c"; uv run python -m $(PKG) --config $$c --smoke || exit 1; done
