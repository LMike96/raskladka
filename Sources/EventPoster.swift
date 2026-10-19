import Cocoa
import Carbon

/// Печатает исправления. Все события помечаются маркером, чтобы перехватчик
/// не принял их за ввод пользователя.
final class EventPoster {
    static let marker: Int64 = 0x524B_4C44  // "RKLD"

    private let source = CGEventSource(stateID: .privateState)
    private let pauseMicroseconds: useconds_t = 1200

    private func post(_ event: CGEvent?) {
        guard let event = event else { return }
        event.setIntegerValueField(.eventSourceUserData, value: EventPoster.marker)
        event.post(tap: .cghidEventTap)
    }

    func key(_ keyCode: UInt16, flags: CGEventFlags = []) {
        let down = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true)
        down?.flags = flags
        post(down)
        let up = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false)
        up?.flags = flags
        post(up)
        usleep(pauseMicroseconds)
    }

    func key(_ stroke: KeyStroke) {
        key(stroke.keyCode, flags: stroke.shift ? .maskShift : [])
    }

    func backspace(_ count: Int) {
        guard count > 0 else { return }
        for _ in 0..<count { key(51) }
    }

    /// Печатает текст. Код клавиши берётся из целевой раскладки (для приложений,
    /// которые читают код клавиши), а сам символ передаётся как Unicode.
    func type(_ text: String, layout: KeyboardLayout?) {
        for ch in text {
            let units = Array(String(ch).utf16)
            let stroke = layout?.keyStroke(for: ch)
            let code = stroke?.keyCode ?? 0
            let flags: CGEventFlags = (stroke?.shift ?? false) ? .maskShift : []
            for isDown in [true, false] {
                let ev = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: isDown)
                ev?.flags = flags
                ev?.keyboardSetUnicodeString(stringLength: units.count, unicodeString: units)
                post(ev)
            }
            usleep(pauseMicroseconds)
        }
    }

    func copy() { key(8, flags: .maskCommand) }   // ⌘C
    func paste() { key(9, flags: .maskCommand) }  // ⌘V
}

/// Сохраняет и восстанавливает содержимое буфера обмена.
struct ClipboardSnapshot {
    private let items: [[NSPasteboard.PasteboardType: Data]]

    init(_ pb: NSPasteboard = .general) {
        items = (pb.pasteboardItems ?? []).map { item in
            var dict: [NSPasteboard.PasteboardType: Data] = [:]
            for type in item.types {
                if let data = item.data(forType: type) { dict[type] = data }
            }
            return dict
        }
    }

    func restore(_ pb: NSPasteboard = .general) {
        pb.clearContents()
        let restored: [NSPasteboardItem] = items.map { dict in
            let item = NSPasteboardItem()
            for (type, data) in dict { item.setData(data, forType: type) }
            return item
        }
        if !restored.isEmpty { pb.writeObjects(restored) }
    }
}
