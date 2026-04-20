#if canImport(AppKit)
import AppKit
import Foundation
import PulseCore
import WebKit

/// Renders the same HTML document `WeeklyReportRenderer` produces
/// for the web-page export, then asks `WKWebView` to print it to PDF
/// so the user gets a file they can email, archive, or drop into
/// Notion / Obsidian without the recipient needing to open HTML in
/// a browser.
///
/// Lives on `MainActor` — `WKWebView` is main-actor-bound on macOS,
/// and `WKWebView.pdf(configuration:)` can only be called once the
/// navigation load finishes. We model that as a `CheckedContinuation`
/// wired to a `WKNavigationDelegate` so the caller's `await` chain
/// reads linearly.
@MainActor
enum WeeklyReportPDFRenderer {

    /// Produce a PDF `Data` blob from a weekly-report HTML string.
    /// Throws if the WebKit load fails (malformed HTML, WebKit
    /// content-blocker fault) or if PDF generation fails.
    static func makePDF(html: String) async throws -> Data {
        let webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 816, height: 1056))
        // Letter portrait in points (8.5 × 11 inches × 96pt/inch). The
        // WeeklyReportHTMLRenderer uses max-width 820px inside a body
        // padding of 8px so the rendered page just fits inside the
        // printable width with one pixel of breathing room.

        let loadAwaiter = LoadAwaiter()
        webView.navigationDelegate = loadAwaiter
        _ = webView.loadHTMLString(html, baseURL: nil)
        try await loadAwaiter.waitForLoad()

        let config = WKPDFConfiguration()
        return try await webView.pdf(configuration: config)
    }

    /// Writes `pdfData` into the same reports directory
    /// `WeeklyReportRenderer.writeToDisk` targets, using a parallel
    /// `weekly-YYYY-MM-DD.pdf` filename so the HTML and PDF siblings
    /// sort adjacent to each other.
    static func writeToDisk(pdfData: Data, endingAt: Date) throws -> URL {
        let fm = FileManager.default
        let support = try fm.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let dir = support
            .appendingPathComponent("Pulse", isDirectory: true)
            .appendingPathComponent("reports", isDirectory: true)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let filename = "weekly-\(dayKey(endingAt)).pdf"
        let url = dir.appendingPathComponent(filename)
        try pdfData.write(to: url, options: .atomic)
        return url
    }

    private static func dayKey(_ date: Date) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let comps = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d",
                      comps.year ?? 0, comps.month ?? 0, comps.day ?? 0)
    }
}

/// Tiny bridge from `WKNavigationDelegate`'s callback-shaped API to
/// a single `async throws` suspension. Dealloc is tied to the
/// `WKWebView` owning it via `navigationDelegate` — the delegate is
/// `weak` there, so `WeeklyReportPDFRenderer.makePDF` keeps it alive
/// through its own strong local reference.
@MainActor
private final class LoadAwaiter: NSObject, @preconcurrency WKNavigationDelegate {

    private var continuation: CheckedContinuation<Void, Error>?

    func waitForLoad() async throws {
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            self.continuation = c
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        continuation?.resume(returning: ())
        continuation = nil
    }

    func webView(
        _ webView: WKWebView,
        didFail navigation: WKNavigation!,
        withError error: Error
    ) {
        continuation?.resume(throwing: error)
        continuation = nil
    }

    func webView(
        _ webView: WKWebView,
        didFailProvisionalNavigation navigation: WKNavigation!,
        withError error: Error
    ) {
        continuation?.resume(throwing: error)
        continuation = nil
    }
}
#endif
