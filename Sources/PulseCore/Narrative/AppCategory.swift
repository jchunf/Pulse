import Foundation

/// F-09 — classifies a foreground bundle into one of four high-level
/// categories used by the Focus donut. Per Q-01 (decision D) the
/// default is auto-classification based on a bundleId prefix table;
/// user whitelists are a follow-up (v1.3) that will override this
/// default.
///
/// The four buckets map to Pulse's "focus donut" segments:
/// - `.deepFocus`     — code editors, writing tools, design tools.
/// - `.communication` — email, chat, video calls.
/// - `.browsing`      — web browsers.
/// - `.other`         — everything not in the table above.
///
/// Unknown / system-shell bundles filtered by
/// `SystemAppFilter.excludedBundles` never reach this classifier —
/// the caller should filter them out first so "Finder" / "dock" time
/// doesn't get bucketed into `.other` and skew the "other" slice.
public enum AppCategory: String, Sendable, CaseIterable, Equatable {
    case deepFocus
    case communication
    case browsing
    case other
}

public enum AppCategoryClassifier {

    /// The canonical entry point. Walks a fixed table of bundleId
    /// prefixes in stable order; the first matching row wins. Callers
    /// pass the bundle active on the event.
    public static func category(for bundleId: String) -> AppCategory {
        let id = bundleId.lowercased()
        for entry in Self.rules {
            for prefix in entry.prefixes where id.hasPrefix(prefix) {
                return entry.category
            }
        }
        return .other
    }

    /// The bundle-prefix → category table. Editable at call site for
    /// tests (pass a custom `rules:` into `classify(rules:bundleId:)`
    /// if we ever expose that overload).
    ///
    /// Kept as struct-of-arrays so a future "user whitelist" layer
    /// can prepend additional rows without rewriting the logic.
    struct Rule {
        let category: AppCategory
        let prefixes: [String]
    }

    static let rules: [Rule] = [
        // Deep focus: makers' tools.
        Rule(category: .deepFocus, prefixes: [
            "com.apple.dt.xcode",
            "com.microsoft.vscode",
            "com.jetbrains.",
            "com.sublimetext.",
            "com.github.atom",
            "dev.zed.zed",
            "org.vim.",
            "com.googlecode.iterm2",
            "com.apple.terminal",
            "com.apple.notes",
            "com.apple.textedit",
            "com.apple.pages",
            "com.apple.iwork.",
            "com.apple.numbers",
            "com.apple.keynote",
            "com.microsoft.word",
            "com.microsoft.excel",
            "com.microsoft.powerpoint",
            "md.obsidian",
            "net.shinyfrog.bear",
            "com.ulyssesapp.",
            "com.literatureandlatte.scrivener",
            "com.figma.",
            "com.bohemiancoding.sketch3",
            "com.seriflabs.affinity",
            "com.adobe.photoshop",
            "com.adobe.illustrator",
            "com.adobe.indesign",
            "com.apple.finalcutpro",
            "com.apple.logic10"
        ]),
        // Communication: real-time + messaging + mail.
        Rule(category: .communication, prefixes: [
            "com.tinyspeck.slackmacgap",
            "com.hnc.discord",
            "us.zoom.xos",
            "com.microsoft.teams",
            "com.cisco.webexmeetingsapp",
            "com.google.meet",
            "com.apple.mail",
            "com.microsoft.outlook",
            "com.apple.messages",
            "com.apple.iChat",
            "com.apple.facetime",
            "desktop.telegram",
            "com.apple.mobilephone",
            "ru.keepcoder.telegram",
            "com.whatsapp.",
            "com.viber."
        ]),
        // Browsing: general web.
        Rule(category: .browsing, prefixes: [
            "com.apple.safari",
            "com.google.chrome",
            "org.mozilla.firefox",
            "com.microsoft.edgemac",
            "company.thebrowser.browser",   // Arc
            "com.brave.browser",
            "com.operasoftware.opera",
            "com.vivaldi.vivaldi"
        ])
    ]
}
