PREFIX ?= $(HOME)/.local
BIN     = $(PREFIX)/bin

.PHONY: help install uninstall test lint

help:
	@echo "make install     symlink backup-wp into $(BIN)"
	@echo "make uninstall   remove that symlink"
	@echo "make test        run the offline test suite"
	@echo "make lint        run shellcheck"
	@echo ""
	@echo "override the location with:  make install PREFIX=/usr/local"

install:
	@mkdir -p "$(BIN)"
	@ln -sfn "$(CURDIR)/backup-wp" "$(BIN)/backup-wp"
	@echo "linked $(BIN)/backup-wp -> $(CURDIR)/backup-wp"
	@printf '%s' "$$PATH" | tr ':' '\n' | grep -qx "$(BIN)" \
		|| echo "note: $(BIN) is not on your PATH"

uninstall:
	@rm -f "$(BIN)/backup-wp"
	@echo "removed $(BIN)/backup-wp"

test:
	@bash test/run-tests.sh

lint:
	@command -v shellcheck >/dev/null \
		|| { echo "shellcheck not installed (brew install shellcheck)"; exit 1; }
	@shellcheck -S warning backup-wp test/run-tests.sh && echo "shellcheck: clean"
