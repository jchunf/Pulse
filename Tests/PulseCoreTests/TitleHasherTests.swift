import Testing
@testable import PulseCore

@Suite("TitleHasher — SHA-256 stability and one-way-ness")
struct TitleHasherTests {

    private let hasher = TitleHasher()

    @Test("identical input → identical hash")
    func deterministic() {
        let a = hasher.hash("Re: invoice 014 — Acme")
        let b = hasher.hash("Re: invoice 014 — Acme")
        #expect(a == b)
    }

    @Test("different input → different hash")
    func collisionsAreUnlikely() {
        #expect(hasher.hash("Project A") != hasher.hash("Project B"))
        #expect(hasher.hash("a") != hasher.hash("A"))
    }

    @Test("empty string still produces a 64-char hex digest")
    func emptyString() {
        let h = hasher.hash("")
        #expect(h.count == 64)
        // Known SHA-256 of empty input.
        #expect(h == "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
    }

    @Test("hash output is lowercase hex")
    func lowercaseHex() {
        let h = hasher.hash("hello")
        #expect(h.allSatisfy { ch in ("0"..."9").contains(ch) || ("a"..."f").contains(ch) })
        #expect(h.count == 64)
    }

    @Test("force-redact sentinel is a stable non-hash string")
    func sentinelStable() {
        #expect(TitleHasher.forceRedactedSentinel == "redacted")
    }

    @Test("multibyte unicode hashes consistently")
    func unicode() {
        let cn = hasher.hash("会议纪要 - 2025 Q4")
        let cn2 = hasher.hash("会议纪要 - 2025 Q4")
        #expect(cn == cn2)
        #expect(cn.count == 64)
    }
}
