#!/usr/bin/env bash
# shellcheck disable=SC2154 # ok, bad, expect, repo and work come from tests/run.sh
# Tests for scripts/blocked-scan.sh, with synthetic lists only (never the real ones).
# Sourced by tests/run.sh, which provides ok/bad/expect, $repo, $work and $fx.

echo "== blocked-scan.sh"
bs="$repo/scripts/blocked-scan.sh"
printf '["Zorblax", "blue moon", "acme/widget_co", "Fizz & Buzz"]\n' > "$work/blocked.json"
printf '["frobnic", "night owl"]\n' > "$work/stems.json"
export BLOCKED_FILE="$work/blocked.json" STEMS_FILE="$work/stems.json"
unset BLOCKED_JSON STEMS_JSON

s() { printf 'here\t%s\n' "$1" | bash "$bs" scan; }
expect 0 "clean text passes"                     s "Ordinary words only"
expect 1 "one-word term as a substring fails"    s "the zorblaxian empire"
grep -q "blocked name #1" <<<"$LAST_OUT" && ok "  reports the term number" || bad "  reports the term number" "$LAST_OUT"
! grep -qi "zorblax" <<<"$LAST_OUT" && ok "  never prints the term or the text" || bad "  never prints the term or the text" "$LAST_OUT"
expect 1 "multi-word term on word boundaries fails" s "Under a Blue Moon tonight"
expect 0 "multi-word term inside a longer word passes" s "a blue moonlight sonata"
expect 0 "multi-word term glued to a word passes" s "deepblue moon"
expect 1 "multi-word term next to punctuation fails" s "(blue moon)"
expect 1 "term with / and _ fails"               s "see ACME/WIDGET_CO docs"
expect 1 "multi-word term with & fails"          s "Fizz & Buzz Ltd"
expect 0 "stem hit is a warning, not a failure"  s "Frobnicate the thing"
grep -q "review stem #1" <<<"$LAST_OUT" && ! grep -qi frobnic <<<"$LAST_OUT" && ok "  warning names only the stem number" || bad "  warning names only the stem number" "$LAST_OUT"
expect 0 "multi-word stem on word boundaries warns" s "a Night Owl"
grep -q "review stem #2" <<<"$LAST_OUT" && ok "  multi-word stem reported" || bad "  multi-word stem reported" "$LAST_OUT"
expect 1 "blocked and stem together still fails" s "zorblax and frobnic"
GITHUB_ACTIONS=true expect 1 "GitHub annotations" s "zorblax"
grep -q "::error title=blocked name::here matches blocked name #1" <<<"$LAST_OUT" && ok "  ::error annotation without the term" || bad "  ::error annotation without the term" "$LAST_OUT"

# Lists from JSON text (secrets), and no lists at all.
expect 1 "lists from BLOCKED_JSON text" env -u BLOCKED_FILE -u STEMS_FILE BLOCKED_JSON='["zorblax"]' bash -c 'printf "x\tZORBLAX\n" | bash "$0" scan' "$bs"
expect 0 "no lists: nothing to match"   env -u BLOCKED_FILE -u STEMS_FILE bash -c 'printf "x\tzorblax\n" | bash "$0" scan' "$bs"
expect 3 "count with no lists exits 3"  env -u BLOCKED_FILE -u STEMS_FILE bash "$bs" count
expect 0 "count with lists"             bash "$bs" count
[ "$LAST_OUT" = "4 2" ] && ok "  counts terms per list" || bad "  counts terms per list" "$LAST_OUT"
expect 2 "a list that is not a JSON array is an error" env BLOCKED_JSON='zorblax' bash -c 'printf "x\ty\n" | bash "$0" scan' "$bs"
expect 0 "mask prints add-mask lines" bash "$bs" mask
[ "$(grep -c "^::add-mask::" <<<"$LAST_OUT")" -ge 6 ] && ok "  at least one mask per term" || bad "  at least one mask per term" "$LAST_OUT"

