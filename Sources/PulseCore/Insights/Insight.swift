import Foundation

/// A single cross-metric observation the engine surfaces on the
/// Dashboard. The engine stays presentation-free: the `payload`
/// carries typed data (counts, ratios, durations, bundle ids) and
/// the UI layer renders a localized sentence from it via String
/// Catalog. This keeps `PulseCore` Foundation-only + testable on
/// Linux, matching the rest of the read-side query layer.
///
/// Review §3.4 ("Cross-metric insights") is the directive for this
/// module: rule-based, transparent, auditable, **no outbound calls**
/// — the on-device privacy pitch would break the instant we shipped
/// a cloud-LLM summary path.
public struct Insight: Sendable, Equatable, Identifiable {

    public let id: String
    public let kind: Kind
    public let payload: InsightPayload

    /// Lightweight taxonomy for the UI to pick an accent / icon. Keep
    /// this closed — we want every new rule to decide between these
    /// three tones rather than invent a fourth and dilute the signal.
    public enum Kind: Sendable, Equatable {
        /// Today stands out in a positive direction (longer focus,
        /// hit a goal, etc.). UI renders in the positive accent.
        case celebratory
        /// A neutral observation worth noticing (unusual pattern vs.
        /// baseline, top-app dominance). UI renders in coral.
        case curious
        /// Calm / reassuring factoid ("steady week"). Reserved for
        /// when we add the "nothing weird today" class of rule.
        case neutral
    }

    public init(id: String, kind: Kind, payload: InsightPayload) {
        self.id = id
        self.kind = kind
        self.payload = payload
    }
}

/// Typed data the UI layer needs to render an insight sentence.
/// Each case carries exactly the values a localized String Catalog
/// entry will interpolate — no stringly-typed dictionaries, no
/// "args: [Any]" blobs. Add a new case + a new Catalog key together
/// whenever a new rule ships.
public enum InsightPayload: Sendable, Equatable {

    /// Today's key-press count diverges from the recent median by
    /// `percentOff`. `direction` disambiguates "busier" vs "quieter"
    /// so the UI can pick separate headline strings per language
    /// (English would otherwise collapse both into an awkward "±X%").
    case activityAnomaly(
        direction: Direction,
        percentOff: Int,
        todayKeys: Int,
        medianKeys: Int
    )

    /// Today's longest uninterrupted focus segment beats the median
    /// of the prior N days by at least the rule's threshold. Always
    /// celebratory — we don't flag "worst focus day" because that
    /// reading crosses into guilt-trip territory (review §2.3 and
    /// §4 caution).
    case deepFocusStandout(
        todayLongestSeconds: Int,
        medianLongestSeconds: Int,
        bundleId: String,
        percentAbove: Int
    )

    /// One app accounts for more than the rule's threshold fraction
    /// of today's active time. Neutral observation — the UI copy
    /// should read as "noticed" not "warned".
    case singleAppDominance(
        bundleId: String,
        fractionOfActive: Double,
        secondsInApp: Int
    )

    /// A single **completed** hour of today diverges from the median
    /// of that same hour-of-day over prior days by ≥ the rule's
    /// threshold. `hour` is 0–23 local time; UI formats as `HH:00`.
    /// The engine emits at most one of these per refresh — whichever
    /// hour has the largest magnitude deviation — so the card stays
    /// a glance, not a list.
    case hourlyActivityAnomaly(
        hour: Int,
        direction: Direction,
        percentOff: Int,
        todayCount: Int,
        medianCount: Int
    )

    /// The user has a ≥ `minimumStreakDays` continuity streak going
    /// into today, but today has not yet cleared the qualifying
    /// threshold. Fires only after a mid-afternoon cutoff so early
    /// risers are not pressured to front-load activity. UI copy
    /// should frame the nudge as **"here's what saves the streak"**,
    /// never as a guilt-trip (review §2.3 / §4 caution).
    case streakAtRisk(
        currentStreak: Int,
        activeHoursToday: Int,
        hoursToQualify: Int
    )

    public enum Direction: Sendable, Equatable {
        case above
        case below
    }
}
