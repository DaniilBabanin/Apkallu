#!/usr/bin/env bash
# Tests for local/state-sync.sh — no LLM, no network.
# Feeds a fixture DECISIONS file with a known mix of tagged and untagged entries
# and asserts the generated block equals the expected block byte-for-byte.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
STATE_SYNC="$REPO_DIR/local/state-sync.sh"

pass=0
fail=0

check() {
    local desc="$1" got="$2" want="$3"
    if [ "$got" = "$want" ]; then
        echo "  PASS: $desc"
        pass=$((pass + 1))
    else
        echo "  FAIL: $desc" >&2
        echo "    want: $(printf '%s' "$want" | head -5)" >&2
        echo "    got:  $(printf '%s' "$got" | head -5)" >&2
        fail=$((fail + 1))
    fi
}

FIXTURE="$(mktemp)"
trap 'rm -f "$FIXTURE"' EXIT

cat > "$FIXTURE" <<'EOF'
# Fixture decisions file for state_sync_test.sh

## D-001 — Alpha decision
**Question:** Is this a test?
**Answer:** yes
**Binding:** yes

---

## D-002 — Beta decision
**Question:** Is this also a test?
**Answer:** yes

---

## D-003 — Gamma decision
**Question:** Third test?
**Answer:** yes
**Binding:** yes

---

## D-004 — Delta decision
**Question:** Fourth test?
**Answer:** mentions "**Binding:** yes" in the body but is not tagged
This line has **Binding:** yes embedded in prose but is indented
EOF

EXPECTED="binding decisions in force
D-001 — Alpha decision
D-003 — Gamma decision"

# Test 1: output matches expected byte-for-byte
got="$("$STATE_SYNC" "$FIXTURE")"
check "fixture: tagged D-001 and D-003 appear, D-002 and D-004 absent" "$got" "$EXPECTED"

# Test 2: no LLM or network calls — script must be pure bash/awk (verified by shellcheck in gate)
# We confirm the script itself runs without any network by checking no curl/wget calls are made.
# (shellcheck -x will also catch use of external commands in gate.sh; this is belt-and-suspenders.)
if grep -qE '\bcurl\b|\bwget\b|\bllm\b' "$STATE_SYNC"; then
    echo "  FAIL: state-sync.sh contains network/LLM calls" >&2
    fail=$((fail + 1))
else
    echo "  PASS: state-sync.sh has no network/LLM calls"
    pass=$((pass + 1))
fi

# Test 3: embedded "**Binding:** yes" in prose (D-004) is NOT treated as a tag
if echo "$got" | grep -q "D-004"; then
    echo "  FAIL: D-004 (prose mention only) must not appear in output" >&2
    fail=$((fail + 1))
else
    echo "  PASS: prose mention of **Binding:** yes in D-004 body not treated as tag"
    pass=$((pass + 1))
fi

# --- apply mode (CM-1: rewrite ONLY the binding block in STATE.md) -----------
BEGIN_MARK='<!-- BEGIN binding-block (auto-synced by local/state-sync.sh apply — do not hand-edit) -->'
END_MARK='<!-- END binding-block -->'

STATE_FIXTURE="$(mktemp)"
trap 'rm -f "$FIXTURE" "$STATE_FIXTURE"' EXIT

cat > "$STATE_FIXTURE" <<EOF
# Test anchor
## Invariants (hand-seeded)
- alpha invariant
- beta invariant

$BEGIN_MARK
stale block line 1 — must be replaced
stale block line 2
$END_MARK
trailing hand-seeded line
EOF

"$STATE_SYNC" apply "$STATE_FIXTURE" "$FIXTURE"

# Test 4: the block BETWEEN the markers byte-matches state-sync print output.
between="$(awk '/BEGIN binding-block/{f=1;next} /END binding-block/{f=0} f' "$STATE_FIXTURE")"
check "apply: between-markers block byte-matches print output" "$between" "$EXPECTED"

# Test 5: hand-seeded section preserved; stale block content gone.
if grep -q 'alpha invariant' "$STATE_FIXTURE" \
   && grep -q 'trailing hand-seeded line' "$STATE_FIXTURE" \
   && ! grep -q 'stale block line' "$STATE_FIXTURE"; then
  echo "  PASS: apply preserves hand-seeded section and drops stale block"
  pass=$((pass + 1))
else
  echo "  FAIL: apply did not preserve hand-seeded section / drop stale block" >&2
  fail=$((fail + 1))
fi

# Test 6: idempotent — a second apply yields the identical block.
"$STATE_SYNC" apply "$STATE_FIXTURE" "$FIXTURE"
between2="$(awk '/BEGIN binding-block/{f=1;next} /END binding-block/{f=0} f' "$STATE_FIXTURE")"
check "apply: idempotent (second apply == first)" "$between2" "$EXPECTED"

# Test 7: missing markers -> refuse (rc 3), file untouched.
NO_MARKERS="$(mktemp)"
printf '# anchor with no markers\njust a line\n' > "$NO_MARKERS"
before="$(cat "$NO_MARKERS")"
rc=0
"$STATE_SYNC" apply "$NO_MARKERS" "$FIXTURE" 2>/dev/null || rc=$?
after="$(cat "$NO_MARKERS")"
rm -f "$NO_MARKERS"
if [ "$rc" -eq 3 ] && [ "$before" = "$after" ]; then
  echo "  PASS: apply refuses (rc 3) and leaves a marker-less file untouched"
  pass=$((pass + 1))
else
  echo "  FAIL: apply on marker-less file: rc=$rc (want 3), file changed=$([ "$before" = "$after" ] && echo no || echo yes)" >&2
  fail=$((fail + 1))
fi

echo ""
echo "state_sync_test: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
