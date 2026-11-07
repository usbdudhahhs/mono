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
        "识别截图里的金额与商户，自动分好类记一笔账，截图压缩后一并存进账单。图片只在本机处理。",
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

    @Parameter(title: "记为待报销", description: "垫付的钱，等公司打款", default: false)
    var reimburse: Bool

    static var parameterSummary: some ParameterSummary {
        Summary("识别 \(\.$image) 并记账") {
            \.$autoSave
            \.$reimburse
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

        // 积分 / 优惠券全额抵扣的单子，实付就是 0。
        // 这种情况说「没读出金额」会让用户对着屏幕上明明白白的 ¥0.00 发懵
        if result.zeroPaid && !result.isValid {
            return .result(dialog: "这笔实付 ¥0.00（积分或优惠券抵扣），没有记账")
        }
        guard result.isValid else {
            throw ScreenshotIntentError.unreadable
        }

        let categoryName = result.category.name
        let amountText = Fmt.money(result.amount)
        let needsReview = result.amountTier.needsReview

        guard autoSave else {
            let hint = needsReview ? "，金额没十足把握，记之前先看一眼" : ""
            return .result(dialog: "识别到 \(categoryName) ¥\(amountText)\(hint)，未记账")
        }

        let note = result.merchant.isEmpty ? categoryName : result.merchant
        // 截图压到长边 1200 存档：放大能看清商户和金额，一张约 100KB
        let receipt = ReceiptStore.compress(uiImage)
        let reimbursement: ReimbursementState = (result.type == .expense && reimburse) ? .pending : .none

        let outcome: (inserted: Bool, upgraded: Bool) = try await MainActor.run {
            let context = AppData.container.mainContext

            // 「轻点背面」很容易连着触发两次。同一笔账记两遍，对账时要多查半天，
            // 所以 90 秒内出现金额、类型、备注都一样的，就当重复触发放过
            var descriptor = FetchDescriptor<Bill>(sortBy: [SortDescriptor(\Bill.createdAt, order: .reverse)])
            descriptor.fetchLimit = 20
            let recent = (try? context.fetch(descriptor)) ?? []
            let duplicate = recent.first { bill in
                bill.type == result.type
                    && abs(bill.amount - result.amount) < 0.005
                    && bill.note == note
                    && abs(Date().timeIntervalSince(bill.createdAt)) < 90
            }
            if let duplicate {
                // 第二次特意说了「待报销」，说明第一笔漏标了，补上而不是再记一笔
                if reimbursement == .pending && duplicate.reimbursement != .pending {
                    duplicate.reimbursement = .pending
                    _ = AppData.save(context)
                    return (false, true)
                }
                return (false, false)
            }

            let bill = Bill(type: result.type,
                            amount: result.amount,
                            categoryID: result.categoryID,
                            note: note,
                            date: result.date,
                            reimbursement: reimbursement,
                            receiptData: receipt,
                            needsReview: needsReview,
                            alternatives: result.alternatives)
            try AppData.insert(bill)
            return (true, false)
        }

        if outcome.upgraded {
            return .result(dialog: "刚记过一笔 ¥\(amountText) · \(categoryName)，已补标待报销")
        }
        if !outcome.inserted {
            return .result(dialog: "刚记过一笔 ¥\(amountText) · \(categoryName)，这次没有重复记")
        }

        var parts = ["已记一笔 · \(categoryName) ¥\(amountText)"]
        if note != categoryName { parts.append(note) }
        if reimbursement == .pending { parts.append("待报销") }
        if needsReview { parts.append("金额请回 MONO 核对") }
        parts.append("截图已存档")
        return .result(dialog: "\(parts.joined(separator: " · "))")
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
