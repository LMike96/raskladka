import Cocoa
import Carbon
import ApplicationServices

/// Слово, которое уже завершено пробелом/табом — его можно переконвертировать Shift'ом.
private struct WordRecord {
    let keys: [KeyStroke]
    let shown: String      // что сейчас на экране
    let lang: Lang         // в какой раскладке оно сейчас
    let boundary: KeyStroke
}

/// Последнее автоматическое исправление — его отменяет короткий Shift.
private struct AutoAction {
    let keys: [KeyStroke]
    let original: String
    let shown: String
    let from: Lang
    let to: Lang
    let switched: Bool
    let boundary: KeyStroke
}

private struct Correction {
    let typed: String
    let output: String
    let target: Lang
    let switched: Bool
}

private struct Conversion {
    let text: String
    let target: Lang
}

final class TypingEngine {
    static let shared = TypingEngine()

    var detector: Detector?
    var onStateChange: (() -> Void)?

    private let layouts = LayoutManager.shared
    private let settings = Settings.shared
    private let poster = EventPoster()
    private var tap: CFMachPort?

    private var token: [KeyStroke] = []
    private var lastWord: WordRecord?
    private var lastAction: AutoAction?
    private var contextLang: Lang?

    private(set) var isAppExcluded = false
    private var frontAppID: String?

    // Отслеживание «короткого Shift»
    private var shiftDown = false
    private var shiftAlone = false
    private var shiftDownAt: TimeInterval = 0
    private var lastToggleTapAt: TimeInterval = 0
    private let shiftTapMax: TimeInterval = 0.35
    private let doubleTapWindow: TimeInterval = 0.45

    private static let boundaryKeys: Set<UInt16> = [49, 48, 36, 76]   // пробел, Tab, Return, Enter
    private static let enterKeys: Set<UInt16> = [36, 76]
    private static let resetKeys: Set<UInt16> = [123, 124, 125, 126, 115, 116, 117, 119, 121, 53, 71]  // стрелки, Home/End, PgUp/PgDn, fwd-del, Esc

    var isRunning: Bool { tap != nil }

    // MARK: - Запуск перехвата

