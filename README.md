# portfolio-ci

Reusable GitHub Actions workflows shared by the repos in my portfolio. Each repo calls the checks it needs with a few lines of YAML, and the logic lives here, tested and pinned.

| Workflow | What it checks | Use it in |
| --- | --- | --- |
| [`attribution.yml`](#attribution) | No commit credits an AI tool as co-author or author | Every repo |
| [`site-quality.yml`](#site-quality) | Broken links, social preview tags, Lighthouse scores | Repos with a live site |
| [`hygiene.yml`](#hygiene) | Merged or stale branches; the README opens with a screenshot and a live link | Every repo |
| [`release.yml`](#release) | On a `v*` tag, publishes a GitHub Release from that version's CHANGELOG section | Repos that ship versions |
| [`scorecard.yml`](#scorecard) | OpenSSF Scorecard supply-chain checks, uploaded to code scanning | Every public repo |
| [`blocked-names.yml`](#blocked-names) | No name from a private block list appears in files, paths, commit messages, refs, tags or PR text | Every public repo |

## Adopting it in a repo

Copy the files you need from [`templates/`](templates) into the repo's `.github/` folder. Workflows go in `.github/workflows/`, and `dependabot.yml` goes in `.github/`. Then replace `PORTFOLIO_CI_SHA` with the commit of the release you want:

```powershell
$sha = gh api repos/ZakJRademacher/portfolio-ci/commits/v1.0.0 --jq .sha
Get-ChildItem .github -Recurse -Filter *.yml | ForEach-Object { (Get-Content $_ -Raw) -replace 'PORTFOLIO_CI_SHA', $sha | Set-Content $_ -NoNewline }
```

The template `dependabot.yml` keeps every SHA pin current, including the pins to portfolio-ci itself. Dependabot opens one grouped PR a week that updates each SHA and its `# vX.Y.Z` comment together.

## Permissions

Every workflow sets `permissions: contents: read` at the top. Jobs that need more ask for it themselves, and a caller must grant at least what the called job asks for:

| Workflow | Job | Extra permission | Why |
| --- | --- | --- | --- |
| `hygiene.yml` | `branches` | `pull-requests: read` | List merged PRs to spot squash-merged branches |
| `release.yml` | `publish` | `contents: write` | Create the release |
| `scorecard.yml` | `analysis` | `actions: read`, `security-events: write` | Read workflow runs; upload SARIF |

GitHub checks these grants before it evaluates `if:`, so a caller must grant them even when the job will be skipped (for example `release.yml` with `dry-run: true`).

## Pinning

Call the workflows at a full commit SHA, with the version in a comment, the same way every action here is pinned:

```yaml
uses: ZakJRademacher/portfolio-ci/.github/workflows/attribution.yml@<commit-sha> # v1.0.0
```

`@v1.0.0` (a fixed tag) or `@v1` (a moving tag that follows the latest 1.x) also work, at the cost of trusting the tag. Inside these workflows, every third-party action is pinned to a full SHA, and the `@lhci/cli` and actionlint versions are fixed. Each workflow checks out its own scripts at the exact commit the caller pinned (`job.workflow_sha`), so a caller never runs scripts from a newer version than the workflow it asked for.

## attribution

Fails if any commit in a push or pull request:

- has a `Co-Authored-By:` line naming Claude or Anthropic
- has a `Claude-Session:` trailer
- contains "Generated with Claude Code"
- has an author or committer named Claude (`claude[bot]` included), with an `anthropic.com` email, or with the `claude[bot]` GitHub noreply address

Matching ignores case. Prose that mentions Claude ("Support the Claude API") passes. The rules match the local git guard (`attribution-guard.sh`), which stops these commits before they are made. Install it from your private config repo as a global git hook.

Which commits it scans: a pull request's commits (`base..head`), or a push's new commits (`before..after`). On a new branch, a tag, a force push, or when the old tip is unknown, it scans everything reachable from the new tip. Set `full-history: true` to scan every branch and tag (useful as a one-off audit).

```yaml
# .github/workflows/checks.yml
name: checks
on:
  push:
  pull_request:

permissions:
  contents: read

jobs:
  attribution:
    uses: ZakJRademacher/portfolio-ci/.github/workflows/attribution.yml@<commit-sha> # v1.0.0
```

| Input | Default | Meaning |
| --- | --- | --- |
| `full-history` | `false` | Scan every commit reachable from any branch or tag |

The status check is named **`attribution / scan`**. My repos allow direct pushes to `main` and don't require pull requests, so this check is a **backstop**. It reports a bad commit after it lands, and then you rewrite history. The real block is the local git guard, which refuses the commit before it is made. Pull requests from forks get a read-only token and no secrets, and the scan only reads commit metadata. It never runs code from the PR.

## site-quality

Checks a live site after it deploys:

- **links:** [lychee](https://github.com/lycheeverse/lychee) checks every link on the listed pages. Set `check-external-links: false` to check same-site links only.
- **social-preview:** each page returns 200 and has `og:title`, `og:image` and a description (`meta name="description"`, or `og:description` as a fallback). The `og:image` must return 200 with an image content type.
- **lighthouse:** [Lighthouse CI](https://github.com/GoogleChrome/lighthouse-ci) runs each page `lighthouse-runs` times and scores the median run against your thresholds. The job summary shows a table of scores, and the full reports are kept as a build artifact for 14 days.

Lighthouse scores on shared runners vary by a few points, so a low score **warns** by default. Set `lighthouse-enforce: true` once your thresholds have some headroom. Broken links and missing preview tags always fail the job.

```yaml
# .github/workflows/site-quality.yml
name: site-quality
on:
  workflow_run:
    workflows: [deploy]        # the name of the workflow that publishes the site
    types: [completed]
  schedule:
    - cron: "0 7 * * 1"        # weekly, to catch links that break later
  workflow_dispatch:

permissions:
  contents: read

jobs:
  site:
    if: ${{ github.event_name != 'workflow_run' || github.event.workflow_run.conclusion == 'success' }}
    uses: ZakJRademacher/portfolio-ci/.github/workflows/site-quality.yml@<commit-sha> # v1.0.0
    with:
      url: https://zakjrademacher.github.io/my-project/
      paths: "/ about.html"
      min-performance: 0.8
      min-accessibility: 0.95
```

| Input | Default | Meaning |
| --- | --- | --- |
| `url` | required | Base URL of the live site |
| `paths` | `""` | Space-separated pages, relative to `url`. Empty means just `url` |
| `check-links` | `true` | Run the link check |
| `check-external-links` | `true` | Also check links that leave the site |
| `lighthouse` | `true` | Run Lighthouse |
| `lighthouse-enforce` | `false` | Fail (rather than warn) when a score is below its threshold |
| `lighthouse-runs` | `3` | Runs per page. The median run is scored |
| `lighthouse-preset` | `desktop` | `desktop` or `mobile` |
| `min-performance` | `0.8` | 0 to 1. Set 0 to turn this category off |
| `min-accessibility` | `0.9` | 0 to 1 |
| `min-best-practices` | `0.9` | 0 to 1 |
| `min-seo` | `0.9` | 0 to 1 |

## hygiene

- **branches:** lists branches on the remote that are merged into the default branch, or whose last commit is older than `stale-days`. A branch also counts as merged when a merged pull request's head is still at the same commit, which catches squash and rebase merges that ancestry checks miss. Flagged branches only warn, unless `fail-on-branches: true`.
- **readme:** after the title and any badges, the README must open with a screenshot (a Markdown image, `<img>` or `<picture>`; badges don't count). It must also link to the live site within the first `readme-top-lines` lines. Links to GitHub, badges and images don't count as live links.

```yaml
# in .github/workflows/checks.yml, next to attribution
  hygiene:
    uses: ZakJRademacher/portfolio-ci/.github/workflows/hygiene.yml@<commit-sha> # v1.0.0
    permissions:
      contents: read
      pull-requests: read
    with:
      live-url: https://zakjrademacher.github.io/my-project/
```

| Input | Default | Meaning |
| --- | --- | --- |
| `check-branches` | `true` | List merged and stale branches |
| `stale-days` | `90` | Days without commits before a branch counts as stale |
| `ignore-branches` | `gh-pages` | Space-separated branches never flagged (the default branch is always ignored) |
| `fail-on-branches` | `false` | Fail rather than warn when a branch is flagged |
| `check-readme` | `true` | Check the README opening |
| `readme-path` | `README.md` | README to check |
| `readme-top-lines` | `15` | The live link must appear within this many lines |
| `live-url` | `""` | If set, the README must link to exactly this URL |
| `require-live-link` | `true` | Set `false` for repos without a site (for example a desktop app) |

## release

On a version tag push, it takes that version's section from `CHANGELOG.md` and publishes it as a GitHub Release. If the release already exists, it updates the notes. The job fails if the section is missing or empty, so add the section before you tag.

Accepted section headings, in [Keep a Changelog](https://keepachangelog.com) style: `## [1.2.0] - 2026-11-24`, `## [1.2.0]`, `## 1.2.0`, `## v1.2.0`. The section runs until the next `## ` heading. Tags with a hyphen (`v2.0.0-rc.1`) become pre-releases.

```yaml
# .github/workflows/release.yml
name: release
on:
  push:
    tags: ["v*.*.*"]

permissions:
  contents: read

jobs:
  release:
    uses: ZakJRademacher/portfolio-ci/.github/workflows/release.yml@<commit-sha> # v1.0.0
    permissions:
      contents: write
```

| Input | Default | Meaning |
| --- | --- | --- |
| `changelog-path` | `CHANGELOG.md` | Changelog location |
| `version` | tag name | Version to release, if not the pushed tag |
| `dry-run` | `false` | Show the notes in the job summary without publishing |
| `draft` | `false` | Create the release as a draft |

Only the `publish` job gets `contents: write`. The job that reads the changelog runs read-only. Releases use `gh release create --verify-tag`, so the tag must already exist on GitHub.

## scorecard

Runs [OpenSSF Scorecard](https://github.com/ossf/scorecard) on the default branch and uploads the findings to the repo's **Security > Code scanning** page. Scorecard covers pinned dependencies, token permissions, branch protection, dangerous workflow patterns and more. It doesn't publish to the public Scorecard API, because publishing needs an `id-token` grant that Scorecard only accepts from a workflow in the repo itself.

```yaml
# .github/workflows/scorecard.yml
name: scorecard
on:
  push:
    branches: [main]
  branch_protection_rule:
  schedule:
    - cron: "30 6 * * 1"
  workflow_dispatch:

permissions:
  contents: read

jobs:
  scorecard:
    uses: ZakJRademacher/portfolio-ci/.github/workflows/scorecard.yml@<commit-sha> # v1.0.0
    permissions:
      contents: read
      actions: read
      security-events: write
```

| Input | Default | Meaning |
| --- | --- | --- |
| `fail-below` | `0` | Fail when the overall score (0 to 10) is below this. `0` reports only |

## blocked-names

Checks for names that must never appear in public. The names come from a private block list that is never stored in this repo, in the calling repo, or in any log. There are two lists, each a JSON array of strings:

| List | A hit means |
| --- | --- |
| blocked names | **Failure**: the job fails |
| review stems | **Warning** only: shown for a person to review, never fails |

Matching ignores case. A one-word term matches anywhere, even inside a longer word. A term with a space in it only matches as whole words, so a two-word phrase inside a longer word doesn't count.

**What is scanned.** With `scope: changes` (the default), it scans the current files and paths, the messages and added lines of the push or PR commits, the ref name, and the PR title, body and branch. With `scope: history`, it scans every branch and tag: all commit messages, tag messages, ref names, and every file version and path ever committed. The same lists are also checked in release notes (`release.yml`) and on live pages (`site-quality.yml`), when you pass them there.

**Where it applies.** It applies to public repos and to anything about to go public. Private repos are exempt: when GitHub reports the repo as `private`, the check is skipped with a notice. Any other answer, including none, counts as public. A live site is always checked, because Pages from a private repo are still public. The attribution checks run everywhere.

**How the lists reach CI.** Through secrets. Store each list as a repository secret, for example with `gh secret set PORTFOLIO_BLOCKED < blocked.json` and `gh secret set PORTFOLIO_BLOCKED_STEMS < stems.json`, and pass them in. Where no list is available (forks, Dependabot PRs, repos without the secrets), the check is skipped with a notice. Set `require-lists: true` to make that an error. Each term is masked in the log before anything runs, and reports show only a location and a term number (`blocked name #12`), never the term or the matching text.

```yaml
# in .github/workflows/checks.yml
  blocked-names:
    uses: ZakJRademacher/portfolio-ci/.github/workflows/blocked-names.yml@<commit-sha> # v1.0.0
    secrets:
      blocked-names: ${{ secrets.PORTFOLIO_BLOCKED }}
      blocked-stems: ${{ secrets.PORTFOLIO_BLOCKED_STEMS }}
```

| Input | Default | Meaning |
| --- | --- | --- |
| `scope` | `changes` | `changes` or `history` (for a scheduled or one-off full audit) |
| `require-lists` | `false` | Fail rather than skip when no list was passed |

The local git guard applies the same rule (private repos exempt, unknown counts as public) and reads the lists from a local folder.

## Testing

```bash
bash tests/run.sh
```

This runs every script against the fixtures in `tests/fixtures`: throwaway git repos, sample READMEs and changelogs, and a local web server for the preview-tag check. It also checks that every action is pinned. On GitHub, [`self-test.yml`](.github/workflows/self-test.yml) runs the same tests, lints the workflows with actionlint and shellcheck, and calls each reusable workflow through `uses: ./...`. That covers a real attribution scan, a hygiene check, a release dry run, and a site check against a live site. It runs on every push and pull request, and weekly.

## Releasing portfolio-ci

Version tags are protected by a ruleset, and the repo owner is the only bypass actor. So **tagging a release needs the owner**: only the owner can push a `v*` tag or move `v1`. The release workflow runs on the tag the owner pushed. It creates the GitHub Release with the workflow token and `--verify-tag`, so it never creates or moves a tag itself and the tag ruleset doesn't block it. The same holds in every repo that uses `release.yml`.

1. Add a `## [x.y.z]` section to [CHANGELOG.md](CHANGELOG.md).
2. The owner tags and pushes: `git tag vX.Y.Z && git push origin vX.Y.Z`. [`publish-release.yml`](.github/workflows/publish-release.yml) then creates the release with `release.yml` itself.
3. The owner moves the major tag: `git tag -f v1 vX.Y.Z && git push -f origin v1`.

## Limits

- Direct pushes to `main` are allowed, so `attribution / scan` and `blocked-names / scan` report a bad commit after it lands. They are a backstop. The local guard is what stops it.
- GitHub lets you edit a merge commit message in the web UI. The push scan flags it, but only after the merge.

## License

MIT
