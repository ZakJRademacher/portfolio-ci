#!/usr/bin/env bash
# blocked-scan.sh: check text against the private block lists.
#
# The lists are flat JSON arrays of strings, kept by Security (never in a repo):
#   blocked names  -> a hit is a FAILURE
#   review stems   -> a hit is a WARNING for a human to review; never fails
# Pass them as JSON text (BLOCKED_JSON / STEMS_JSON, e.g. from Actions secrets) or
# as files (BLOCKED_FILE / STEMS_FILE, e.g. a local copy for the git guard).
#
# Policy: blocked names fail in public repos and in anything about to go public
# (live pages, release notes). Private repos are exempt. Use `visibility` to decide,
# and treat anything that can't be confirmed private as public.
#
# Matching ignores case. A one-word term matches as a substring; a term with a
# space in it matches only on word boundaries (so ordinary two-word phrases
# inside longer words don't trip it).
#
# Output never contains a term or the text that matched: only where it was found
# and the term's number in its list (blocked #N / stem #N).
#
# Commands (each reads the repository in the current directory):
#   scan                 stdin lines "<location><TAB><text>" -> report; exit 1 on a blocked hit
#   mask                 print ::add-mask:: for every term (GitHub Actions)
#   count                print "<blocked> <stems>" term counts; exit 3 when both are empty
#   messages <revs...>   stream commit messages for the rev-list args
#   diff-lines           stdin `git log -p -U0 --format=%x1e%h` or `git diff -U0` -> stream of added lines
#   added <revs...>      stream lines added by those commits (and the paths they touch)
#   tree                 stream every text file and path in the working tree (tracked files)
#   history              stream every blob and path reachable from any ref or tag,
#                        all commit messages, tag messages and ref names
#   text <label>         stdin free text (PR body, release notes) -> stream
#   visibility [url...]  print "private" only when every GitHub remote (or each given
#                        URL) is confirmed private via `gh api`; otherwise "public".
#                        No remote, a non-GitHub remote, or any lookup failure -> public.
#                        Confirmed answers are cached in .git/portfolio-visibility
#                        (private for 10 minutes, public for 1 day). PORTFOLIO_GH overrides gh.
#   html-text <label>    stdin HTML -> stream of its visible text and attribute values,
#                        with entities decoded (needs python3 or python)
set -uo pipefail

cmd=${1:-}; [ $# -gt 0 ] && shift
tab=$'\t'

# --- lists -------------------------------------------------------------------
terms_from() { # $1 = JSON text -> one term per line
    printf '%s' "$1" | tr -d '\r' | grep -o '"\([^"\\]\|\\.\)*"' \
        | sed -e 's/^"//' -e 's/"$//' -e 's/\\"/"/g' -e 's/\\\\/\\/g'
}
json_of() { # $1 = JSON text var value, $2 = file path
    if [ -n "$1" ]; then printf '%s' "$1"
    elif [ -n "$2" ] && [ -f "$2" ]; then cat "$2"
    fi
}
load_lists() {
    work=$(mktemp -d); trap 'rm -rf "$work"' EXIT
    local b s
    b=$(json_of "${BLOCKED_JSON:-}" "${BLOCKED_FILE:-}")
    s=$(json_of "${STEMS_JSON:-}" "${STEMS_FILE:-}")
    for pair in "blocked:$b" "stems:$s"; do
        local name=${pair%%:*} json=${pair#*:} rest
        if [ -n "$json" ]; then
            # Must be a flat array of strings: with the strings removed, only brackets,
            # commas and whitespace may remain. \u escapes are not supported.
            rest=$(printf '%s' "$json" | tr -d '\r\n' | sed -e 's/"\([^"\\]\|\\.\)*"/S/g')
            if ! printf '%s' "$rest" | grep -qE '^[[:space:]]*\[[[:space:]]*(S([[:space:]]*,[[:space:]]*S)*)?[[:space:]]*\][[:space:]]*$'; then
                echo "blocked-scan: the $name list is not a flat JSON array of strings" >&2; exit 2
            fi
            if printf '%s' "$json" | grep -q '\\u'; then
                echo "blocked-scan: the $name list uses \\u escapes, which are not supported; write the characters directly" >&2; exit 2
            fi
        fi
        terms_from "$json" | sed -e '/^$/d' > "$work/$name.all"
        # Split into one-word (substring) and multi-word (word boundary) pattern files.
        grep -v '[[:space:]]' "$work/$name.all" > "$work/$name.single" || true
        grep '[[:space:]]' "$work/$name.all" > "$work/$name.multi" || true
    done
}

# --- report ------------------------------------------------------------------
# $1 list name, $2 stream file -> lines "<location><TAB><term number>"
hits() {
    local list=$1 stream=$2 all="$work/$1.all"
    [ -s "$all" ] || return 0
    {
        [ -s "$work/$list.single" ] && grep -a -i -F -f "$work/$list.single" "$stream"
        [ -s "$work/$list.multi" ]  && grep -a -i -w -F -f "$work/$list.multi" "$stream"
    } | sort -u | while IFS= read -r line; do
        loc=${line%%"$tab"*}
        n=0
        while IFS= read -r term; do
            n=$((n + 1))
            case "$term" in
                *[[:space:]]*) printf '%s\n' "$line" | grep -a -q -i -w -F -- "$term" ;;
                *)             printf '%s\n' "$line" | grep -a -q -i -F -- "$term" ;;
            esac && printf '%s\t%s\n' "$loc" "$n"
        done < "$all"
    done | sort -u
}

