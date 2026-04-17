# Workflow — how to ship a change in Pulse

> Operating contract between the user and the agent. The summary: **never
> merge a PR without green CI**, and the agent must be able to read CI
> failures itself.

## The PR loop

For every change worth shipping:

1. **Create a feature branch** off `main`. Name pattern:
   `claude/<phase>-<topic>` (e.g. `claude/b3-distance`).

2. **Commit and push**. Push always carries the branch's full history.

3. **Open a PR** targeting `main`. Use the `mcp__github__create_pull_request`
   tool. Title and body should be informative; reference the relevant
   `docs/*` for context.

4. **Subscribe** to the PR via `mcp__github__subscribe_pr_activity`.
   Activity (CI status, comments, reviews) will flow into the conversation.

5. **Wait for CI** — `ci.yml` runs `lint`, `build-and-test (macos-14)`
   and `build-and-test (macos-15)`. All three must complete with
   `conclusion: success`.

6. **If CI fails**, the workflow auto-posts a comment to the PR with:
   - run URL
   - last 120 lines of `resolve.log`, `build.log`, `test.log`
   - distilled `error:` / `warning:` / `FAIL` lines
   The agent reads the comment via
   `mcp__github__pull_request_read get_comments` and iterates by
   pushing fixes to the same branch.

7. **Once CI is green**, merge — only then is `main` updated.

8. **Never** force-push to `main`, never merge with `--no-verify` or
   while the check runs are red. If something blocks shipping, raise it
   in the PR conversation, do not bypass.

## Tools the agent uses for this loop

| Step | Tool |
|---|---|
| Push code | `Bash` → `git push -u origin <branch>` |
| Open PR | `mcp__github__create_pull_request` |
| Subscribe | `mcp__github__subscribe_pr_activity` |
| Read CI status | `mcp__github__pull_request_read` (`get_check_runs`) |
| Read failure log comments | `mcp__github__pull_request_read` (`get_comments`) |
| Merge | `mcp__github__merge_pull_request` (only after green) |

## CI itself (what `.github/workflows/ci.yml` does)

- `lint` (macos-15): runs `scripts/lint.sh` — privacy red lines + style
- `build-and-test (macos-14)`, `build-and-test (macos-15)`:
  - `setup-xcode@v1` pins Xcode 16+ so Swift Testing is available
  - `swift package resolve | tee resolve.log`
  - `swift build --build-tests | tee build.log`
  - `swift test --parallel --enable-code-coverage | tee test.log`
  - `xcrun llvm-cov` produces a coverage report (warns if < 85%)
  - on **failure**: uploads `*.log` as artifacts AND posts a comment on
    the PR with the relevant log excerpts so the agent can self-debug

## Nightly CI

`.github/workflows/nightly.yml` runs once a day on `macos-15` with
`PULSE_RUN_BENCHMARKS=1`. Failures don't block PRs but should be
investigated within a day.

## Branch protection (recommended setup, not enforced by code)

- Require `lint`, `build-and-test (macos-14)`, `build-and-test (macos-15)`
  to pass before merge
- Require linear history (no merge commits inside feature branches)
- Squash on merge

## What the agent does NOT do

- Open PRs without being asked (or, in CI-fix branches, without a clear
  "this is a fix" need that the user has consented to)
- Merge red PRs
- Push directly to `main`
- Force-push or rewrite published history

## Troubleshooting checklist when CI is red

1. Read the most recent **PR failure comment** — it has the actual error.
2. If the comment is missing (e.g. workflow hadn't posted it yet),
   download the `logs-<runner>` artifact from the run.
3. Reproduce locally if a Mac is available
   (`make build && make test`).
4. Push the fix to the same branch, wait for the next CI run.
5. Iterate. Don't merge until all required checks are `success`.
