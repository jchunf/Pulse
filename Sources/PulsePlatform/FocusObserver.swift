#if canImport(AppKit)
import AppKit
import Foundation
import PulseCore

/// F-37 — observes the macOS Focus / Do-Not-Disturb state and emits
/// `.focusEntered` / `.focusExited` `DomainEvent`s. Same shape as
/// `LidPowerObserver`: caller hands a `@Sendable` sink to `start(...)`,
/// observer captures it weakly under a lock, runtime gating (pause /
/// retention / privacy) is applied downstream by the writer.
///
/// **Detection strategy.** macOS has no public API for "is the user
/// currently in Focus mode", but the Focus engine writes its state
/// to `~/Library/DoNotDisturb/DB/Assertions.json` whenever a Focus
/// is active. We watch that file with a `DispatchSource` filesystem
/// object source and re-read on every change. The file is in the
/// user's own Library so reading it requires NO TCC permission —
/// no onboarding card needs adding.
///
/// **Fallback.** Older / oddly-configured installs may post a
/// `com.apple.focus.focus-mode-changed` distributed notification.
/// We register defensively; the handler just kicks the file-watch
/// re-read so the two paths converge on the same source of truth.
///
/// **Privacy posture.** The only thing we extract is (a) "is Focus
/// currently active?" and (b) optionally the mode display name
/// (e.g. "Work"). No notifications, no app blocklists, nothing
/// else from the file is ever read or stored.
public final class FocusObserver: @unchecked Sendable {

    /// Path to the Focus-engine state file. Stable across macOS 14
    /// and 15; if Apple moves it the observer just stays at "no
    /// Focus detected" until we re-test.
    private static let assertionsPath: String = {
        let home = NSHomeDirectory()
        return "\(home)/Library/DoNotDisturb/DB/Assertions.json"
    }()

    /// Distributed-notification name posted by `focusd` on mode
    /// changes — undocumented, defensive backup.
    private static let focusChangedNotification = Notification.Name("com.apple.focus.focus-mode-changed")

    private let clock: Clock
    private let queue: DispatchQueue
    private var fileSource: DispatchSourceFileSystemObject?
    private var fileDescriptor: Int32 = -1
    private var distributedObserver: NSObjectProtocol?

    /// Last reported state. `nil` = unknown / never sampled (never
    /// emit `.focusExited` on first sample, only on transitions).
    private var lastIsActive: Bool?
    private var lastModeName: String?

    private var handler: (@Sendable (DomainEvent) -> Void)?
    private let lock = NSLock()

    public init(clock: Clock = SystemClock()) {
        self.clock = clock
        self.queue = DispatchQueue(label: "com.pulse.FocusObserver", qos: .utility)
    }

    deinit {
        stop()
    }

    public func start(handler: @escaping @Sendable (DomainEvent) -> Void) {
        lock.lock()
        self.handler = handler
        lock.unlock()

        // Initial sample so we know the starting state. Don't emit
        // a `.focusEntered` on first run if Focus IS active —
        // that would create a phantom "you just turned Focus on"
        // event at startup. Just record the state.
        sampleAndMaybeEmit(emitInitial: false)

        // File watcher. Re-installed on every event because file-
        // system sources can vanish if the file is rewritten
        // atomically (DoNotDisturb engine does atomic replace).
        installFileSource()

        // Distributed-notification fallback.
        let observer = DistributedNotificationCenter.default().addObserver(
            forName: Self.focusChangedNotification,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            self?.queue.async { [weak self] in
                self?.sampleAndMaybeEmit(emitInitial: false)
            }
        }
        lock.lock()
        self.distributedObserver = observer
        lock.unlock()
    }

    public func stop() {
        lock.lock()
        if let obs = distributedObserver {
            DistributedNotificationCenter.default().removeObserver(obs)
            distributedObserver = nil
        }
        handler = nil
        lock.unlock()
        teardownFileSource()
    }

    /// Test hook — let unit tests pretend the file changed and
    /// observe what the observer would emit.
    public func simulateAssertionsFileChanged() {
        sampleAndMaybeEmit(emitInitial: false)
    }

    // MARK: - File source

