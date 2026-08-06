#!/usr/bin/env bash
#
# integration-smoke.sh — drive the real `stele` binary against a real stele server.
#
# This exists because both repositories once had a green test suite and four broken
# contracts between them. The CLI's own suite asserts against a fake transport whose
# expectations were derived from the CLI's code rather than from the server's routes,
# so a field name that disagreed with the server passed every test in this repo and
# failed on the first live request. Nothing but a real server can catch that class of
# bug, and nothing catches it repeatedly unless it is one command.
#
# It boots nothing. Point it at a server that is already running — a throwaway one —
# and hand it that deployment's STELE_UPLOAD_TOKEN, which is the documented bootstrap
# credential and the only thing that can mint the first client.
#
#   scripts/integration-smoke.sh --host http://127.0.0.1:8099 --token "$TEST_TOKEN"
#   STELE_SMOKE_HOST=… STELE_SMOKE_TOKEN=… scripts/integration-smoke.sh
#
# NEVER point it at production and never hand it a real credential. It mints
# credentials, publishes a page and revokes what it minted; on a production server
# that is real litter with real audit rows behind it.
#
set -uo pipefail

# ---------------------------------------------------------------------------------
# Arguments
# ---------------------------------------------------------------------------------

HOST="${STELE_SMOKE_HOST:-}"
TOKEN="${STELE_SMOKE_TOKEN:-}"
STELE_BIN="${STELE_BIN:-stele}"
# Optional: a command that runs psql against the *server's* database, used only for
# the attribution check, which cannot be made over HTTP — no route reports who wrote
# a page, deliberately. Skipped with a printed SKIP when unset.
#   STELE_SMOKE_PSQL='docker exec stele-postgres psql -U stele -d stele_integration'
PSQL="${STELE_SMOKE_PSQL:-}"

while [ $# -gt 0 ]; do
    case "$1" in
        --host)  HOST="${2:-}"; shift 2 ;;
        --token) TOKEN="${2:-}"; shift 2 ;;
        --bin)   STELE_BIN="${2:-}"; shift 2 ;;
        --psql)  PSQL="${2:-}"; shift 2 ;;
        -h|--help)
            sed -n '2,26p' "$0" | sed 's/^# \{0,1\}//'
            exit 0 ;;
        *) echo "unknown argument: $1" >&2; exit 64 ;;
    esac
done

die() { echo "smoke: $*" >&2; exit 64; }

[ -n "$HOST" ]  || die "no host. Pass --host <url> or set STELE_SMOKE_HOST."
[ -n "$TOKEN" ] || die "no token. Pass --token <value> or set STELE_SMOKE_TOKEN. Use a test-run token, never a real one."
command -v curl    >/dev/null || die "curl is required."
command -v python3 >/dev/null || die "python3 is required (it reads the JSON this script asserts on)."
command -v "$STELE_BIN" >/dev/null || [ -x "$STELE_BIN" ] || die "no stele binary at '$STELE_BIN'. Build it with 'swift build -c release' and pass --bin .build/release/stele."

# Strip a trailing slash so "$HOST/pages" never becomes "//pages".
HOST="${HOST%/}"

# ---------------------------------------------------------------------------------
# Expectation harness — first failure ends the run, non-zero
# ---------------------------------------------------------------------------------

CHECKS=0

pass() { CHECKS=$((CHECKS + 1)); printf '  \033[32mok\033[0m   %s\n' "$1"; }

fail() {
    printf '  \033[31mFAIL\033[0m %s\n' "$1" >&2
    [ $# -gt 1 ] && printf '       expected: %s\n       actual:   %s\n' "$2" "${3:-}" >&2
    printf '\nsmoke: failed after %d passing checks.\n' "$CHECKS" >&2
    exit 1
}

section() { printf '\n\033[1m%s\033[0m\n' "$1"; }

# expect_eq <label> <expected> <actual>
expect_eq() {
    if [ "$2" = "$3" ]; then pass "$1"; else fail "$1" "$2" "$3"; fi
}

# expect_contains <label> <needle> <haystack>
expect_contains() {
    case "$3" in
        *"$2"*) pass "$1" ;;
        *) fail "$1" "output containing '$2'" "$3" ;;
    esac
}

