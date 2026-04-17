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

5. **Actively poll CI status** — **do not sit idle waiting for webhooks**.
   After opening the PR, immediately call `mcp__github__pull_request_read`
   with method `get_check_runs`. Keep polling on a light cadence (e.g.
   every ~30 seconds) until **every required check has
   `status: completed`**. Webhook events are a bonus, not a substitute
   for polling — if they arrive, great; if they don't, polling finds the
   result anyway. Never end a turn with "I'll wait for the webhook" —
   check right now.

6. **Read results**:
   - All `conclusion: success` → **still read PR comments** via
     `mcp__github__pull_request_read get_comments`. CI posts a
     "⚠️ passed with warnings" comment if the run emitted `warning:` /
     `error:` / assertion lines even while staying green. Investigate
     those before merging — a green run with warnings is not done.
   - Any `conclusion: failure` → read the "❌ failed" PR comment. Parse,
     diagnose, push a fix to the same branch, then poll again.
   - Any `status: in_progress` → poll again until completed.
   - Clean green with no warning comment → proceed to merge (step 8).

7. **Never** end a turn describing work as "done" if CI is still pending
   or red. "Waiting for CI" is not a completion state.

8. **Once all required checks are green**, merge via
   `mcp__github__merge_pull_request` (squash) and
   `mcp__github__unsubscribe_pr_activity`. Only then is `main` updated.

9. **Never** force-push to `main`, never merge with `--no-verify` or
   while the check runs are red. If something blocks shipping, raise it
   in the PR conversation, do not bypass.

## Tools the agent uses for this loop

| Step | Tool |
|---|---|
| Push code | `Bash` → `git push -u origin <branch>` |
| Open PR | `mcp__github__create_pull_request` |
| Subscribe | `mcp__github__subscribe_pr_activity` |
| **Poll CI status (active)** | `mcp__github__pull_request_read` (`get_check_runs`) — call after every push, every fix, and whenever the PR is waiting for CI |
| Read failure log comments | `mcp__github__pull_request_read` (`get_comments`) |
| Merge | `mcp__github__merge_pull_request` (only after all required checks `success`) |
| Unsubscribe | `mcp__github__unsubscribe_pr_activity` (after merge / close) |

## CI itself (what `.github/workflows/ci.yml` does)

- `lint` (macos-15): runs `scripts/lint.sh` — privacy red lines + style
- `build-and-test (macos-14)`, `build-and-test (macos-15)`:
  - `setup-xcode@v1` pins Xcode 16+ so Swift Testing is available
  - `swift package resolve | tee resolve.log`
  - `swift build --build-tests | tee build.log`
  - `swift test --parallel --enable-code-coverage | tee test.log`
  - `xcrun llvm-cov` produces a coverage report (warns if < 85%)
  - on **failure or passing-with-warnings**: uploads `*.log` as
    artifacts AND posts a comment on the PR with the relevant log
    excerpts so the agent can self-debug. Clean green runs post no
    comment.

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
4. Push the fix to the same branch, **then call `get_check_runs`
   immediately** to confirm the new run started, and keep polling until
   it completes.
5. Iterate. Don't merge until all required checks are `success`.

## Turn-end rule

Before ending a turn that involves a PR:

- If the PR is open with CI not yet completed: **poll `get_check_runs`
  now**. If still pending, state the current status and the next
  expected checkpoint. Don't declare the turn "done".
- If the PR is open with CI failed: fix or escalate. Never end a turn
  with a red PR and no next step.
- If the PR is open with CI all green: merge (or explicitly confirm with
  the user, per §"What the agent does NOT do"). A green, un-merged PR
  is an incomplete turn unless the user directed otherwise.
