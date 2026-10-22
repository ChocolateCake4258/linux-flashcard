SHELL := /bin/bash
PYTHON ?= python3
OUTPUT ?= /tmp/linux-flashcard-release

.PHONY: help check test lint release

help:
	@echo "make check   - source/encoding checks and Python regression tests"
	@echo "make lint    - ShellCheck for guest scripts (severity=error)"
	@echo "make release OUTPUT=/path/out - verified Windows download ZIP"
	@echo "Windows user: download the release, extract it, open START.bat"

check:
	$(PYTHON) -B tools/check-source.py
	$(MAKE) test

test:
	$(PYTHON) -B -m unittest discover -s win/tests -p 'test_*.py' -v

lint:
	@command -v shellcheck >/dev/null || { echo "Install ShellCheck to run make lint"; exit 1; }
	@bash -c 'set -e; while IFS= read -r -d "" script; do [[ -f "$$script" ]] || continue; shellcheck --severity=error -x "$$script"; done < <(git ls-files -z --cached --others --exclude-standard -- "*.sh")'

release:
	$(PYTHON) -B tools/make-public-download.py --output "$(OUTPUT)" --version "$$(tr -d '\r\n' < VERSION)"