# json_field <file> <dotted.path> — prints the value, or the empty string for null/absent.
# json_key_state <file> <key> -> "absent", "null", or "set".
#
# `json_field` collapses a null and a missing key to the same empty string, and for `expires`
# that is exactly the distinction worth testing: the synthesised `Encodable` would *drop* the
# key for a page that is kept, leaving a reader unable to tell "no deadline" from "this tool
# has no opinion about deadlines". Both ends hand-write an encoder to say null out loud.
json_key_state() {
    python3 - "$1" "$2" <<'PY'
import json, sys
document = json.load(open(sys.argv[1]))
key = sys.argv[2]
print("absent" if key not in document else "null" if document[key] is None else "set")
PY
}

json_field() {
    python3 - "$1" "$2" <<'PY'
import json, sys
node = json.load(open(sys.argv[1]))
for key in sys.argv[2].split('.'):
    if key.lstrip('-').isdigit() and isinstance(node, list):
        node = node[int(key)]
    elif isinstance(node, dict):
        node = node.get(key)
    else:
        node = None
    if node is None:
        print(''); sys.exit(0)
print(node if not isinstance(node, (dict, list)) else json.dumps(node))
PY
}

# json_client_field <file> <client name> <field> — from an `admin clients list --json` array.
json_client_field() {
    python3 - "$1" "$2" "$3" <<'PY'
import json, sys
rows = json.load(open(sys.argv[1]))
for row in rows:
    if row.get('name') == sys.argv[2]:
        value = row.get(sys.argv[3])
        if value is None:
            print('')
        elif isinstance(value, (dict, list)):
            print(json.dumps(value, separators=(',', ':')))
        else:
            print(value)
        sys.exit(0)
print('<no such client>')
PY
}

# Runs the CLI and captures its exit status without tripping `set -e`-style aborts.
# stdout goes to $OUT, stderr to $ERR, status to $STATUS.
#
# The two streams are kept apart rather than merged, because the split is itself a promise this
# tool makes: stdout carries the URL and nothing else, so `url=$(stele publish page.html)`
# works. Merging them here would have hidden a regression that put a second line on stdout.
run_stele() {
    ERR_FILE="$WORK/stderr"
    OUT="$("$STELE_BIN" "$@" --host "$HOST" 2>"$ERR_FILE")"
    STATUS=$?
    ERR="$(cat "$ERR_FILE")"
}

http_status() { curl -sS -o /dev/null -w '%{http_code}' "$@"; }

# ---------------------------------------------------------------------------------
# State this run creates, and the trap that takes it back
# ---------------------------------------------------------------------------------

RUN_ID="$$-$(date +%s)"
OPERATOR="smoke-op-$RUN_ID"
AGENT="smoke-agent-$RUN_ID"
EPHEMERAL="smoke-eph-$RUN_ID"

WORK="$(mktemp -d)"

# The credential file is NOT relocatable: `NSHomeDirectory()` resolves through the
# passwd database and ignores $HOME, so this script cannot sandbox itself into a temp
# home the way a test would. It moves the real file aside and puts it back instead —
# which is also why the trap runs on every exit path including a failed expectation.
CRED_DIR="$(eval echo ~)/.config/stele"
CRED="$CRED_DIR/credentials.json"
CRED_BACKUP="$WORK/credentials.json.backup"
CRED_EXISTED=0
[ -f "$CRED" ] && { cp -p "$CRED" "$CRED_BACKUP"; CRED_EXISTED=1; }

cleanup() {
    local status=$?
    # Revoke every credential this run minted. Best effort: a failed expectation must
    # not be masked by a cleanup error, and an already-revoked name answers 200 anyway.
    for name in "$OPERATOR" "$AGENT" "$EPHEMERAL"; do
        curl -sS -o /dev/null -X DELETE "$HOST/admin/clients/$name" \
            -H "Authorization: Bearer $TOKEN" 2>/dev/null
    done
    if [ "$CRED_EXISTED" = 1 ]; then
        mkdir -p "$CRED_DIR" && cp -p "$CRED_BACKUP" "$CRED" && chmod 600 "$CRED"
    else
        rm -f "$CRED"
        rmdir "$CRED_DIR" 2>/dev/null
    fi
    rm -rf "$WORK"
    return $status
}
trap cleanup EXIT