# A location (path, ref, URL) can itself contain a listed term, in any letter case,
# which literal masks would not catch. In CI (or with BLOCKED_REDACT=1) such a
# location is replaced by a short hash of it.
safe_loc() {
    local loc=$1
    if [ "${GITHUB_ACTIONS:-}" = true ] || [ "${BLOCKED_REDACT:-}" = 1 ]; then
        # Compare with case and punctuation ignored, so "Blue-Moon" or "blue_moon"
        # in a path or ref counts as containing "blue moon".
        norm() { tr '[:upper:]' '[:lower:]' | sed -e 's/[^a-z0-9&]\{1,\}/ /g'; }
        if printf '%s\n' "$loc" | grep -q -i -F -f <(cat "$work/blocked.all" "$work/stems.all") \
           || printf '%s\n' "$loc" | norm | grep -q -F -f <(cat "$work/blocked.all" "$work/stems.all" | norm); then
            loc="location withheld (it contains a listed name; id $(printf '%s' "$1" | sha1sum | cut -c1-10))"
        fi
    fi
    printf '%s' "$loc"
}

scan() {
    load_lists
    local stream="$work/stream"
    cat > "$stream"
    local fails warns
    fails=$(hits blocked "$stream")
    warns=$(hits stems "$stream")
    local gh=${GITHUB_ACTIONS:-}
    if [ -n "$warns" ]; then
        echo "Names to review (warning only, not a failure):"
        while IFS="$tab" read -r loc n; do
            loc=$(safe_loc "$loc")
            echo "  $loc: review stem #$n"
            [ -n "$gh" ] && echo "::warning title=name to review::$loc matches review stem #$n"
        done <<< "$warns"
    fi
    if [ -n "$fails" ]; then
        echo "Blocked names found:"
        while IFS="$tab" read -r loc n; do
            loc=$(safe_loc "$loc")
            echo "  $loc: blocked name #$n"
            [ -n "$gh" ] && echo "::error title=blocked name::$loc matches blocked name #$n"
        done <<< "$fails"
        if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
            { echo "### Blocked names"; echo; echo "$(wc -l <<< "$fails") hit(s); see the job log for locations. Terms are not shown."; } >> "$GITHUB_STEP_SUMMARY"
        fi
        return 1
    fi
    echo "No blocked names found."
    return 0
}

# --- streams -----------------------------------------------------------------
# Every producer returns non-zero when git fails, so a scan never passes on
# partial input.
messages() {
    git --no-replace-objects log --format='%x1e%h%n%B' "$@" | awk '
        /^\036/ { h = substr($0, 2); n = 0; next }
        { n++; print "commit " h " message line " n "\t" $0 }'
}

