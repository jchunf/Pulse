import Foundation
import PulseCore

/// F-44 — shared read-side helper for the App Intents in
/// `PulseAppIntents.swift`. Lazily opens the same SQLite file the GUI
/// app writes to (`~/Library/Application Support/Pulse/pulse.db`),
/// caches an `EventStore`, and exposes a tiny query surface.
///
/// Intents run inside the Pulse app process — the SwiftUI app already
/// holds a `PulseDatabase` open via `AppDelegate`, but App Intents
/// don't have a handle to that singleton (they're instantiated by the
/// system). Opening a parallel read connection is cheap because GRDB's
/// pooled connection model coexists with the writer's serial queue.
///
/// The backend is intentionally read-only-ish: it never enqueues
/// events, never writes, never starts the collector runtime. Whatever
/// `~/Library/Application Support/Pulse/pulse.db` already contains is
/// the answer.
enum PulseIntentBackend {

    private static let lock = NSLock()
    private static var cachedStore: EventStore?

    /// Returns a shared `EventStore`. The first call opens the DB; later
    /// calls reuse it. If the DB doesn't exist yet (first launch with no
    /// data), throws `PulseIntentError.databaseUnavailable`.
    static func store() throws -> EventStore {
        lock.lock()
        defer { lock.unlock() }
        if let cached = cachedStore { return cached }
        let url = try databaseURL()
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw PulseIntentError.databaseUnavailable
        }
        let database = try PulseDatabase.open(at: url)
        let store = EventStore(database: database)
        cachedStore = store
        return store
    }

    private static func databaseURL() throws -> URL {
        let support = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: false
        )
        let directory = support.appendingPathComponent("Pulse", isDirectory: true)
        return directory.appendingPathComponent("pulse.db")
    }
}

enum PulseIntentError: LocalizedError {
    case databaseUnavailable

    var errorDescription: String? {
        switch self {
        case .databaseUnavailable:
            return "Pulse hasn't recorded any data yet."
        }
    }
}
