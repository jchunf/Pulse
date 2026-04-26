import Foundation
import CoreGraphics
import CoreImage

/// F-04 — renders a `MouseDisplayHistogram` into a pixel buffer
/// (`CGImage`) for display on the Dashboard. The renderer is
/// deliberately small and allocation-stable: one `CGContext` per call,
/// one optional Core Image blur pass, done. Not a per-frame pipeline.
///
/// Color ramp: density ∈ [0, 1] maps linearly through a 3-stop gradient
/// (transparent → sage → coral) that matches the "Vital Pulse" visual
/// language. The raw counts are log-compressed (`log1p`) before
/// normalisation so a single hotspot at (say) the dock region does not
/// flatten the rest of the map to black.
///
/// The output image's pixel dimensions are `gridSize * scale` on each
/// axis. A scale of 4 produces 512×512 on a 128-cell grid — enough
/// detail to survive UI-space rescaling on a Retina display without
/// visible pixel boundaries, but cheap enough to render in a few
/// milliseconds so `DashboardModel`'s refresh loop doesn't stall.
///
/// Thread-safety: stateless. Safe to call from any thread; a shared
/// singleton is fine.
public struct MouseDensityRenderer: Sendable {

    public struct Configuration: Sendable {
        /// Side length in pixels per bin cell. 4 → 512×512 for a 128
        /// grid. Keep ≥ 2 so the optional blur pass has room to work.
        public let pixelsPerCell: Int
        /// Optional Gaussian blur radius in output-pixel units. `nil`
        /// disables blur — useful in tests where we want to assert
        /// pixel equality on specific cells.
        public let blurRadius: Double?
        /// Color ramp RGBA stops ordered by intensity (0…1). Must
        /// contain at least two stops; the first is intensity 0, the
        /// last is intensity 1, intermediate stops are evenly spaced.
        public let rampStops: [ColorStop]
        /// Exponent applied to the `log1p`-normalised intensity before
        /// the ramp lookup. `1.0` is no-op (linear); higher values
        /// push quiet cells towards the floor of the ramp, so a
        /// Strava-style "dark surface, peaks pop" reading is achieved
        /// without needing a non-monotonic ramp. Default `1.6` —
        /// felt right in dogfood: peaks stay punchy, the long tail of
        /// 1-or-2-hit cells fades into the dark plate so the eye is
        /// drawn to the regions the cursor actually parked in.
        public let intensityGamma: Double

        public init(
            pixelsPerCell: Int = 4,
            blurRadius: Double? = 3.5,
            rampStops: [ColorStop] = MouseDensityRenderer.defaultRamp,
            intensityGamma: Double = 1.6
        ) {
            precondition(pixelsPerCell >= 1, "pixelsPerCell must be positive")
            precondition(rampStops.count >= 2, "ramp needs ≥ 2 stops")
            precondition(intensityGamma > 0, "intensityGamma must be positive")
            self.pixelsPerCell = pixelsPerCell
            self.blurRadius = blurRadius
            self.rampStops = rampStops
            self.intensityGamma = intensityGamma
        }
    }

    /// One color + alpha in the density ramp. Stored as sRGB 0…1 floats.
    public struct ColorStop: Sendable, Equatable {
        public let red: Double
        public let green: Double
        public let blue: Double
        public let alpha: Double

        public init(red: Double, green: Double, blue: Double, alpha: Double) {
            self.red = red
            self.green = green
            self.blue = blue
            self.alpha = alpha
        }
    }

    /// Default ramp — single-hue coral luminance against a dark
    /// surface, modelled on Strava's personal heatmap aesthetic
    /// rather than the thermal blue→red palette web-analytics
    /// products use (those only work because there's a screenshot
    /// underneath; without one, "red" has nothing to point at and
    /// the visual reads as a broken dashboard).
    ///
    /// The first stop is fully transparent so the dark display
    /// plate behind the bitmap shows through for low-density
    /// regions. Combined with `Configuration.intensityGamma > 1`,
    /// quiet areas fade into the plate while peaks lift through
    /// coral toward a near-white halo — the "where did your cursor
    /// live this week" story emerges without a legend.
    public static let defaultRamp: [ColorStop] = [
        ColorStop(red: 0.961, green: 0.396, blue: 0.396, alpha: 0.0),  // coral, transparent (dark plate shows)
        ColorStop(red: 0.972, green: 0.498, blue: 0.435, alpha: 0.65), // coral, mid glow
        ColorStop(red: 1.000, green: 0.870, blue: 0.780, alpha: 1.0)   // coral→white halo at peak
    ]

