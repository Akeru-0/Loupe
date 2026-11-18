import AppKit

/// The library's keyboard shortcuts, independent of which view receives the key event.
public enum KeyCommand: Equatable {
    case rate(Int), toggleFavorite, edit, trash, toggleViewer, closeViewer, previous, next, zoomIn, zoomOut

    /// `characters` as in `NSEvent.charactersIgnoringModifiers`. Shift is ignored (⌘+ is typed as ⇧⌘=);
    /// function and numeric-pad flags, which arrow keys carry, are ignored too.
    public static func from(characters: String, modifiers: NSEvent.ModifierFlags) -> KeyCommand? {
        let mods = modifiers.intersection([.command, .option, .control])
        if mods == .command {
            switch characters {
            case "\u{7F}": return .trash
            case "=", "+": return .zoomIn
            case "-": return .zoomOut
            default: return nil
            }
        }
        guard mods.isEmpty else { return nil }
        switch characters {
        case "0", "1", "2", "3", "4", "5": return .rate(Int(characters)!)
        case "f": return .toggleFavorite
        case "e": return .edit
        case " ": return .toggleViewer
        case "\u{1B}": return .closeViewer
        case String(Character(UnicodeScalar(UInt16(NSLeftArrowFunctionKey))!)): return .previous
        case String(Character(UnicodeScalar(UInt16(NSRightArrowFunctionKey))!)): return .next
        default: return nil
        }
    }
}
