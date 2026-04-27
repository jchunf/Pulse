import Foundation
import GRDB

/// F-04 — mouse trajectory density read layer. Backed by
/// `day_mouse_density`, the pre-binned 128×128 histogram populated at
/// rollup time (see `V4__mouse_density.sql` + `rollRawToSecond`).
///
/// Read pattern: select the cells inside the window, then group by
/// `display_id`. Fetching is cheap — the grid is capped at 16 384 cells
/// per (day, display) and the real world produces 1-3k non-zero cells,
/// so a 7-day window across 2 displays returns O(20k) rows, a fraction
/// of the work of the raw-move scan it replaces.
public extension EventStore {

    /// Returns one `MouseDisplayHistogram` per display with any activity
    /// inside the window `[endingAt - days, endingAt]` (inclusive of both
    /// the earliest and the day containing `endingAt`). Displays with no
    /// recorded points are omitted rather than returned as empty — the
    /// card uses the list of returned displays as "displays actually used
    /// in this window".
    ///
    /// Ordering: displays are sorted by total count (descending) so the
    /// most-active display anchors the card. Within each histogram the
    /// cells are sorted ascending by (bin_y, bin_x) to make the result
    /// diff-friendly in tests.
    func mouseDensity(
        endingAt: Date,
        days: Int = 7,
        calendar: Calendar = .current
    ) throws -> [MouseDisplayHistogram] {
        precondition(days >= 1, "days must be at least 1")
        let endDay = calendar.startOfDay(for: endingAt)
        guard let startDay = calendar.date(byAdding: .day, value: -(days - 1), to: endDay),
              let rangeEnd = calendar.date(byAdding: .day, value: 1, to: endDay)
        else {
            return []
        }
        let startSec = Int64(startDay.timeIntervalSince1970)
        let endSec = Int64(rangeEnd.timeIntervalSince1970)

        let rows = try database.queue.read { db -> [Row] in
            try Row.fetchAll(db, sql: """
                SELECT display_id, bin_x, bin_y, SUM(count) AS total
                FROM day_mouse_density
                WHERE day >= ? AND day < ?
                GROUP BY display_id, bin_x, bin_y
                ORDER BY display_id, bin_y, bin_x
                """, arguments: [startSec, endSec])
        }

        var byDisplay: [Int64: [MouseDensityCell]] = [:]
        var totals: [Int64: Int64] = [:]
        for row in rows {
            let displayId: Int64 = row["display_id"]
            let binX: Int = row["bin_x"]
            let binY: Int = row["bin_y"]
            let count: Int64 = row["total"]
            byDisplay[displayId, default: []].append(
                MouseDensityCell(binX: binX, binY: binY, count: count)
            )
            totals[displayId, default: 0] += count
        }

        return byDisplay
            .map { (displayId, cells) in
                MouseDisplayHistogram(
                    displayId: UInt32(truncatingIfNeeded: displayId),
                    gridSize: MouseTrajectoryGrid.size,
                    totalCount: totals[displayId] ?? 0,
                    cells: cells
                )
            }
            .sorted { lhs, rhs in
                if lhs.totalCount != rhs.totalCount {
                    return lhs.totalCount > rhs.totalCount
                }
                return lhs.displayId < rhs.displayId
            }
    }

