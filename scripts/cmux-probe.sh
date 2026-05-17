#!/usr/bin/env bash
# cmux-probe.sh — verify cmux + SSH readiness for Telecmux iOS client.
#
# Usage:
#   Local check (run on the Mac that hosts cmux):
#       ./scripts/cmux-probe.sh
#
#   Remote check (run from another machine over SSH):
#       ./scripts/cmux-probe.sh ssh user@mac
#       ./scripts/cmux-probe.sh ssh user@mac.tailnet.ts.net
#
# Exit codes:
#   0  all checks passed
#   1  cmux not installed / not running
#   2  socket unreachable
#   3  a required CLI command failed
#   4  SSH transport failed (remote mode only)
#
# What it verifies:
#   1. `cmux` binary exists and reports a version
#   2. `cmux ping` returns successfully (socket is alive)
#   3. `cmux capabilities` JSON is parseable
#   4. `cmux list-windows`, `list-workspaces`, `list-panes`, `tree --json` work
#   5. `cmux list-notifications --json` works
#   6. `cmux events` stream opens and emits at least one heartbeat in 3s
#   7. (Optional) `cmux read-screen` against the first pane
#
# Reads no secrets. Writes nothing on the remote.

set -u

# ---------- args ----------
MODE="local"
SSH_TARGET=""
if [[ "${1:-}" == "ssh" ]]; then
  MODE="ssh"
  SSH_TARGET="${2:-}"
  if [[ -z "$SSH_TARGET" ]]; then
    echo "error: 'ssh' mode requires a target, e.g. user@host" >&2
    exit 2
  fi
fi

# ---------- runner ----------
# run_cmux <args...>  --> runs cmux locally or via SSH depending on MODE
run_cmux() {
  if [[ "$MODE" == "ssh" ]]; then
    # -o BatchMode=yes  : never prompt for password (key auth only — matches Hermit)
    # -o ConnectTimeout : fail fast if host unreachable
    ssh -o BatchMode=yes -o ConnectTimeout=5 "$SSH_TARGET" "cmux $*"
  else
    cmux "$@"
  fi
}

ok()    { printf "  \033[32m✓\033[0m %s\n" "$*"; }
warn()  { printf "  \033[33m!\033[0m %s\n" "$*"; }
fail()  { printf "  \033[31m✗\033[0m %s\n" "$*"; }
hdr()   { printf "\n\033[1m%s\033[0m\n" "$*"; }

# ---------- 0. ssh reachability ----------
if [[ "$MODE" == "ssh" ]]; then
  hdr "0. SSH transport"
  if ssh -o BatchMode=yes -o ConnectTimeout=5 "$SSH_TARGET" "true" 2>/dev/null; then
    ok "ssh $SSH_TARGET reachable (key auth, no prompt)"
  else
    fail "ssh $SSH_TARGET failed — check key auth, hostname, or Tailscale state"
    exit 4
  fi
fi

# ---------- 1. cmux binary ----------
hdr "1. cmux binary"
if version_out=$(run_cmux --version 2>&1); then
  ok "cmux installed → ${version_out}"
else
  fail "cmux not found on PATH (target: $MODE${SSH_TARGET:+ $SSH_TARGET})"
  echo "      install: brew install --cask cmux" >&2
  exit 1
fi

# ---------- 2. socket alive ----------
hdr "2. socket (cmux ping)"
if ping_out=$(run_cmux ping 2>&1); then
  ok "socket reachable → ${ping_out}"
else
  fail "cmux ping failed → ${ping_out}"
  echo "      is the cmux.app running? open -a cmux" >&2
  exit 2
fi

