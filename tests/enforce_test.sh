#!/usr/bin/env bash
# Tests for loop/enforce.sh — the mechanical agency/client commit split + external-project commit
# flow. (Kill-switch tests removed 2026-06-12 with the switches themselves — director ruling.)
# Fixture-driven: every case runs in a throwaway git repo and pins "today" / the ledger via env,
# so NO claude, NO network, and the live repo's state never affects the assertions.
set -euo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENF="$SELF_DIR/loop/enforce.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

FAIL=0
N=0
pass() { N=$((N + 1)); echo "ok   $1"; }
fail() { N=$((N + 1)); FAIL=1; echo "FAIL $1"; }

# Fresh temp git repo standing in for the agency repo: director/ + one commit so rev-list works.
new_agency() {
  local d
  d="$(mktemp -d "$TMP/ag.XXXXXX")"
  git -C "$d" init -q
  git -C "$d" config user.email t@t
  git -C "$d" config user.name t
  git -C "$d" config commit.gpgsign false
  mkdir -p "$d/director"
  printf '# Decisions Queue\n' > "$d/director/DECISIONS.md"
  printf 'seed\n' > "$d/seed"
  git -C "$d" add -A
  git -C "$d" commit -q -m init
  printf '%s' "$d"
}

# Fresh temp git repo standing in for a CLIENT project checkout: one committed file.
new_project() {
  local d
  d="$(mktemp -d "$TMP/proj.XXXXXX")"
  git -C "$d" init -q
  git -C "$d" config user.email d@d
  git -C "$d" config user.name Dev
  git -C "$d" config commit.gpgsign false
  printf 'v1\n' > "$d/app.js"
  git -C "$d" add -A
  git -C "$d" commit -q -m "initial app"
  printf '%s' "$d"
}

# enforce.sh against an agency fixture with the standard overrides.
enf() { # $1 = agency repo, rest = args
  local repo="$1"; shift
  ENFORCE_REPO="$repo" CLIENT_LEDGER=cl.log "$ENF" "$@"
}

# --- 7. record appends a 5-field tab-separated ledger line -----------------------------------
D="$(new_agency)"
enf "$D" record proj feat/pen deadbeef "fix the thing" >/dev/null 2>&1
fields="$(awk -F'\t' 'END{print NF}' "$D/cl.log")"
hasproj="$(cut -f2 "$D/cl.log")"
if [ "$fields" = 5 ] && [ "$hasproj" = proj ]; then
  pass "record appends one 5-field (date/proj/branch/sha/subject) ledger line"
else
  fail "record ledger line (fields=$fields proj=$hasproj)"
fi

# --- 8. counts: agency from git history, client from ledger, days since last client ----------
D="$(new_agency)"   # 1 commit
printf '2026-06-05T10:00:00+00:00\tp\tb\ts1\tone\n2026-06-06T10:00:00+00:00\tp\tb\ts2\ttwo\n' > "$D/cl.log"
out="$(ENFORCE_TODAY=2026-06-07 enf "$D" counts)"
if [ "$out" = "agency=1 client=2 last_client=2026-06-06 days=1" ]; then
  pass "counts: agency=1 (git) client=2 (ledger) last_client/days correct"
else
  fail "counts output: '$out'"
fi

# counts with no ledger -> client=0, last_client=never
D="$(new_agency)"
out="$(ENFORCE_TODAY=2026-06-07 enf "$D" counts)"
if [ "$out" = "agency=1 client=0 last_client=never days=-" ]; then
  pass "counts: empty ledger -> client=0, last_client=never"
else
  fail "counts empty-ledger output: '$out'"
fi

# --- 9. sanitize strips attribution + agency tokens + loop: prefix, keeps the dev body --------
clean="$(printf 'loop: add pen pointer handling\n\nDrag selects, finger scrolls.\nCo-Authored-By: Claude <x>\n🤖 Generated with Claude Code\nrefs cascade unit D-007 in NOTES.md\n' \
          | "$ENF" sanitize)"
