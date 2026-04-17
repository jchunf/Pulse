# A6 Progress — Permission Recovery Assistant (F-49 deepening)

> Delivered under branch `claude/check-progress-XvlUY`. Sixth A-track
> slice. Builds on the existing HealthPanel + PermissionSnapshot
> infrastructure from B1 and A5.

## Scope

Close a common MVP failure mode: macOS revokes Input Monitoring and
Accessibility across upgrades or when the app binary is replaced. Today
the menu bar icon flips to `exclamationmark.triangle` and the
HealthPanel's status headline reads "Permissions needed" — but the user
has no in-app action to take. They must know which pane of System
Settings to open, which isn't obvious.

A6 adds a `PermissionAssistantView` to the menu bar that appears only
when required permissions are missing, and gives the user a one-click
deep-link to each relevant System Settings pane.

## ✅ Delivered

### PulseCore

| Path | Change |
|---|---|
| `Permissions/PermissionService.swift` | New `Permission.required: [Permission]` (inputMonitoring + accessibility). New `Permission.systemSettingsURL: URL?` returning `x-apple.systempreferences:` deep-link URLs for each pane. New `Permission.displayName: String` for human-facing labels. New `PermissionSnapshot.missingRequired: [Permission]` that lists required permissions whose status is not `.granted`, in canonical ordering. `isAllRequiredGranted` rewritten to share logic with `missingRequired`. |

### PulseApp

| Path | Change |
|---|---|
| `PulseApp.swift` | New `PermissionAssistantView`. Rendered as an empty view when nothing is missing; otherwise shows an orange triangle label, a one-line explainer, and one `Button` per missing permission that calls `NSWorkspace.shared.open(url)` on the pane-specific deep-link. Placed in `HealthMenuView` directly after the permission list so users see the context before the call-to-action. |

### Tests (Swift Testing, 6 new cases)

| Suite | New cases |
|---|---|
| `PermissionServiceTests` (new) | 6: `required` equals `[inputMonitoring, accessibility]`; every `Permission.allCases` has a `Privacy`-pane URL; every case has a non-empty `displayName`; `missingRequired` returns only unsatisfied required perms (optional ones don't leak); empty set when all required granted; canonical ordering preserved. |

## 🟡 Intentionally deferred

1. **Dashboard warning banner** — same assistant on the main Dashboard window so users who never open the menu bar still see the call-to-action. Simple View addition; kept out of this PR.
2. **Automatic re-check after deep-link** — today the user has to switch back to Pulse; the polling loop picks up the status change within 1s. A `NSApplication.didBecomeActiveNotification` hook could force an immediate refresh.
3. **First-run onboarding flow** — a full guided "welcome → privacy → Input Monitoring → Accessibility → done" flow that uses the same deep-links but in a stepwise UX. Tracks with the UX milestone alongside Settings.
4. **Permission request prompts** — `PermissionService.requestAccess(for:)` is already part of the protocol but the deep-link path is complementary (and survives a case where macOS already denied silently).

## 🧪 Verification

- Swift toolchain not available in this sandbox. Compile + test runs on
  the macos-14 / macos-15 matrix.
- Manual UI verification: revoke Pulse's Input Monitoring permission in
  System Settings, re-open Pulse's menu bar — the assistant block
  should appear with "Open Input Monitoring settings" and clicking it
  should jump straight to the Privacy → Input Monitoring pane.

## Related documents

- B1 → `B1-PROGRESS.md` (shipped `PermissionSnapshot`, `PermissionService`)
- A5 → `A5-PROGRESS.md` (menu bar control pattern used here)
- Feature spec → `02-features.md#f-49-自检状态页`
- Onboarding → `06-onboarding-permissions.md`
