import Foundation
import GRDB

/// F-25 lifetime tier — every `hour_summary` row Pulse has ever written,
/// summed into one number. Used to fire a once-per-user-per-landmark
/// celebration ("Today you crossed a marathon *lifetime*, not just a
/// marathon today"). Queried once per Dashboard refresh; the sum is
/// over O(365) rows/year so it stays a negligible PK-index scan.
///
/// Not rolled into `todaySummary`: the Dashboard wants today + lifetime
/// as separate numbers — today to brag about, lifetime to unlock
/// landmarks that would take weeks to ever reach in a single day.
public extension EventStore {

    /// Sum of every `mouse_distance_mm` ever written to `hour_summary`.
    /// Live data (un-rolled minutes / seconds / raw) is ignored because
    /// the lifetime story is about persistent progress, not the current
    /// refresh tick. Returns 0 for a pristine install.
    func lifetimeMouseDistanceMillimeters() throws -> Double {
        try database.queue.read { db -> Double in
            try Double.fetchOne(db, sql: """
                SELECT COALESCE(SUM(mouse_distance_mm), 0.0)
                FROM hour_summary
                """) ?? 0
        }
    }
}
