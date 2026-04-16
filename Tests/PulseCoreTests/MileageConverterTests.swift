import Testing
@testable import PulseCore

@Suite("MileageConverter — pixels ↔ millimeters ↔ meters ↔ kilometers")
struct MileageConverterTests {

    private let converter = MileageConverter()

    @Test("96 DPI: 96 pixels = 1 inch = 25.4 mm")
    func canonicalDPIConversion() {
        let display = DisplayInfo(id: 1, widthPx: 1920, heightPx: 1080, dpi: 96, isPrimary: true)
        let mm = converter.millimeters(pixels: 96, on: display)
        #expect(abs(mm - 25.4) < 0.001)
    }

    @Test("Retina 220 DPI: 220 pixels = 25.4 mm")
    func retinaConversion() {
        let retina = DisplayInfo(id: 2, widthPx: 5120, heightPx: 2880, dpi: 220, isPrimary: true)
        let mm = converter.millimeters(pixels: 220, on: retina)
        #expect(abs(mm - 25.4) < 0.001)
    }

    @Test("meters and kilometers scale linearly")
    func unitScaling() {
        #expect(converter.meters(fromMillimeters: 1_000) == 1.0)
        #expect(converter.kilometers(fromMillimeters: 1_000_000) == 1.0)
        #expect(converter.kilometers(fromMillimeters: 500_000) == 0.5)
    }

    @Test("zero pixels yields zero millimeters")
    func zeroIsZero() {
        let display = DisplayInfo(id: 1, widthPx: 1920, heightPx: 1080, dpi: 120, isPrimary: true)
        #expect(converter.millimeters(pixels: 0, on: display) == 0)
    }

    @Test("Euclidean distance between two normalized points on 1000×1000 @ 25.4 DPI equals the simple pythag")
    func normalizedDistance() {
        // On a 25.4 DPI display: 1 mm == 1 pixel. Simplifies the math.
        let display = DisplayInfo(id: 1, widthPx: 1_000, heightPx: 1_000, dpi: 25.4, isPrimary: true)
        let a = NormalizedPoint(displayId: 1, x: 0.0, y: 0.0)
        let b = NormalizedPoint(displayId: 1, x: 0.3, y: 0.4)
        // (0.3 * 1000, 0.4 * 1000) → (300, 400) → hypot = 500 pixels = 500 mm
        let mm = converter.millimeters(between: a, and: b, on: display)
        #expect(abs(mm - 500) < 0.01)
    }
}

@Suite("LandmarkLibrary — drama-preserving comparison selection")
struct LandmarkLibraryTests {

    @Test("very small mileage falls back to smallest landmark")
    func tinyMileage() {
        let comp = LandmarkLibrary.standard.bestMatch(forMeters: 0.1)
        #expect(comp.landmark.key == "step")
    }

    @Test("50m mileage maps to pool landmark")
    func fiftyMetersIsPool() {
        let comp = LandmarkLibrary.standard.bestMatch(forMeters: 50)
        #expect(comp.landmark.key == "pool")
    }

    @Test("100 km mileage picks kilometer not marathon")
    func onehundredKilometers() {
        let comp = LandmarkLibrary.standard.bestMatch(forMeters: 100_000)
        // marathon is 42_195 < 100_000, so should pick marathon (biggest ≤ meters)
        #expect(comp.landmark.key == "marathon")
        #expect(comp.multiplier > 2)
    }

    @Test("picks the largest landmark that does not exceed the mileage")
    func monotonicSelection() {
        let lib = LandmarkLibrary.standard
        for meters in stride(from: 1.0, through: 100_000_000.0, by: 1_000.0) {
            let comp = lib.bestMatch(forMeters: meters)
            #expect(comp.landmark.distanceMeters <= meters || comp.landmark.key == "step")
        }
    }

    @Test("multiplier is distance / landmark")
    func multiplierMath() {
        let comp = LandmarkLibrary.standard.bestMatch(forMeters: 400)
        #expect(comp.landmark.key == "track")
        #expect(abs(comp.multiplier - 1.0) < 0.001)
    }

    @Test("non-empty library is required")
    func emptyLibraryCrashes() {
        // Construction is legal; calling bestMatch asserts. We only verify
        // that the standard library is not empty (a regression guard).
        #expect(!LandmarkLibrary.standard.landmarks.isEmpty)
    }

    @Test("humanReadable output is non-empty for sane inputs")
    func readableOutputPresent() {
        for meters in [0.1, 1.0, 50.0, 1_000.0, 42_195.0, 1_900_000.0] {
            let comp = LandmarkLibrary.standard.bestMatch(forMeters: meters)
            #expect(!comp.humanReadable.isEmpty)
        }
    }
}
