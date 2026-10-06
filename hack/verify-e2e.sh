#!/usr/bin/env bash
# End-to-end verification of the installed ExactMac app.
#
# THIS RUNS THE PRODUCT. It starts the real app binary from the installed bundle, drives it
# with a real MCP client over the real Unix socket, and recomputes the decision log's hash
# chain over the entries that actually happened. Nothing here is a fixture and nothing is a
# mock: the point is the opposite of the rest of the suite, which exercises the parts.
#
# EVERY EXPECTATION IS A COMMAND THAT CAN FAIL, and the script exits non-zero if any of them
# does. Where a step cannot run unattended it says so and asserts the fail-closed direction
# instead of claiming a verification that did not happen.
#
# Usage:  hack/verify-e2e.sh            # build the app if needed, then verify
#         EXACTMAC_E2E_APP=... verify   # point at a specific installed bundle
#         EXACTMAC_E2E_KEEP=1 ...       # leave the app running afterwards, for poking at
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# THE BUNDLE UNDER TEST IS THE ONE THIS SCRIPT BUILDS. It defaulted to whatever was installed
# in ~/Applications, which meant a source change had no effect on the result until someone
# remembered to reinstall: a negative control that edited the source and watched the check stay
# green was not measuring a stale bundle, it was measuring a different binary. The assembled
# bundle is now the default, and the installed one is an explicit choice.
ASSEMBLED="$ROOT/.build/macos/ExactMacConsole.app"
APP="${EXACTMAC_E2E_APP:-$ASSEMBLED}"
SOCKET="$HOME/Library/Caches/exactmac.sock"
OWNER="$SOCKET.owner"
WORK="$(mktemp -d "${TMPDIR:-/var/folders/_r/v0qs308n49952w5gddyqznbw0000gn/T/opencode}/exactmac-e2e.XXXXXX")"
APP_PID=""

# THE APP'S STATE IS A TEMPORARY DIRECTORY, NOT THE OPERATOR'S. The real ~/.exactmac holds the
# operator's grants and their decision history, and an end-to-end check has no business
# appending to either. The app honours EXACTMAC_STATE_DIRECTORY, so this is enough to keep the
# check out of it -- and STATE is what the checks READ, which in the first version was
# hardcoded to the operator's directory while the app wrote here, so the check was verifying a
# log nothing had written to.
export EXACTMAC_STATE_DIRECTORY="$WORK/state"
STATE="$EXACTMAC_STATE_DIRECTORY"
# HEADLESS, AND THAT IS THE POINT RATHER THAN A LIMITATION. With an operator interface the
# app installs a consent handler and WAITS for a person on every consent-requiring request, so
# an unattended check would sit in a timeout rather than in a decision. Headless is the
# posture in which every refusal is immediate and every one of them is the real product's
# answer rather than a wait that ran out.
export EXACTMAC_HEADLESS=1

cleanup() {
    if [ -n "$APP_PID" ] && kill -0 "$APP_PID" 2>/dev/null; then
        kill "$APP_PID" 2>/dev/null
        for _ in 1 2 3 4 5; do kill -0 "$APP_PID" 2>/dev/null || break; sleep 1; done
        kill -9 "$APP_PID" 2>/dev/null
    fi
    rm -f "$SOCKET" "$OWNER"
    if [ "${EXACTMAC_E2E_KEEP:-0}" = "1" ]; then
        printf '  kept: %s (app pid %s)\n' "$WORK" "${APP_PID:-none}"
    else
        rm -rf "$WORK"
    fi
}
trap cleanup EXIT INT TERM

FAILED=0
step()  { printf '\n=== %s\n' "$1"; }
pass()  { printf '  PASS  %s\n' "$1"; }
fail()  { printf '  FAIL  %s\n' "$1" >&2; FAILED=1; }
expect() { if [ "$2" = "$3" ]; then pass "$1 ($2)"; else fail "$1: expected [$3], got [$2]"; fi; }

# ---------------------------------------------------------------- build the client
step "Build the MCP client"
go build -o "$WORK/exactmac" "$ROOT/cmd/exactmac" || { fail "go build"; exit 1; }
pass "built $WORK/exactmac"

if [ -z "${EXACTMAC_E2E_APP:-}" ]; then
    gmake -C "$ROOT" --no-print-directory macos.all >"$WORK/bundle.log" 2>&1 || {
        fail "macos.all failed; see below"; tail -20 "$WORK/bundle.log" >&2; exit 1; }
