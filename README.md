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
expires 2026-08-11 10:31

$ stele publish report.html --slug q3-report --ttl never
https://stele.example.com/q3-report
kept until deleted

$ stele update q3-report report.html
https://stele.example.com/q3-report
kept until deleted

$ stele amend q3-report --slug q3-final
https://stele.example.com/q3-final
kept until deleted

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
document. The deadline under the URL is on stderr for that reason, and it is printed at all
because the server's default is *ephemeral* — a page published with no `--ttl` is eventually
unpublished, and a caller handed only a URL would find that out when the link broke.

## Commands

| Command | Who runs it | Does |
| --- | --- | --- |
| `stele auth login [--host <url>] [--admin]` | human, once | Prompts for the token on a TTY, verifies it, writes the credential `0600`. An operator token is *spent*, not stored — see below. |
| `stele auth status` | agent or human | Host, client name, scopes, expiry — never the token. |
| `stele auth logout` | human | Forgets the local credential. Does not revoke it. |
| `stele publish <file> [--slug <name>] [--ttl <days>]` | agent | `POST /pages`. Prints the URL on stdout and the page's deadline on stderr. |
| `stele update <slug> <file>` | agent | `PUT /pages/:slug`. Never creates, and never changes the deadline. |
| `stele amend <slug> [--slug <name>] [--ttl <days>]` | agent | `PATCH /pages/:slug`. Renames a page, moves its deadline, or both, without touching a byte of it. A rename is a hard move — the old URL starts 404ing at once. |
| `stele delete <slug>` | agent | `DELETE /pages/:slug`. Permanent and immediate — the slug is freed and returns to the pool, so every link to it breaks. Prints nothing on stdout; the confirmation is on stderr. |
| `stele skill` | agent | Proxies `GET /skill`, so the binary keeps zero copies of the contract. |
| `stele admin clients create <name>` | operator | Mints a credential and prints the token **once**. `--scopes`, `--expires-in 90d`. |
| `stele admin clients list` | operator | Names, scopes, last use, revocation state. |
| `stele admin clients revoke <name>` | operator | Stops a credential working, keeping its record. |

Every command takes `--host` and `--json`. Styling is a presentation layer only; the core
operations in `SteleKit` return plain data and print nothing, which is what makes `--json` a
rendering choice rather than a second code path — and JSON output is never styled, because it is
a machine contract.

## Getting a credential onto a machine

An `admin` token is not a credential to keep. It is the one thing that can mint credentials, and
on this server it cannot even publish — `admin` and `publish` are disjoint, so a machine holding
the operator token can revoke every credential on the deployment and cannot upload a page.

So `stele auth login` spends it. Paste an operator token and it mints a publish-only credential
named after the machine, stores *that*, and never writes what you pasted to disk:

```
$ stele auth login
host (e.g. https://stele.example.com): https://stele.example.com
token for https://stele.example.com:
that is https://stele.example.com's bootstrap token (shared-upload-token). It is configuration
rather than a credential — it stops working when the deployment is redeployed — and it carries
`admin`, so storing it here would let anything on this machine mint and revoke credentials.
Minting a publish-only credential for this machine instead. Pass --admin to store the operator
credential as it stands.
name for this machine [argos]:
authenticated as argos on https://stele.example.com — scopes: publish
stored 0600 in ~/.config/stele/credentials.json
the admin token was not written to disk.
```

A publish-only token takes the path it always took: verified, stored, nothing else said.

If the name is already live the credential is not silently replaced — rotating one is
revoke-then-mint under the same name, which destroys whatever is publishing under it today, so
it asks:

```
name for this machine [argos]:
a credential named argos is already live on https://stele.example.com (created 2026-06-02, last
used 2026-08-04).
revoke it and mint a replacement? [y/N]
```

Declining asks for another name instead.

`--admin` stores the operator token as it stands, which is what the workstation you administer
the deployment from wants. The credential file holds one credential per host, so that machine
holds `admin` *instead of* `publish` and `stele publish` stops working on it.

