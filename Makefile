PREFIX ?= $(HOME)/.local
BIN    := $(PREFIX)/bin/stele
BUILT  := .build/release/stele

# oh-my-zsh puts custom/completions on fpath whether or not it exists, so when oh-my-zsh is
# installed we can create that directory and need no .zshrc edit. Test for ~/.oh-my-zsh, not
# for the completions dir itself — the latter is usually absent until something writes to it.
# The fallback, ~/.zfunc, does need `fpath=(~/.zfunc $fpath)` before compinit.
ZSHCOMP ?= $(if $(wildcard $(HOME)/.oh-my-zsh),$(HOME)/.oh-my-zsh/custom/completions,$(HOME)/.zfunc)

.PHONY: build test install install-completions uninstall clean

build:
	swift build -c release

test:
	swift test

# install to a temp name and rename: writing over a binary that is currently
# executing fails with ETXTBSY, but rename is atomic and always works. This matters more
# here than for a single-user tool — agents run `stele publish` unattended, so a reinstall
# can land while another invocation is mid-request, and the failure would surface as a
# broken install with no obvious cause.
install: build
	@mkdir -p $(PREFIX)/bin
	@install -m 755 $(BUILT) $(BIN).new
	@mv -f $(BIN).new $(BIN)
	@echo "installed stele $$($(BIN) --version) -> $(BIN)"

# Only the command tree is baked into this script; anything completed from live data is
# completed by calling the installed binary back at TAB time. So this needs rerunning when
# commands or flags change, not when your credentials or hosts do.
install-completions: install
	@mkdir -p $(ZSHCOMP)
	@$(BIN) --generate-completion-script zsh > $(ZSHCOMP)/_stele
	@rm -f $(HOME)/.zcompdump*
	@echo "installed completions -> $(ZSHCOMP)/_stele (restart zsh)"

uninstall:
	rm -f $(BIN) $(ZSHCOMP)/_stele

clean:
	swift package clean