if grep -q '^add pen pointer handling$' <<<"$clean" \
     && grep -q 'Drag selects, finger scrolls.' <<<"$clean" \
     && ! grep -qiE 'claude|co-authored|🤖|cascade|D-007|NOTES.md|^loop:' <<<"$clean"; then
  pass "sanitize: strips loop: prefix + Claude/AI attribution + agency tokens, keeps dev text"
else
  fail "sanitize output: $(printf '%s' "$clean" | tr '\n' '|')"
fi

# --- 10. project-commit gate GREEN: isolated branch commit + sanitized msg + ledger + default untouched
D="$(new_agency)"
P="$(new_project)"
defbranch="$(git -C "$P" rev-parse --abbrev-ref HEAD)"
printf 'v2 with pen support\n' > "$P/app.js"
msg="$(printf 'loop: add pen pointer handling\nCo-Authored-By: Claude <x>')"
set +e
ENFORCE_REPO="$D" CLIENT_LEDGER=cl.log "$ENF" project-commit "$P" feat/pen 'true' "$msg" >/dev/null 2>&1
rc=$?
set -e
on_branch="$(git -C "$P" rev-parse --abbrev-ref HEAD)"
commit_msg="$(git -C "$P" log -1 --format='%B' 2>/dev/null)"
def_commits="$(git -C "$P" rev-list --count "$defbranch")"
ledger_n="$(awk 'END{print NR+0}' "$D/cl.log" 2>/dev/null || echo 0)"
ledger_branch="$(cut -f3 "$D/cl.log" 2>/dev/null)"
if [ "$rc" -eq 0 ] && [ "$on_branch" = feat/pen ] \
     && grep -q '^add pen pointer handling$' <<<"$commit_msg" \
     && ! grep -qiE 'claude|co-authored|^loop:' <<<"$commit_msg" \
     && [ "$def_commits" = 1 ] && [ "$ledger_n" = 1 ] && [ "$ledger_branch" = feat/pen ]; then
  pass "project-commit (gate green): isolated branch + sanitized msg + ledger record + default branch untouched"
else
  fail "project-commit green (rc=$rc branch=$on_branch def_commits=$def_commits ledger_n=$ledger_n msg='$(tr '\n' ' ' <<<"$commit_msg")')"
fi

# --- 11. project-commit gate RED: rc 1, no commit, no ledger line ----------------------------
D="$(new_agency)"
P="$(new_project)"
printf 'broken\n' > "$P/app.js"
before="$(git -C "$P" rev-parse HEAD)"
set +e
ENFORCE_REPO="$D" CLIENT_LEDGER=cl.log "$ENF" project-commit "$P" feat/pen 'false' "more work" >/dev/null 2>&1
rc=$?
set -e
after="$(git -C "$P" rev-parse HEAD)"
ledger_exists="$([ -f "$D/cl.log" ] && echo yes || echo no)"
if [ "$rc" -eq 1 ] && [ "$before" = "$after" ] && [ "$ledger_exists" = no ]; then
  pass "project-commit (gate red): rc 1, project HEAD unchanged, no ledger record"
else
  fail "project-commit red (rc=$rc head_changed=$([ "$before" = "$after" ] && echo no || echo yes) ledger=$ledger_exists)"
fi

# --- 12. project-commit with nothing to commit -> rc 2 --------------------------------------
D="$(new_agency)"
P="$(new_project)"
set +e
ENFORCE_REPO="$D" CLIENT_LEDGER=cl.log "$ENF" project-commit "$P" feat/pen 'true' "noop" >/dev/null 2>&1
rc=$?
set -e
if [ "$rc" -eq 2 ]; then
  pass "project-commit with a clean project tree: rc 2 (nothing to commit)"
else
  fail "project-commit nothing-to-commit (rc=$rc, want 2)"
fi

echo "---"
if [ "$FAIL" -ne 0 ]; then
  echo "enforce_test: FAILURES present ($N checks run)"
  exit 1
fi
echo "enforce_test: ALL $N checks passed"