# Writes the credential file the way `stele auth login` would, at 0600.
#
# `auth login` itself cannot be scripted: it demands a TTY by design and refuses a
# pipe, which check 3.1 asserts rather than works around. The file format is documented
# in the README and is a contract with the user's text editor, so seeding it is the
# supported non-interactive path — but it does mean the interactive half of `auth login`
# (the prompt, the echo-off read, the verify-before-write) is NOT covered here.
seed_credential() {
    mkdir -p "$CRED_DIR" && chmod 700 "$CRED_DIR"
    python3 - "$CRED" "$HOST" "$1" "$2" <<'PY'
import json, os, sys
path, host, client, token = sys.argv[1:5]
fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
with os.fdopen(fd, 'w') as handle:
    json.dump({host: {"client": client, "token": token}}, handle, indent=2)
    handle.write("\n")
PY
    chmod 600 "$CRED"
}

printf '\033[1mstele integration smoke\033[0m\n'
printf 'host   %s\n' "$HOST"
printf 'binary %s (%s)\n' "$STELE_BIN" "$("$STELE_BIN" --version 2>/dev/null || echo '?')"
printf 'run    %s\n' "$RUN_ID"

# ---------------------------------------------------------------------------------
section "1. the server answers, and the shared token mints the first credential"
# ---------------------------------------------------------------------------------

expect_eq "GET /healthz is 200" "200" "$(http_status "$HOST/healthz")"
expect_eq "GET /healthz says ok" "ok" "$(curl -sS "$HOST/healthz")"

curl -sS -o "$WORK/operator.json" -w '%{http_code}' \
    -X POST "$HOST/admin/clients" \
    -H "Authorization: Bearer $TOKEN" \
    -H 'Content-Type: application/json' \
    -d "{\"name\":\"$OPERATOR\",\"scopes\":[\"admin\",\"publish\"]}" > "$WORK/status"
expect_eq "POST /admin/clients with the shared token is 201" "201" "$(cat "$WORK/status")"

OPERATOR_TOKEN="$(json_field "$WORK/operator.json" token)"
case "$OPERATOR_TOKEN" in
    stele_pat_*) pass "the minted token carries the stele_pat_ prefix" ;;
    *) fail "the minted token carries the stele_pat_ prefix" "stele_pat_…" "<a token of ${#OPERATOR_TOKEN} chars>" ;;
esac
expect_eq "the mint response names the credential" "$OPERATOR" "$(json_field "$WORK/operator.json" client.name)"

# The shared token is the operator's, not a publisher's. If this ever answers 201 the
# demotion has been undone and every agent's credential is redundant.
expect_eq "the shared token cannot publish (admin scope only)" "403" \
    "$(http_status -X POST "$HOST/pages" -H "Authorization: Bearer $TOKEN" -H 'Content-Type: text/html' --data '<p>x</p>')"

# ---------------------------------------------------------------------------------
section "2. auth login refuses a pipe, and the credential file is seeded 0600"
# ---------------------------------------------------------------------------------

# The load-bearing custody rule: a token must not be able to arrive through a pipe,
# because that is the environment and the shell history the credential file exists to
# keep it out of. Exit 2 is "a human has to do this", not "try again".
OUT="$(echo "$OPERATOR_TOKEN" | "$STELE_BIN" auth login --host "$HOST" 2>&1)"; STATUS=$?
expect_eq "auth login refuses a non-TTY stdin, exit 2" "2" "$STATUS"
expect_contains "…and says why" "not a TTY" "$OUT"

seed_credential "$OPERATOR" "$OPERATOR_TOKEN"
expect_eq "the seeded credential file is 0600" "600" "$(stat -c '%a' "$CRED")"

# ---------------------------------------------------------------------------------
section "3. auth status — the first command the skill tells an agent to run"
# ---------------------------------------------------------------------------------

run_stele auth status --json
expect_eq "auth status exits 0" "0" "$STATUS"
printf '%s' "$OUT" > "$WORK/status.json"
expect_eq "…and reports the credential the server knows" "$OPERATOR" "$(json_field "$WORK/status.json" client)"
expect_eq "…as verified against the server" "True" "$(json_field "$WORK/status.json" verified)"
expect_contains "…with its scopes" "admin" "$(json_field "$WORK/status.json" scopes)"

