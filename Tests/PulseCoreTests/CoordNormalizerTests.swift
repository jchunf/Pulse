import Testing
import CoreGraphics
@testable import PulseCore

/// Tests for `CoordNormalizer`. This is the single most important piece of
/// math in Pulse — every mouse event's storage shape depends on it, and a
/// bug here silently corrupts historical heatmaps. Coverage target: 100%.
@Suite("CoordNormalizer — pixel → [0,1] normalization")
struct CoordNormalizerTests {

    // MARK: - Fixtures

    private let normalizer = CoordNormalizer()

    private let fhd = DisplayInfo(id: 1, widthPx: 1920, heightPx: 1080, dpi: 109, isPrimary: true)
    private let uhd = DisplayInfo(id: 2, widthPx: 3840, heightPx: 2160, dpi: 163, isPrimary: false)
    private let square = DisplayInfo(id: 3, widthPx: 1000, heightPx: 1000, dpi: 100, isPrimary: false)

    // MARK: - Basic normalization

    @Test("origin maps to (0, 0)")
    func originIsZero() {
        let point = normalizer.normalize(localPoint: .zero, on: fhd)
        #expect(point.x == 0)
        #expect(point.y == 0)
        #expect(point.displayId == 1)
    }

    @Test("display center maps to (0.5, 0.5)")
    func centerIsHalf() {
        let center = CGPoint(x: 960, y: 540)
        let point = normalizer.normalize(localPoint: center, on: fhd)
        #expect(point.x == 0.5)
        #expect(point.y == 0.5)
    }

    @Test("bottom-right corner maps to (1, 1) exactly")
    func bottomRightIsOne() {
        let corner = CGPoint(x: 1920, y: 1080)
        let point = normalizer.normalize(localPoint: corner, on: fhd)
        #expect(point.x == 1)
        #expect(point.y == 1)
    }

    @Test("4K display produces same normalized value as FHD for equivalent relative position")
    func resolutionIndependent() {
        let fhdPoint = normalizer.normalize(localPoint: CGPoint(x: 960, y: 540), on: fhd)
        let uhdPoint = normalizer.normalize(localPoint: CGPoint(x: 1920, y: 1080), on: uhd)
        #expect(fhdPoint.x == uhdPoint.x)
        #expect(fhdPoint.y == uhdPoint.y)
    }

    // MARK: - Clamping

    @Test("negative coordinates clamp to 0")
    func negativesClampToZero() {
        let point = normalizer.normalize(localPoint: CGPoint(x: -5, y: -100), on: fhd)
        #expect(point.x == 0)
        #expect(point.y == 0)
    }

    @Test("coordinates past the edge clamp to 1")
    func overflowClampsToOne() {
        let point = normalizer.normalize(localPoint: CGPoint(x: 99_999, y: 99_999), on: fhd)
        #expect(point.x == 1)
        #expect(point.y == 1)
    }

    @Test("NaN in input produces 0, never a NaN normalized value")
    func nanInputIsZero() {
        let point = normalizer.normalize(localPoint: CGPoint(x: CGFloat.nan, y: CGFloat.nan), on: fhd)
        #expect(!point.x.isNaN)
        #expect(!point.y.isNaN)
        #expect(point.x == 0)
        #expect(point.y == 0)
    }

    // MARK: - Denormalize roundtrip

    @Test(
        "normalize(denormalize(p)) ≈ p for several positions",
        arguments: [
            CGPoint(x: 0, y: 0),
            CGPoint(x: 123.4, y: 56.7),
            CGPoint(x: 500, y: 500),
            CGPoint(x: 999.9, y: 999.9)
        ]
    )
    func roundtrip(point: CGPoint) {
        let normalized = normalizer.normalize(localPoint: point, on: square)
        let back = normalizer.denormalize(normalized, on: square)
        #expect(abs(back.x - point.x) < 0.001)
        #expect(abs(back.y - point.y) < 0.001)
    }

    // MARK: - Display identity preservation

    @Test("display id is carried through on every normalization")
    func displayIdentityPreserved() {
        for display in [fhd, uhd, square] {
            let normalized = normalizer.normalize(localPoint: CGPoint(x: 10, y: 10), on: display)
            #expect(normalized.displayId == display.id)
        }
    }

    // MARK: - Degenerate displays

    @Test("zero-width display does not produce NaN")
    func zeroWidthDisplayIsSafe() {
        let zeroWidth = DisplayInfo(id: 99, widthPx: 0, heightPx: 1080, dpi: 96, isPrimary: false)
        let point = normalizer.normalize(localPoint: CGPoint(x: 10, y: 10), on: zeroWidth)
        #expect(!point.x.isNaN)
        #expect(point.x >= 0 && point.x <= 1)
    }
}