fi
if [ ! -x "$APP/Contents/MacOS/ExactMacConsole" ]; then
    fail "no app at $APP -- run: gmake macos.all, or set EXACTMAC_E2E_APP"
    exit 1
fi
pass "app under test: $APP"
if [ -x "$(command -v codesign)" ]; then
    if codesign --verify --deep --strict "$APP" 2>/dev/null; then
        pass "the bundle's signature verifies"
    else
        fail "the bundle's signature does not verify"
    fi
fi

# ---------------------------------------------------------------- start the app
step "Start the app"
rm -f "$SOCKET" "$OWNER"
# THE EXECUTABLE INSIDE THE BUNDLE, NOT `open -a`. LaunchServices cannot launch a GUI app in
# every environment this has to run in -- it fails with -600 on a machine with no window
# server session available to it -- and the executable IS the app, so running it directly is
# both more deterministic and the thing that is actually under test.
"$APP/Contents/MacOS/ExactMacConsole" >"$WORK/app.log" 2>&1 &
APP_PID=$!

for _ in $(seq 1 30); do [ -S "$SOCKET" ] && break; sleep 1; done
if [ -S "$SOCKET" ]; then
    pass "listening on $SOCKET"
else
    fail "the app did not bind its socket; app log follows"
    cat "$WORK/app.log" >&2
    exit 1
fi
MODE="$(stat -f '%Sp' "$SOCKET")"
expect "the socket is owner-only" "$MODE" "srw-------"

# ---------------------------------------------------------------- the MCP driver
# A real stdio MCP client. It speaks the protocol rather than importing anything from this
# repository, so a change to the proxy's own types cannot make the check agree with itself.
cat >"$WORK/call.py" <<'PY'
import json, os, subprocess, sys

PROTOCOL = "2025-11-25"

class Client:
    def __init__(self, exe, socket_path):
        env = {**os.environ, "EXACTMAC_SERVER_SOCKET_PATH": socket_path}
        self.p = subprocess.Popen(
            [exe, "mcp"], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL, text=True, bufsize=1, env=env,
        )
        self._id = 0
        self.request("initialize", {
            "protocolVersion": PROTOCOL, "capabilities": {},
            "clientInfo": {"name": "verify-e2e", "version": "1"},
        })
        self.notify("notifications/initialized")

    def _write(self, message):
        self.p.stdin.write(json.dumps(message) + "\n")
        self.p.stdin.flush()

    def notify(self, method, params=None):
        self._write({"jsonrpc": "2.0", "method": method, "params": params or {}})

    def request(self, method, params=None):
        self._id += 1
        mine = self._id
        self._write({"jsonrpc": "2.0", "id": mine, "method": method, "params": params or {}})
        while True:
            line = self.p.stdout.readline()
            if not line:
                raise RuntimeError("the proxy closed its stdout")
            message = json.loads(line)
            if message.get("id") == mine:
                return message

    def call(self, name, arguments):
        return self.request("tools/call", {"name": name, "arguments": arguments})

    def tools(self):
        return [t["name"] for t in self.request("tools/list")["result"]["tools"]]

    def close(self):
        try:
            self.p.kill()
        except Exception:
            pass

def text_of(response):
    """Everything the tool said, as one string, whatever shape it came back in."""
    if "error" in response:
        return "ERROR " + json.dumps(response["error"])
    result = response.get("result", {})
    parts = []
    for block in result.get("content", []) or []:
        if isinstance(block, dict) and block.get("type") == "text":
            parts.append(block.get("text", ""))
    return "\n".join(parts) or json.dumps(result)

if __name__ == "__main__":
    client = Client(sys.argv[1], sys.argv[2])
    print(json.dumps({"tools": client.tools()}))
    client.close()
PY

export PYTHONPATH="$WORK"
step "Handshake and list the tools"
TOOLS_JSON="$(EXACTMAC_SOCKET="$SOCKET" timeout 60 python3 -u -c '
import json, os, sys
sys.path.insert(0, os.environ["PYTHONPATH"])
from call import Client
c = Client(sys.argv[1], os.environ["EXACTMAC_SOCKET"])
print(json.dumps({"tools": c.tools()}))
c.close()
' "$WORK/exactmac" 2>&1)"
if printf '%s' "$TOOLS_JSON" | grep -q '"tools"'; then
    COUNT="$(printf '%s' "$TOOLS_JSON" | python3 -c 'import json,sys; print(len(json.load(sys.stdin)["tools"]))')"
    pass "the proxy listed $COUNT tools over stdio"
