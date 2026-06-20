#!/usr/bin/env bash
# Tests for status.sh — fixture-driven (STATUS_REPO override), so the live repo's state never
# affects the assertions. NO claude, NO network. Plus one live smoke run against this repo.
set -euo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STATUS="$SELF_DIR/status.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

FAIL=0
N=0
pass() { N=$((N + 1)); echo "ok   $1"; }
fail() { N=$((N + 1)); FAIL=1; echo "FAIL $1"; }

# Fresh temp git repo with a backlog (one claimed unit, one ready unit) and a decisions file
# covering all three answer states: director-resolved, empty, system-default-only.
new_repo() {
  local d
  d="$(mktemp -d "$TMP/repo.XXXXXX")"
  git -C "$d" init -q
  git -C "$d" config user.email t@t
  git -C "$d" config user.name t
  git -C "$d" config commit.gpgsign false
  cat > "$d/backlog.md" <<'EOF'
# Backlog

## Bootstrap
- [ ] **claimed unit** — being worked. <!-- cascade: id=cT-u1 blocked-by=none -->
- [ ] **ready unit** — next in line. <!-- cascade: id=cT-u2 blocked-by=none -->

## Done
- [x] **finished task** (2026-06-06) — done earlier.
EOF
  mkdir -p "$d/director"
  cat > "$d/director/DECISIONS.md" <<'EOF'
# Decisions Queue

## D-001 — resolved by director
**Asked:** 2026-06-06 · **Default applies:** 2026-06-13 → default = (a)
**Question:** q?
**Answer:** (a) — director 2026-06-06. ✅ RESOLVED

---

## D-002 — empty answer
**Asked:** 2026-06-07 · **Default applies:** 2026-06-10 → default = (a)
**Question:** q?
**Answer:**

---

## D-003 — system default only
**Asked:** 2026-06-07 · **Default applies:** 2026-06-14 → default = (a)
**Question:** q?
**Answer:**
**Default picked by the executing agent (2026-06-07):** (a). Recorded so the director can override.
EOF
  git -C "$d" add -A
  git -C "$d" commit -q -m init
  printf '%s' "$d"
}

run_status() { STATUS_REPO="$1" STATE_DIR="$TMP/nostate" "$STATUS" 2>&1; }

# --- 1. claims: age, branch, stale detection; NEXT UP skips the claimed unit -------------------
D="$(new_repo)"
mkdir -p "$D/current_tasks"
sleep 0.05 &
DEAD_PID=$!
wait "$DEAD_PID" 2>/dev/null || true
{
  printf 'unit: cT-u1\n'
  printf 'branch: cascade/cT-u1\n'
  printf 'worktree: %s/.cascade/worktrees/cT-u1\n' "$D"
  printf 'claimed: %s\n' "$(date -d '-2 hours' -Iseconds)"
  printf 'pid: %s\n' "$DEAD_PID"
} > "$D/current_tasks/cT-u1.claim"

OUT="$(run_status "$D")"
if grep -q 'cT-u1  claimed 2h0m ago  branch cascade/cT-u1' <<<"$OUT" \
     && grep -q 'stale claim?' <<<"$OUT"; then
  pass "claim shown with age, branch, and stale (dead dispatcher) marker"
else
  fail "claim shown with age, branch, and stale marker — got: $(grep -A2 'ACTIVE UNITS' <<<"$OUT")"
fi
if grep -A1 'NEXT UP' <<<"$OUT" | grep -q 'ready unit'; then
  pass "NEXT UP skips the claimed unit, shows the ready one"
else
  fail "NEXT UP skips the claimed unit — got: $(grep -A1 'NEXT UP' <<<"$OUT")"
fi
if grep -q 'backlog: 2 open / 1 done' <<<"$OUT"; then
  pass "backlog open/done counts"
else
  fail "backlog open/done counts — got: $(grep 'backlog:' <<<"$OUT")"
fi

# --- 2. live claim (alive pid) is not marked stale ---------------------------------------------
sed -i "s/^pid: .*/pid: $$/" "$D/current_tasks/cT-u1.claim"
OUT="$(run_status "$D")"
if grep -q "dispatcher alive (pid $$)" <<<"$OUT" && ! grep -q 'stale claim?' <<<"$OUT"; then
  pass "alive dispatcher pid reported, no stale marker"
else
  fail "alive dispatcher pid reported — got: $(grep 'cT-u1' <<<"$OUT")"
