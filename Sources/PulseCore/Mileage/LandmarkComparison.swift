import Foundation

/// A real-world landmark with a distance in meters, used to turn a bare mouse
/// mileage number into a dramatic comparison. See F-07 / F-25 and the UX
/// principle P4 ("data storytelling") in `docs/11-ux-principles.md`.
public struct Landmark: Sendable, Equatable {
    public let key: String          // stable identifier for L10n keys
    public let displayName: String  // default English name; localized at render time
    public let distanceMeters: Double

    public init(key: String, displayName: String, distanceMeters: Double) {
        self.key = key
        self.displayName = displayName
        self.distanceMeters = distanceMeters
    }
}

/// A comparison output: "your mouse moved N meters, that's P× a swimming pool".
public struct LandmarkComparison: Sendable, Equatable {
    public let landmark: Landmark
    public let multiplier: Double          // mileage / landmark
    public let humanReadable: String       // e.g. "≈ 3.2× a marathon"

    public init(landmark: Landmark, multiplier: Double, humanReadable: String) {
        self.landmark = landmark
        self.multiplier = multiplier
        self.humanReadable = humanReadable
    }
}

/// Chooses the "most dramatic but still sensible" landmark for a given mileage.
/// The heuristic: pick the largest landmark whose distance is ≤ the mileage,
/// unless mileage is tiny, in which case fall back to the smallest (pool / bus).
///
/// This keeps the first-day UX meaningful ("2 steps", "half a pool") and the
/// milestone UX impressive ("40× a marathon", "once across the Pacific").
public struct LandmarkLibrary: Sendable {
    public let landmarks: [Landmark]

    public init(landmarks: [Landmark]) {
        self.landmarks = landmarks.sorted(by: { $0.distanceMeters < $1.distanceMeters })
    }

    /// The default library shipped with Pulse. Values are approximate,
    /// rounded to be evocative rather than precise.
    public static let standard: LandmarkLibrary = {
        LandmarkLibrary(landmarks: [
            Landmark(key: "step",         displayName: "step",                 distanceMeters: 0.75),
            Landmark(key: "pool",         displayName: "swimming pool length", distanceMeters: 50),
            Landmark(key: "track",        displayName: "athletics track lap",  distanceMeters: 400),
            Landmark(key: "kilometer",    displayName: "kilometer",            distanceMeters: 1_000),
            Landmark(key: "marathon",     displayName: "marathon",             distanceMeters: 42_195),
            Landmark(key: "beijing_gz",   displayName: "Beijing → Guangzhou",  distanceMeters: 1_900_000),
            Landmark(key: "pacific",      displayName: "the Pacific",          distanceMeters: 15_500_000),
            Landmark(key: "equator",      displayName: "Earth's equator",      distanceMeters: 40_075_000)
        ])
    }()

    /// Returns the landmark whose distance is closest to, but not greater
    /// than, the given mileage. If the mileage is smaller than every
    /// landmark, returns the smallest one anyway (for first-day UX).
    public func bestMatch(forMeters meters: Double) -> LandmarkComparison {
        precondition(!landmarks.isEmpty, "landmark library must not be empty")
        let match: Landmark = landmarks.last(where: { $0.distanceMeters <= meters }) ?? landmarks[0]
        let multiplier = match.distanceMeters > 0 ? meters / match.distanceMeters : 0
        let readable = formatMultiplier(multiplier, landmark: match)
        return LandmarkComparison(landmark: match, multiplier: multiplier, humanReadable: readable)
    }

    /// English default formatting. UI layers provide localized variants.
    private func formatMultiplier(_ m: Double, landmark: Landmark) -> String {
        if m < 0.01 {
            return "a tiny fraction of a \(landmark.displayName)"
        } else if m < 1 {
            let pct = Int((m * 100).rounded())
            return "\(pct)% of a \(landmark.displayName)"
        } else if m < 2 {
            return "about 1× a \(landmark.displayName)"
        } else {
            let rounded = (m * 10).rounded() / 10
            return "≈ \(rounded)× a \(landmark.displayName)"
        }
    }
}
