#if canImport(AppKit)
import Foundation
import PulseCore

/// Drives the menu-bar anomaly badge. Polls every minute (independently
/// of DashboardModel, which only polls while its window is open), asks
/// `AnomalyDetector` whether today's numbers diverge ±30% from the
/// past-7-day median, and publishes a `Bool` the MenuBarLabel observes.
///
/// A slow cadence (60 s) is plenty here — the signal is "has a metric
/// drifted meaningfully today" and the badge only needs to update a few
/// times an hour.
@MainActor
final class AnomalyMonitor: ObservableObject {

    @Published private(set) var hasAnomaly: Bool = false

    private let store: EventStore?
    private var task: Task<Void, Never>?

    init(store: EventStore?) {
        self.store = store
    }

    func start() {
        guard task == nil else { return }
        task = Task { [weak self] in
            while !Task.isCancelled {
                await self?.check()
                try? await Task.sleep(nanoseconds: 60 * 1_000_000_000)
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
    }

    private func check() async {
        guard let store else { return }
        let now = Date()
        let dayStart = Calendar.current.startOfDay(for: now)
        let dayEnd = dayStart.addingTimeInterval(86_400)
        do {
            let summary = try store.todaySummary(
                start: dayStart, end: dayEnd, capUntil: now
            )
            let trend = try store.dailyTrend(endingAt: now, days: 8)
            // dailyTrend returns oldest → newest with today as last;
            // drop today so the detector sees only the 7-day history.
            let past = Array(trend.dropLast())
            hasAnomaly = AnomalyDetector.hasAnomaly(today: summary, past: past)
        } catch {
            hasAnomaly = false
        }
    }
}
#endif
