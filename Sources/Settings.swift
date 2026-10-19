import Foundation

final class Settings {
    static let shared = Settings()
    private let defaults = UserDefaults.standard

    enum Key {
        static let enabled = "enabled"
        static let autoSwitch = "autoSwitch"
        static let shiftTap = "shiftTap"
        static let doubleShift = "doubleShiftSelection"
        static let sound = "sound"
        static let fixTwoCaps = "fixTwoCaps"
        static let dash = "dashReplace"
        static let learning = "learning"
        static let excluded = "excludedApps"
    }

    /// Среды разработки, терминалы и т.п. — там автоисправление только мешает.
    static let defaultExcluded: [String] = [
        "com.apple.Terminal",
        "com.googlecode.iterm2",
        "dev.warp.Warp-Stable",
        "net.kovidgoyal.kitty",
        "io.alacritty",
        "com.github.wez.wezterm",
        "com.mitchellh.ghostty",
        "com.apple.dt.Xcode",
        "com.microsoft.VSCode",
        "com.microsoft.VSCodeInsiders",
        "com.todesktop.230313mzl4w4u92",
        "dev.zed.Zed",
        "com.sublimetext.4",
        "com.panic.Nova",
        "com.google.android.studio",
        "com.jetbrains.*",
        "com.apple.keychainaccess",
        "com.1password.1password",
        "com.valvesoftware.steam"
    ]

    private init() {
        defaults.register(defaults: [
            Key.enabled: true,
            Key.autoSwitch: true,
            Key.shiftTap: true,
            Key.doubleShift: true,
            Key.sound: true,
            Key.fixTwoCaps: true,
            Key.dash: true,
            Key.learning: true,
            Key.excluded: Settings.defaultExcluded
        ])
    }

    func bool(_ key: String) -> Bool { defaults.bool(forKey: key) }
    func toggle(_ key: String) { defaults.set(!defaults.bool(forKey: key), forKey: key) }

    var enabled: Bool { bool(Key.enabled) }
    var autoSwitch: Bool { bool(Key.autoSwitch) }
    var shiftTap: Bool { bool(Key.shiftTap) }
    var doubleShift: Bool { bool(Key.doubleShift) }
    var sound: Bool { bool(Key.sound) }
    var fixTwoCaps: Bool { bool(Key.fixTwoCaps) }
    var dash: Bool { bool(Key.dash) }
    var learning: Bool { bool(Key.learning) }

    var excludedApps: [String] {
        get { defaults.stringArray(forKey: Key.excluded) ?? [] }
        set { defaults.set(newValue, forKey: Key.excluded) }
    }

    func isExcluded(_ bundleID: String?) -> Bool {
        guard let id = bundleID else { return false }
        for pattern in excludedApps {
            if pattern.hasSuffix("*") {
                if id.hasPrefix(String(pattern.dropLast())) { return true }
            } else if pattern == id {
                return true
            }
        }
        return false
    }

    func setExcluded(_ bundleID: String, _ excluded: Bool) {
        var list = excludedApps
        if excluded {
            if !list.contains(bundleID) { list.append(bundleID) }
        } else {
            list.removeAll { $0 == bundleID }
        }
        excludedApps = list
    }

    func resetExclusions() { excludedApps = Settings.defaultExcluded }
}