`stele admin clients create` is unchanged and still the way to provision a machine you are not
sitting at, or to mint a credential with a non-default scope or lifetime. What changed is that
it is no longer the only way — and the common case, a machine credentialling itself, no longer
routes a shown-once secret through a second terminal.

One trade this makes deliberately: the operator token now gets typed at a TTY on the machine
being provisioned, rather than never leaving the workstation. It is read with echo off, used for
one request and never written down — but it is a real exposure, and `admin clients create`
remains available for anyone who would rather carry the minted token instead.

## Page lifetimes

Pages are ephemeral by default. `--ttl` says otherwise:

| `--ttl` | Means |
| --- | --- |
| omitted | on `publish`, the server's default lifetime, a matter of days; on `amend`, the deadline already in force |
| `30`, `30d` | thirty days |
| `2w` | fourteen days |
| `never` | kept until you delete it |

Two asymmetries shape the rules here. The first is why the default is ephemeral at all: a page
that outlives its purpose fails quietly and forever, while one that expires too early fails
loudly to somebody who can republish it. The second is why nothing is ever rounded — a lifetime
finer than a day, like `12h`, is refused rather than quietly turned into `1d`, because the
failure mode of guessing is a link that dies on a schedule nobody typed.

The maximum is deliberately *not* enforced here. That bound belongs to the server's
`PageLifetime`, the same way the slug rules belong to its `Slug`; a copy in this repository
would be a second source of truth that drifts silently the day the server moves it, and the
`400` it earns names the real limit. What this side checks is only what the server cannot: that
you wrote something meaning a number of days, and that turning it into one does not overflow.

A deadline is fixed for a page's *body*, not for the page. `stele update` still has no `--ttl` —
replacing a body cannot buy the link another week, and a lifetime quietly reset by every edit
would be a deadline nobody could predict — and the server still answers `?ttl=` on `PUT` with a
`400` rather than a `200` that silently ignored it. That refusal is not a gap waiting to be
filled; it is the rule that a replacement cannot retime a page. Moving a deadline is a separate
act, and `stele amend --ttl` is the one thing that performs it.

Two things about it want knowing before you type it. An omitted `--ttl` on `amend` means *leave
the deadline exactly where it is* — not "apply the default", which is what omitting it on
`publish` means. The two commands read the same absence in opposite directions deliberately, and
the direction here is the safe one: the alternative is a `--slug` rename that also, silently,
puts a week's deadline on a page somebody published to keep. And the lifetime you do pass is
counted from the moment of the request rather than from publication, so `--ttl 30` on a page
published three weeks ago grants thirty fresh days rather than the nine that were left of them.
It is a new lease, not an adjustment to the old one.

The deadline itself is always read off the response, never computed here: the server resolves it
against *its* clock at the moment of the upload, applies its own default when you say nothing,
and on `update` reports the deadline the page already had — a date this side never knew. `amend`
is no different: what comes back is the deadline now in force, whether you moved it or left it
alone, and it is the only honest answer to what happened, because only the server's clock knows
when "thirty days from now" lands.

## What a rename costs

A lifetime is one way a link you handed somebody stops working. `stele amend --slug` is the
other, and it is the faster one, so it gets said plainly: a rename is a hard move. The old name
is freed the instant the rename commits. There is no redirect, no tombstone, nothing recording
that the page was ever called that — the old URL begins serving the ordinary `404`, the same
bytes a slug nobody has ever used gets, and the name goes straight back in the pool for the next
`--slug` anybody asks for. A rename is not a forwarding address. It is a deletion and a
publication that happen to preserve the contents.

Which makes the question to ask beforehand not "would a better name be nice" but "who already
has the old one". A URL that has not left your terminal renames freely, and that is the case
`amend` is for: the generated three-word slug you have decided to replace before sending it
anywhere. A URL already sitting in somebody's inbox is a different matter — renaming it breaks
it for them, with no notice and no trail back. The tool for changing what a circulated link says
is `stele update`, which replaces the contents and leaves the address alone. That is the whole
division of labour between the two: `update` keeps the URL and replaces the page, `amend` keeps
the page and replaces the URL.