diff_lines() {
    awk '
        /^\036/ { c = substr($0, 2); next }
        /^\+\+\+ / { p = substr($0, 5); sub(/^b\//, "", p); if (p != "/dev/null") print pre() "path " p "\t" p; next }
        /^--- / { next }
        /^@@ / { match($0, /\+[0-9]+/); n = substr($0, RSTART + 1, RLENGTH - 1) + 0; next }
        /^\+/ { print pre() p ":" n "\t" substr($0, 2); n++; next }
        function pre() { return c == "" ? "" : "commit " c " " }'
}

added() {
    # --diff-merges=first-parent: lines a merge brings in count too.
    git --no-replace-objects log -p -U0 --no-color --no-ext-diff --no-renames \
        --diff-merges=first-parent --format='%x1e%h' "$@" | diff_lines
}

tree() {
    git ls-files | awk '{ print "path " $0 "\t" $0 }' || return 2
    local files
    files=$(git grep -I -l -e '' -- .) || [ $? -eq 1 ] || return 2   # 1 = no text files
    [ -n "$files" ] || return 0
    while IFS= read -r f; do
        awk -v f="$f" '{ print f ":" FNR "\t" $0 }' "$f" || return 2
    done <<< "$files"
}

history() {
    messages --all || return 2
    git for-each-ref --format='%(refname)' | awk '{ print "ref " $0 "\t" $0 }' || return 2
    local refs objs
    refs=$(git for-each-ref --format='%(objecttype) %(refname:short)' refs/tags) || return 2
    while read -r type name; do
        [ "$type" = tag ] || continue
        git cat-file tag "$name" | awk -v t="$name" 'f { print "tag " t " message\t" $0 } /^$/ { f = 1 }' || return 2
    done <<< "$refs"
    # Every path that ever existed (rev-list shows only one path per object).
    git --no-replace-objects log --all --format= --name-only --no-renames --diff-merges=first-parent \
        | awk 'NF && !seen[$0]++ { print "path " $0 "\t" $0 }' || return 2
    objs=$(git --no-replace-objects rev-list --objects --all) || return 2
    local types sha type
    types=$(cut -d' ' -f1 <<< "$objs" | git --no-replace-objects cat-file --batch-check='%(objectname) %(objecttype)') || return 2
    declare -A isblob=()
    while read -r sha type; do [ "$type" = blob ] && isblob[$sha]=1; done <<< "$types"
    while read -r sha path; do
        [ -n "${isblob[$sha]:-}" ] || continue
        git cat-file -p "$sha" | awk -v p="${path:-blob}@${sha:0:12}" '{ print p ":" FNR "\t" $0 }' || return 2
    done <<< "$objs"
}

text() {
    awk -v l="${1:-text}" '{ print l " line " NR "\t" $0 }'
}

# HTML -> the raw lines, plus the visible text and attribute values with entities
# decoded, so "&amp;" or a name split by a tag still matches.
html_text() {
    local py label=${1:-page}
    py=$(command -v python3 || command -v python) || { echo "blocked-scan: html-text needs python" >&2; return 2; }
    local html; html=$(cat)
    printf '%s\n' "$html" | text "$label (html)"
    printf '%s\n' "$html" | "$py" -I -c '
import html.parser, sys
class P(html.parser.HTMLParser):
    def __init__(self):
        super().__init__(convert_charrefs=True); self.out = []; self.skip = 0
    def handle_starttag(self, tag, attrs):
        if tag in ("script", "style"): self.skip += 1
        for k, v in attrs:
            if v and k in ("alt", "title", "content", "href", "src", "aria-label", "placeholder", "value"): self.out.append("\n" + v + "\n")
    def handle_endtag(self, tag):
        if tag in ("script", "style") and self.skip: self.skip -= 1
        if tag in ("p", "div", "li", "br", "h1", "h2", "h3", "h4", "h5", "h6", "tr", "td", "th", "section", "article", "title"): self.out.append("\n")
    def handle_data(self, d):
        if not self.skip: self.out.append(d)
p = P(); p.feed(sys.stdin.read()); p.close()
text = " ".join("".join(p.out).replace("\r", "").split(" "))
print("\n".join(" ".join(l.split()) for l in text.split("\n") if l.strip()))
' | text "$label (text)"
}

# --- visibility ----------------------------------------------------------------
github_slug() { # URL -> owner/repo, or nothing for a non-GitHub URL
    printf '%s\n' "$1" \
        | sed -nE 's#^(https?://([^@/]+@)?github\.com/|(ssh://)?git@github\.com[:/])([^/]+/[^/]+)/?$#\4#p' \
        | sed -e 's/\.git$//'
}

lookup_visibility() { # owner/repo -> private|public|internal, or nothing when unknown
    local slug=$1 cache now line v ts
    cache="$(git rev-parse --git-common-dir 2>/dev/null)/portfolio-visibility"
    now=$(date +%s)
    if [ -f "$cache" ]; then
        line=$(awk -v s="$slug" '$1 == s' "$cache" | tail -1)
        v=$(printf '%s' "$line" | awk '{print $2}'); ts=$(printf '%s' "$line" | awk '{print $3}')
        if [ -n "$v" ] && [ -n "$ts" ]; then
            ttl=86400; [ "$v" = private ] && ttl=600
            [ $((now - ts)) -lt "$ttl" ] && { echo "$v"; return; }
        fi
    fi
    v=$("${PORTFOLIO_GH:-gh}" api "repos/$slug" --jq .visibility 2>/dev/null | tr -d '\r[:space:]')
    case "$v" in
        private|public|internal)
            if [ -d "$(dirname "$cache")" ]; then
                { awk -v s="$slug" '$1 != s' "$cache" 2>/dev/null; echo "$slug $v $now"; } > "$cache.tmp" && mv "$cache.tmp" "$cache"
            fi
            echo "$v" ;;
    esac
}

visibility() {
    local urls=() u slug
    if [ $# -gt 0 ]; then
        urls=("$@")
    else
        # Configured URLs, and the effective ones after insteadOf / pushInsteadOf.
        while IFS= read -r u; do [ -n "$u" ] && urls+=("$u"); done < <(
            git config --get-regexp '^remote\..*\.(url|pushurl)$' 2>/dev/null | awk '{print $2}'
            for r in $(git remote 2>/dev/null); do
                git remote get-url --all "$r" 2>/dev/null
                git remote get-url --push --all "$r" 2>/dev/null
            done)
    fi
    [ ${#urls[@]} -gt 0 ] || { echo public; return; }
    for u in "${urls[@]}"; do
        slug=$(github_slug "$u")
        [ -n "$slug" ] || { echo public; return; }
        [ "$(lookup_visibility "$slug")" = private ] || { echo public; return; }
    done
    echo private
}

case "$cmd" in
    scan) scan ;;
    mask)
        # Each term as written, in lower case and in upper case. Workflow commands
        # decode %25, %0D and %0A, so % is escaped first.
        load_lists
        cat "$work/blocked.all" "$work/stems.all" | while IFS= read -r t; do
            printf '%s\n' "$t"
            printf '%s\n' "$t" | tr '[:upper:]' '[:lower:]'
            printf '%s\n' "$t" | tr '[:lower:]' '[:upper:]'
        done | awk '!seen[$0]++' | sed -e 's/%/%25/g' | while IFS= read -r v; do echo "::add-mask::$v"; done ;;
    count) load_lists; b=$(wc -l < "$work/blocked.all"); s=$(wc -l < "$work/stems.all"); echo "$b $s"; [ "$b" -gt 0 ] || [ "$s" -gt 0 ] || exit 3 ;;
    messages) messages "$@" ;;
    diff-lines) diff_lines ;;
    added) added "$@" ;;
    tree) tree ;;
    history) history ;;
    text) text "$@" ;;
    html-text) html_text "$@" ;;
    visibility) visibility "$@" ;;
    *) sed -n '2,/^set -uo/p' "$0" | sed -e '$d' -e 's/^# \{0,1\}//'; exit 2 ;;
esac