    private func installFileSource() {
        teardownFileSource()
        let path = Self.assertionsPath
        let fd = open(path, O_EVTONLY)
        // The Assertions.json file may not exist yet — when no Focus
        // has ever been active, the directory may be empty. In that
        // case watch the parent directory for creation.
        if fd < 0 {
            installDirectorySource()
            return
        }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .extend, .attrib, .delete, .rename],
            queue: queue
        )
        source.setEventHandler { [weak self] in
            self?.sampleAndMaybeEmit(emitInitial: false)
            // Atomic-replace deletes the original; reinstall the
            // watcher pointing at the new inode.
            self?.installFileSource()
        }
        source.setCancelHandler { [weak self] in
            if let self, self.fileDescriptor >= 0 {
                close(self.fileDescriptor)
                self.fileDescriptor = -1
            }
        }
        lock.lock()
        self.fileDescriptor = fd
        self.fileSource = source
        lock.unlock()
        source.resume()
    }

    private func installDirectorySource() {
        let dir = (Self.assertionsPath as NSString).deletingLastPathComponent
        let fd = open(dir, O_EVTONLY)
        guard fd >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .extend, .attrib],
            queue: queue
        )
        source.setEventHandler { [weak self] in
            // Some change in the parent dir — try installing on the
            // file again (which may have just been created).
            self?.installFileSource()
            self?.sampleAndMaybeEmit(emitInitial: false)
        }
        source.setCancelHandler { [weak self] in
            if let self, self.fileDescriptor >= 0 {
                close(self.fileDescriptor)
                self.fileDescriptor = -1
            }
        }
        lock.lock()
        self.fileDescriptor = fd
        self.fileSource = source
        lock.unlock()
        source.resume()
    }

    private func teardownFileSource() {
        lock.lock()
        let source = self.fileSource
        self.fileSource = nil
        lock.unlock()
        source?.cancel()
    }

    // MARK: - Parse + emit

    /// Reads `Assertions.json` and emits a `.focusEntered` /
    /// `.focusExited` event when the active state has flipped vs
    /// the last sample. `emitInitial == false` suppresses emit on
    /// the very first sample so a Focus that was already active at
    /// app launch doesn't create a phantom transition event.
    private func sampleAndMaybeEmit(emitInitial: Bool) {
        let (isActive, modeName) = currentFocusState()
        lock.lock()
        let priorActive = lastIsActive
        let priorMode = lastModeName
        lastIsActive = isActive
        lastModeName = modeName
        let sink = handler
        lock.unlock()

        guard let sink = sink else { return }
        // Suppress the very first observation — only emit on
        // transitions. Caller can override via `emitInitial`.
        guard let prior = priorActive else {
            if emitInitial && isActive {
                sink(.focusEntered(modeName: modeName, at: clock.now))
            }
            return
        }
        if isActive != prior {
            if isActive {
                sink(.focusEntered(modeName: modeName, at: clock.now))
            } else {
                sink(.focusExited(at: clock.now))
            }
        } else if isActive && modeName != priorMode {
            // Same active state but mode swapped (Work → Personal).
            // Treat as exit-then-enter so the read-side timeline
            // captures the boundary.
            sink(.focusExited(at: clock.now))
            sink(.focusEntered(modeName: modeName, at: clock.now))
        }
    }

    /// Returns `(isActive, modeName)`. `modeName` may be `nil` even
    /// when active if the JSON shape doesn't expose it the way we
    /// expect. We're defensive by design — Apple has changed the
    /// schema before.
    private func currentFocusState() -> (Bool, String?) {
        let path = Self.assertionsPath
        guard FileManager.default.fileExists(atPath: path),
              let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              !data.isEmpty,
              let json = try? JSONSerialization.jsonObject(with: data)
        else {
            return (false, nil)
        }
        let modeName = Self.findModeIdentifier(in: json)
        // Active iff we found at least one assertion record. The
        // helper returns the first mode identifier it finds, OR
        // an empty string sentinel meaning "found a record but no
        // mode name". Both count as active.
        if modeName != nil {
            return (true, modeName?.isEmpty == true ? nil : modeName)
        }
        return (false, nil)
    }

    /// Walks the JSON tree looking for the first assertion record.
    /// Returns the mode identifier if present, an empty string if
    /// an assertion was found but no mode name, or `nil` if no
    /// assertions exist (= Focus inactive).
    static func findModeIdentifier(in node: Any) -> String? {
        if let dict = node as? [String: Any] {
            // Common shape: a dict containing
            // "assertionDetailsModeIdentifier".
            if let mode = dict["assertionDetailsModeIdentifier"] as? String, !mode.isEmpty {
                return Self.humanReadableMode(from: mode)
            }
            // Recurse — assertion records sit inside nested arrays.
            for value in dict.values {
                if let found = findModeIdentifier(in: value) {
                    return found
                }
            }
            // Found an assertion record (with the storeAssertionRecords
            // key holding an empty array? or with a record we can't
            // parse?). Return empty string sentinel only if at least
            // one assertion record was present.
            if let records = dict["storeAssertionRecords"] as? [Any], !records.isEmpty {
                return ""
            }
        } else if let array = node as? [Any] {
            for item in array {
                if let found = findModeIdentifier(in: item) {
                    return found
                }
            }
        }
        return nil
    }

    /// Strips the bundle-id-style prefix off a Focus mode identifier
    /// so the dashboard surfaces a friendly label.
    /// `"com.apple.donotdisturb.mode.work"` → `"Work"`.
    static func humanReadableMode(from identifier: String) -> String {
        let last = identifier.split(separator: ".").last.map(String.init) ?? identifier
        return last.prefix(1).uppercased() + last.dropFirst()
    }
}
#endif