Everything an amendment is not asked to change survives it, including the record of which
credential published the page. That is deliberate rather than an oversight: the column names who
wrote the bytes, and an amendment writes none — so renaming somebody's page cannot make it look
like yours.

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
| 5 | that slug is taken — ask for a different `--slug` |
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

The message carries the remedy the *route* has, which is why the table above does not. Dropping
`--slug` is an escape `publish` offers and `amend` does not: there it means "do not rename", the
server allocates nothing, and an amendment asking for neither a name nor a deadline is refused
before it is sent. A 5 from `stele amend` means pick a different name or leave the page where it
is.

Code 8 is the version gate: the CLI sends `User-Agent: stele-cli/<version>` on every request and
a server whose `minimumCLIVersion` is higher answers `426`. The remedy is printed with the
error — `make -C ~/repos/stele-cli install`, then retry once.

## Configuration

**No environment variable configures the credential, the token or the host.** Not one, and there
is no `STELE_TOKEN` escape hatch for CI either: an env-var fallback would reopen the exact hole
this tool closes, and it would get used, because it is easier. The credential file is the only
configuration this program has, and whatever an env var would have answered, it answers instead.

The claim is that precise because it is the checkable one. The program does read the
environment, in two places that could not carry a secret if they tried: `NO_COLOR`, `TERM` and
`COLORTERM` decide whether output is styled, and `SAP_SHELL` tells the completion generator which
shell asked. Neither names a host, and neither can supply a token. "There are no environment
variables" would be a tidier sentence and a false one, and a security claim that is false in a
detail is one a reader is right to stop trusting in general.

**`HOME` is not one of them, which is worth stating because it is the natural guess.** The
credential file's directory comes from `NSHomeDirectory()`, and on Linux — the platform the
agents run on — that resolves through the passwd database (`getpwuid(getuid())->pw_dir`) rather
than reading `$HOME`. Checked, not assumed: `HOME=/tmp/elsewhere stele auth status --json` still
reports the real user's path in `credentialFile`. So there is no environment variable anywhere
that relocates the credential — a stronger property than the one a reader would assume, with one
practical consequence worth knowing before it surprises you: a script cannot sandbox this program
into a temp home. Anything needing to run against a scratch credential has to move the real file
aside and put it back, which is exactly what `scripts/integration-smoke.sh` does.

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

There is deliberately no `XDG_CONFIG_HOME` support, and — per the note above — no `HOME` support
either. A variable that *relocates* the credential file is a way to point an agent at a
credential the user did not write, and it turns "where is my credential?" into a question with an
invisible answer. The file is where the user's account says it is, and nothing in the environment
moves it.

Four rules make the custody boundary real:

- **The token is never an argument.** `auth login` reads it from a TTY, because argv is visible
  in `ps` and lands in shell history — and shell history is something an agent reads. There is
  no `--token` flag to reach for, and a non-TTY stdin is refused rather than read: `echo $TOKEN |
  stele auth login` would put the credential straight back into the environment and the history
  this design removes it from.
- **Loose permissions are refused.** A group- or world-readable credential file is an error, the
  way `ssh` treats a private key, not a warning to proceed past — and the check runs on every
  load, not only at login, because a `chmod` afterwards is exactly the accident it is here for.
- **The token only ever goes to the host it was filed under.** Not just in how the URL is built:
  `URLSession` follows redirects by itself and copies the `Authorization` header onto the
  redirected request, so a server that can answer for the configured host could collect the
  credential by replying `302 Location: http://somewhere-else/` while the caller saw an ordinary
  success. The transport installs a redirect policy that follows a 3xx only within the same
  scheme, host and port, and reports anything else as a refusal instead of following it.
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

