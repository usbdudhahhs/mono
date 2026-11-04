//
//  ScreenshotIntent.swift
//  MonoLedger
//
//  给「快捷指令」用的动作：截屏 → 识别 → 自动分类 → 记一笔
//
//  在快捷指令里搜「MONO」或「截图记账」就能找到。
//  接收图像参数，端上跑 Vision，不联网。
//

import AppIntents
import Foundation
import SwiftUI
import SwiftData
import UIKit
import UniformTypeIdentifiers

// MARK: - 错误

enum ScreenshotIntentError: LocalizedError {
    case missingImage
    case unreadable

    var errorDescription: String? {
        switch self {
        case .missingImage: return "没有拿到截图"
        case .unreadable:   return "这张图里没读出金额，试着截得完整一点"
        }
    }
}

// MARK: - 截图记账

struct ScreenshotBookkeepingIntent: AppIntent {
    static var title: LocalizedStringResource = "截图记账"
    static var description: IntentDescription = IntentDescription(
        "识别截图里的金额与商户，自动分好类记一笔账，原图一并存进账单。图片只在本机处理。",
        categoryName: "记账",
        searchKeywords: ["记账", "截图", "识别", "账单", "OCR"]
    )

    /// 后台完成，不打断用户
    static var openAppWhenRun: Bool = false

    /// 留空时不报错，自动去相册拿刚截的那张图 —— 这样「轻点背面」不用再配「截屏」动作
    @Parameter(title: "截图", description: "留空则自动取相册里最近的一张截图")
    var image: IntentFile?

    @Parameter(title: "立即入账", description: "关闭时只识别不记账", default: true)
    var autoSave: Bool

    static var parameterSummary: some ParameterSummary {
        Summary("识别 \(\.$image) 并记账") {
            \.$autoSave
        }
    }

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let uiImage: UIImage

        if let file = image {
            // 快捷指令有时给的是文件 URL，不一定是内存里的 Data
            var data = file.data
            if data == nil, let url = file.fileURL {
                data = try? Data(contentsOf: url)
            }
            guard let data, let decoded = UIImage(data: data) else {
                throw ScreenshotIntentError.missingImage
            }
            uiImage = decoded
        } else {
            // 没传图：走相册兜底，用户刚按物理键截的屏就在那儿
            uiImage = try await LatestScreenshot.recent()
        }

        let result = try await BillParser.parse(image: uiImage)
        guard result.isValid else {
            throw ScreenshotIntentError.unreadable
        }

        let categoryName = result.category.name
        let amountText = Fmt.money(result.amount)

        guard autoSave else {
            return .result(dialog: "识别到 \(categoryName) ¥\(amountText)，未记账")
        }

        let note = result.merchant.isEmpty ? categoryName : result.merchant
        // 快捷指令传进来的截图原样留档，之后可以在账单详情里回看
        let receipt = ReceiptStore.compress(uiImage)
        try await MainActor.run {
            let bill = Bill(type: result.type,
                            amount: result.amount,
                            categoryID: result.categoryID,
                            note: note,
                            date: result.date,
                            account: result.account,
                            receiptData: receipt)
            try AppData.insert(bill)
        }

        return .result(dialog: "已记一笔 · \(categoryName) ¥\(amountText)\(note == categoryName ? "" : " · \(note)")，截图已存档")
    }
}

// MARK: - Siri / 快捷指令入口

struct MonoAppShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: ScreenshotBookkeepingIntent(),
            phrases: [
                "用\(.applicationName)记一笔截图",
                "让\(.applicationName)识别这张截图"
            ],
            shortTitle: "截图记账",
            systemImageName: "doc.text.viewfinder"
        )
    }
}
