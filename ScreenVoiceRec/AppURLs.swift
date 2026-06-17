//
//  AppURLs.swift
//  ScreenVoiceRec
//

import Foundation

enum AppURLs {
    /// App Store Connect「支持 URL」须与此地址一致。
    static let support = URL(string: "https://iamwmh.github.io/ScreenVoiceRec/docs/help/support.html")!
    static let userGuide = URL(string: "https://iamwmh.github.io/ScreenVoiceRec/docs/help/")!

    static let supportEmail = "iamwmh@gmail.com"

    static var supportMailto: URL {
        var components = URLComponents()
        components.scheme = "mailto"
        components.path = supportEmail
        components.queryItems = [
            URLQueryItem(name: "subject", value: "ScreenVoiceRec Support")
        ]
        return components.url!
    }
}