# ---------------------------------------------------------------------------------
section "4. publish, and the bytes come back unchanged"
# ---------------------------------------------------------------------------------

cat > "$WORK/page.html" <<'HTML'
<!doctype html>
<html lang="en"><head><meta charset="utf-8"><title>smoke</title>
<link rel="stylesheet" href="/assets/stele.css"></head>
<body><h1>integration smoke</h1><p>héllo — 世界 🎉</p></body></html>
HTML

run_stele publish "$WORK/page.html"
expect_eq "publish exits 0" "0" "$STATUS"
URL="$OUT"
SLUG="${URL##*/}"
case "$URL" in
    "$HOST"/*) pass "publish prints a URL on this host and nothing else ($SLUG)" ;;
    *) fail "publish prints only the URL" "$HOST/<slug>" "$URL" ;;
esac

curl -sS "$URL" -o "$WORK/fetched.html"
if cmp -s "$WORK/page.html" "$WORK/fetched.html"; then
    pass "the published page comes back byte for byte (UTF-8 intact)"
else
    fail "the published page comes back byte for byte" "the file that was sent" "$(diff "$WORK/page.html" "$WORK/fetched.html" | head -5)"
fi
expect_eq "…served as text/html" "text/html; charset=utf-8" \
    "$(curl -sS -o /dev/null -w '%{content_type}' "$URL")"

# The deadline is real output and it is on the *other* stream. Both halves matter: a caller
# doing `url=$(stele publish page.html)` must not capture it, and a caller watching the
# terminal must see it — a page published with no --ttl is ephemeral, and being handed a bare
# URL is how you find that out when the link breaks.
expect_contains "…and the deadline is reported on stderr" "expires" "$ERR"
# Counted rather than pattern-matched: `$(printf '\n')` is the empty string — command
# substitution strips trailing newlines — so the obvious `case` spelling asks whether stdout
# contains "", which every string does, and the check passes for one line and fails for ten.
if [ "$(printf '%s' "$OUT" | wc -l)" -eq 0 ]; then
    pass "…while stdout stays the URL and nothing else"
else
    fail "stdout stays one line" "just the URL" "$OUT"
fi

# ---------------------------------------------------------------------------------
section "4b. page lifetimes: the default is ephemeral and --ttl is the way out"
# ---------------------------------------------------------------------------------

# What the server actually stored, not what the CLI printed. `expires` is the server's key and
# an explicit null is its way of saying "kept" — the distinction the CLI's own encoder keeps.
run_stele publish "$WORK/page.html" --json
expect_eq "publish --json exits 0" "0" "$STATUS"
printf '%s' "$OUT" > "$WORK/page-default.json"
DEFAULT_EXPIRY="$(json_field "$WORK/page-default.json" expires)"
expect_eq "a page published with no --ttl is ephemeral by default" "set" \
    "$(json_key_state "$WORK/page-default.json" expires)"
expect_eq "…and --json puts nothing on stderr" "" "$ERR"

run_stele publish "$WORK/page.html" --ttl never --json
expect_eq "--ttl never exits 0" "0" "$STATUS"
printf '%s' "$OUT" > "$WORK/page-never.json"
expect_eq "…and the page is kept: an explicit null, not a missing key" "null" \
    "$(json_key_state "$WORK/page-never.json" expires)"

run_stele publish "$WORK/page.html" --ttl 1
expect_eq "--ttl 1 exits 0" "0" "$STATUS"
expect_contains "…and reports a deadline a day out" "expires" "$ERR"
TTL_URL="$OUT"
expect_eq "…and the page is served now" "200" "$(http_status "$TTL_URL")"

# A week and a day are different lifetimes, and the CLI must not be quietly sending the same
# thing for both. Compared through the server's own record rather than the printed line.
run_stele publish "$WORK/page.html" --ttl 90 --json
expect_eq "--ttl 90 exits 0" "0" "$STATUS"
printf '%s' "$OUT" > "$WORK/page-90.json"
if [ "$(json_field "$WORK/page-90.json" expires)" != "$DEFAULT_EXPIRY" ]; then
    pass "…and --ttl 90 stores a different deadline than the default"
else
    fail "--ttl 90 reaches the server" "a deadline unlike the default" "$DEFAULT_EXPIRY"
fi

# Refused here, before the upload: nothing is rounded, and no page is created.
run_stele publish "$WORK/page.html" --ttl 12h
expect_eq "a sub-day lifetime is refused, exit 1" "1" "$STATUS"
expect_contains "…and the message says days are the resolution" "whole days" "$ERR"
expect_eq "…and nothing was published" "" "$OUT"

# Refused there, by the server, which owns the maximum. The CLI keeps no copy of that bound,
# so this is the leg that proves an over-long lifetime still fails — with the server's number.
run_stele publish "$WORK/page.html" --ttl 3650000
expect_eq "a lifetime past the server's ceiling is a 400, exit 1" "1" "$STATUS"

# ---------------------------------------------------------------------------------
section "5. update replaces it in place"
# ---------------------------------------------------------------------------------

cat > "$WORK/page2.html" <<'HTML'
<!doctype html>
<html lang="en"><head><meta charset="utf-8"><title>smoke v2</title></head>
<body><h1>integration smoke</h1><p>replaced</p></body></html>
HTML

run_stele update "$SLUG" "$WORK/page2.html"
expect_eq "update exits 0" "0" "$STATUS"
expect_eq "…and keeps the same URL" "$URL" "$OUT"
curl -sS "$URL" -o "$WORK/fetched2.html"
if cmp -s "$WORK/page2.html" "$WORK/fetched2.html"; then
    pass "the replacement is what is served"
else
    fail "the replacement is what is served" "the second file" "$(diff "$WORK/page2.html" "$WORK/fetched2.html" | head -5)"
fi

# A page's deadline is set once, at publish. Replacing the body must not buy the link another
# week — which is why `update` has no --ttl to offer and the server answers `?ttl=` on PUT
# with a 400 rather than a 200 that ignored it.
expect_contains "…and still reports the deadline it already had" "expires" "$ERR"
run_stele update "$SLUG" "$WORK/page2.html" --ttl never
# 64, not 1: an option the command does not declare is a usage error, and ArgumentParser exits
# `EX_USAGE` for those. The distinction is worth pinning — 1 would mean the flag was accepted
# and something later refused it, which is the outcome this check exists to rule out.
expect_eq "update has no --ttl to give" "64" "$STATUS"
expect_contains "…and says so rather than silently extending the page" "--ttl" "$ERR"

# ---------------------------------------------------------------------------------
section "6. --expires-in survives the round trip"
# ---------------------------------------------------------------------------------

# The silent one. `expiresIn` has to be spelled the server's way in the request body —
# the server ignores keys it does not know, so a misspelling earns a cheerful 201 and a
# credential that never expires. Nothing but reading the expiry back catches it, and
# the CLI's own tests cannot, because both halves would be wrong together.
run_stele admin clients create "$AGENT" --expires-in 30d --json
expect_eq "admin clients create --expires-in exits 0" "0" "$STATUS"
printf '%s' "$OUT" > "$WORK/agent.json"
AGENT_TOKEN="$(json_field "$WORK/agent.json" token)"
[ -n "$AGENT_TOKEN" ] || fail "the create response carries the one-time token" "a token" "<empty>"
pass "the create response carries the one-time token"

run_stele admin clients list --json
expect_eq "admin clients list exits 0" "0" "$STATUS"
printf '%s' "$OUT" > "$WORK/list.json"
AGENT_EXPIRY="$(json_client_field "$WORK/list.json" "$AGENT" expiresAt)"
[ -n "$AGENT_EXPIRY" ] || fail "the expiry comes back non-null from the listing" \
    "an ISO 8601 timestamp" "null — --expires-in did not reach the server"
pass "the expiry comes back non-null from the listing ($AGENT_EXPIRY)"

# The scope default is the other half of the same contract: an agent credential gets
# `publish` and nothing else, which is what makes revocation worth doing.
expect_eq "…and the credential carries publish and nothing else" '["publish"]' \
    "$(json_client_field "$WORK/list.json" "$AGENT" scopes)"

# ---------------------------------------------------------------------------------
section "7. an expiry is enforced, not merely stored"
# ---------------------------------------------------------------------------------

run_stele admin clients create "$EPHEMERAL" --expires-in 2s --json
expect_eq "a 2-second credential is minted" "0" "$STATUS"
printf '%s' "$OUT" > "$WORK/eph.json"
EPH_TOKEN="$(json_field "$WORK/eph.json" token)"
expect_eq "…and works immediately" "200" \
    "$(http_status "$HOST/admin/whoami" -H "Authorization: Bearer $EPH_TOKEN")"
sleep 4
expect_eq "…and is refused once it has expired" "401" \
    "$(http_status "$HOST/admin/whoami" -H "Authorization: Bearer $EPH_TOKEN")"

# ---------------------------------------------------------------------------------
section "8. a publish-only credential: 200 from whoami, 403 from the admin routes"
# ---------------------------------------------------------------------------------

seed_credential "$AGENT" "$AGENT_TOKEN"

run_stele auth status --json
expect_eq "auth status works for a publish-only credential" "0" "$STATUS"
printf '%s' "$OUT" > "$WORK/agent-status.json"
expect_eq "…and names it" "$AGENT" "$(json_field "$WORK/agent-status.json" client)"

run_stele admin clients list
expect_eq "admin clients list is 403 -> exit 4" "4" "$STATUS"
run_stele admin clients create "smoke-should-not-exist-$RUN_ID"
expect_eq "admin clients create is 403 -> exit 4" "4" "$STATUS"
run_stele admin clients revoke "$OPERATOR"
expect_eq "admin clients revoke is 403 -> exit 4" "4" "$STATUS"

run_stele publish "$WORK/page.html"
expect_eq "…but publishing works" "0" "$STATUS"
AGENT_URL="$OUT"
AGENT_SLUG="${AGENT_URL##*/}"
pass "the agent published $AGENT_SLUG"

