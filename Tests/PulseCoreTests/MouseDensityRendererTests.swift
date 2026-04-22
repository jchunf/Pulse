import Testing
import Foundation
import CoreGraphics
@testable import PulseCore

@Suite("MouseDensityRenderer — histogram to CGImage")
struct MouseDensityRendererTests {

    // MARK: - Empty input

    @Test("empty histogram returns nil (no peak to normalise against)")
    func emptyReturnsNil() {
        let histogram = MouseDisplayHistogram(
            displayId: 1,
            gridSize: MouseTrajectoryGrid.size,
            totalCount: 0,
            cells: []
        )
        let renderer = MouseDensityRenderer()
        #expect(renderer.render(histogram) == nil)
    }

    @Test("all-zero cells render as nil")
    func allZeroCellsReturnNil() {
        let histogram = MouseDisplayHistogram(
            displayId: 1,
            gridSize: MouseTrajectoryGrid.size,
            totalCount: 0,
            cells: [
                MouseDensityCell(binX: 0, binY: 0, count: 0),
                MouseDensityCell(binX: 1, binY: 1, count: 0)
            ]
        )
        let renderer = MouseDensityRenderer()
        #expect(renderer.render(histogram) == nil)
    }

    // MARK: - Pixel dimensions

    @Test("output image dimensions = gridSize × pixelsPerCell")
    func imageSizeMatchesConfig() {
        let histogram = MouseDisplayHistogram(
            displayId: 1,
            gridSize: 16,
            totalCount: 1,
            cells: [MouseDensityCell(binX: 0, binY: 0, count: 1)]
        )
        let renderer = MouseDensityRenderer(
            configuration: .init(pixelsPerCell: 3, blurRadius: nil)
        )
        let image = renderer.render(histogram)
        #expect(image?.width == 16 * 3)
        #expect(image?.height == 16 * 3)
    }

    // MARK: - Ramp sampling

    @Test("ramp sampling clamps positions outside [0, 1]")
    func rampClampsOutOfRange() {
        let ramp = MouseDensityRenderer.defaultRamp
        let low = MouseDensityRenderer.sample(ramp: ramp, at: -0.5)
        let high = MouseDensityRenderer.sample(ramp: ramp, at: 1.5)
        #expect(low.alpha == ramp.first!.alpha)
        #expect(high.alpha == ramp.last!.alpha)
    }

    @Test("ramp sampling at 0 / 0.5 / 1 hits stop 0 / stop 1 / stop 2 for a 3-stop ramp")
    func rampHitsStopsAtExactFractions() {
        let ramp = [
            MouseDensityRenderer.ColorStop(red: 0.0, green: 0.0, blue: 0.0, alpha: 0.0),
            MouseDensityRenderer.ColorStop(red: 0.5, green: 0.5, blue: 0.5, alpha: 0.5),
            MouseDensityRenderer.ColorStop(red: 1.0, green: 1.0, blue: 1.0, alpha: 1.0)
        ]
        let zero = MouseDensityRenderer.sample(ramp: ramp, at: 0.0)
        let mid = MouseDensityRenderer.sample(ramp: ramp, at: 0.5)
        let one = MouseDensityRenderer.sample(ramp: ramp, at: 1.0)
        #expect(zero == ramp[0])
        #expect(mid == ramp[1])
        #expect(one == ramp[2])
    }

    @Test("ramp sampling interpolates linearly between adjacent stops")
    func rampInterpolatesLinearly() {
        let ramp = [
            MouseDensityRenderer.ColorStop(red: 0.0, green: 0.0, blue: 0.0, alpha: 0.0),
            MouseDensityRenderer.ColorStop(red: 1.0, green: 1.0, blue: 1.0, alpha: 1.0)
        ]
        let quarter = MouseDensityRenderer.sample(ramp: ramp, at: 0.25)
        #expect(abs(quarter.red - 0.25) < 1e-9)
        #expect(abs(quarter.alpha - 0.25) < 1e-9)
    }

    // MARK: - Pixel content (blur-free path)

    @Test("a lone peak cell writes non-zero pixels in its tile and zeros elsewhere")
    func peakCellAppearsInPixels() throws {
        let grid = 8
        let histogram = MouseDisplayHistogram(
            displayId: 1,
            gridSize: grid,
            totalCount: 10,
            cells: [MouseDensityCell(binX: 3, binY: 4, count: 10)]
        )
        let renderer = MouseDensityRenderer(
            configuration: .init(pixelsPerCell: 2, blurRadius: nil)
        )
        let image = try #require(renderer.render(histogram))
        #expect(image.width == grid * 2)
        #expect(image.height == grid * 2)

        // Round-trip the CGImage back to bytes.
        let pixels = try bytes(from: image)
        let stride = image.bytesPerRow
        // Sampled coordinate: center of the (3, 4) cell when scaled 2×.
        let x = 3 * 2 + 1
        let y = 4 * 2 + 1
        let offset = y * stride + x * 4
        let alpha = pixels[offset + 3]
        #expect(alpha > 0, "peak cell should have non-zero alpha")

        // A cell away from (3, 4) should be fully transparent.
        let offsetEmpty = (0) * stride + 0 * 4
        #expect(pixels[offsetEmpty + 3] == 0)
    }

    // MARK: - Helpers

    /// Copy the pixel bytes out of a `CGImage` for inspection.
    private func bytes(from image: CGImage) throws -> [UInt8] {
        let width = image.width
        let height = image.height
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        var raw = [UInt8](repeating: 0, count: width * height * 4)
        let ctx = try #require(CGContext(
            data: &raw,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        ctx.clear(CGRect(x: 0, y: 0, width: width, height: height))
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return raw
    }
}
