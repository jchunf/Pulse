import Testing
import Foundation
@testable import PulseCore

@Suite("NarrativeEngine — best-match anchor picker")
struct NarrativeEngineTests {

    @Test("values below the smallest anchor return nil")
    func belowFloorReturnsNil() {
        let engine = NarrativeEngine.standard
        // keystrokes.headline = 80; anything below is not dramatic.
        #expect(engine.bestMatch(metric: .keystrokes, value: 50) == nil)
        // focus.shortFilm = 15 min = 900 s; anything below is not focus.
        #expect(engine.bestMatch(metric: .focusDurationSeconds, value: 600) == nil)
    }

    @Test("zero and negative values always return nil")
    func nonPositiveReturnsNil() {
        let engine = NarrativeEngine.standard
        for metric in NarrativeMetric.allCases {
            #expect(engine.bestMatch(metric: metric, value: 0) == nil)
            #expect(engine.bestMatch(metric: metric, value: -1) == nil)
        }
    }

    @Test("picks the largest anchor that fits — keystrokes novel tier")
    func pickLargestBelowValueKeystrokes() throws {
        let engine = NarrativeEngine.standard
        let comparison = try #require(
            engine.bestMatch(metric: .keystrokes, value: 200_000)
        )
        #expect(comparison.anchor.key == "keystrokes.novel")
        #expect(comparison.multiplier == 2.0)
        #expect(comparison.metric == .keystrokes)
        #expect(comparison.rawValue == 200_000)
    }

    @Test("picks the largest anchor that fits — focus pomodoro tier")
    func pickLargestBelowValueFocus() throws {
        let engine = NarrativeEngine.standard
        // 30 min = 1800 s. Floor candidates (sorted asc): shortFilm 900,
        // episode 1320, pomodoro 1500, feature 7200, workday 28800.
        // Largest ≤ 1800 is pomodoro (1500).
        let comparison = try #require(
            engine.bestMatch(metric: .focusDurationSeconds, value: 1_800)
        )
        #expect(comparison.anchor.key == "focus.pomodoro")
    }

    @Test("picks the largest anchor that fits — scroll novel tier (F-17)")
    func pickLargestBelowValueScrollTicks() throws {
        let engine = NarrativeEngine.standard
        // Floor candidates (sorted asc): blogPost 30, tweetFeed 150,
        // magazine 600, novel 3_000, encyclopediaVolume 25_000.
        // Largest ≤ 9_000 is novel (3_000).
        let comparison = try #require(
            engine.bestMatch(metric: .scrollTicks, value: 9_000)
        )
        #expect(comparison.anchor.key == "scroll.novel")
        #expect(comparison.metric == .scrollTicks)
        #expect(abs(comparison.multiplier - 3.0) < 0.001)
    }

    @Test("scroll ticks below smallest anchor return nil (F-17)")
    func scrollTicksBelowFloorReturnsNil() {
        let engine = NarrativeEngine.standard
        // scroll.blogPost = 30; 29 ticks is below the smallest anchor.
        #expect(engine.bestMatch(metric: .scrollTicks, value: 29) == nil)
    }

    @Test("exact anchor boundary returns multiplier 1")
    func boundaryMultiplierIsOne() throws {
        let engine = NarrativeEngine.standard
        let comparison = try #require(
            engine.bestMatch(metric: .focusDurationSeconds, value: 7_200)
        )
        #expect(comparison.anchor.key == "focus.feature")
        #expect(abs(comparison.multiplier - 1.0) < 0.001)
    }

    @Test("absent metric in a custom engine returns nil")
    func customEngineMissingMetric() {
        let engine = NarrativeEngine(anchors: [
            .keystrokes: [
                NarrativeAnchor(
                    key: "demo", displayName: "demo",
                    valueInMetricUnits: 10, metric: .keystrokes
                )
            ]
        ])
        #expect(engine.bestMatch(metric: .focusDurationSeconds, value: 10_000) == nil)
        #expect(engine.bestMatch(metric: .keystrokes, value: 100) != nil)
    }
}