fi

# --- 3. decisions: empty answer + system-default pending; director-resolved excluded -----------
if grep -q 'QUESTIONS WAITING (2)' <<<"$OUT" \
     && grep -q 'D-002 — empty answer' <<<"$OUT" \
     && grep -q 'D-003 — system default only.*default recorded — override open' <<<"$OUT" \
     && ! grep -q 'D-001' <<<"$OUT"; then
  pass "decisions: UNANSWERED + DEFAULTED pending, director-resolved excluded"
else
  fail "decisions tiers — got: $(grep -A4 'QUESTIONS WAITING' <<<"$OUT")"
fi

# --- 4. all answered -> explicit zero state ----------------------------------------------------
sed -i 's/^\*\*Answer:\*\*$/**Answer:** (a) — director 2026-06-07./' "$D/director/DECISIONS.md"
OUT="$(run_status "$D")"
if grep -q 'QUESTIONS WAITING (0)' <<<"$OUT"; then
  pass "all answered -> QUESTIONS WAITING (0)"
else
  fail "all answered -> QUESTIONS WAITING (0) — got: $(grep 'QUESTIONS WAITING' <<<"$OUT")"
fi

# --- 5. live smoke: runs on this repo, rc 0, all six sections present -------------------------
if OUT="$("$STATUS")" && grep -q '^RUNNING' <<<"$OUT" && grep -q '^ACTIVE UNITS' <<<"$OUT" \
     && grep -q '^QUEUE' <<<"$OUT" && grep -q '^NEXT UP' <<<"$OUT" \
     && grep -q 'QUESTIONS WAITING' <<<"$OUT" && grep -q '^RECENT' <<<"$OUT"; then
  pass "live smoke: rc 0, all six sections present"
else
  fail "live smoke: rc 0, all six sections present"
fi

# --- 6. QUEUE section degrades silently when PG is down (gate hermetic: AGENCY_PG_PORT=1) ------
# Gate exports AGENCY_PG_PORT=1 (closed port) → PG_AVAIL=0. QUEUE section must render without
# error, showing "(PG unavail)" instead of crashing the status output.
OUT="$(run_status "$(new_repo)")"
if grep -q '^QUEUE' <<<"$OUT" && grep -q '(PG unavail)' <<<"$OUT"; then
  pass "QUEUE section PG down: present, shows (PG unavail), rc 0"
else
  fail "QUEUE section PG down — got: $(grep -A3 '^QUEUE' <<<"$OUT")"
fi

# --- 7. QUEUE section renders with PG up (mock psql) → state counts, oldest queued, leases ----
# A mock psql in TMP/bin returns canned data; AGENCY_PG_PORT=5432 overrides the gate's port=1
# so _pg_init's SELECT 1 reaches the mock and sets PG_AVAIL=1.
mkdir -p "$TMP/bin"
cat > "$TMP/bin/psql" <<'MOCK'
#!/usr/bin/env bash
# Mock psql for status QUEUE tests: args are: "conn_str" "-tAc" "SQL"
SQL="${3:-$(cat 2>/dev/null || true)}"
case "$SQL" in
  "SELECT 1") echo 1 ;;
  *"ORDER BY state"*) printf 'done: 3\nqueued: 1\n' ;;
  *"ORDER BY created_at"*) echo "test-oldest-job" ;;
  *"state='running'"*) echo 2 ;;
esac
exit 0
MOCK
chmod +x "$TMP/bin/psql"

D_MOCK="$(new_repo)"
OUT="$(STATUS_REPO="$D_MOCK" STATE_DIR="$TMP/nostate" PATH="$TMP/bin:$PATH" \
        AGENCY_PG_PORT=5432 "$STATUS" 2>&1)"
if grep -q '^QUEUE' <<<"$OUT" && grep -q 'done: 3' <<<"$OUT" \
     && grep -q 'test-oldest-job' <<<"$OUT" && grep -q 'leases in flight: 2' <<<"$OUT"; then
  pass "QUEUE section PG up (mock): shows state counts, oldest queued, leases in flight"
else
  fail "QUEUE section PG up — got: $(grep -A10 '^QUEUE' <<<"$OUT")"
fi

echo "---"
if [ "$FAIL" -ne 0 ]; then
  echo "status_test: FAIL"
  exit 1
fi
echo "status_test: $N/$N passed"