# Streams from a repository.
r="$work/bs-repo"; git init -q "$r"; cd "$r" || exit 1
echo "fine" > a.txt; git add a.txt; git commit -q -m "Base"
base=$(git rev-parse HEAD)
printf 'line one\nmentions zorblax here\n' > b.txt; git add b.txt; git commit -q -m "Add b"
scan_range() { bash "$bs" added "$base..HEAD" | bash "$bs" scan; }
expect 1 "added lines in a commit range"         scan_range
grep -q "b.txt:2: blocked name #1" <<<"$LAST_OUT" && ok "  location is commit, path and line" || bad "  location is commit, path and line" "$LAST_OUT"
git reset -q --hard "$base"
echo "plain" > "zorblax-notes.txt"; git add .; git commit -q -m "Add notes"
expect 1 "a path with a blocked name"            scan_range
git reset -q --hard "$base"
git commit -q --allow-empty -m "Fix" -m "About the Blue Moon project"
expect 1 "commit messages"                       bash -c 'bash "$0" messages "$1..HEAD" | bash "$0" scan' "$bs" "$base"
git reset -q --hard "$base"
echo "old zorblax line" > old.txt; git add old.txt; git commit -q -m "Old"; old=$(git rev-parse HEAD)
echo "unrelated" >> old.txt; git commit -q -am "Touch old"
expect 0 "only added lines count, not old lines in the same file" bash -c 'bash "$0" added "$1..HEAD" | bash "$0" scan' "$bs" "$old"
expect 1 "tree scan finds it in the current files" bash -c 'bash "$0" tree | bash "$0" scan' "$bs"
git rm -q old.txt; git commit -q -m "Remove old"
expect 0 "tree scan is clean after removal"      bash -c 'bash "$0" tree | bash "$0" scan' "$bs"
expect 1 "history scan still finds the removed file" bash -c 'bash "$0" history | bash "$0" scan' "$bs"
git checkout -q -b side; printf 'x\n' > s.txt; git add s.txt; git commit -q -m "Side"; git checkout -q main 2>/dev/null || git checkout -q master
git tag -a v0.1.0 -m "Release for the night owl crowd" "$base"
expect 1 "history scan (removed file still fails)" bash -c 'bash "$0" history | bash "$0" scan' "$bs"
grep -q "tag v0.1.0 message: review stem #2" <<<"$LAST_OUT" && ok "  stem in a tag message is reported as a warning" || bad "  stem in a tag message is reported as a warning" "$LAST_OUT"
expect 0 "history covers tag messages"           bash -c 'bash "$0" history | grep -q "^tag v0.1.0 message"' "$bs"
git branch -q zorblax-branch
expect 1 "history covers ref names"              bash -c 'bash "$0" history | grep "^ref " | bash "$0" scan' "$bs"
expect 1 "free text (PR body, release notes)"    bash -c 'printf "Intro\nThe blue moon release\n" | bash "$0" text "pull request body" | bash "$0" scan' "$bs"
grep -q "pull request body line 2: blocked name #2" <<<"$LAST_OUT" && ok "  free-text location" || bad "  free-text location" "$LAST_OUT"
cd "$repo" || exit 1
unset BLOCKED_FILE STEMS_FILE

echo "== blocked-scan.sh visibility (fake gh)"
fake="$work/fake-gh"
cat > "$fake" <<'GH'
#!/bin/sh
echo "$*" >> "$FAKE_GH_LOG"
case "$2" in
    repos/me/private-repo) echo private ;;
    repos/me/public-repo)  echo public ;;
    repos/me/inner-repo)   echo internal ;;
    *) echo "HTTP 404" >&2; exit 1 ;;
