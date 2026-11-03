import AppKit
import HyperCore
import SwiftUI

/// A HyperMusic keyboard action.
///
/// | Action            | Deck A  | Deck B  |
/// |-------------------|---------|---------|
/// | Play/pause        | Q       | P       |
/// | Quantized start   | W       | O       |
/// | Nudge − / +       | A / S   | K / L   |
/// | Bend while held   | Z / X   | , / .   |
/// | Loop              | E       | I       |
/// | PFL               | 1       | 0       |
///
/// ⌘1…⌘8 load branch N, ← / → step the crossfader, + / − rate the last transition.
enum HyperShortcut: Equatable {
    case playPause(HyperDeckID)
    case quantizedStart(HyperDeckID)
    case nudge(HyperDeckID, forward: Bool)
    case bend(HyperDeckID, up: Bool)
    case loop(HyperDeckID)
    case pfl(HyperDeckID)
    /// Zero-based index into the centre's branches.
    case loadBranch(Int)
    case crossfaderStep(towardB: Bool)
    case rate(Int)

    /// Active from key-down to key-up.
    var isHeld: Bool {
        if case .bend = self { return true }
        return false
    }

    /// Whether auto-repeat key-downs fire the action again.
    var repeats: Bool {
        switch self {
        case .nudge, .crossfaderStep: true
        default: false
        }
    }

    private static let leftArrow: UInt16 = 123
    private static let rightArrow: UInt16 = 124

    private static let plain: [String: HyperShortcut] = [
        "q": .playPause(.a), "p": .playPause(.b),
        "w": .quantizedStart(.a), "o": .quantizedStart(.b),
        "a": .nudge(.a, forward: false), "s": .nudge(.a, forward: true),
        "k": .nudge(.b, forward: false), "l": .nudge(.b, forward: true),
        "z": .bend(.a, up: false), "x": .bend(.a, up: true),
        ",": .bend(.b, up: false), ".": .bend(.b, up: true),
        "e": .loop(.a), "i": .loop(.b),
        "1": .pfl(.a), "0": .pfl(.b),
        "+": .rate(1), "=": .rate(1),
        "-": .rate(-1), "−": .rate(-1),
    ]

    /// The action for a key event, from `NSEvent.charactersIgnoringModifiers`, `keyCode` and
    /// `modifierFlags`. Control and Option chords never match; Command only with 1…8.
    static func match(characters: String, keyCode: UInt16, modifiers: NSEvent.ModifierFlags) -> HyperShortcut? {
        let flags = modifiers.intersection([.command, .control, .option])
        if flags == .command {
            guard let n = Int(characters), (1...8).contains(n) else { return nil }
            return .loadBranch(n - 1)
        }
        guard flags.isEmpty else { return nil }
        switch keyCode {
        case leftArrow: return .crossfaderStep(towardB: false)
        case rightArrow: return .crossfaderStep(towardB: true)
        default: return plain[characters.lowercased()]
        }
    }
}

/// Installs the HyperMusic keyboard shortcuts while the view is on screen.
///
/// Uses an `NSEvent` local monitor (not `.onKeyPress`) because it needs key-up for bend and
/// must work whatever control has focus in the tab. Events pass through untouched when a text
/// field is editing (its field editor is first responder) or when a sheet is in front, so typing
/// never triggers actions. Handled events are consumed (no system beep).
struct HyperShortcutsModifier: ViewModifier {
    let perform: (HyperShortcut, _ keyDown: Bool) -> Void

    @State private var monitor: Any?
    /// Held shortcuts by key code, so key-up releases what key-down started even if the
    /// modifiers changed in between.
    @State private var held: [UInt16: HyperShortcut] = [:]

    func body(content: Content) -> some View {
        content
            .onAppear { install() }
            .onDisappear { remove() }
    }

    private func install() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp]) { event in
            handle(event) ? nil : event
        }
    }

    private func remove() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        for shortcut in held.values { perform(shortcut, false) }
        held.removeAll()
    }

    /// Returns true when the event was a HyperMusic shortcut.
    private func handle(_ event: NSEvent) -> Bool {
        if event.type == .keyUp {
            guard let shortcut = held.removeValue(forKey: event.keyCode) else { return false }
            perform(shortcut, false)
            return true
        }
        guard let window = event.window, window.attachedSheet == nil, window.sheetParent == nil,
              !(window.firstResponder is NSText),
              let shortcut = HyperShortcut.match(characters: event.charactersIgnoringModifiers ?? "",
                                                 keyCode: event.keyCode, modifiers: event.modifierFlags)
        else { return false }
        if event.isARepeat {
            if shortcut.repeats { perform(shortcut, true) }
            return true
        }
        if shortcut.isHeld { held[event.keyCode] = shortcut }
        perform(shortcut, true)
        return true
    }
}

extension View {
    func hyperShortcuts(_ perform: @escaping (HyperShortcut, _ keyDown: Bool) -> Void) -> some View {
        modifier(HyperShortcutsModifier(perform: perform))
    }
}
