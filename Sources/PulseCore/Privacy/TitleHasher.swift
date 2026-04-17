import Foundation
import CryptoKit

/// Hashes window title text into a stable identifier without preserving the
/// original content. Uses SHA-256, full hex (lowercase), 64 chars.
///
/// Why this exists: window titles routinely contain personal information
/// (email subjects, file names, contact names). The default privacy mode
/// stores `(bundleId, hash)` so the user can see "this window appeared 14
/// times today" without Pulse retaining the readable string. See
/// `docs/05-privacy.md#4.2`.
public struct TitleHasher: Sendable {

    public init() {}

    /// Hashes the title using its UTF-8 bytes. Whitespace is *not* normalized
    /// — two visually similar titles with different whitespace produce
    /// different hashes (correct: if they differ to the user, they differ to
    /// us).
    public func hash(_ title: String) -> String {
        let bytes = Array(title.utf8)
        let digest = SHA256.hash(data: bytes)
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    /// A non-content placeholder for windows belonging to applications
    /// flagged as "force-redact" (Messages, WhatsApp, 1Password, etc.).
    /// We don't even hash these — the bundleId is enough to know the app
    /// was active without revealing window topology.
    public static let forceRedactedSentinel: String = "redacted"
}
