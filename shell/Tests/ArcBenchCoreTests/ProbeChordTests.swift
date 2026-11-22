import Testing
@testable import ArcBenchCore

/// The chords the performance check's probe accepts, and the ones it never posts.
struct ProbeChordTests {
    @Test func parsesTheChordsThePerformanceCheckUses() {
        #expect(ProbeChord.parse("cmd+t") == .commandT)
        #expect(ProbeChord.parse("cmd+w") == .commandW)
        #expect(ProbeChord.parse("esc") == .escape)
        #expect(ProbeChord.parse("cmd+1") == .digit(1, .command))
        #expect(ProbeChord.parse("cmd+2") == .digit(2, .command))
        #expect(ProbeChord.parse("opt+cmd+n") == .optionCommandN)
        #expect(ProbeChord.parse("Command+N") == KeyChord("N", 45, .command))
        #expect(ProbeChord.parse("ctrl+tab") == .controlTab)
        #expect(ProbeChord.parse("opt+cmd+down") == KeyChord("↓", 125, [.option, .command]))
        #expect(ProbeChord.parse("opt+cmd+left") == .optionCommandLeft)
        #expect(ProbeChord.parse("opt+cmd+left")?.isArrow == true)
        #expect(ProbeChord.parse("shift+cmd+]") == KeyChord("]", 30, [.shift, .command]))
    }

    @Test func rejectsWhatItDoesNotKnow() {
        #expect(ProbeChord.parse("") == nil)
        #expect(ProbeChord.parse("cmd") == nil)
        #expect(ProbeChord.parse("cmd+q+w") == nil)
        #expect(ProbeChord.parse("hyper+t") == nil)
        #expect(ProbeChord.parse("cmd+0") == nil)
        #expect(ProbeChord.parse("cmd+q") == nil)
    }

    @Test func controlWithADigitIsNeverPosted() {
        for digit in 1 ... 9 {
            #expect(ProbeChord.refusal(.digit(digit, .control)) != nil)
            #expect(ProbeChord.refusal(.digit(digit, [.control, .shift])) != nil)
            #expect(ProbeChord.refusal(.digit(digit, .command)) == nil)
        }
        #expect(ProbeChord.refusal(.controlTab) == nil)
        #expect(ProbeChord.refusal(.commandT) == nil)
    }

    @Test func aReservedShortcutIsRefusedByName() {
        let reserved = [ReservedShortcut(keyCode: 45, modifiers: [.option, .command], name: "Arc's Little Arc")]
        #expect(ProbeChord.refusal(.optionCommandN, reserved: reserved)?.contains("Arc's Little Arc") == true)
        #expect(ProbeChord.refusal(.commandT, reserved: reserved) == nil)
    }
}