# ---------------------------------------------------------------------------------
section "9. attribution — client_id is recorded on the page"
# ---------------------------------------------------------------------------------

# No HTTP route reports who wrote a page, deliberately, so this one needs the database.
if [ -n "$PSQL" ]; then
    WRITER="$($PSQL -At -c "SELECT c.name FROM pages p JOIN clients c ON c.id = p.client_id WHERE p.slug = '$AGENT_SLUG'" 2>&1)"
    expect_eq "the page records the credential that wrote it" "$AGENT" "$WRITER"
else
    printf '  \033[33mskip\033[0m %s\n' "attribution: set STELE_SMOKE_PSQL to check pages.client_id"
fi

# ---------------------------------------------------------------------------------
section "10. revocation actually stops the credential working"
# ---------------------------------------------------------------------------------

seed_credential "$OPERATOR" "$OPERATOR_TOKEN"
run_stele admin clients revoke "$AGENT"
expect_eq "revoke exits 0" "0" "$STATUS"
run_stele admin clients revoke "$AGENT" --json
expect_eq "…and is idempotent" "0" "$STATUS"

run_stele admin clients list --json
printf '%s' "$OUT" > "$WORK/list2.json"
expect_eq "…the listing still shows the revoked credential" "revoked" \
    "$(json_client_field "$WORK/list2.json" "$AGENT" state)"

