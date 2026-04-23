import Foundation

/// Resolves the `Pulse_PulseCore.bundle` resource bundle shipped inside
/// the host .app. We cannot use SPM's auto-generated `Bundle.module`:
/// the variant emitted by the current toolchain for our executable
/// build only probes `Bundle.main.bundleURL/<name>.bundle` plus a
/// hardcoded `/Users/runner/…` CI build path. Neither exists inside a
/// shipped .app (resources live under `Contents/Resources/`), so the
/// accessor's closure fires `fatalError("could not load resource
/// bundle")` inside `Migrator.bundled()`'s dispatch_once and crashes
/// the process before `AppDelegate.init()` returns. dev-latest build
/// 111 shipped with exactly that crash.
///
/// This helper probes the right places in the right order:
///
///   1. `Bundle.main.resourceURL` — the .app's `Contents/Resources/`
///      directory, the canonical home per Apple's bundle conventions.
///      This is where `scripts/package.sh` drops the SPM output.
///   2. `Bundle(for: BundleFinder.self).resourceURL` — when the host
///      is a framework rather than a flat .app. Rare for us, free to
///      include as defense-in-depth.
///   3. `Bundle.main.bundleURL` — matches SPM's accessor so `swift
///      run` / `swift test` invocations (where the executable IS the
///      main bundle) still find the sibling .bundle directory.
enum PulseCoreResources {

    /// Singleton `Bundle` holding this target's resources (SQL
    /// migrations). Evaluated lazily; subsequent calls are free.
    static let bundle: Bundle = {
        let bundleName = "Pulse_PulseCore"
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
        fatalError("PulseCoreResources: could not locate \(bundleName).bundle under any known candidate path")
    }()

    /// Anchor class used by `Bundle(for:)` above. Scoped to this file
    /// so nothing outside the accessor can accidentally pin resource
    /// lookups to this target.
    private final class BundleFinder {}
}

public extension Bundle {
    /// Stable accessor for PulseCore's resource bundle. Prefer this
    /// over `Bundle.module` — see `PulseCoreResources` header comment
    /// for why the auto-generated accessor crashes in shipped .apps.
    static var pulseCore: Bundle { PulseCoreResources.bundle }
}