esac
GH
chmod +x "$fake"
export PORTFOLIO_GH="$fake" FAKE_GH_LOG="$work/gh.log"
v() { bash "$bs" visibility "$@"; }
vr="$work/vis"; git init -q "$vr"; cd "$vr" || exit 1
[ "$(v)" = public ] && ok "no remote -> public (fail safe)" || bad "no remote -> public"
git remote add origin https://github.com/me/private-repo.git
[ "$(v)" = private ] && ok "private GitHub remote -> private" || bad "private GitHub remote -> private"
: > "$FAKE_GH_LOG"; v >/dev/null
[ ! -s "$FAKE_GH_LOG" ] && ok "  second lookup comes from the cache" || bad "  second lookup comes from the cache" "$(cat "$FAKE_GH_LOG")"
sed -i 's/ \([0-9]*\)$/ 1/' .git/portfolio-visibility
: > "$FAKE_GH_LOG"; v >/dev/null
[ -s "$FAKE_GH_LOG" ] && ok "  stale cache entry is looked up again" || bad "  stale cache entry is looked up again"
git remote add mirror git@github.com:me/public-repo.git
[ "$(v)" = public ] && ok "any public remote -> public" || bad "any public remote -> public"
git remote remove mirror
git remote set-url --push origin https://gitlab.com/me/private-repo.git
[ "$(v)" = public ] && ok "a non-GitHub push URL -> public" || bad "a non-GitHub push URL -> public"
git config --unset remote.origin.pushurl
git remote add other https://github.com/me/unknown-repo
[ "$(v)" = public ] && ok "lookup failure (404 / not signed in) -> public" || bad "lookup failure -> public"
git remote remove other
[ "$(v ssh://git@github.com/me/private-repo.git)" = private ] && ok "ssh:// URL parsed" || bad "ssh:// URL parsed"
[ "$(v https://github.com/me/inner-repo)" = public ] && ok "internal counts as public" || bad "internal counts as public"
[ "$(v /some/local/path.git)" = public ] && ok "local path -> public" || bad "local path -> public"
[ "$(PORTFOLIO_GH=/nonexistent/gh v https://github.com/me/new-private)" = public ] && ok "gh missing -> public" || bad "gh missing -> public"
cd "$repo" || exit 1
unset PORTFOLIO_GH FAKE_GH_LOG

echo "== blocked-scan.sh hardening"
export BLOCKED_FILE="$work/blocked.json" STEMS_FILE="$work/stems.json"
out=$(printf 'path ZORBLAX/x.txt\tZORBLAX/x.txt\n' | BLOCKED_REDACT=1 bash "$bs" scan 2>&1)
grep -q "location withheld" <<<"$out" && ! grep -qi zorblax <<<"$out" && ok "a location containing a term is withheld (any case)" || bad "a location containing a term is withheld" "$out"
out=$(printf 'path ZORBLAX/x.txt\tZORBLAX/x.txt\n' | bash "$bs" scan 2>&1)
grep -q "ZORBLAX/x.txt" <<<"$out" && ok "  locally (no CI) the location is shown" || bad "  locally the location is shown" "$out"
GITHUB_ACTIONS=true bash -c 'printf "ref refs/heads/Blue-Moon-x\trefs/heads/Blue Moon x\n" | bash "$0" scan' "$bs" > "$work/o" 2>&1
! grep -qi "blue" "$work/o" && ok "  in CI the location is withheld automatically" || bad "  in CI the location is withheld automatically" "$(cat "$work/o")"
for bad_json in '["a", 3]' '{"a": "b"}' '["a" "b"]' '["unterminated]'; do
    expect 2 "malformed list rejected: $bad_json" env -u BLOCKED_FILE BLOCKED_JSON="$bad_json" bash -c 'printf "x\ty\n" | bash "$0" scan' "$bs"
