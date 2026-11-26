#!/usr/bin/env bash
# Local and CI tests for the scripts behind the reusable workflows.
#   bash tests/run.sh
# Needs git, bash, python 3 (as python3 or python). No network.
set -u

here=$(cd "$(dirname "$0")" && pwd)
repo=$(cd "$here/.." && pwd)
fx="$here/fixtures"
py=$(command -v python3 || command -v python)
work=$(mktemp -d)
server_pid=''
cleanup() { [ -n "$server_pid" ] && kill "$server_pid" 2>/dev/null; rm -rf "$work"; }
trap cleanup EXIT

export GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL="$work/gitconfig"
printf '[user]\n\tname = Test Human\n\temail = human@example.com\n[init]\n\tdefaultBranch = main\n[commit]\n\tgpgsign = false\n[tag]\n\tgpgsign = false\n' > "$GIT_CONFIG_GLOBAL"
unset GITHUB_STEP_SUMMARY

pass=0; fail=0
ok()  { pass=$((pass+1)); echo "ok   $1"; }
bad() { fail=$((fail+1)); echo "FAIL $1"; [ -n "${2:-}" ] && sed 's/^/     | /' <<<"$2"; }
# expect <exit code> <name> <command...>
expect() {
    local want=$1 name=$2; shift 2
    local out rc; out=$("$@" 2>&1); rc=$?
    if [ "$rc" -eq "$want" ]; then ok "$name"; else bad "$name (wanted exit $want, got $rc)" "$out"; fi
    LAST_OUT=$out
}

echo "== attribution-scan.sh"
scan="$repo/scripts/attribution-scan.sh"
r="$work/scan"; git init -q "$r"; cd "$r" || exit 1
git commit -q --allow-empty -m "Base"
git commit -q --allow-empty -m "Support the Claude API" -m "Co-Authored-By: Jane <jane@example.com>"
expect 0 "clean history passes" bash "$scan" HEAD
base=$(git rev-parse HEAD)
git commit -q --allow-empty -m "Fix" -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
expect 1 "Co-Authored-By Claude fails" bash "$scan" "$base..HEAD"
grep -q "message line: Co-Authored-By: Claude" <<<"$LAST_OUT" && ok "  names the offending line" || bad "  names the offending line" "$LAST_OUT"
grep -q "::error" <<<"$LAST_OUT" && ok "  emits a GitHub error annotation" || bad "  emits a GitHub error annotation" "$LAST_OUT"
git reset -q --hard "$base"
for case in "Claude-Session: abc" "🤖 Generated with [Claude Code](https://claude.com/claude-code)" "co-authored-by: bot <x@anthropic.com>"; do
    git commit -q --allow-empty -m "x" -m "$case"
    expect 1 "fails: $case" bash "$scan" "$base..HEAD"
    git reset -q --hard "$base"
done
git commit -q --allow-empty -m "x" -m "Co-Authored-By: Claudette <c@notanthropic.com>"; expect 0 "passes: co-author Claudette at notanthropic.com" bash "$scan" "$base..HEAD"; git reset -q --hard "$base"
git commit -q --allow-empty -m "x" -m "Co-Authored-By: Pat	Smith <x@example.com>" --author "Claude	Bot <c@example.com>"; expect 1 "fails: tab inside an author name" bash "$scan" "$base..HEAD"; git reset -q --hard "$base"
git commit -q --allow-empty -m "x" --author "Claude <c@example.com>";              expect 1 "fails: author Claude" bash "$scan" "$base..HEAD"; git reset -q --hard "$base"
git commit -q --allow-empty -m "x" --author "Bot <b@mail.anthropic.com>";          expect 1 "fails: anthropic.com subdomain" bash "$scan" "$base..HEAD"; git reset -q --hard "$base"
git commit -q --allow-empty -m "x" --author "H <1+claude[bot]@users.noreply.github.com>"; expect 1 "fails: claude[bot] noreply" bash "$scan" "$base..HEAD"; git reset -q --hard "$base"
GIT_COMMITTER_NAME=Claude git commit -q --allow-empty -m "x";                       expect 1 "fails: committer Claude" bash "$scan" "$base..HEAD"; git reset -q --hard "$base"
git commit -q --allow-empty -m "x" --author "Claudette <c@notanthropic.com>";      expect 0 "passes: Claudette at notanthropic.com" bash "$scan" "$base..HEAD"; git reset -q --hard "$base"
expect 0 "--all works" bash "$scan" --all
expect 2 "unreadable range is an error, not a pass" bash "$scan" "deadbeef..HEAD"
GITHUB_STEP_SUMMARY="$work/summary.md"; export GITHUB_STEP_SUMMARY
git commit -q --allow-empty -m "x" -m "Claude-Session: s"; bash "$scan" "$base..HEAD" >/dev/null 2>&1
grep -q "Attribution scan failed" "$work/summary.md" && ok "writes a job summary table" || bad "writes a job summary table"
unset GITHUB_STEP_SUMMARY; cd "$repo" || exit 1