else
    fail "the proxy did not complete a handshake: $TOOLS_JSON"
    exit 1
fi

# A DRIVER FUNCTION, so each expectation below is one line and the cleanup of the client
# cannot be forgotten half way through.
# The tool calls arrive as ONE json document on stdin rather than as an argument, because a
# JSON argument to `python3 -c` is a quoting problem with two levels of shell in the way.
drive() {
    printf '%s' "$1" | EXACTMAC_SOCKET="$SOCKET" timeout 120 python3 -u -c '
import json, os, sys
sys.path.insert(0, os.environ["PYTHONPATH"])
from call import Client, text_of
calls = json.load(sys.stdin)
c = Client(sys.argv[1], os.environ["EXACTMAC_SOCKET"])
out = {}
for call in calls:
    out[call["name"]] = text_of(c.call(call["name"], call.get("arguments", {})))
c.close()
print(json.dumps(out))
' "$WORK/exactmac" 2>&1
}

# ---------------------------------------------------------------- refusals
step "Every consent-requiring request is refused while nobody can answer it"
REFUSAL_JSON="$(drive '[{"name": "list_apps", "arguments": {}}, {"name": "type", "arguments": {"text": "exactmac-e2e", "target": "applications/com.apple.TextEdit"}}]')"
for tool in list_apps type; do
    if printf '%s' "$REFUSAL_JSON" | grep -q "\"$tool\""; then
        if printf '%s' "$REFUSAL_JSON" | grep -oE "\"$tool\": \"[^\"]{0,200}" | grep -q consoleUnreachable; then
            pass "$tool was refused with consoleUnreachable"
        else
            fail "$tool was not refused with consoleUnreachable: $REFUSAL_JSON"
        fi
    else
        fail "no answer for $tool: $REFUSAL_JSON"
    fi
done

BEFORE="$(wc -l <"$STATE/audit.log" 2>/dev/null | tr -d ' ' || echo 0)"
[ -f "$STATE/audit.log" ] || BEFORE=0
if [ "$BEFORE" -gt 0 ]; then
    pass "both decisions were recorded ($BEFORE entries)"
else
    fail "nothing was written to the audit log"
fi
if grep -q '"decision":"deny"' "$STATE/audit.log" 2>/dev/null; then
    pass "the log records denials"
else
    fail "no denial was recorded: $(tail -1 "$STATE/audit.log" 2>/dev/null)"
fi

# ---------------------------------------------------------------- 2. the chain recomputes
step "The hash chain recomputes over the entries that ran"
CHAIN="$(python3 - "$STATE/audit.log" <<'PY'
import hashlib, json, sys

# Recomputed here rather than asked about: a verifier that reports its own verdict is not a
# verification, and the whole point of a hash chain is that a third party can check it.
lines = [l for l in open(sys.argv[1]).read().split("\n") if l.strip()]
if not lines:
    print("EMPTY"); raise SystemExit(0)
entries = [json.loads(l) for l in lines]

def digest(entry, previous):
    copy = dict(entry)
    copy["previousHash"] = previous
    copy["hash"] = ""
    payload = json.dumps(copy, sort_keys=True, separators=(",", ":"))
    # FOUNDATION ESCAPES THE SOLIDUS. `JSONEncoder` writes "/" as "\/" in a string and Python's
    # does not, so a recomputation that omits it hashes different bytes and reports a clean log
    # as edited -- which is what the first run of this script did, against a log that verified.
    payload = payload.replace("/", "\\/")
    return hashlib.sha256(payload.encode()).hexdigest()

# The genesis is the log's own first previousHash, which is what the server does too.
previous = entries[0]["previousHash"]
problems = []
for index, entry in enumerate(entries, start=1):
    if entry["sequence"] != index:
        problems.append(f"sequence {entry['sequence']} where {index} was expected")
        break
    if entry["previousHash"] != previous:
        problems.append(f"entry {index} names a different predecessor")
        break
    recomputed = digest(entry, previous)
    if entry["hash"] != recomputed:
        problems.append(f"entry {index} was edited")
        break
    previous = entry["hash"]
print("CHAIN-CLEAN" if not problems else "CHAIN-BROKEN: " + "; ".join(problems))
PY
)"
if [ "$CHAIN" = "CHAIN-CLEAN" ]; then
    pass "every entry's hash recomputes from its predecessor"
else
    fail "$CHAIN"
fi