    func start() -> Bool {
        if tap != nil { return true }
        func bit(_ t: CGEventType) -> CGEventMask { CGEventMask(1) << CGEventMask(t.rawValue) }
        let mask = bit(.keyDown) | bit(.flagsChanged) | bit(.leftMouseDown) | bit(.rightMouseDown) | bit(.otherMouseDown)

        let callback: CGEventTapCallBack = { _, type, event, refcon in
            guard let refcon = refcon else { return Unmanaged.passUnretained(event) }
            let engine = Unmanaged<TypingEngine>.fromOpaque(refcon).takeUnretainedValue()
            return engine.handle(type: type, event: event)
        }

        guard let newTap = CGEvent.tapCreate(tap: .cgSessionEventTap,
                                             place: .headInsertEventTap,
                                             options: .defaultTap,
                                             eventsOfInterest: mask,
                                             callback: callback,
                                             userInfo: Unmanaged.passUnretained(self).toOpaque()) else {
            return false
        }
        tap = newTap
        let runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, newTap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: newTap, enable: true)
        onStateChange?()
        return true
    }

    func setFrontApp(_ bundleID: String?) {
        frontAppID = bundleID
        isAppExcluded = settings.isExcluded(bundleID)
        resetAll()
    }

    func refreshExclusion() {
        isAppExcluded = settings.isExcluded(frontAppID)
    }

    func resetAll() {
        token.removeAll()
        lastWord = nil
        lastAction = nil
        contextLang = nil
    }

    // MARK: - Обработка событий

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        let pass = Unmanaged.passUnretained(event)

        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap = tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return pass
        }
        if event.getIntegerValueField(.eventSourceUserData) == EventPoster.marker { return pass }
        guard settings.enabled, !isAppExcluded, detector != nil else { return pass }

        switch type {
        case .keyDown:
            return handleKeyDown(event)
        case .flagsChanged:
            handleFlags(event)
        case .leftMouseDown, .rightMouseDown, .otherMouseDown:
            shiftAlone = false
            resetAll()
        default:
            break
        }
        return pass
    }

    private func handleFlags(_ event: CGEvent) {
        let keyCode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
        let flags = event.flags
        let others: CGEventFlags = [.maskCommand, .maskControl, .maskAlternate]

        guard keyCode == 56 || keyCode == 60 else {   // левый / правый Shift
            if keyCode != 57 { shiftAlone = false }    // 57 — Caps Lock, не мешает
            return
        }
        if flags.contains(.maskShift) && !shiftDown {
            shiftDown = true
            shiftAlone = flags.intersection(others).isEmpty
            shiftDownAt = ProcessInfo.processInfo.systemUptime
        } else if !flags.contains(.maskShift) && shiftDown {
            shiftDown = false
            let held = ProcessInfo.processInfo.systemUptime - shiftDownAt
            if shiftAlone && held < shiftTapMax && settings.shiftTap {
                DispatchQueue.main.async { [weak self] in self?.onShiftTap() }
            }
            shiftAlone = false
        }
    }

    private func handleKeyDown(_ event: CGEvent) -> Unmanaged<CGEvent>? {
        let pass = Unmanaged.passUnretained(event)
        shiftAlone = false

        let keyCode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
        let flags = event.flags

        if !flags.intersection([.maskCommand, .maskControl, .maskAlternate]).isEmpty {
            resetAll()
            return pass
        }
        guard let cur = layouts.currentLang, let curLayout = layouts.layout(for: cur),
              layouts.layout(for: cur.other) != nil else {
            resetAll()
            return pass
        }

        if keyCode == 51 {   // Backspace
            if !token.isEmpty {
                token.removeLast()
            } else if let w = lastWord, !TypingEngine.enterKeys.contains(w.boundary.keyCode), w.lang == cur {
                token = w.keys   // стёрли пробел — снова «внутри» слова
            }
            lastWord = nil
            lastAction = nil
            return pass
        }
        if TypingEngine.boundaryKeys.contains(keyCode) {
            return handleBoundary(event, keyCode: keyCode, flags: flags, cur: cur)
        }
        if TypingEngine.resetKeys.contains(keyCode) {
            resetAll()
            return pass
        }

        let stroke = KeyStroke(keyCode: keyCode, shift: flags.contains(.maskShift), caps: flags.contains(.maskAlphaShift))
        guard let ch = curLayout.translate(stroke), !ch.isEmpty else {
            resetAll()
            return pass
        }
        token.append(stroke)
        if token.count > 48 { token.removeAll() }
        lastWord = nil
        lastAction = nil
        return pass
    }

    private func handleBoundary(_ event: CGEvent, keyCode: UInt16, flags: CGEventFlags, cur: Lang) -> Unmanaged<CGEvent>? {
        let boundary = KeyStroke(keyCode: keyCode, shift: flags.contains(.maskShift), caps: false)
        let isEnter = TypingEngine.enterKeys.contains(keyCode)

        guard !token.isEmpty else {
            lastWord = nil
            lastAction = nil
            return Unmanaged.passUnretained(event)
        }
        let keys = token
        token.removeAll()

        guard let fix = process(keys: keys, cur: cur) else {
            lastWord = isEnter ? nil : WordRecord(keys: keys, shown: text(keys, cur), lang: cur, boundary: boundary)
            lastAction = nil
            return Unmanaged.passUnretained(event)
        }

        // Применяем исправление и «съедаем» исходный пробел/Enter — он будет напечатан заново после слова
        poster.backspace(fix.typed.count)
        if fix.switched {
            layouts.select(fix.target)
            playSwitchSound()
        }
        poster.type(fix.output, layout: layouts.layout(for: fix.target))
        poster.key(boundary)

        if isEnter {
            lastAction = nil
            lastWord = nil
        } else {
            lastAction = AutoAction(keys: keys, original: fix.typed, shown: fix.output, from: cur,
                                    to: fix.target, switched: fix.switched, boundary: boundary)
            lastWord = WordRecord(keys: keys, shown: fix.output, lang: fix.target, boundary: boundary)
        }
        return nil
    }

    // MARK: - Решение по слову

    private func text(_ keys: [KeyStroke], _ lang: Lang) -> String {
        guard let layout = layouts.layout(for: lang) else { return "" }
        return keys.map { layout.translate($0) ?? "" }.joined()
    }

    private func process(keys: [KeyStroke], cur: Lang) -> Correction? {
        guard let detector = detector,
              let curLayout = layouts.layout(for: cur),
              let altLayout = layouts.layout(for: cur.other) else { return nil }

        let curChars = keys.map { curLayout.translate($0) ?? "" }
        let altChars = keys.map { altLayout.translate($0) ?? "" }
        let typed = curChars.joined()

        if settings.dash && typed == "--" {
            return Correction(typed: typed, output: "—", target: cur, switched: false)
        }

        var finalText = typed
        var target = cur
        var switched = false

        if settings.autoSwitch, let span = TypingEngine.extractSpan(curChars, altChars) {
            let alt = cur.other
            let curWord = curChars[span.letters].joined().lowercased()
            let altFull = TypingEngine.stripEdges(altChars[span.word].joined()).lowercased()
            let altTrim = TypingEngine.stripEdges(altChars[span.letters].joined()).lowercased()

            var useFull = false
            var useTrim = false
            if span.word != span.letters && !altTrim.isEmpty {
                // Например «Ghbdtn,»: запятая — это и «б», и обычная запятая. Выбираем вариант со словом из словаря.
                if detector.isKnown(altFull, alt) && detector.shouldConvert(cur: curWord, curLang: cur, alt: altFull, context: contextLang) {
                    useFull = true
                } else if detector.shouldConvert(cur: curWord, curLang: cur, alt: altTrim, context: contextLang) {
                    useTrim = true
                } else if detector.shouldConvert(cur: curWord, curLang: cur, alt: altFull, context: contextLang) {
                    useFull = true
                }
            } else {
                useFull = detector.shouldConvert(cur: curWord, curLang: cur, alt: altFull, context: contextLang)
            }

            if useFull {
                finalText = altChars.joined()
            } else if useTrim {
                finalText = curChars[..<span.letters.lowerBound].joined()
                    + altChars[span.letters].joined()
                    + curChars[(span.letters.upperBound + 1)...].joined()
            }
            if useFull || useTrim {
                target = alt
                switched = true
                contextLang = alt
            } else if detector.isKnown(curWord, cur) {
                contextLang = cur
            }
        }

        if settings.fixTwoCaps && !keys.contains(where: { $0.caps }) {
            finalText = TypingEngine.fixTwoCaps(finalText)
        }
        if finalText == typed && !switched { return nil }
        return Correction(typed: typed, output: finalText, target: target, switched: switched)
    }

    /// Границы слова в нажатиях.
    /// word — клавиши, которые хоть в одной раскладке дают букву (например «,» = «б»);
    /// letters — от первой до последней буквы в текущей раскладке.
    private struct Span {
        let word: ClosedRange<Int>
        let letters: ClosedRange<Int>
    }

    private static func extractSpan(_ cur: [String], _ alt: [String]) -> Span? {
        func isLetter(_ s: String) -> Bool { s.count == 1 && (s.first?.isLetter ?? false) }
        if cur.contains(where: { $0.first?.isNumber ?? false }) { return nil }
        if alt.contains(where: { $0.isEmpty }) { return nil }
        let wordChar = cur.indices.map { isLetter(cur[$0]) || isLetter(alt[$0]) || cur[$0] == "'" }
        guard let i = wordChar.firstIndex(of: true), let j = wordChar.lastIndex(of: true) else { return nil }
        if wordChar[i...j].contains(false) { return nil }   // пробелы/цифры внутри — не трогаем
        guard let ci = (i...j).first(where: { isLetter(cur[$0]) }),
              let cj = (i...j).last(where: { isLetter(cur[$0]) }),
              cj - ci + 1 >= 2 else { return nil }
        return Span(word: i...j, letters: ci...cj)
    }

    static func stripEdges(_ s: String) -> String {
        var chars = Array(s)
        while let f = chars.first, !f.isLetter { chars.removeFirst() }
        while let l = chars.last, !l.isLetter { chars.removeLast() }
        return String(chars)
    }

    /// «ПРивет» → «Привет»
    static func fixTwoCaps(_ s: String) -> String {
        var chars = Array(s)
        guard let start = chars.firstIndex(where: { $0.isLetter }) else { return s }
        var end = start
        while end < chars.count && chars[end].isLetter { end += 1 }
        let word = Array(chars[start..<end])
        guard word.count >= 3, word[0].isUppercase, word[1].isUppercase,
              word[2...].allSatisfy({ $0.isLowercase }) else { return s }
        if let lower = word[1].lowercased().first { chars[start + 1] = lower }
        return String(chars)
    }

    private func coreWord(_ s: String, _ lang: Lang) -> String? {
        let w = TypingEngine.stripEdges(s).lowercased()
        return Detector.isWord(w, lang) ? w : nil
    }

    // MARK: - Короткий Shift

    private func onShiftTap() {
        guard settings.enabled, !isAppExcluded, let cur = layouts.currentLang, layouts.hasBothLayouts else { return }
        let now = ProcessInfo.processInfo.systemUptime

        if let action = lastAction { revert(action); return }
        if !token.isEmpty { convertToken(cur); return }
        if let word = lastWord { convertLastWord(word); return }

        if settings.doubleShift && now - lastToggleTapAt < doubleTapWindow {
            lastToggleTapAt = 0
            layouts.select(cur.other)            // отменяем переключение от первого нажатия
            convertSelectionViaClipboard()
            return
        }
        if let selected = axSelectedText(), !selected.isEmpty {
            convertSelection(selected)
            return
        }
        layouts.select(cur.other)
        playSwitchSound()
        lastToggleTapAt = now
    }

    /// Отмена автоисправления + запоминание слова, чтобы больше его не трогать.
    private func revert(_ a: AutoAction) {
        poster.backspace(a.shown.count + 1)
        if a.switched { layouts.select(a.from) }
        poster.type(a.original, layout: layouts.layout(for: a.from))
        poster.key(a.boundary)
        if a.switched && settings.learning, let detector = detector {
            if let w = coreWord(a.original, a.from) { detector.learned.add(w, a.from) }
            if let w = coreWord(a.shown, a.to) { detector.learned.remove(w, a.to) }
        }
        lastAction = nil
        lastWord = WordRecord(keys: a.keys, shown: a.original, lang: a.from, boundary: a.boundary)
        contextLang = a.from
    }

    private func convertToken(_ cur: Lang) {
        let shown = text(token, cur)
        let converted = text(token, cur.other)
        poster.backspace(shown.count)
        layouts.select(cur.other)
        poster.type(converted, layout: layouts.layout(for: cur.other))
        contextLang = cur.other
        playSwitchSound()
    }

    private func convertLastWord(_ w: WordRecord) {
        let target = w.lang.other
        let converted = text(w.keys, target)
        poster.backspace(w.shown.count + 1)
        layouts.select(target)
        poster.type(converted, layout: layouts.layout(for: target))
        poster.key(w.boundary)
        if settings.learning, let detector = detector {
            if let c = coreWord(converted, target) { detector.learned.add(c, target) }
            if let s = coreWord(w.shown, w.lang) { detector.learned.remove(s, w.lang) }
        }
        lastWord = WordRecord(keys: w.keys, shown: converted, lang: target, boundary: w.boundary)
        lastAction = nil
        contextLang = target
        playSwitchSound()
    }

    // MARK: - Выделенный текст

    private func convertText(_ s: String) -> Conversion? {
        var ru = 0, en = 0
        for ch in s.lowercased() {
            if Detector.ruLetters.contains(ch) { ru += 1 } else if ch.isASCII && ch.isLetter { en += 1 }
        }
        guard ru + en > 0 else { return nil }
        let from: Lang = ru >= en ? .ru : .en
        guard let fromLayout = layouts.layout(for: from), let toLayout = layouts.layout(for: from.other) else { return nil }
        var out = ""
        for ch in s {
            if let stroke = fromLayout.keyStroke(for: ch), let t = toLayout.translate(stroke) {
                out += t
            } else {
                out.append(ch)
            }
        }
        return Conversion(text: out, target: from.other)
    }

    private func focusedElement() -> AXUIElement? {
        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, 0.25)
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
              let element = focused else { return nil }
        let ax = element as! AXUIElement
        AXUIElementSetMessagingTimeout(ax, 0.25)
        return ax
    }

    private func axSelectedText() -> String? {
        guard let element = focusedElement() else { return nil }
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXSelectedTextAttribute as CFString, &value) == .success else { return nil }
        return value as? String
    }

    private func convertSelection(_ selected: String) {
        guard let conv = convertText(selected) else { return }
        var replaced = false
        if let element = focusedElement() {
            replaced = AXUIElementSetAttributeValue(element, kAXSelectedTextAttribute as CFString, conv.text as CFString) == .success
        }
        if !replaced {
            if conv.text.count <= 120 {
                poster.type(conv.text, layout: layouts.layout(for: conv.target))
            } else {
                pasteText(conv.text)
            }
        }
        layouts.select(conv.target)
        playSwitchSound()
        resetAll()
    }

    /// Универсальный способ для любых приложений: ⌘C → конвертация → ⌘V, буфер восстанавливается.
    private func convertSelectionViaClipboard() {
        let pb = NSPasteboard.general
        let snapshot = ClipboardSnapshot(pb)
        let before = pb.changeCount
        poster.copy()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) { [weak self] in
            guard let self = self else { return }
            guard pb.changeCount != before,
                  let s = pb.string(forType: .string), !s.isEmpty,
                  let conv = self.convertText(s) else {
                snapshot.restore(pb)
                return
            }
            pb.clearContents()
            pb.setString(conv.text, forType: .string)
            self.poster.paste()
            self.layouts.select(conv.target)
            self.playSwitchSound()
            self.resetAll()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { snapshot.restore(pb) }
        }
    }

    private func pasteText(_ s: String) {
        let pb = NSPasteboard.general
        let snapshot = ClipboardSnapshot(pb)
        pb.clearContents()
        pb.setString(s, forType: .string)
        poster.paste()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { snapshot.restore(pb) }
    }

    // MARK: - Звук

    private func playSwitchSound() {
        guard settings.sound else { return }
        NSSound(named: NSSound.Name("Tink"))?.play()
    }
}