done
bs_json=$(printf '["caf%s%s"]' "$(printf '\134')" u00e9)   # \134 = backslash; keeps this file ASCII
expect 2 "backslash-u escapes rejected" env -u BLOCKED_FILE BLOCKED_JSON="$bs_json" bash -c 'printf "x\ty\n" | bash "$0" scan' "$bs"
expect 0 "an empty list is fine"          env -u BLOCKED_FILE -u STEMS_FILE BLOCKED_JSON='[]' bash -c 'printf "x\ty\n" | bash "$0" scan' "$bs"
out=$(env -u BLOCKED_FILE -u STEMS_FILE BLOCKED_JSON='["Mix%Case"]' bash "$bs" mask)
grep -qx '::add-mask::Mix%25Case' <<<"$out" && grep -qx '::add-mask::mix%25case' <<<"$out" && grep -qx '::add-mask::MIX%25CASE' <<<"$out" \
    && ok "mask: as written, lower, upper, with % escaped" || bad "mask variants" "$out"
expect 1 "html: &amp; entity is decoded"   bash -c 'printf "<p>Fizz &amp; Buzz</p>\n" | bash "$0" html-text page | bash "$0" scan' "$bs"
expect 1 "html: name split by a tag"       bash -c 'printf "<p>Blue <b>Moon</b></p>\n" | bash "$0" html-text page | bash "$0" scan' "$bs"
expect 1 "html: name in an attribute"      bash -c 'printf "<img alt=\"zorbl&#97;x logo\">\n" | bash "$0" html-text page | bash "$0" scan' "$bs"
expect 0 "html: clean page"                bash -c 'printf "<p>Hello &amp; welcome</p>\n" | bash "$0" html-text page | bash "$0" scan' "$bs"

r="$work/bs-merge"; git init -q "$r"; cd "$r" || exit 1
git commit -q --allow-empty -m "Base"; base=$(git rev-parse HEAD)
git checkout -q -b topic; echo "zorblax" > t.txt; git add t.txt; git commit -q -m "t"; git rm -q t.txt; git commit -q -m "rm"
git checkout -q -; echo "m" > m.txt; git add m.txt; git commit -q -m "m"
git merge -q --no-ff --no-edit topic -s ours 2>/dev/null; git checkout -q topic -- . 2>/dev/null; true
git checkout -q -b fix "$base"; echo "plain" > a.txt; git add a.txt; git commit -q -m "a"
git checkout -q -b m2 "$base"; echo "x" > b.txt; git add b.txt; git commit -q -m "b"
git merge -q --no-commit fix 2>/dev/null; echo "zorblax via merge" >> a.txt; git add a.txt; git commit -q -m "Merge fix"
expect 1 "added lines introduced by a merge commit count" bash -c 'bash "$0" added "$1..HEAD" | bash "$0" scan' "$bs" "$base"
# Same blob at two paths: the second path (with a listed name) must still be scanned.
git checkout -q -b paths "$base"; echo "same" > one.txt; git add one.txt; git commit -q -m "one"
cp one.txt "zorblax-copy.txt"; git add .; git commit -q -m "copy"; git rm -q "zorblax-copy.txt"; git commit -q -m "rm copy"
expect 1 "history: a path that shares its blob with another path" bash -c 'bash "$0" history | grep "^path " | bash "$0" scan' "$bs"
cd "$work" || exit 1; mkdir -p notrepo; cd notrepo || exit 1
expect 2 "history outside a repo fails instead of passing" bash "$bs" history
cd "$repo" || exit 1

echo "== visibility: effective URLs"
export PORTFOLIO_GH="$fake" FAKE_GH_LOG="$work/gh.log"
vr="$work/vis2"; git init -q "$vr"; cd "$vr" || exit 1
git remote add origin https://github.com/me/private-repo.git
git config url."https://github.com/me/public-repo".insteadOf https://github.com/me/private-repo
[ "$(bash "$bs" visibility)" = public ] && ok "an insteadOf rewrite to a public repo counts" || bad "an insteadOf rewrite to a public repo counts"
cd "$repo" || exit 1
unset PORTFOLIO_GH FAKE_GH_LOG BLOCKED_FILE STEMS_FILE
