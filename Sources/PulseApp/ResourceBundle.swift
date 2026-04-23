import Foundation

/// Resolves the `Pulse_PulseApp.bundle` resource bundle (hosts the
/// `Localizable.xcstrings` catalog) shipped inside the .app. See
/// `Sources/PulseCore/Resources/ResourceBundle.swift` for the full
/// explanation — TL;DR: SPM's auto-generated `Bundle.module` for this
/// target only probes paths that don't exist inside a packaged .app,
/// so every `Text("…", bundle: .module)` call would `fatalError` on
/// launch the moment SwiftUI resolved a string from the catalogue.
///
/// The candidate order mirrors the PulseCore helper: real .app first
/// (`Bundle.main.resourceURL`), framework fallback, then `swift run`
/// layout (executable == main bundle).
enum PulseAppResources {

    static let bundle: Bundle = {
        let bundleName = "Pulse_PulseApp"
        let candidates: [URL?] = [
            Bundle.main.resourceURL,
            Bundle(for: BundleFinder.self).resourceURL,
            Bundle.main.bundleURL
        ]
        for candidate in candidates {
            guard let url = candidate?.appendingPathComponent(bundleName + ".bundle") else {
                continue
            }
            if let bundle = Bundle(url: url) {
                return bundle
            }
        }
        fatalError("PulseAppResources: could not locate \(bundleName).bundle under any known candidate path")
    }()

    private final class BundleFinder {}
}

extension Bundle {
    /// PulseApp's resource bundle (Localizable.xcstrings). Replaces
    /// `Bundle.module` at every `Text(…, bundle: .module)` call site —
    /// `bundle: .pulse` is the short form.
    static var pulse: Bundle { PulseAppResources.bundle }
}
