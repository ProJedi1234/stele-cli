# justfile — build, test and install the stele CLI. `just` on its own lists them.
#
# Every recipe is a thin wrapper over `swift` or `install`; there is no build logic
# here that Package.swift does not already own.

set shell := ["bash", "-uc"]

prefix := env('PREFIX', home_directory() / ".local")
bin    := prefix / "bin" / "stele"
built  := ".build" / "release" / "stele"

# oh-my-zsh puts custom/completions on fpath whether or not it exists, so when oh-my-zsh is
# installed we can create that directory and need no .zshrc edit. Test for ~/.oh-my-zsh, not
# for the completions dir itself — the latter is usually absent until something writes to it.
# The fallback, ~/.zfunc, does need `fpath=(~/.zfunc $fpath)` before compinit.
zshcomp := env('ZSHCOMP', if path_exists(home_directory() / ".oh-my-zsh") == "true" {
    home_directory() / ".oh-my-zsh" / "custom" / "completions"
} else {
    home_directory() / ".zfunc"
})

[private]
default:
    @just --list --unsorted

# Release build.
build:
    swift build -c release

# The unit suite. The integration smoke test is scripts/integration-smoke.sh — see README.
test:
    swift test

# Installs to a temp name and renames: writing over a binary that is currently executing
# fails with ETXTBSY, but rename is atomic and always works. This matters more here than
# for a single-user tool — agents run `stele publish` unattended, so a reinstall can land
# while another invocation is mid-request, and the failure would surface as a broken
# install with no obvious cause.

# Build and install to $PREFIX/bin (default ~/.local/bin).
install: build
    @mkdir -p {{ quote(prefix / "bin") }}
    @install -m 755 {{ quote(built) }} {{ quote(bin + ".new") }}
    @mv -f {{ quote(bin + ".new") }} {{ quote(bin) }}
    @echo "installed stele $({{ quote(bin) }} --version) -> {{bin}}"

# Only the command tree is baked into this script; anything completed from live data is
# completed by calling the installed binary back at TAB time. So this needs rerunning when
# commands or flags change, not when your credentials or hosts do.

# Install the zsh completion script alongside the binary.
install-completions: install
    @mkdir -p {{ quote(zshcomp) }}
    @{{ quote(bin) }} --generate-completion-script zsh > {{ quote(zshcomp / "_stele") }}
    @rm -f {{ quote(home_directory() / ".zcompdump") }}*
    @echo "installed completions -> {{ zshcomp / "_stele" }} (restart zsh)"

# Remove the binary and the completion script.
uninstall:
    rm -f {{ quote(bin) }} {{ quote(zshcomp / "_stele") }}

# Drop the build directory's SwiftPM state.
clean:
    swift package clean
