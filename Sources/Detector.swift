import Foundation

enum Lang: String {
    case ru, en
    var other: Lang { self == .ru ? .en : .ru }
}

/// Одно физическое нажатие клавиши (не символ!) — так одно и то же нажатие
/// можно перевести в любую раскладку.
struct KeyStroke: Equatable {
    let keyCode: UInt16
    let shift: Bool
    let caps: Bool
}

// MARK: - Языковая модель (частотный словарь + триграммы)

final class LanguageModel {
    let lang: Lang
    private var dict: [String: Double] = [:]
    private var tri: [String: Double] = [:]
    private var bi: [String: Double] = [:]
    private let alphabetSize: Double
    private let smoothing = 0.1

    init(lang: Lang) {
        self.lang = lang
        alphabetSize = lang == .ru ? 34 : 28
        load()
    }

    private func load() {
        if let url = Bundle.main.url(forResource: "\(lang.rawValue)_dict", withExtension: "txt"),
           let text = try? String(contentsOf: url, encoding: .utf8) {
            dict.reserveCapacity(100_000)
            for line in text.split(separator: "\n") {
                let parts = line.split(separator: "\t")
                if parts.count == 2, let z = Double(parts[1]) {
                    dict[String(parts[0])] = z
                }
            }
        }
        if let url = Bundle.main.url(forResource: "\(lang.rawValue)_ngrams", withExtension: "txt"),
           let text = try? String(contentsOf: url, encoding: .utf8) {
            for line in text.split(separator: "\n") {
                let parts = line.split(separator: "\t")
                guard parts.count == 3, let v = Double(parts[2]) else { continue }
                if parts[0] == "3" { tri[String(parts[1])] = v } else { bi[String(parts[1])] = v }
            }
        }
    }

    var isLoaded: Bool { !dict.isEmpty }

    private func normalize(_ w: String) -> String {
        lang == .ru ? w.replacingOccurrences(of: "ё", with: "е") : w
    }

    /// Частотность слова по шкале Zipf или nil, если слова нет в словаре.
    func zipf(_ w: String) -> Double? {
        if let z = dict[w] { return z }
        if lang == .ru, w.contains("ё") { return dict[normalize(w)] }
        return nil
    }

    /// Средняя лог-вероятность триграмм слова: чем ближе к нулю, тем «естественнее» слово для языка.
    func score(_ w: String) -> Double {
        let chars = Array("^" + normalize(w) + "$")
        guard chars.count >= 3 else { return -12 }
        var total = 0.0
        var n = 0
        for i in 0..<(chars.count - 2) {
            let t = String(chars[i...(i + 2)])
            let b = String(chars[i...(i + 1)])
            let p = ((tri[t] ?? 0) + smoothing) / ((bi[b] ?? 0) + smoothing * alphabetSize)
            total += log(p)
            n += 1
        }
        return total / Double(n)
    }
}

// MARK: - Выученные слова пользователя

final class LearnedWords {
    private var sets: [Lang: Set<String>] = [.ru: [], .en: []]
    let directory: URL

    init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        directory = base.appendingPathComponent("Raskladka", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for lang in [Lang.ru, Lang.en] {
            if let text = try? String(contentsOf: file(lang), encoding: .utf8) {
                sets[lang] = Set(text.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces).lowercased() }.filter { !$0.isEmpty })
            }
        }
    }

    private func file(_ lang: Lang) -> URL {
        directory.appendingPathComponent("learned_\(lang.rawValue).txt")
    }

    var count: Int { (sets[.ru]?.count ?? 0) + (sets[.en]?.count ?? 0) }

    func contains(_ word: String, _ lang: Lang) -> Bool { sets[lang]?.contains(word) ?? false }

    func add(_ word: String, _ lang: Lang) {
        guard !word.isEmpty, !contains(word, lang) else { return }
        sets[lang, default: []].insert(word)
        save(lang)
    }

    func remove(_ word: String, _ lang: Lang) {
        guard contains(word, lang) else { return }
        sets[lang]?.remove(word)
        save(lang)
    }

    func reset() {
        sets = [.ru: [], .en: []]
        save(.ru)
        save(.en)
    }

    private func save(_ lang: Lang) {
        let text = (sets[lang] ?? []).sorted().joined(separator: "\n")
        try? text.write(to: file(lang), atomically: true, encoding: .utf8)
    }
}

// MARK: - Детектор неправильной раскладки

final class Detector {
    let models: [Lang: LanguageModel]
    let learned = LearnedWords()

    // Пороги подобраны на симуляции по частотным корпусам RU/EN.
    private let scoreGap = 1.0      // насколько «другой» язык должен быть правдоподобнее
    private let scoreFloor = -4.5   // минимальная правдоподобность результата
    private let uncleanFloor = -3.6 // строже, если набранное похоже на ссылку/код (точки внутри и т.п.)
    private let zipfGap = 1.0       // для слов, которые есть в обоих словарях

    static let ruLetters = Set("абвгдеёжзийклмнопрстуфхцчшщъыьэюя")

    init() {
        models = [.ru: LanguageModel(lang: .ru), .en: LanguageModel(lang: .en)]
    }

    static func isWord(_ w: String, _ lang: Lang) -> Bool {
        guard !w.isEmpty else { return false }
        switch lang {
        case .ru:
            return w.allSatisfy { ruLetters.contains($0) }
        case .en:
            let parts = w.split(separator: "'", omittingEmptySubsequences: false)
            guard parts.count <= 2 else { return false }
            return parts.allSatisfy { part in !part.isEmpty && part.allSatisfy { $0.isASCII && $0.isLetter } }
        }
    }

    /// Слово известно языку (словарь или обучение).
    func isKnown(_ w: String, _ lang: Lang) -> Bool {
        guard Detector.isWord(w, lang) else { return false }
        return learned.contains(w, lang) || models[lang]?.zipf(w) != nil
    }

    /// cur — слово так, как оно напечаталось; alt — те же клавиши в другой раскладке.
    /// Оба в нижнем регистре, без пунктуации по краям.
    func shouldConvert(cur: String, curLang: Lang, alt: String, context: Lang?) -> Bool {
        let altLang = curLang.other
        guard cur.count >= 2, let curModel = models[curLang], let altModel = models[altLang] else { return false }
        let curIsWord = Detector.isWord(cur, curLang)
        let altIsWord = Detector.isWord(alt, altLang)

        // 1. Обучение пользователя важнее всего
        if curIsWord && learned.contains(cur, curLang) { return false }
        if altIsWord && learned.contains(alt, altLang) { return true }

        // 2. Словари
        let zc = curIsWord ? curModel.zipf(cur) : nil
        let za = altIsWord ? altModel.zipf(alt) : nil
        if let zc = zc {
            guard let za = za else { return false }
            if context == curLang { return false }   // уже пишем на этом языке — не трогаем
            return za - zc >= zipfGap
        }
        if za != nil { return true }

        // 3. Триграммная модель для слов вне словаря
        let cs = curIsWord ? curModel.score(cur) : -12
        let altScore = altIsWord ? altModel.score(alt) : -12
        let floor = curIsWord ? scoreFloor : uncleanFloor
        return altScore - cs > scoreGap && altScore > floor
    }
}