    public let configuration: Configuration

    public init(configuration: Configuration = Configuration()) {
        self.configuration = configuration
    }

    /// Render `histogram` to a `CGImage`. Returns `nil` when there is
    /// nothing to render (no cells, or every cell is zero) — callers
    /// should treat that as the card's empty state.
    public func render(_ histogram: MouseDisplayHistogram) -> CGImage? {
        guard histogram.peakCount > 0, !histogram.cells.isEmpty else { return nil }

        let gridSize = histogram.gridSize
        let scale = configuration.pixelsPerCell
        let pixelsSide = gridSize * scale
        let bytesPerPixel = 4
        let bytesPerRow = pixelsSide * bytesPerPixel
        var pixels = [UInt8](repeating: 0, count: pixelsSide * pixelsSide * bytesPerPixel)

        // Normalise with `log1p` so one hotspot doesn't drown out the
        // rest of the map. `log1p(0) = 0`, so empty cells stay at 0.
        let peakLog = log1p(Double(histogram.peakCount))
        guard peakLog > 0 else { return nil }

        let gamma = configuration.intensityGamma
        for cell in histogram.cells where cell.count > 0 {
            let raw = log1p(Double(cell.count)) / peakLog
            // Gamma-curve the normalised intensity before sampling
            // so quiet cells fall toward the ramp floor and peaks
            // pop. With `gamma == 1` this is a no-op.
            let intensity = pow(max(0.0, min(1.0, raw)), gamma)
            let color = Self.sample(ramp: configuration.rampStops, at: intensity)
            let r = UInt8(clamping: Int((color.red * 255).rounded()))
            let g = UInt8(clamping: Int((color.green * 255).rounded()))
            let b = UInt8(clamping: Int((color.blue * 255).rounded()))
            let a = UInt8(clamping: Int((color.alpha * 255).rounded()))

            let x0 = cell.binX * scale
            let y0 = cell.binY * scale
            for dy in 0..<scale {
                let row = (y0 + dy) * bytesPerRow
                for dx in 0..<scale {
                    let offset = row + (x0 + dx) * bytesPerPixel
                    pixels[offset]     = r
                    pixels[offset + 1] = g
                    pixels[offset + 2] = b
                    pixels[offset + 3] = a
                }
            }
        }

        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)
        guard let provider = CGDataProvider(data: Data(pixels) as CFData) else { return nil }
        guard let raw = CGImage(
            width: pixelsSide,
            height: pixelsSide,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: bytesPerRow,
            space: colorSpace,
            bitmapInfo: bitmapInfo,
            provider: provider,
            decode: nil,
            shouldInterpolate: true,
            intent: .defaultIntent
        ) else { return nil }

        guard let blurRadius = configuration.blurRadius, blurRadius > 0 else { return raw }
        return Self.blur(raw, radius: blurRadius) ?? raw
    }

    // MARK: - Ramp sampling

    /// Linear interpolation along a sorted-by-intensity ramp of stops.
    /// `position` is clamped to `[0, 1]`.
    static func sample(ramp: [ColorStop], at position: Double) -> ColorStop {
        let p = max(0.0, min(1.0, position))
        if ramp.count == 1 { return ramp[0] }
        let lastIndex = Double(ramp.count - 1)
        let scaled = p * lastIndex
        let lower = Int(scaled.rounded(.down))
        let upper = min(lower + 1, ramp.count - 1)
        let t = scaled - Double(lower)
        let a = ramp[lower]
        let b = ramp[upper]
        return ColorStop(
            red:   a.red   + (b.red   - a.red)   * t,
            green: a.green + (b.green - a.green) * t,
            blue:  a.blue  + (b.blue  - a.blue)  * t,
            alpha: a.alpha + (b.alpha - a.alpha) * t
        )
    }

    // MARK: - Optional blur

    /// Runs a `CIGaussianBlur` on `image` and crops the bloomed edges
    /// back to the original frame. Returns `nil` if Core Image refuses
    /// (e.g. in a headless environment without a default context).
    private static func blur(_ image: CGImage, radius: Double) -> CGImage? {
        let ci = CIImage(cgImage: image)
        guard let filter = CIFilter(name: "CIGaussianBlur") else { return nil }
        filter.setValue(ci, forKey: kCIInputImageKey)
        filter.setValue(radius, forKey: kCIInputRadiusKey)
        guard let output = filter.outputImage?.cropped(to: ci.extent) else { return nil }
        let context = CIContext(options: [.useSoftwareRenderer: true])
        return context.createCGImage(output, from: ci.extent)
    }
}
