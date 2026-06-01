//
//  L10n.swift
//  ScreenVoiceRec
//

import Foundation

/// 字符串目录键与 `String(localized:)` 的薄封装；系统会根据用户首选语言（含 en-CA、fr-CA）自动选文案。
enum L10n {
    static func tr(_ key: String) -> String {
        String(localized: String.LocalizationValue(key))
    }

    static func tr(_ key: String, _ args: CVarArg...) -> String {
        String(format: String(localized: String.LocalizationValue(key)), locale: Locale.current, arguments: args)
    }
}
