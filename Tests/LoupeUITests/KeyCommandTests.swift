import AppKit
import Testing
@testable import LoupeUI

@Suite struct KeyCommandTests {
    private func key(_ characters: String, _ modifiers: NSEvent.ModifierFlags = []) -> KeyCommand? {
        KeyCommand.from(characters: characters, modifiers: modifiers)
    }

    private func functionKey(_ code: Int) -> String { String(Character(UnicodeScalar(UInt32(code))!)) }

    @Test func mapsKeys() {
        for n in 0...5 { #expect(key("\(n)") == .rate(n)) }
        #expect(key("6") == nil)
        #expect(key("f") == .toggleFavorite)
        #expect(key("e") == .edit)
        #expect(key("\u{7F}", .command) == .trash)
        #expect(key(" ") == .toggleViewer)
        #expect(key("\u{1B}") == .closeViewer)
        // Arrow keys arrive with the function and numeric-pad flags set.
        #expect(key(functionKey(NSLeftArrowFunctionKey), [.function, .numericPad]) == .previous)
        #expect(key(functionKey(NSRightArrowFunctionKey), [.function, .numericPad]) == .next)
        #expect(key("=", .command) == .zoomIn)
        #expect(key("+", [.command, .shift]) == .zoomIn)
        #expect(key("-", .command) == .zoomOut)
        #expect(key("m") == nil)  // Phase 4 (show edits)
    }

    @Test func modifiersMustMatch() {
        #expect(key("\u{7F}") == nil)  // plain delete never trashes
        #expect(key("=") == nil)
        #expect(key("-") == nil)
        #expect(key("3", .command) == nil)
        #expect(key("f", .command) == nil)
        #expect(key("e", .option) == nil)
        #expect(key(functionKey(NSLeftArrowFunctionKey), [.command, .function, .numericPad]) == nil)
        #expect(key("\u{7F}", [.command, .option]) == nil)
    }
}
