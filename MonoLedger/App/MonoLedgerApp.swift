//
//  MonoLedgerApp.swift
//  MonoLedger
//
//  应用入口
//

import SwiftUI
import SwiftData

@main
struct MonoLedgerApp: App {
    @AppStorage("mono.theme") private var themeMode: String = "system"

    private var scheme: ColorScheme? {
        switch themeMode {
        case "light": return .light
        case "dark":  return .dark
        default:      return nil
        }
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .preferredColorScheme(scheme)
                .onAppear {
                    SeedData.runIfNeeded(AppData.container.mainContext)
                    // 提前要一次相册权限，否则快捷指令在后台拿不到截图
                    LatestScreenshot.prepare()
                }
        }
        .modelContainer(AppData.container)
    }
}