seed_credential "$AGENT" "$AGENT_TOKEN"
run_stele auth status
expect_eq "the revoked credential is refused by auth status, exit 3" "3" "$STATUS"
run_stele publish "$WORK/page.html"
expect_eq "…and by publish, exit 3" "3" "$STATUS"
expect_eq "…and over raw HTTP, 401" "401" \
    "$(http_status -X POST "$HOST/pages" -H "Authorization: Bearer $AGENT_TOKEN" -H 'Content-Type: text/html' --data '<p>x</p>')"
expect_eq "…while the page it published is still readable" "200" "$(http_status "$AGENT_URL")"

# ---------------------------------------------------------------------------------
section "11. the exit-code vocabulary agrees with the server's statuses"
# ---------------------------------------------------------------------------------

seed_credential "$OPERATOR" "$OPERATOR_TOKEN"

run_stele publish "$WORK/page.html" --slug "$SLUG"
expect_eq "409 slug taken -> exit 5" "5" "$STATUS"

# The same status, the other resource. A `409` means two unrelated things on this server
# and the client only learns which from the route it asked — so this is a real-server
# assertion the unit tests cannot make on their own, and the mistake it guards against
# (telling an operator whose credential name collided to "choose another --slug") was
# live until the conflict was split.
# `$OPERATOR` and not `$AGENT`: a revoked name does not hold the name — the server frees it
# so a credential can be rotated under the same one — and `$AGENT` was revoked in section 9,
# so asking for it again would earn a cheerful 201 and mint a credential this assertion
# would then have to clean up. `$OPERATOR` is the credential this section is authenticated
# as, so it is live by construction.
run_stele admin clients create "$OPERATOR"
expect_eq "409 client name taken -> exit 1" "1" "$STATUS"
expect_contains "…and the advice is about credentials, not slugs" \
    "stele admin clients revoke" "$ERR"
