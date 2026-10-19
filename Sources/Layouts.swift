import Carbon
import Foundation

/// Обёртка над системной раскладкой: переводит физическую клавишу в символ
/// по-настоящему (через UCKeyTranslate), поэтому работает и с «Русская», и с «Русская – ПК»,
/// и с ABC / U.S. / British.
final class KeyboardLayout {
    let source: TISInputSource
    let id: String
    let name: String
    let lang: Lang
    private let layoutData: Data
    private var reverse: [Character: KeyStroke] = [:]

    init?(source: TISInputSource, lang: Lang) {
        guard let ptr = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else { return nil }
        let cfData = Unmanaged<CFData>.fromOpaque(ptr).takeUnretainedValue()
        layoutData = cfData as Data
        self.source = source
        self.lang = lang
        let identifier = KeyboardLayout.stringProperty(source, kTISPropertyInputSourceID) ?? "?"
        self.id = identifier
        self.name = KeyboardLayout.stringProperty(source, kTISPropertyLocalizedName) ?? identifier
        buildReverseMap()
    }

    static func stringProperty(_ source: TISInputSource, _ key: CFString) -> String? {
        guard let ptr = TISGetInputSourceProperty(source, key) else { return nil }
        return Unmanaged<CFString>.fromOpaque(ptr).takeUnretainedValue() as String
    }

    func translate(_ keyCode: UInt16, shift: Bool, caps: Bool) -> String? {
        var modifiers: UInt32 = 0
        if shift { modifiers |= 2 }   // shiftKey >> 8
        if caps { modifiers |= 4 }    // alphaLock >> 8
        var deadKeyState: UInt32 = 0
        var length: UniCharCount = 0
        var chars = [UniChar](repeating: 0, count: 8)
        let maxLength = UniCharCount(chars.count)
        let kbdType = UInt32(LMGetKbdType())
        let status: OSStatus = layoutData.withUnsafeBytes { raw -> OSStatus in
            guard let base = raw.baseAddress else { return -1 }
            let layout = base.assumingMemoryBound(to: UCKeyboardLayout.self)
            return UCKeyTranslate(layout, keyCode, UInt16(kUCKeyActionDown), modifiers, kbdType,
                                  OptionBits(1) /* kUCKeyTranslateNoDeadKeysMask */,
                                  &deadKeyState, maxLength, &length, &chars)
        }
        guard status == noErr, length > 0 else { return nil }
        let s = String(utf16CodeUnits: chars, count: Int(length))
        // Управляющие символы (Enter, Tab, стрелки, F-клавиши) нам не нужны
        if let scalar = s.unicodeScalars.first, scalar.value < 0x20 || scalar.value == 0x7F { return nil }
        return s
    }

    func translate(_ k: KeyStroke) -> String? {
        translate(k.keyCode, shift: k.shift, caps: k.caps)
    }

    /// Какую клавишу нажать, чтобы получить этот символ в данной раскладке.
    func keyStroke(for ch: Character) -> KeyStroke? {
        reverse[ch]
    }

    private func buildReverseMap() {
        // Сначала основная клавиатура (0…50), цифровой блок — потом, чтобы не перебивал.
        for shift in [false, true] {
            for code in UInt16(0)...UInt16(127) {
                guard let s = translate(code, shift: shift, caps: false), s.count == 1, let ch = s.first else { continue }
                if reverse[ch] == nil {
                    reverse[ch] = KeyStroke(keyCode: code, shift: shift, caps: false)
                }
            }
        }
    }
}

final class LayoutManager: NSObject {
    static let shared = LayoutManager()

    private(set) var preferred: [Lang: KeyboardLayout] = [:]
    private var byID: [String: KeyboardLayout] = [:]
    private(set) var currentLang: Lang?

    var onChange: (() -> Void)?
    var onExternalChange: (() -> Void)?

    private override init() {
        super.init()
        let dnc = DistributedNotificationCenter.default()
        dnc.addObserver(self, selector: #selector(selectionChanged),
                        name: NSNotification.Name(kTISNotifySelectedKeyboardInputSourceChanged as String),
                        object: nil, suspensionBehavior: .deliverImmediately)
        dnc.addObserver(self, selector: #selector(sourcesChanged),
                        name: NSNotification.Name(kTISNotifyEnabledKeyboardInputSourcesChanged as String),
                        object: nil, suspensionBehavior: .deliverImmediately)
    }

    var hasBothLayouts: Bool { preferred[.ru] != nil && preferred[.en] != nil }

    func layout(for lang: Lang) -> KeyboardLayout? { preferred[lang] }

    func reload() {
        byID = [:]
        var found: [Lang: KeyboardLayout] = [:]
        let filter: [String: Any] = [
            kTISPropertyInputSourceCategory as String: kTISCategoryKeyboardInputSource as String
        ]
        guard let listRef = TISCreateInputSourceList(filter as CFDictionary, false) else { return }
        let list = listRef.takeRetainedValue() as! [TISInputSource]
        for src in list {
            guard KeyboardLayout.stringProperty(src, kTISPropertyInputSourceType) == (kTISTypeKeyboardLayout as String) else { continue }
            guard let langPtr = TISGetInputSourceProperty(src, kTISPropertyInputSourceLanguages) else { continue }
            let langs = (Unmanaged<CFArray>.fromOpaque(langPtr).takeUnretainedValue() as NSArray) as? [String] ?? []
            guard let first = langs.first else { continue }
            let lang: Lang
            if first == "ru" { lang = .ru } else if first.hasPrefix("en") { lang = .en } else { continue }
            guard let layout = KeyboardLayout(source: src, lang: lang) else { continue }
            byID[layout.id] = layout
            if found[lang] == nil { found[lang] = layout }
        }
        for lang in [Lang.ru, Lang.en] {
            if let keep = preferred[lang], let fresh = byID[keep.id] {
                preferred[lang] = fresh
            } else {
                preferred[lang] = found[lang]
            }
        }
        refreshCurrent()
        onChange?()
    }

    func refreshCurrent() {
        guard let src = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue() else {
            currentLang = nil
            return
        }
        let id = KeyboardLayout.stringProperty(src, kTISPropertyInputSourceID) ?? ""
        if let layout = byID[id] {
            preferred[layout.lang] = layout
            currentLang = layout.lang
        } else {
            currentLang = nil
        }
    }

    func select(_ lang: Lang) {
        guard let layout = preferred[lang] else { return }
        currentLang = lang
        TISSelectInputSource(layout.source)
        onChange?()
    }

    @objc private func selectionChanged() {
        let old = currentLang
        refreshCurrent()
        if old != currentLang { onExternalChange?() }
        onChange?()
    }

    @objc private func sourcesChanged() {
        reload()
    }
}
