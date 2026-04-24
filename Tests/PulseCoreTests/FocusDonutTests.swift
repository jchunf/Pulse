import Testing
import Foundation
@testable import PulseCore

@Suite("FocusDonutBuilder + AppCategoryClassifier (F-09)")
struct FocusDonutTests {

    @Test("Xcode bundle classifies as deep focus")
    func xcodeIsDeepFocus() {
        #expect(AppCategoryClassifier.category(for: "com.apple.dt.Xcode") == .deepFocus)
    }

    @Test("VS Code + JetBrains bundles classify as deep focus")
    func editorsAreDeepFocus() {
        #expect(AppCategoryClassifier.category(for: "com.microsoft.VSCode") == .deepFocus)
        #expect(AppCategoryClassifier.category(for: "com.jetbrains.intellij") == .deepFocus)
    }

    @Test("Safari + Chrome classify as browsing")
    func browsersAreBrowsing() {
        #expect(AppCategoryClassifier.category(for: "com.apple.Safari") == .browsing)
        #expect(AppCategoryClassifier.category(for: "com.google.Chrome") == .browsing)
    }

    @Test("Slack + Mail classify as communication")
    func commsAreCommunication() {
        #expect(AppCategoryClassifier.category(for: "com.tinyspeck.slackmacgap") == .communication)
        #expect(AppCategoryClassifier.category(for: "com.apple.mail") == .communication)
    }

    @Test("unknown bundles fall back to .other")
    func unknownIsOther() {
        #expect(AppCategoryClassifier.category(for: "com.example.unknown") == .other)
        #expect(AppCategoryClassifier.category(for: "") == .other)
    }

    @Test("builder keeps all four segments and sums per-bundle seconds")
    func builderProducesAllCategories() {
        let rows: [AppUsageRow] = [
            AppUsageRow(bundleId: "com.apple.dt.Xcode",          secondsUsed: 3_600),
            AppUsageRow(bundleId: "com.microsoft.VSCode",        secondsUsed: 1_200),
            AppUsageRow(bundleId: "com.tinyspeck.slackmacgap",   secondsUsed: 900),
            AppUsageRow(bundleId: "com.apple.Safari",            secondsUsed: 1_800),
            AppUsageRow(bundleId: "com.example.unknown",         secondsUsed: 600)
        ]
        let donut = FocusDonutBuilder.build(from: rows)
        #expect(donut.segments.count == 4)
        let byCategory = Dictionary(uniqueKeysWithValues: donut.segments.map { ($0.category, $0.seconds) })
        #expect(byCategory[.deepFocus] == 4_800)
        #expect(byCategory[.communication] == 900)
        #expect(byCategory[.browsing] == 1_800)
        #expect(byCategory[.other] == 600)
        #expect(donut.totalSeconds == 8_100)
        #expect(abs(donut.deepFocusFraction - 4_800.0 / 8_100.0) < 0.0001)
    }

    @Test("empty input produces empty-sum donut with all segments")
    func emptyInput() {
        let donut = FocusDonutBuilder.build(from: [])
        #expect(donut.segments.count == 4)
        #expect(donut.totalSeconds == 0)
        #expect(donut.deepFocusFraction == 0)
    }
}
