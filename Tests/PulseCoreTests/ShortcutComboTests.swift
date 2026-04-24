import Testing
@testable import PulseCore

@Suite("ShortcutCombo — canonical combo string builder (F-33)")
struct ShortcutComboTests {

    @Test("pure cmd+letter forms cmd+<letter>")
    func cmdLetter() {
        // keyCode 8 == 'c'.
        #expect(ShortcutCombo.canonical(keyCode: 8, modifiers: [.cmd]) == "cmd+c")
    }

    @Test("ctrl+opt+shift+cmd order is deterministic")
    func deterministicModifierOrder() {
        // keyCode 1 == 's'.
        let combo = ShortcutCombo.canonical(
            keyCode: 1,
            modifiers: [.cmd, .shift, .ctrl, .opt]
        )
        #expect(combo == "ctrl+opt+shift+cmd+s")
    }

    @Test("shift-only is not a shortcut trigger")
    func shiftAloneSkipped() {
        // keyCode 0 == 'a'. Shift+A is capital A, not a shortcut.
        #expect(ShortcutCombo.canonical(keyCode: 0, modifiers: [.shift]) == nil)
    }

    @Test("no modifiers → nil")
    func noModifiersSkipped() {
        #expect(ShortcutCombo.canonical(keyCode: 0, modifiers: []) == nil)
    }

    @Test("unknown keyCode returns nil")
    func unknownKeyCodeSkipped() {
        // 9999 is not in the table.
        #expect(ShortcutCombo.canonical(keyCode: 9999, modifiers: [.cmd]) == nil)
    }

    @Test("named keys render to stable strings")
    func namedKeys() {
        #expect(ShortcutCombo.canonical(keyCode: 36, modifiers: [.cmd]) == "cmd+return")
        #expect(ShortcutCombo.canonical(keyCode: 53, modifiers: [.cmd, .opt]) == "opt+cmd+escape")
        #expect(ShortcutCombo.canonical(keyCode: 51, modifiers: [.cmd]) == "cmd+delete")
    }

    @Test("digits are recognised")
    func digits() {
        // keyCode 20 == '3'. cmd+shift+3 = screenshot.
        #expect(ShortcutCombo.canonical(keyCode: 20, modifiers: [.cmd, .shift]) == "shift+cmd+3")
    }
}