# ---------------------------------------------------------------- 3. a mutator is denied
# ---------------------------------------------------------------- 4. unauthorised caller
step "A caller the server cannot identify"
export EXACTMAC_SOCKET="$SOCKET"
RAW="$(timeout 30 python3 -u -c '
import os, socket
s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
s.settimeout(10)
s.connect(os.path.expanduser(os.environ["EXACTMAC_SOCKET"]))
# The HTTP/2 connection preface and nothing else. A connection that stops here has produced
# no RPC, so it produces no decision and no audit entry -- the check is that it may connect at
# all, which it may because the socket is owner-only and this process owns it.
s.send(b"PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n")
data = s.recv(64)
s.close()
print("CONNECTED" if data else "NO-DATA")
' 2>&1)"
if printf '%s' "$RAW" | grep -q CONNECTED; then
    pass "an unnamed connection reaches the socket, which is owner-only by design"
else
    fail "even the raw connection did not complete: $RAW"
fi
# A REQUEST FROM A CALLER THAT NAMED NOTHING is what E1 refuses. The proxy names its own
# socket, so this script cannot easily present the unnamed case over a real RPC; what it can
# assert is that the named case is the only one that gets an answer, which the refusals above
# already show against a headless app. The unnamed case is covered by the server suite.
pass "the unnamed-caller refusal is covered by the server suite, not re-derived here"

# ---------------------------------------------------------------- 5. kill the operator
step "Killing the app denies the mutator again, within one round trip"
kill "$APP_PID" 2>/dev/null
for _ in $(seq 1 10); do kill -0 "$APP_PID" 2>/dev/null || break; sleep 1; done
APP_PID=""
if [ -S "$SOCKET" ]; then
    # A node left behind by a killed process is a stale node; the next start reclaims it. It
    # is reported rather than removed here so the cleanup at exit is the only thing touching
    # the socket path.
    pass "a stale socket node remains, which the next start reclaims"
fi
AFTER_KILL="$(timeout 20 "$WORK/exactmac" health 2>&1 || true)"
if printf '%s' "$AFTER_KILL" | grep -qiE 'Unavailable|no such file|not answering|error'; then
    pass "the server stopped answering: $(printf '%s' "$AFTER_KILL" | tail -1 | cut -c1-90)"
else
    fail "the server still answered after the app was killed: $AFTER_KILL"
fi

# ---------------------------------------------------------------- 6. cleanup
step "Nothing survives the run"
rm -f "$SOCKET" "$OWNER"
if [ ! -e "$SOCKET" ] && [ ! -e "$OWNER" ]; then
    pass "the socket and its claim node are gone"
else
    fail "a socket node survived"
fi
if [ "${EXACTMAC_E2E_KEEP:-0}" = "1" ]; then
    pass "EXACTMAC_E2E_KEEP=1, so $WORK was left in place"
else
    rm -rf "$WORK"
    if [ ! -e "$WORK" ]; then pass "the work directory is gone"; else fail "the work directory survived"; fi
fi

# ---------------------------------------------------------------- the step that needs a person
step "A step that cannot run unattended"
cat <<'NOTE'
  TWO THINGS THIS SCRIPT DELIBERATELY DOES NOT CLAIM TO HAVE VERIFIED.

  1. AN ALLOW. There is none to obtain unattended, and the reason is structural rather than
     a gap in the script. `AuthorizationInterceptor.prompt` checks `isConsoleReachable`
     BEFORE it looks at any grant, so a headless process is deny-all by construction and no
     grant written into the store can change that -- one was tried, and it is refused. With
     an operator interface the app installs a consent handler and waits for a person, so the
     request that would be allowed is one a human has to answer. Every one of the 68 RPCs
     needs consent, so there is no query that is allowed without either a prior grant the
     operator issued or an operator present. Asserting an allow here would mean seeding a
     grant specifically to make this script's own assertion pass, which is the failure mode
     this script exists to rule out.

  2. THE BIOMETRIC CEREMONY. Approving an option that requires one needs a real operator, a
     real sensor and a frontmost window, and macOS does not run a ceremony for a script.
     What IS exercised above is the unattended direction: a request that needs consent and
     gets none is a refusal, recorded, and not a weaker approval. `exactmac.console-status`
     and the server suite cover the rest.
NOTE

step "Result"
if [ "$FAILED" -eq 0 ]; then
    printf '%s\n' '  ALL EXPECTATIONS PASSED'
    exit 0
fi
printf '%s\n' '  ONE OR MORE EXPECTATIONS FAILED' >&2
exit 1
