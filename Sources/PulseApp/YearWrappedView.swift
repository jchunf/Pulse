#if canImport(AppKit)
import AppKit
import Combine
import Foundation
import PulseCore
import SwiftUI

// MARK: - F-24 — Year wrapped
//
// "Spotify Wrapped" for Pulse: a year-to-date summary of the
// numbers Pulse has been quietly accumulating. Built from
// `EventStore.yearWrappedSnapshot(yearStart:capUntil:)` — no new
// collection, all sources already disclosed in
// `docs/03-data-collection.md`.
//
// Single scrollable page (deliberately not a slideshow): screenshot
// friendly + simple to share. The "Save as image…" button at the
// bottom uses SwiftUI's `ImageRenderer` to flatten the entire
// scrolled content into a PNG and drops it into a user-chosen
// path via `NSSavePanel`.

@MainActor
final class YearWrappedModel: ObservableObject {

    @Published private(set) var snapshot: YearWrappedSnapshot?
    @Published private(set) var errorMessage: String?
    @Published private(set) var isLoading: Bool = false

    /// `nil` when the database is unavailable (fresh install whose
    /// migrations haven't run, or a fork that disabled the store).
    /// The view shows the error message instead of trying to render
    /// stale defaults.
    private let store: EventStore?

    init(store: EventStore?) {
        self.store = store
    }

    /// Compute the snapshot. Cheap relative to a Dashboard refresh
    /// (it does walk per-day for `longestFocus`), so we run it on a
    /// detached cooperative task and let the main actor render the
    /// loading spinner in the meantime.
    func load() async {
        guard let store else {
            errorMessage = String(
                localized: "Pulse hasn't recorded any data yet.",
                bundle: .pulse,
                comment: "F-24 YearWrappedView — DB-unavailable error."
            )
            return
        }
        isLoading = true
        defer { isLoading = false }
        let now = Date()
        let calendar = Calendar.current
        // Year start: Jan 1 00:00 in the user's local time. Caller
        // can override via `Calendar.current.date(...)` later if we
        // ever ship "show me a custom range".
        let yearStart = calendar.date(
            from: DateComponents(
                year: calendar.component(.year, from: now),
                month: 1,
                day: 1
            )
        ) ?? now

        let result: Result<YearWrappedSnapshot, Error> = await Task.detached(priority: .userInitiated) {
            do {
                let snap = try store.yearWrappedSnapshot(
                    yearStart: yearStart,
                    capUntil: now,
                    calendar: calendar
                )
                return .success(snap)
            } catch {
                return .failure(error)
            }
        }.value

        switch result {
        case .success(let snap):
            self.snapshot = snap
            self.errorMessage = nil
        case .failure(let error):
            self.errorMessage = String.localizedStringWithFormat(
                NSLocalizedString(
                    "Couldn't compute wrapped: %@",
                    bundle: .pulse,
                    comment: "F-24 YearWrappedView — query-error fallback."
                ),
                error.localizedDescription
            )
        }
    }
}

struct YearWrappedView: View {

    @ObservedObject var model: YearWrappedModel