echo "== attribution-range.sh"
ar="$repo/scripts/attribution-range.sh"
cd "$r" || exit 1
git reset -q --hard "$base"; one=$(git rev-parse HEAD~1); two=$(git rev-parse HEAD)
z=0000000000000000000000000000000000000000
rng() { env -i PATH="$PATH" HOME="$HOME" GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL="$GIT_CONFIG_GLOBAL" "$@" bash "$ar" 2>/dev/null; }
[ "$(rng FULL=true AFTER="$two")" = "--all" ] && ok "full-history scans --all" || bad "full-history scans --all"
[ "$(rng PR_BASE="$one" PR_HEAD="$two" EVENT=pull_request AFTER=x)" = "$one..$two" ] && ok "pull request scans base..head" || bad "pull request scans base..head"
[ "$(rng EVENT=push REF_TYPE=branch BEFORE="$one" AFTER="$two")" = "$one..$two" ] && ok "push scans before..after" || bad "push scans before..after"
[ "$(rng EVENT=push REF_TYPE=branch BEFORE="$z" AFTER="$two")" = "$two" ] && ok "new branch scans everything reachable" || bad "new branch scans everything reachable"
[ "$(rng EVENT=push REF_TYPE=branch BEFORE="$two" AFTER="$one")" = "$one" ] && ok "force push (before not an ancestor) scans everything" || bad "force push scans everything"
[ "$(rng EVENT=push REF_TYPE=branch BEFORE=1234567890123456789012345678901234567890 AFTER="$two")" = "$two" ] && ok "unknown before sha scans everything" || bad "unknown before sha scans everything"
[ "$(rng EVENT=push REF_TYPE=tag BEFORE="$one" AFTER="$two")" = "$two" ] && ok "tag push scans everything" || bad "tag push scans everything"
cd "$repo" || exit 1

. "$here/blocked-scan.test.sh"

echo "== changelog-section.sh"
cl="$repo/scripts/changelog-section.sh"
expect 0 "## [1.2.0] - date found" bash "$cl" v1.2.0 "$fx/CHANGELOG.md"
grep -q "Release notes come from this section." <<<"$LAST_OUT" && ! grep -q "Plain heading" <<<"$LAST_OUT" \
    && ok "  section stops at the next heading" || bad "  section stops at the next heading" "$LAST_OUT"
