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

    /// 打开系统默认邮件客户端，并预填收件人与主题。
    static let supportMailto = URL(string: "mailto:\(supportEmail)?subject=ScreenVoiceRec%20Support")!
}
