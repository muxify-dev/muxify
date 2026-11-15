import AppKit
import Carbon.HIToolbox
import MuxifyCore

extension KeyTrigger {
    /// The trigger a key press stands for, or nil for a key Muxify cannot
    /// name.
    init?(_ event: NSEvent, layout: KeyboardLayout? = .current) {
        let modifiers = Modifiers(event.modifierFlags)
        if let special = SpecialKey.allCases.first(where: { $0.keyCodes.contains(event.keyCode) }) {
            self.init(modifiers: modifiers, key: .special(special))
        } else if let character = layout?.commandCharacter(keyCode: event.keyCode) {
            self.init(modifiers: modifiers, key: .character(character))
        } else {
            return nil
        }
    }

    /// Shows the trigger as the item's shortcut.
    func show(in item: NSMenuItem) {
        switch key {
        case .character(let character): item.keyEquivalent = String(character)
        case .special(let special): item.keyEquivalent = special.keyEquivalent
        }
        var flags: NSEvent.ModifierFlags = []
        if modifiers.contains(.control) { flags.insert(.control) }
        if modifiers.contains(.option) { flags.insert(.option) }
        if modifiers.contains(.shift) { flags.insert(.shift) }
        if modifiers.contains(.command) { flags.insert(.command) }
        item.keyEquivalentModifierMask = flags
    }

    /// As macOS writes shortcuts in menus, e.g. `⌃⌘S`.
    var symbol: String {
        let glyphs: [(Modifiers, String)] = [(.control, "⌃"), (.option, "⌥"), (.shift, "⇧"), (.command, "⌘")]
        let prefix = glyphs.filter { modifiers.contains($0.0) }.map(\.1).joined()
        switch key {
        case .character(" "): return prefix + "Space"
        case .character(let character): return prefix + character.uppercased()
        case .special(let special): return prefix + special.glyph
        }
    }
}

/// The characters a keyboard layout types, read from its key table.
struct KeyboardLayout {
    private let table: Data

    /// The layout the user types with now. An input method such as Japanese
    /// resolves to the key layout under it.
    static var current: KeyboardLayout? {
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue() else { return nil }
        return KeyboardLayout(source)
    }

    /// The installed layout with this id, such as `com.apple.keylayout.Russian`.
    init?(inputSourceID: String) {
        let filter = [kTISPropertyInputSourceID as String: inputSourceID] as CFDictionary
        guard let sources = TISCreateInputSourceList(filter, true)?.takeRetainedValue() as? [TISInputSource],
              let source = sources.first else { return nil }
        self.init(source)
    }

    private init?(_ source: TISInputSource) {
        guard let raw = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else { return nil }
        table = Unmanaged<CFData>.fromOpaque(raw).takeUnretainedValue() as Data
    }

    /// The character the key types with only ⌘ held, lowercased. Shift is
    /// left off so `cmd+shift+1` stays "1" and not "!"; Control is left off
    /// because with it the key types no character.
    func commandCharacter(keyCode: UInt16) -> Character? {
        var deadKeys: UInt32 = 0
        var length = 0
        var units = [UniChar](repeating: 0, count: 4)
        let status = table.withUnsafeBytes { bytes -> OSStatus in
            guard let layout = bytes.bindMemory(to: UCKeyboardLayout.self).baseAddress else { return OSStatus(paramErr) }
            return UCKeyTranslate(layout, keyCode, UInt16(kUCKeyActionDown), UInt32(cmdKey >> 8) & 0xFF,
                                  UInt32(LMGetKbdType()), OptionBits(kUCKeyTranslateNoDeadKeysBit),
                                  &deadKeys, units.count, &length, &units)
        }
        guard status == noErr else { return nil }
        return String(utf16CodeUnits: units, count: length).lowercased().first
    }
}

private extension KeyTrigger.SpecialKey {
    var keyCodes: [UInt16] {
        switch self {
        case .enter: [0x24, 0x4C]
        case .tab: [0x30]
        case .escape: [0x35]
        case .backspace: [0x33]
        case .delete: [0x75]
        case .left: [0x7B]
        case .right: [0x7C]
        case .down: [0x7D]
        case .up: [0x7E]
        }
    }

    /// The character a menu item's key equivalent names the key by.
    var keyEquivalent: String {
        switch self {
        case .enter: "\r"
        case .tab: "\t"
        case .escape: "\u{1B}"
        case .backspace: "\u{8}"
        case .delete: "\u{F728}"
        case .left: "\u{F702}"
        case .right: "\u{F703}"
        case .down: "\u{F701}"
        case .up: "\u{F700}"
        }
    }

    var glyph: String {
        switch self {
        case .enter: "↩"
        case .tab: "⇥"
        case .escape: "⎋"
        case .backspace: "⌫"
        case .delete: "⌦"
        case .left: "←"
        case .right: "→"
        case .down: "↓"
        case .up: "↑"
        }
    }
}

extension KeyTrigger.Modifiers {
    init(_ flags: NSEvent.ModifierFlags) {
        self = []
        if flags.contains(.control) { insert(.control) }
        if flags.contains(.option) { insert(.option) }
        if flags.contains(.shift) { insert(.shift) }
        if flags.contains(.command) { insert(.command) }
    }
}