# ---------- 3. capabilities ----------
hdr "3. capabilities"
if caps_json=$(run_cmux capabilities 2>&1); then
  # crude JSON sanity check (jq optional)
  if command -v jq >/dev/null 2>&1; then
    if echo "$caps_json" | jq . >/dev/null 2>&1; then
      ok "capabilities JSON parsed ($(echo "$caps_json" | jq -r 'keys | join(",")' 2>/dev/null))"
    else
      warn "capabilities returned but not valid JSON"
    fi
  else
    ok "capabilities returned ($(echo "$caps_json" | wc -c | tr -d ' ') bytes — install jq for parsing)"
  fi
else
  fail "cmux capabilities failed → ${caps_json}"
  exit 3
fi

# ---------- 4. inventory commands ----------
hdr "4. read-only inventory commands"
for cmd in "list-windows" "list-workspaces" "list-panes" "tree --json" "list-notifications --json"; do
  if out=$(run_cmux $cmd 2>&1); then
    n=$(echo "$out" | wc -l | tr -d ' ')
    ok "cmux $cmd → ${n} line(s)"
  else
    fail "cmux $cmd failed → ${out}"
    exit 3
  fi
done

# ---------- 5. event stream ----------
hdr "5. event stream (cmux events, 3s window)"
# In 0.64.x `cmux events` is not yet implemented — the CLI prints its top-level
# help instead. We detect that and report explicitly so Telecmux's polling
# fallback is the documented path.
events_stdout=$(mktemp); events_stderr=$(mktemp)
if [[ "$MODE" == "ssh" ]]; then
  ssh -o BatchMode=yes -o ConnectTimeout=5 "$SSH_TARGET" "cmux events" >"$events_stdout" 2>"$events_stderr" &
else
  cmux events >"$events_stdout" 2>"$events_stderr" &
fi
events_pid=$!
sleep 3
kill "$events_pid" 2>/dev/null || true
wait "$events_pid" 2>/dev/null || true
stderr_blob=$(cat "$events_stderr")
stdout_first=$(head -1 "$events_stdout" 2>/dev/null)
if [[ "$stderr_blob" == *"Unknown command"* ]] || [[ "$stdout_first" == "cmux - control cmux via Unix socket"* ]]; then
  warn "cmux events not implemented in this build — Telecmux will use polling (expected for 0.64.x)"
else
  line_count=$(wc -l <"$events_stdout" | tr -d ' ')
  if [[ "$line_count" -gt 0 ]]; then
    first_event=$(echo "$stdout_first" | cut -c1-120)
    ok "events stream emitted ${line_count} line(s); first: ${first_event}"
  else
    warn "events stream opened but emitted 0 lines in 3s"
  fi
fi
rm -f "$events_stdout" "$events_stderr"

# ---------- 6. sample read-screen ----------
hdr "6. sample read-screen on first pane"
if ! command -v jq >/dev/null 2>&1; then
  warn "jq not installed — skip (brew install jq)"
else
  # cmux's read/send/send-key all key off `--surface`, not `--pane`.
  # list-panes returns ref form ("surface:34"); read-screen accepts either.
  surface_ref=$(run_cmux --json list-panes 2>/dev/null | jq -r '.panes[0].surface_refs[0] // empty')
  if [[ -n "$surface_ref" ]]; then
    if screen_out=$(run_cmux read-screen --surface "$surface_ref" 2>&1); then
      bytes=$(printf "%s" "$screen_out" | wc -c | tr -d ' ')
      ok "read-screen --surface $surface_ref → ${bytes} bytes"
    else
      warn "read-screen failed on surface $surface_ref → ${screen_out}"
    fi
  else
    warn "no surfaces returned (open a workspace in cmux to test this)"
  fi
fi

hdr "All checks complete."
echo
echo "Next step:"
if [[ "$MODE" == "ssh" ]]; then
  echo "  Telecmux can connect via: $SSH_TARGET"
  echo "  Use this hostname when creating a Host in the app."
else
  echo "  Run again over SSH to verify Hermit's actual transport:"
  echo "    ./scripts/cmux-probe.sh ssh \$(whoami)@\$(hostname)"
fi
