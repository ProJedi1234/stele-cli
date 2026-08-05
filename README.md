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
host (e.g. https://stele.example.com): https://stele.example.com
token for https://stele.example.com:
authenticated as claude-code on https://stele.example.com — scopes: publish
stored 0600 in ~/.config/stele/credentials.json

$ stele publish report.html
https://stele.example.com/quiet-cedar-otter

$ stele publish report.html --slug q3-report
https://stele.example.com/q3-report

$ stele update q3-report report.html
https://stele.example.com/q3-report

$ stele auth status
host       https://stele.example.com
client     claude-code
scopes     publish
expires    never
last used  2026-08-04 10:31
state      active
credential ~/.config/stele/credentials.json
```

Only the URL, the JSON and the skill document go to stdout. Prompts, warnings and errors go to
stderr, so `url=$(stele publish page.html)` captures a URL and `stele skill | less` pages a
document.

## Commands

| Command | Who runs it | Does |
| --- | --- | --- |
| `stele auth login [--host <url>]` | human, once | Prompts for the token on a TTY, verifies it against the server, writes the credential `0600`. |
| `stele auth status` | agent or human | Host, client name, scopes, expiry — never the token. |
| `stele auth logout` | human | Forgets the local credential. Does not revoke it. |
| `stele publish <file> [--slug <name>]` | agent | `POST /pages`. Prints the URL and nothing else. |
| `stele update <slug> <file>` | agent | `PUT /pages/:slug`. Never creates. |
| `stele skill` | agent | Proxies `GET /skill`, so the binary keeps zero copies of the contract. |
| `stele admin clients create <name>` | operator | Mints a credential and prints the token **once**. `--scopes`, `--expires-in 90d`. |
| `stele admin clients list` | operator | Names, scopes, last use, revocation state. |
| `stele admin clients revoke <name>` | operator | Stops a credential working, keeping its record. |

Every command takes `--host` and `--json`. Styling is a presentation layer only; the core
operations in `SteleKit` return plain data and print nothing, which is what makes `--json` a
rendering choice rather than a second code path — and JSON output is never styled, because it is
a machine contract.

## Exit codes

The primary reader of this tool is an agent, and an agent branches on `$?` before it reads
prose. So outcomes with different next steps get different codes; `stele --help` prints the same
table.

| | |
| --- | --- |
| 0 | success |
| 1 | failed — read the message, fix the input, do not retry |
| 2 | no usable credential here — ask the user to run `stele auth login` |
| 3 | the server rejected the credential — ask the user to log in again |
| 4 | valid credential, insufficient scope — an operator has to run this |
| 5 | that slug is taken — choose another `--slug` or omit it |
| 6 | the page is too large or the wrong type |
| 7 | no such page or client |
| 8 | the CLI is too old — reinstall it and retry once |
| 9 | could not reach the server — retryable |
| 10 | the server failed — retry once, then stop |

```
$ stele publish report.html --slug q3-report
Error: that slug is already taken: slug 'q3-report' is in use. Choose another `--slug`, or omit
it and let the server generate one.
$ echo $?
5
```

Code 8 is the version gate: the CLI sends `User-Agent: stele-cli/<version>` on every request and
a server whose `minimumCLIVersion` is higher answers `426`. The remedy is printed with the
error — `make -C ~/repos/stele-cli install`, then retry once.

## Configuration

**There are no environment variables.** Not one, and there is no `STELE_TOKEN` escape hatch for
CI either: an env-var fallback would reopen the exact hole this tool closes, and it would get
used, because it is easier. The credential file is the only configuration this program has, and
whatever an env var would have answered, it answers instead.

`~/.config/stele/credentials.json`, keyed by host so one file can hold several deployments:

```json
{
  "default": "https://stele.example.com",
  "https://stele.example.com": { "client": "claude-code", "token": "stele_pat_…" }
}
```

Host selection is the case that matters. `stele auth login --host <url>` records the host it
authenticated against; commands use it implicitly when the file holds exactly one, the `default`
key breaks the tie when it holds several, and `--host` overrides per invocation. Nothing is
guessed: several hosts with no default is an error naming them, because a `stele publish` whose
destination depends on something invisible is worse than one that stops and asks.

There is deliberately no `XDG_CONFIG_HOME` support. "This program reads no environment
variables" is a claim worth being able to make without an asterisk, and a relocatable credential
path is also a way to point an agent at a file the user did not write.

Three rules make the custody boundary real:

- **The token is never an argument.** `auth login` reads it from a TTY, because argv is visible
  in `ps` and lands in shell history — and shell history is something an agent reads. There is
  no `--token` flag to reach for, and a non-TTY stdin is refused rather than read: `echo $TOKEN |
  stele auth login` would put the credential straight back into the environment and the history
  this design removes it from.
- **Loose permissions are refused.** A group- or world-readable credential file is an error, the
  way `ssh` treats a private key, not a warning to proceed past — and the check runs on every
  load, not only at login, because a `chmod` afterwards is exactly the accident it is here for.
- **No subcommand ever prints the token**, including `auth status`, including `--json`, and
  including error paths. A 401 says the credential was rejected, not which credential. This is
  enforced by access control rather than by care: `Token`'s plaintext accessors are `internal`
  to `SteleKit`, so the executable — which is where every `print` lives — has no expression that
  yields it.

  The one exception is `admin clients create`, which must print the token it just minted because
  the server keeps only a SHA-256 and cannot reissue it. That path goes through `MintedToken`, a
  separate type whose `.secret` is the library's only public accessor, spelled out at the call
  site so it is the line a reviewer stops on. It is in the `--json` payload too — omitting it
  there would make `--json` a quiet way to lose a credential you just created.

This stops *accidental* exposure — echoed commands, transcripts, a token pasted into a page —
which is where essentially every real leak comes from. It does not stop an agent that decides to
`cat` the file, and it is not sold as doing so.

## Build

Same three commands the server's skill document gives an agent that finds `stele` missing:

```sh
git clone git@github.com:ProJedi1234/stele-cli.git ~/repos/stele-cli
make -C ~/repos/stele-cli install                # builds release, installs to ~/.local/bin
make -C ~/repos/stele-cli install-completions    # optional, zsh only
```

Requires Swift 6.0+. Builds and runs on Linux and macOS. `PREFIX ?= ~/.local`, so
`make install PREFIX=/usr/local` puts it elsewhere. The install writes to a temporary name and
renames over the target, because writing over a binary that is currently executing fails with
`ETXTBSY` and `rename(2)` does not — a second agent mid-publish must not be able to fail your
reinstall.

By hand, if you would rather not use `make`:

```sh
swift build -c release
install -m 755 .build/release/stele ~/.local/bin/stele
```

Two traps worth naming, because neither error message points at its cause:

- `~/.local/bin` has to be on `PATH`, or the freshly installed binary is invisible and
  `stele auth status` reports "command not found" on a machine that has it.
- On a swiftly-managed toolchain, `swift build` in a **non-interactive** shell needs
  `LD_LIBRARY_PATH=~/.local/share/swiftly/compat-lib`. The `.zshrc` sets it, but a process
  shelling out non-interactively does not inherit that, and the build fails with a linker error
  that looks nothing like a missing environment variable.

## Shell completion

```sh
make install-completions   # writes _stele to oh-my-zsh's custom/completions, or ~/.zfunc
```

`~/.zfunc` needs `fpath=(~/.zfunc $fpath)` in `.zshrc` before `compinit`; oh-my-zsh's
`custom/completions` is already on `fpath` and needs no edit. `make install-completions` removes
`~/.zcompdump*` afterwards, which is what makes the new completions appear without a manual cache
purge. `stele --generate-completion-script {zsh,bash,fish}` emits the script directly if you
install it elsewhere.

Stored hosts are completed by calling the installed binary back at TAB time, so `--host <TAB>`
offers the deployments this machine actually holds a credential for. Only the command tree is
baked into the generated script, so it needs regenerating when commands or flags change — not
when your hosts or credentials do.

## Tests

```sh
swift test
```

Everything with a decision in it lives in `SteleKit` as a pure function taking its world as a
parameter — the home directory into `CredentialStore`, the transport into `SteleClient` — so the
suite covers the credential file's permissions and host resolution, the request each command
builds, the status-code vocabulary, and the promise the whole project rests on: that no
rendering of a credential, and no case of any error type, can be made to print a token.
