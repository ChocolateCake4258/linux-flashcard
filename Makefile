# Обёртка над bash-скриптами сборки кастомного ISO Kubuntu.
# Использование: make prepare | make iso | make clean | make lint | make publish

SHELL := /bin/bash

.PHONY: prepare iso clean lint check publish help

help:
	@echo "Цели:"
	@echo "  make prepare  — установить утилиты сборки на хост (sudo)"
	@echo "  make iso      — собрать custom-kubuntu.iso (основной процесс)"
	@echo "  make clean    — удалить временные папки (ISO и результат сохраняются)"
	@echo "  make lint     — статическая проверка bash-скриптов (bash -n)"
	@echo "  make publish  — загрузить собранный ISO в GitHub Release (gh, необязательно)"

prepare:
	./prepare.sh

iso:
	./build.sh

clean:
	./cleanup.sh

lint:
	@set -e; for f in ./build.sh ./cleanup.sh ./config.sh ./prepare.sh ./install-chroot.sh ./lib/common.sh; do \
		bash -n "$$f" && echo "ok: $$f"; done

publish:
	@test -f custom-kubuntu.iso || { echo "Сначала: make iso"; exit 1; }
	@command -v gh >/dev/null || { echo "Нужен gh: https://cli.github.com/"; exit 1; }
	@echo "Загрузка custom-kubuntu.iso и .sha256 в релиз 'nightly'..."
	gh release upload nightly custom-kubuntu.iso custom-kubuntu.iso.sha256 --clobber