[ "$(head -1 <<<"$LAST_OUT")" = "### Added" ] && ok "  leading blank lines trimmed" || bad "  leading blank lines trimmed" "$LAST_OUT"
expect 0 "## 1.1.0 (no brackets) found" bash "$cl" 1.1.0 "$fx/CHANGELOG.md"
! grep -q "compare" <<<"$LAST_OUT" && ok "  link references excluded" || bad "  link references excluded" "$LAST_OUT"
expect 0 "## v1.0.0 found" bash "$cl" v1.0.0 "$fx/CHANGELOG.md"
expect 1 "empty section fails" bash "$cl" v1.3.0 "$fx/CHANGELOG.md"
expect 1 "missing version fails" bash "$cl" v9.9.9 "$fx/CHANGELOG.md"
expect 1 "1.2 does not match 1.2.0" bash "$cl" v1.2 "$fx/CHANGELOG.md"
expect 1 "missing file fails" bash "$cl" v1.2.0 "$fx/nope.md"
printf '## [2.0.0]\r\n\r\n- CRLF file\r\n' > "$work/crlf.md"
expect 0 "CRLF changelog works" bash "$cl" v2.0.0 "$work/crlf.md"

echo "== readme_check.py"
rc="$repo/scripts/readme_check.py"
expect 0 "title, badge, screenshot, live link" "$py" "$rc" "$fx/readme/good.md"
expect 0 "HTML title and centred <img>" "$py" "$rc" "$fx/readme/good-html.md"
expect 0 "--live-url matches (trailing slash ignored)" "$py" "$rc" "$fx/readme/good.md" --live-url https://perigee.example.dev
expect 1 "--live-url mismatch fails" "$py" "$rc" "$fx/readme/good.md" --live-url https://other.example.dev
expect 1 "text before the screenshot fails" "$py" "$rc" "$fx/readme/text-first.md"
expect 1 "badges are not screenshots" "$py" "$rc" "$fx/readme/badges-only.md"
expect 1 "GitHub and image links are not live links" "$py" "$rc" "$fx/readme/no-live-link.md"
expect 1 "links in HTML comments and code blocks do not count" "$py" "$rc" "$fx/readme/hidden-link.md"
expect 0 "--no-live-link skips the link rule" "$py" "$rc" "$fx/readme/no-live-link.md" --no-live-link
expect 1 "missing README fails" "$py" "$rc" "$fx/readme/nope.md"

echo "== lhci_config.py"
lc="$repo/scripts/lhci_config.py"
expect 0 "config written" "$py" "$lc" "$work/lhci.json" --urls "https://a.dev/ https://a.dev/b" --runs 3 --performance 0.7 --seo 0 --level warn
"$py" - "$work/lhci.json" <<'EOF' && ok "  urls, runs, median, warn level, seo off" || bad "  urls, runs, median, warn level, seo off" "$(cat "$work/lhci.json")"
import json, sys
c = json.load(open(sys.argv[1]))["ci"]
a = c["assert"]["assertions"]
assert c["collect"]["url"] == ["https://a.dev/", "https://a.dev/b"]
assert c["collect"]["numberOfRuns"] == 3 and c["collect"]["settings"] == {"preset": "desktop"}
assert a["categories:performance"] == ["warn", {"minScore": 0.7, "aggregationMethod": "median-run"}]
assert "categories:seo" not in a and a["categories:accessibility"][1]["minScore"] == 0.9
assert c["upload"]["target"] == "filesystem"
EOF
expect 1 "threshold above 1 rejected" "$py" "$lc" "$work/x.json" --urls "https://a.dev/" --performance 80

echo "== lhci_summary.py"
mkdir -p "$work/lhci"
for s in 0.5 0.9 0.7; do
    printf '{"finalDisplayedUrl":"https://a.dev/","categories":{"performance":{"score":%s},"seo":{"score":1}}}' "$s" > "$work/lhci/lhr-$s.json"
done
expect 0 "summary runs" "$py" "$repo/scripts/lhci_summary.py" "$work/lhci"
grep -q "| https://a.dev/ | 70 | - | - | 100 |" <<<"$LAST_OUT" && ok "  median score per category" || bad "  median score per category" "$LAST_OUT"