    /// `Bundle.pulse` already accessed elsewhere; we resolve display
    /// names through this cache to share state with the Dashboard.
    private static let displayNameCache = BundleDisplayNameCache()

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                if let snapshot = model.snapshot {
                    content(for: snapshot)
                } else if let message = model.errorMessage {
                    Text(message)
                        .foregroundStyle(PulseDesign.critical)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.vertical, 80)
                } else {
                    ProgressView()
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.vertical, 80)
                }
            }
            .padding(28)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(width: 640, height: 720)
        .background(PulseDesign.surface)
        .task { await model.load() }
    }

    @ViewBuilder
    private func content(for snapshot: YearWrappedSnapshot) -> some View {
        header(snapshot)
        daysCard(snapshot)
        keystrokesCard(snapshot)
        mouseDistanceCard(snapshot)
        if !snapshot.topApps.isEmpty {
            topAppsCard(snapshot)
        }
        if let focus = snapshot.longestFocus {
            longestFocusCard(focus)
        }
        if let busiest = snapshot.busiestDay {
            busiestDayCard(busiest)
        }
        rhythmCard(snapshot)
        exportButton(snapshot)
    }

    // MARK: - Sections

    private func header(_ snapshot: YearWrappedSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Pulse · Year so far", bundle: .pulse)
                .font(.system(.largeTitle, design: .rounded, weight: .semibold))
            Text(headerSubtitle(snapshot))
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func daysCard(_ snapshot: YearWrappedSnapshot) -> some View {
        wrappedCard {
            cardLabel(key: "Days with Pulse")
            Text(PulseFormat.integer(snapshot.daysActive))
                .font(.system(size: 56, weight: .bold, design: .rounded))
                .foregroundStyle(PulseDesign.coral)
            if let firstActive = snapshot.firstActiveAt {
                Text(
                    String.localizedStringWithFormat(
                        NSLocalizedString(
                            "Recording since %@.",
                            bundle: .pulse,
                            comment: "F-24 days-active subtitle. %@ is a localized short date."
                        ),
                        Self.dateFormatter.string(from: firstActive)
                    )
                )
                .font(.footnote)
                .foregroundStyle(.secondary)
            }
        }
    }

    private func keystrokesCard(_ snapshot: YearWrappedSnapshot) -> some View {
        wrappedCard {
            cardLabel(key: "Keystrokes")
            Text(PulseFormat.integer(snapshot.totalKeyPresses))
                .font(.system(size: 56, weight: .bold, design: .rounded))
                .foregroundStyle(PulseDesign.coral)
            // Words ≈ keystrokes / 5 (English average). Books ≈
            // words / 80,000 (rough mid-length novel). The narrative
            // is intentionally approximate — it's a fun fact, not
            // word-count software.
            let approxWords = snapshot.totalKeyPresses / 5
            Text(
                String.localizedStringWithFormat(
                    NSLocalizedString(
                        "Roughly %@ words — about %@ a mid-length novel.",
                        bundle: .pulse,
                        comment: "F-24 keystrokes subtitle. %1$@ formatted word count, %2$@ multiplier like '0.3×' or '2×'."
                    ),
                    PulseFormat.integer(approxWords),
                    novelMultiplier(words: approxWords)
                )
            )
            .font(.footnote)
            .foregroundStyle(.secondary)
        }
    }

    private func mouseDistanceCard(_ snapshot: YearWrappedSnapshot) -> some View {
        wrappedCard {
            cardLabel(key: "Mouse distance")
            let metres = snapshot.totalMouseDistanceMillimeters / 1_000.0
            Text(PulseFormat.distance(millimeters: snapshot.totalMouseDistanceMillimeters))
                .font(.system(size: 56, weight: .bold, design: .rounded))
                .foregroundStyle(PulseDesign.coral)
            let comparison = LandmarkLibrary.standard.bestMatch(forMeters: metres)
            Text(PulseFormat.landmarkComparisonSentence(for: comparison))
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    private func topAppsCard(_ snapshot: YearWrappedSnapshot) -> some View {
        wrappedCard {
            cardLabel(key: "Most-used apps")
            VStack(spacing: 8) {
                ForEach(Array(snapshot.topApps.enumerated()), id: \.element.id) { index, app in
                    HStack {
                        Text("\(index + 1)")
                            .font(.title3.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .frame(width: 28, alignment: .leading)
                        Text(Self.displayNameCache.name(for: app.bundleId))
                            .font(.title3)
                        Spacer()
                        Text(PulseFormat.duration(seconds: app.secondsUsed))
                            .font(.title3.monospacedDigit())
                            .foregroundStyle(PulseDesign.coral)
                    }
                }
            }
        }
    }

    private func longestFocusCard(_ focus: FocusSegment) -> some View {
        wrappedCard {
            cardLabel(key: "Longest focus session")
            Text(PulseFormat.duration(seconds: focus.durationSeconds))
                .font(.system(size: 48, weight: .bold, design: .rounded))
                .foregroundStyle(PulseDesign.coral)
            Text(
                String.localizedStringWithFormat(
                    NSLocalizedString(
                        "%1$@ on %2$@",
                        bundle: .pulse,
                        comment: "F-24 longest-focus subtitle. %1$@ app display name, %2$@ short date."
                    ),
                    Self.displayNameCache.name(for: focus.bundleId),
                    Self.dateFormatter.string(from: focus.startedAt)
                )
            )
            .font(.footnote)
            .foregroundStyle(.secondary)
        }
    }

    private func busiestDayCard(_ busiest: BusiestDay) -> some View {
        wrappedCard {
            cardLabel(key: "Busiest day")
            Text(Self.dateFormatter.string(from: busiest.day))
                .font(.system(size: 36, weight: .bold, design: .rounded))
                .foregroundStyle(PulseDesign.coral)
            Text(
                String.localizedStringWithFormat(
                    NSLocalizedString(
                        "%@ keystrokes + clicks combined.",
                        bundle: .pulse,
                        comment: "F-24 busiest-day subtitle. %@ formatted total event count."
                    ),
                    PulseFormat.integer(busiest.totalEvents)
                )
            )
            .font(.footnote)
            .foregroundStyle(.secondary)
        }
    }

    private func rhythmCard(_ snapshot: YearWrappedSnapshot) -> some View {
        wrappedCard {
            cardLabel(key: "Your rhythm")
            if let hour = snapshot.mostActiveHourOfDay {
                Text(formatHour(hour))
                    .font(.system(size: 36, weight: .bold, design: .rounded))
                    .foregroundStyle(PulseDesign.coral)
                Text(
                    String.localizedStringWithFormat(
                        NSLocalizedString(
                            "Your peak hour. You were active across %lld of 24 hours of the day.",
                            bundle: .pulse,
                            comment: "F-24 rhythm subtitle. %lld is the number of distinct hours-of-day with activity."
                        ),
                        snapshot.distinctActiveHoursOfDay
                    )
                )
                .font(.footnote)
                .foregroundStyle(.secondary)
            } else {
                Text("Pulse needs a few more hours of recorded activity before it can pick out your peak. Check back at the end of a fuller day.", bundle: .pulse)
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func exportButton(_ snapshot: YearWrappedSnapshot) -> some View {
        Button {
            saveAsImage(snapshot: snapshot)
        } label: {
            Label {
                Text("Save as image…", bundle: .pulse)
            } icon: {
                Image(systemName: "square.and.arrow.down")
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
        .padding(.top, 12)
    }

    // MARK: - Helpers

    @ViewBuilder
    private func wrappedCard<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            content()
        }
        .pulseFeaturedCard()
    }

    private func cardLabel(key: LocalizedStringKey) -> some View {
        Text(key, bundle: .pulse)
            .font(PulseDesign.labelFont)
            .tracking(0.3)
            .foregroundStyle(.secondary)
    }

    private func headerSubtitle(_ snapshot: YearWrappedSnapshot) -> String {
        let yearString = String(Calendar.current.component(.year, from: snapshot.yearStart))
        let asOf = Self.dateFormatter.string(from: snapshot.capturedAt)
        return String.localizedStringWithFormat(
            NSLocalizedString(
                "%1$@ · as of %2$@",
                bundle: .pulse,
                comment: "F-24 header subtitle. %1$@ is the year, %2$@ is a localized short date."
            ),
            yearString,
            asOf
        )
    }

    private func novelMultiplier(words: Int) -> String {
        let novelWords = 80_000
        let multiplier = Double(words) / Double(novelWords)
        if multiplier < 0.05 {
            return "a small fraction of"
        } else if multiplier < 1 {
            return String(format: "%.1f×", multiplier)
        } else {
            return String(format: "%.0f×", multiplier)
        }
    }

    private func formatHour(_ hour: Int) -> String {
        // Render as "9:00–10:00" etc. — clearer than the bare hour
        // index and matches the way users describe "my peak hour".
        let next = (hour + 1) % 24
        return "\(hour):00–\(next):00"
    }

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .none
        return f
    }()

    // MARK: - Image export

    /// Render the entire scrollable content into a PNG via SwiftUI's
    /// `ImageRenderer`, then ask the user where to save it. The
    /// rendered view is a copy of the live one — it doesn't include
    /// the "Save as image…" button itself, just the data.
    private func saveAsImage(snapshot: YearWrappedSnapshot) {
        // Build a non-scrolling, button-free copy of the layout for
        // export. `frame(width: 640)` matches the live view so the
        // typography lands the same.
        let exportView = YearWrappedExportSnapshot(
            snapshot: snapshot,
            displayName: { Self.displayNameCache.name(for: $0) }
        )
        .frame(width: 640)
        .background(PulseDesign.surface)

        let renderer = ImageRenderer(content: exportView)
        renderer.scale = NSScreen.main?.backingScaleFactor ?? 2.0
        guard let nsImage = renderer.nsImage,
              let tiff = nsImage.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let png = bitmap.representation(using: .png, properties: [:]) else {
            return
        }

        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.nameFieldStringValue = "pulse-wrapped.png"
        panel.canCreateDirectories = true
        panel.directoryURL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
        panel.title = NSLocalizedString(
            "Save year wrapped image",
            bundle: .pulse,
            comment: "F-24 NSSavePanel title."
        )
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try? png.write(to: url)
    }
}

/// Static, non-scrolling rendering of the wrapped page used by
/// `ImageRenderer` to produce the exported PNG. Drops the export
/// button (no clickable element makes sense in a still image)
/// and the ScrollView wrapper (we want every section in the
/// final bitmap, not just the visible viewport).
private struct YearWrappedExportSnapshot: View {

    let snapshot: YearWrappedSnapshot
    let displayName: (String) -> String

    var body: some View {
        VStack(spacing: 24) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Pulse · Year so far", bundle: .pulse)
                    .font(.system(.largeTitle, design: .rounded, weight: .semibold))
                Text(headerLine)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            simpleCard(label: "Days with Pulse", value: PulseFormat.integer(snapshot.daysActive))
            simpleCard(label: "Keystrokes", value: PulseFormat.integer(snapshot.totalKeyPresses))
            simpleCard(
                label: "Mouse distance",
                value: PulseFormat.distance(millimeters: snapshot.totalMouseDistanceMillimeters)
            )
            if !snapshot.topApps.isEmpty {
                appsCard
            }
            if let focus = snapshot.longestFocus {
                simpleCard(
                    label: "Longest focus session",
                    value: PulseFormat.duration(seconds: focus.durationSeconds),
                    sub: "\(displayName(focus.bundleId)) · \(Self.dateFormatter.string(from: focus.startedAt))"
                )
            }
            if let busiest = snapshot.busiestDay {
                simpleCard(
                    label: "Busiest day",
                    value: Self.dateFormatter.string(from: busiest.day),
                    sub: "\(PulseFormat.integer(busiest.totalEvents)) keystrokes + clicks"
                )
            }
            if let hour = snapshot.mostActiveHourOfDay {
                simpleCard(
                    label: "Peak hour",
                    value: "\(hour):00–\((hour + 1) % 24):00",
                    sub: "Active across \(snapshot.distinctActiveHoursOfDay) of 24 hours"
                )
            }
        }
        .padding(28)
    }

    private var headerLine: String {
        let yearString = String(Calendar.current.component(.year, from: snapshot.yearStart))
        return "\(yearString) · as of \(Self.dateFormatter.string(from: snapshot.capturedAt))"
    }

    private var appsCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Most-used apps", bundle: .pulse)
                .font(PulseDesign.labelFont)
                .tracking(0.3)
                .foregroundStyle(.secondary)
            ForEach(Array(snapshot.topApps.enumerated()), id: \.element.id) { index, app in
                HStack {
                    Text("\(index + 1)")
                        .font(.title3.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .frame(width: 28, alignment: .leading)
                    Text(displayName(app.bundleId))
                        .font(.title3)
                    Spacer()
                    Text(PulseFormat.duration(seconds: app.secondsUsed))
                        .font(.title3.monospacedDigit())
                        .foregroundStyle(PulseDesign.coral)
                }
            }
        }
        .pulseFeaturedCard()
    }

    private func simpleCard(label: LocalizedStringKey, value: String, sub: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(label, bundle: .pulse)
                .font(PulseDesign.labelFont)
                .tracking(0.3)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: 56, weight: .bold, design: .rounded))
                .foregroundStyle(PulseDesign.coral)
            if let sub {
                Text(sub)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .pulseFeaturedCard()
    }

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .none
        return f
    }()
}
#endif
