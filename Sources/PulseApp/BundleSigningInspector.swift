#if canImport(AppKit)
import AppKit
import Foundation

/// Runtime `codesign -dv --verbose=4` snapshot of Sparkle's bundled
/// helpers. Pulse is ad-hoc signed and a dogfooder kept hitting
/// `SUSparkleErrorDomain #4005` ("remote port connection invalidated
/// from the updater") even after PR #155, #156, #157 each tried a
/// plausible-but-wrong fix:
///
/// - #155: per-item Sparkle helper signing in `package.sh`
/// - #156: drop the follow-up `codesign --deep --force` pass that
///   was undoing #155
/// - #157: strip `com.apple.quarantine` from the bundle on launch
///
/// All three landed; v2.0.9 still hit the same #4005 with
/// `Quarantine: clean (0 paths)` and the bundle in
/// `/Applications/Pulse.app`. So the working theory now is *some
/// signature characteristic we haven't audited yet* — the
/// helper's authority, identifier, team-id, or designated
/// requirement.
///
/// Rather than guess and ship another wrong fix, this inspector runs
/// `/usr/bin/codesign -dv --verbose=4` against each Sparkle helper
/// and stores the verbatim output in `UserDefaults`. The
/// `DiagnosticsCard` surfaces the raw text so the user can copy it
/// over and we get one definitive look at what's actually inside
/// the running app.
enum BundleSigningInspector {

    /// Helpers Sparkle 2.x relies on. Order matters only for the
    /// display in `DiagnosticsCard`; we capture each independently.
    private static let helperRelativePaths: [(label: String, path: String)] = [
        ("Pulse.app (outer)", ""),
        ("Sparkle.framework", "Contents/Frameworks/Sparkle.framework"),
        ("Sparkle dylib",     "Contents/Frameworks/Sparkle.framework/Versions/B/Sparkle"),
        ("Autoupdate",        "Contents/Frameworks/Sparkle.framework/Versions/B/Autoupdate"),
        ("Updater.app",       "Contents/Frameworks/Sparkle.framework/Versions/B/Updater.app"),
        ("Downloader.xpc",    "Contents/Frameworks/Sparkle.framework/Versions/B/XPCServices/Downloader.xpc"),
        ("Installer.xpc",     "Contents/Frameworks/Sparkle.framework/Versions/B/XPCServices/Installer.xpc")
    ]

    /// UserDefaults key for the JSON-encoded `[label: codesignOutput]`
    /// dictionary. Read by `DiagnosticsCard` and surfaced under a
    /// disclosure group.
    static let lastReportKey = "pulse.update.codesignReport"
    static let lastReportAtKey = "pulse.update.codesignReportAt"

    /// Run `codesign -dv --verbose=4` against every helper in
    /// `helperRelativePaths` resolved from `bundlePath`, capture the
    /// stdout+stderr of each, and stash a single JSON dictionary
    /// into UserDefaults. Best-effort — a missing helper, or a
    /// codesign that fails to spawn, is recorded as an error string
    /// in place of its output so the user still sees the full
    /// per-helper map.
    static func captureReport(bundlePath: String) {
        var report: [String: String] = [:]
        for entry in helperRelativePaths {
            let full = entry.path.isEmpty
                ? bundlePath
                : "\(bundlePath)/\(entry.path)"
            report[entry.label] = inspect(path: full)
        }
        if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]),
           let text = String(data: data, encoding: .utf8) {
            UserDefaults.standard.set(text, forKey: lastReportKey)
            UserDefaults.standard.set(Date(), forKey: lastReportAtKey)
        }
    }

    private static func inspect(path: String) -> String {
        guard FileManager.default.fileExists(atPath: path) else {
            return "<not found>"
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        process.arguments = ["-dv", "--verbose=4", path]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do {
            try process.run()
        } catch {
            return "<codesign launch failed: \(error.localizedDescription)>"
        }
        process.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let text = String(data: data, encoding: .utf8) ?? "<empty / non-utf8 output>"
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
#endif