echo "== site_meta.py (local server)"
port=$((20000 + RANDOM % 20000))
(cd "$fx/site" && exec "$py" -m http.server "$port" --bind 127.0.0.1) >/dev/null 2>&1 &
server_pid=$!
for _ in $(seq 1 50); do "$py" -c "import urllib.request; urllib.request.urlopen('http://127.0.0.1:$port/index.html')" 2>/dev/null && break; sleep 0.2; done
sm="$repo/scripts/site_meta.py"
expect 0 "page with og:title, og:image (relative) and description" "$py" "$sm" "http://127.0.0.1:$port/index.html"
expect 1 "page without tags fails" "$py" "$sm" "http://127.0.0.1:$port/missing.html"
grep -q "missing og:title" <<<"$LAST_OUT" && grep -q "missing og:image" <<<"$LAST_OUT" && grep -q "missing meta description" <<<"$LAST_OUT" \
    && ok "  reports each missing tag" || bad "  reports each missing tag" "$LAST_OUT"
expect 1 "og:image that does not load fails" "$py" "$sm" "http://127.0.0.1:$port/broken-image.html"
grep -q "og:image https://127.0.0.1:1/nope.png" <<<"$LAST_OUT" && ok "  uses the first og:image and reports it" || bad "  uses the first og:image and reports it" "$LAST_OUT"
expect 0 "relative og:image resolves against the URL after a redirect" "$py" "$sm" "http://127.0.0.1:$port/sub"
expect 1 "404 page fails" "$py" "$sm" "http://127.0.0.1:$port/nope.html"
expect 1 "one bad page fails the run" "$py" "$sm" "http://127.0.0.1:$port/index.html" "http://127.0.0.1:$port/missing.html"

echo "== branch-hygiene.sh"
bh="$repo/scripts/branch-hygiene.sh"
o="$work/origin.git"; git init -q --bare "$o"
r="$work/bh"; git clone -q "$o" "$r" 2>/dev/null; cd "$r" || exit 1
git commit -q --allow-empty -m "Base"; git push -q origin main
git checkout -q -b merged-feature; git commit -q --allow-empty -m "f"; git push -q origin merged-feature
git checkout -q main; git merge -q --ff-only merged-feature; git push -q origin main
git checkout -q -b old-work; GIT_COMMITTER_DATE="2020-01-01T00:00:00Z" git commit -q --allow-empty -m "old"; git push -q origin old-work
git checkout -q -b active main; git commit -q --allow-empty -m "new"; git push -q origin active
git checkout -q -b gh-pages main; GIT_COMMITTER_DATE="2020-01-01T00:00:00Z" git commit -q --allow-empty -m "site"; git push -q origin gh-pages
git checkout -q main; git fetch -q origin
expect 3 "flags merged and stale branches" env -u GH_TOKEN bash "$bh" main 90 "gh-pages"
grep -q '`merged-feature` | merged into main' <<<"$LAST_OUT" && ok "  merged branch flagged" || bad "  merged branch flagged" "$LAST_OUT"
grep -q '`old-work` | no commits for' <<<"$LAST_OUT" && ok "  stale branch flagged" || bad "  stale branch flagged" "$LAST_OUT"
! grep -qE '`(active|gh-pages|main)`' <<<"$LAST_OUT" && ok "  active, ignored and default branches not flagged" || bad "  active, ignored and default branches not flagged" "$LAST_OUT"
git push -q origin :merged-feature :old-work; git fetch -q --prune origin
expect 0 "clean repo passes" env -u GH_TOKEN bash "$bh" main 90 "gh-pages"
cd "$repo" || exit 1

echo "== workflow files"
for f in "$repo"/.github/workflows/*.yml; do
    n=$(basename "$f")
    bad_pins=$(grep -nE '^\s*(-\s*)?uses:\s+[^.]' "$f" | grep -vE '@([0-9a-f]{40}|sha256:[0-9a-f]{64}) # v?[0-9]' || true)
    [ -z "$bad_pins" ] && ok "$n: every action pinned to a full SHA or digest with a version comment" || bad "$n: unpinned action" "$bad_pins"
done

echo
echo "passed: $pass  failed: $fail"
[ "$fail" -eq 0 ]
