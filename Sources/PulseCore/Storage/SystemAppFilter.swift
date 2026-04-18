import Foundation

/// Bundle IDs that occupy the macOS foreground but **don't** represent
/// the user actually using their Mac:
///
/// - `com.apple.loginwindow` becomes the foreground while the screen is
///   locked. Pre-A26g a 12-hour overnight lock got credited to the user
///   as a 12-hour "deep focus session" on `loginwindow`, which is the
///   exact opposite of focus.
/// - `com.apple.WindowManager` is the Stage Manager runtime — it briefly
///   takes focus while the user is *organising* windows, not while they
///   are *in* them.
/// - `com.apple.dock` shows up when the user is in a Dock context menu;
///   they're navigating, not using.
///
/// Read paths in the analytics layer (`appUsageRanking`,
/// `longestFocusSegment`, `sessionPosture`) consult this set and skip
/// matching intervals so the user-facing surfaces never report this
/// kind of away / chrome time as activity.
///
/// Why filter at the read layer rather than at the writer:
/// 1. The raw `system_events` table stays an honest log of what the
///    OS actually told us — useful for the privacy-audit window and
///    for any future "lock periods" feature that wants to surface
///    away time deliberately.
/// 2. Adding more bundle IDs to the exclusion list later doesn't
///    require re-running the rollups.
public enum SystemAppFilter {
    public static let excludedBundles: Set<String> = [
        "com.apple.loginwindow",
        "com.apple.WindowManager",
        "com.apple.dock"
    ]
}