The one exception is the redirect policy, which is a decision `URLSession` makes rather than one
this code makes — a fake transport would test the seam and not the thing. So those tests stand up
two real HTTP servers on loopback ports and assert that the one the credential was *not* filed
under never sees a byte of it, while a redirect within a single origin is still followed.

### The integration smoke test

`swift test` cannot catch a disagreement with the server, and this is not a hypothetical: every
assertion in it runs against a `FakeTransport` whose expectations were written from *this*
repository's code. A field name spelled differently from the server's is therefore wrong in the
client and wrong in the test that checks the client, and both halves agree with each other all
the way to the first live request. That is how four contract breaks once shipped with two green
suites — including a `--expires-in` that travelled under a key the server ignored, earning a
cheerful `201` and a credential that never expired.

The fix is the one thing no unit test can do: drive the real binary against a real server.

```sh
scripts/integration-smoke.sh --host http://127.0.0.1:8099 --token "$TEST_TOKEN"
```

It boots nothing — point it at a server that is already running and give it that deployment's
`STELE_UPLOAD_TOKEN`, which is the documented bootstrap credential and the only thing that can
mint the first client. Arguments may also arrive as `STELE_SMOKE_HOST`, `STELE_SMOKE_TOKEN`,
`STELE_BIN` and `STELE_SMOKE_PSQL`.

| Flag | | |
| --- | --- | --- |
| `--host <url>` | required | The server under test. |
| `--token <value>` | required | Its `STELE_UPLOAD_TOKEN`. **A test-run token, never a real one.** |
| `--bin <path>` | optional | The binary to drive; defaults to `stele` on `PATH`. Use `.build/release/stele` to test what you just built rather than what is installed. |
| `--psql <command>` | optional | A command that reaches the server's database, e.g. `docker exec stele-postgres psql -U stele -d stele_smoke`. Only the attribution check needs it, because no route reports who wrote a page — without it that one check prints `skip`. |

It walks the whole documented lifecycle — mint, log in, `auth status`, publish, fetch the bytes
back and compare them, update, amend, `--expires-in` there *and* back, expiry actually enforced,
a publish-only credential answered `200` by whoami and `403` by the admin routes, revocation that
really stops working, the exit-code vocabulary, the version gate, and the byte-identity of every
`404`. It prints each check, stops at the first failure, and exits non-zero.

The amend leg is the one worth naming, because most of what it asserts cannot be seen from
inside this repository: that a rename really does free the old name at once — the old URL 404s
in the same breath, and the name is claimable again — that the contents and the content type
come through the move untouched, and above all that a rename with no `--ttl` leaves the deadline
exactly where it was. That last check is run against a page published `--ttl never`, so a client
that helpfully sent a default lifetime would show up as a permanent page with a week to live.
It also pins the refusals: exit 5 for a name another live page holds, exit 7 for a slug with no
live page behind it, and exit 1 for an amendment that named nothing to amend — that one with the
credential file moved aside, which is how the script proves the refusal happened before anything
was sent.

Two things it does not do, stated because a canary you trust wrongly is worse than none:

- **It cannot drive `stele auth login` interactively.** That command demands a TTY by design and
  refuses a pipe; the script asserts the *refusal* — which is the load-bearing custody rule — and
  then seeds the credential file at `0600` in the documented format for the rest of the run. The
  prompt, the echo-off read and the verify-before-write are not covered.
- **It leaves litter.** The server has a delete route but this CLI ships no command that reaches
  it, so each run leaves eight pages and three
  credential rows behind; it revokes every credential it mints, but a revoked row is still a row.
  Five of those pages expire on their own — the lifetime checks publish several deliberately —
  but three were published or amended to `--ttl never` and will still be there next year. The
  footer names those three, since they are the only ones a human ever has to clean up. Run it
  against a throwaway deployment, never against production.

It also moves `~/.config/stele/credentials.json` aside and restores it on every exit path,
including a failed check — see the `HOME` note under Configuration for why it cannot simply use a
temp directory instead.
