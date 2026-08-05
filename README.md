# stele

Publish HTML pages to a [stele](https://github.com/ProJedi1234/stele-pages) server and get a
readable three-word URL back.

**The point of this tool is custody, not ergonomics.** Every writer used to share one bearer
token, and an agent that publishes pages had to hold it — a secret in the same context window as
a document about to go up at a guessable URL. Here the token lives in a `0600` file that
`stele auth login` writes once, from a TTY. The agent runs `stele publish page.html` and never
sees it.

```
$ stele auth login
token: (not echoed)
authenticated as claude-code on https://stele.example.com — scopes: publish

$ stele publish page.html
https://stele.example.com/quiet-cedar-otter
```

## Commands

Scaffolding only so far — the command tree lands in later commits. See the implementation plan
for the intended shape (`auth login/status/logout`, `publish`, `update`, `skill`, and
`admin clients` for the operator).

Every command takes `--json` and emits the same models. Styling is a presentation layer only;
the core operations return plain data and print nothing.

## Credentials

`~/.config/stele/credentials.json`, keyed by host so one file can hold several deployments.
Three rules make the custody boundary real:

- **The token is never an argument.** `auth login` reads it from a TTY, because argv is visible
  in `ps` and lands in shell history — and shell history is something an agent reads.
- **Loose permissions are refused.** A group- or world-readable credential file is an error, the
  way `ssh` treats a private key, not a warning to proceed past.
- **No subcommand ever prints the token**, including `auth status` and including error paths. A
  401 says the credential was rejected, not which credential.

This stops *accidental* exposure — echoed commands, transcripts, a token pasted into a page —
which is where essentially every real leak comes from. It does not stop an agent that decides to
`cat` the file, and it is not sold as doing so.

## Configuration

There are no environment variables, deliberately, and no `STELE_TOKEN` escape hatch for CI: an
env-var fallback would reopen the exact hole this closes, and it would get used, because it is
easier. Everything an env var would have answered, the credential file answers instead.

Host selection is the case that matters. `stele auth login --host <url>` records the host it
authenticated against; commands use it implicitly when the file holds exactly one, a `default`
key breaks the tie when it holds several, and `--host` overrides per invocation.

## Build

```sh
swift build -c release
install -m 755 .build/release/stele ~/.local/bin/stele
```

or, which also handles reinstalling over a copy that is currently running:

```sh
make install     # PREFIX ?= ~/.local
```

Requires Swift 6.0+. Builds and runs on Linux and macOS.

Two traps worth naming, because neither error message points at its cause:

- `~/.local/bin` has to be on `PATH`, or the freshly installed binary is invisible.
- On a swiftly-managed toolchain, `swift build` in a **non-interactive** shell needs
  `LD_LIBRARY_PATH=~/.local/share/swiftly/compat-lib`. The `.zshrc` sets it, but a process
  shelling out non-interactively does not inherit that, and the build fails with a linker error
  that looks nothing like a missing environment variable.

## Shell completion

```sh
make install-completions   # writes _stele to oh-my-zsh's custom/completions, or ~/.zfunc
```

Only the command tree is baked into the generated script, so it needs regenerating when commands
or flags change — not when your hosts or credentials do.

`~/.zfunc` needs `fpath=(~/.zfunc $fpath)` in `.zshrc` before `compinit`; oh-my-zsh's
`custom/completions` is already on `fpath` and needs no edit. `make install-completions` removes
`~/.zcompdump*` afterwards, which is what makes the new completions appear without a manual cache
purge. `stele --generate-completion-script {zsh,bash,fish}` emits the script directly if you
install it elsewhere.
