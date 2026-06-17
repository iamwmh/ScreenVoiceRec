//
//  ScreenVoiceRecApp.swift
//  ScreenVoiceRec
//

import AppKit
import SwiftUI

@main
struct ScreenVoiceRecApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .defaultSize(width: 560, height: 720)
        .commands {
            CommandGroup(replacing: .help) {
                Button(L10n.tr("help.menu.guide")) {
                    NSWorkspace.shared.open(AppURLs.userGuide)
                }
                Button(L10n.tr("help.menu.support")) {
                    NSWorkspace.shared.open(AppURLs.support)
                }
            }
        }
    }
}
