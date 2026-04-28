#if canImport(AppKit)
import Testing
import Foundation
@testable import PulsePlatform

/// F-37 — `FocusObserver` parses macOS's
/// `~/Library/DoNotDisturb/DB/Assertions.json` to detect whether the
/// user is in Focus / DND. The format is undocumented and Apple has
/// changed it before, so we pass several plausible JSON shapes through
/// the parser and confirm it stays defensive: returns the mode name
/// when found, an empty-string sentinel when an assertion record exists
/// without a mode name, and `nil` when no assertions are present
/// (= Focus inactive).
@Suite("FocusObserver — Assertions.json parsing")
struct FocusObserverTests {

    @Test("nil for empty dict (no assertions)")
    func emptyDictIsInactive() throws {
        let parsed = try parse("{}")
        #expect(FocusObserver.findModeIdentifier(in: parsed) == nil)
    }

    @Test("returns humanised mode name for top-level assertionDetailsModeIdentifier")
    func topLevelModeIdentifier() throws {
        let parsed = try parse("""
            { "assertionDetailsModeIdentifier": "com.apple.donotdisturb.mode.work" }
            """)
        #expect(FocusObserver.findModeIdentifier(in: parsed) == "Work")
    }

    @Test("walks into storeAssertionRecords for nested mode identifiers")
    func nestedRecord() throws {
        let parsed = try parse("""
            {
              "storeAssertionRecords": [
                {
                  "assertionDetails": {
                    "assertionDetailsModeIdentifier": "com.apple.donotdisturb.mode.personal"
                  }
                }
              ]
            }
            """)
        #expect(FocusObserver.findModeIdentifier(in: parsed) == "Personal")
    }

    @Test("returns empty-string sentinel when an assertion has no mode name")
    func recordWithoutModeName() throws {
        let parsed = try parse("""
            { "storeAssertionRecords": [{ "someOtherKey": 1 }] }
            """)
        // Sentinel "" — assertion exists, mode name not parseable.
        #expect(FocusObserver.findModeIdentifier(in: parsed) == "")
    }

    @Test("nil when storeAssertionRecords is empty (no Focus on)")
    func emptyAssertionsArray() throws {
        let parsed = try parse(#"{ "storeAssertionRecords": [] }"#)
        #expect(FocusObserver.findModeIdentifier(in: parsed) == nil)
    }

    @Test("humanReadableMode strips the bundle-id prefix and capitalises")
    func humanReadableLastComponent() {
        #expect(FocusObserver.humanReadableMode(from: "com.apple.donotdisturb.mode.sleep") == "Sleep")
        #expect(FocusObserver.humanReadableMode(from: "com.apple.donotdisturb.mode.driving") == "Driving")
        // Single-component identifiers (no dots) are passed through with
        // the first letter capitalised.
        #expect(FocusObserver.humanReadableMode(from: "fitness") == "Fitness")
    }

    @Test("ignores arrays mixed with non-dict entries")
    func mixedArrayShape() throws {
        let parsed = try parse("""
            [
              "noise",
              42,
              { "assertionDetailsModeIdentifier": "com.apple.donotdisturb.mode.reading" }
            ]
            """)
        #expect(FocusObserver.findModeIdentifier(in: parsed) == "Reading")
    }

    private func parse(_ text: String) throws -> Any {
        let data = Data(text.utf8)
        return try JSONSerialization.jsonObject(with: data, options: [.allowFragments])
    }
}
#endif