    /// F-16 — same shape as `mouseDensity` but reads from
    /// `day_click_density` (populated by the V7 rollup pass). Used by
    /// the "clicks" leg of `MouseTrajectoryCard`'s dwell/click toggle.
    /// Mirrors the query exactly so a caller can swap one for the
    /// other without touching the renderer or the per-tile shape.
    func mouseClickDensity(
        endingAt: Date,
        days: Int = 7,
        calendar: Calendar = .current
    ) throws -> [MouseDisplayHistogram] {
        precondition(days >= 1, "days must be at least 1")
        let endDay = calendar.startOfDay(for: endingAt)
        guard let startDay = calendar.date(byAdding: .day, value: -(days - 1), to: endDay),
              let rangeEnd = calendar.date(byAdding: .day, value: 1, to: endDay)
        else {
            return []
        }
        let startSec = Int64(startDay.timeIntervalSince1970)
        let endSec = Int64(rangeEnd.timeIntervalSince1970)

        let rows = try database.queue.read { db -> [Row] in
            try Row.fetchAll(db, sql: """
                SELECT display_id, bin_x, bin_y, SUM(count) AS total
                FROM day_click_density
                WHERE day >= ? AND day < ?
                GROUP BY display_id, bin_x, bin_y
                ORDER BY display_id, bin_y, bin_x
                """, arguments: [startSec, endSec])
        }

        var byDisplay: [Int64: [MouseDensityCell]] = [:]
        var totals: [Int64: Int64] = [:]
        for row in rows {
            let displayId: Int64 = row["display_id"]
            let binX: Int = row["bin_x"]
            let binY: Int = row["bin_y"]
            let count: Int64 = row["total"]
            byDisplay[displayId, default: []].append(
                MouseDensityCell(binX: binX, binY: binY, count: count)
            )
            totals[displayId, default: 0] += count
        }

        return byDisplay
            .map { (displayId, cells) in
                MouseDisplayHistogram(
                    displayId: UInt32(truncatingIfNeeded: displayId),
                    gridSize: MouseTrajectoryGrid.size,
                    totalCount: totals[displayId] ?? 0,
                    cells: cells
                )
            }
            .sorted { lhs, rhs in
                if lhs.totalCount != rhs.totalCount {
                    return lhs.totalCount > rhs.totalCount
                }
                return lhs.displayId < rhs.displayId
            }
    }

    /// Latest `DisplayInfo` snapshot recorded for `displayId`, or `nil`
    /// if this display has never written a snapshot. The trajectory card
    /// uses this to honor the display's physical aspect ratio when
    /// sizing the rendered heatmap tile.
    func latestDisplaySnapshot(displayId: UInt32) throws -> DisplayInfo? {
        try database.queue.read { db -> DisplayInfo? in
            guard let row = try Row.fetchOne(db, sql: """
                SELECT width_px, height_px, dpi, is_primary
                FROM display_snapshots
                WHERE display_id = ?
                ORDER BY ts DESC
                LIMIT 1
                """, arguments: [Int64(displayId)])
            else { return nil }
            let widthPx: Int = row["width_px"]
            let heightPx: Int = row["height_px"]
            let dpi: Double = row["dpi"]
            let isPrimary: Int = row["is_primary"]
            return DisplayInfo(
                id: displayId,
                widthPx: widthPx,
                heightPx: heightPx,
                dpi: dpi,
                isPrimary: isPrimary == 1
            )
        }
    }
}

// MARK: - Value types

/// The single 128-cell grid side length used across the density
/// pipeline. Lives as a namespace because both the write path
/// (`rollRawToSecond` SQL) and the read path consume it as a contract.
public enum MouseTrajectoryGrid {
    public static let size: Int = 128
}

/// One non-zero cell of the binned density grid for a given display.
/// `binX` / `binY` are 0-based integers in `[0, MouseTrajectoryGrid.size)`.
public struct MouseDensityCell: Sendable, Equatable {
    public let binX: Int
    public let binY: Int
    public let count: Int64

    public init(binX: Int, binY: Int, count: Int64) {
        self.binX = binX
        self.binY = binY
        self.count = count
    }
}

/// All activity recorded for one display inside the queried window.
/// Callers iterate `cells` to render; `totalCount` is cached for the
/// card header ("N moves recorded across this display").
public struct MouseDisplayHistogram: Sendable, Equatable {
    public let displayId: UInt32
    public let gridSize: Int
    public let totalCount: Int64
    public let cells: [MouseDensityCell]

    public init(displayId: UInt32, gridSize: Int, totalCount: Int64, cells: [MouseDensityCell]) {
        self.displayId = displayId
        self.gridSize = gridSize
        self.totalCount = totalCount
        self.cells = cells
    }

    /// Peak cell count, used by the renderer to normalize the color
    /// ramp. Zero when there are no cells (the caller should avoid
    /// rendering an empty histogram, but it's a safe value here).
    public var peakCount: Int64 {
        cells.map(\.count).max() ?? 0
    }
}