case "$ERR" in
    *--slug*) fail "the name conflict does not mention --slug" "no --slug" "$ERR" ;;
    *) pass "the name conflict does not mention --slug" ;;
esac
run_stele update "smoke-no-such-page-$RUN_ID" "$WORK/page.html"
expect_eq "404 no such page -> exit 7" "7" "$STATUS"
run_stele publish "$WORK/page.html" --content-type application/json
expect_eq "415 unsupported type -> exit 6" "6" "$STATUS"
run_stele publish "$WORK/page.html" --slug admin
expect_eq "400 reserved slug -> exit 1" "1" "$STATUS"
run_stele admin clients revoke "smoke-no-such-client-$RUN_ID"
expect_eq "404 no such client -> exit 7" "7" "$STATUS"

# ---------------------------------------------------------------------------------
section "12. server invariants the CLI depends on"
# ---------------------------------------------------------------------------------

# The version gate. A CLI too old to speak the contract must be told to reinstall
# rather than fail somewhere further in; a caller that does not claim to be the CLI
# must be waved through, because curl is still a supported way to publish.
expect_eq "an old stele-cli User-Agent is answered 426" "426" \
    "$(http_status -X POST "$HOST/pages" -H "Authorization: Bearer $OPERATOR_TOKEN" \
        -H 'User-Agent: stele-cli/0.0.1' -H 'Content-Type: text/html' --data '<p>x</p>')"
expect_eq "whoami is deliberately not version-gated" "200" \
    "$(http_status "$HOST/admin/whoami" -H "Authorization: Bearer $OPERATOR_TOKEN" \
        -H 'User-Agent: stele-cli/0.0.1')"

# Every miss on the public read surface is one page, so a scanner cannot map the
# namespace faster than guessing. A route that grows a distinguishable 404 breaks it.
NOTFOUND=""
for path in /assets /pages /admin /smoke-no-such-slug /NOT-A-SLUG; do
    body="$(curl -sS "$HOST$path" | cksum)"
    status="$(http_status "$HOST$path")"
    [ "$status" = "404" ] || fail "GET $path is 404" "404" "$status"
    if [ -z "$NOTFOUND" ]; then NOTFOUND="$body"
    elif [ "$body" != "$NOTFOUND" ]; then fail "GET $path returns the same 404 body as the others" "$NOTFOUND" "$body"
    fi
done
pass "every 404 on the public read surface is byte-identical"

# `stele skill` proxies GET /skill, which is how an agent learns the contract. A binary
# that could not fetch it would send the agent to a stale copy.
run_stele skill
expect_eq "stele skill exits 0" "0" "$STATUS"
expect_contains "…and returns the server's own skill document" "stele auth status" "$OUT"

# ---------------------------------------------------------------------------------

printf '\n\033[32msmoke: %d checks passed.\033[0m\n' "$CHECKS"
printf 'Left behind on %s: 2 pages (%s, %s) and %d client rows, revoked.\n' \
    "$HOST" "$SLUG" "$AGENT_SLUG" 3
printf 'The server has no delete route, so pages and revoked credentials accumulate —\n'
printf 'which is why this belongs on a throwaway deployment, not a real one.\n'
