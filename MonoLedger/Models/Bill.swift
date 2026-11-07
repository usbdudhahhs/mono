//
//  Bill.swift
//  MonoLedger
//
//  账单与报销
//

import Foundation
import SwiftData
import SwiftUI

// MARK: - 类型

enum RecordType: String, Codable, CaseIterable, Identifiable {
    case expense
    case income

    var id: String { rawValue }

    var title: String {
        switch self {
        case .expense: return "支出"
        case .income:  return "收入"
        }
    }

    var sign: String {
        switch self {
        case .expense: return "-"
        case .income:  return "+"
        }
    }
}

// MARK: - 报销

/// 报销状态：垫付的钱，最终不该算在自己头上
enum ReimbursementState: String, Codable, CaseIterable, Identifiable {
    case none      // 不报销
    case pending   // 已垫付，等公司打款
    case done      // 已到账，不计入个人支出

    var id: String { rawValue }

    var title: String {
        switch self {
        case .none:    return "不报销"
        case .pending: return "待报销"
        case .done:    return "已报销"
        }
    }

    /// 列表里的短标签，不报销时为空
    var badgeText: String {
        switch self {
        case .none:    return ""
        case .pending: return "待报销"
        case .done:    return "已报销"
        }
    }

    var tint: Color {
        switch self {
        case .none:    return Color(hex: "#8E8E93")
        case .pending: return Color(hex: "#FF9F0A")
        case .done:    return Color(hex: "#30D158")
        }
    }

    var hint: String {
        switch self {
        case .none:    return "自己承担的一笔支出。"
        case .pending: return "钱已经花出去了，还在等报销款。这段时间仍计入支出。"
        case .done:    return "报销已到账，这笔支出不再计入你的实际开销。"
        }
    }
}

// MARK: - 账单

@Model
final class Bill {
    var typeRaw: String
    var amount: Double
    var categoryID: String
    var note: String
    var date: Date

    // 报销
    var reimbursementRaw: String = ReimbursementState.none.rawValue

    /// 截图识别出来的金额还没被本人确认过。
    /// 有这一条，识别错了也不会悄悄留在账本里 —— 首页会一直提示到核对完。
    var needsReview: Bool = false

    /// 识别时的备选金额，逗号分隔，核对时一键替换
    var reviewAlternativesRaw: String = ""

    /// 截图凭证。图片存成文件，不塞进数据库主表
    @Attribute(.externalStorage) var receiptData: Data?

    var createdAt: Date

    /// 备份/恢复用的稳定标识，跨设备去重靠它
    var uuid: String = UUID().uuidString

    /// 删除时间。非空表示在回收站里，30 天后彻底清掉。
    /// 加可选字段是 SwiftData 的轻量迁移，老数据自动补 nil。
    var deletedAt: Date? = nil

    init(type: RecordType,
         amount: Double,
         categoryID: String,
         note: String,
         date: Date,
         reimbursement: ReimbursementState = .none,
         receiptData: Data? = nil,
         needsReview: Bool = false,
         alternatives: [Double] = []) {
        self.typeRaw = type.rawValue
        self.amount = amount
        self.categoryID = categoryID
        self.note = note
        self.date = Calendar.current.startOfDay(for: date)
        self.reimbursementRaw = reimbursement.rawValue
        self.receiptData = receiptData
        self.createdAt = Date()
        self.uuid = UUID().uuidString
        self.needsReview = needsReview
        self.reviewAlternativesRaw = alternatives
            .map { String(format: "%.2f", $0) }
            .joined(separator: ",")
    }
}

// MARK: - 派生属性

extension Bill {
    /// 正常账单的查询条件：回收站里的不参与任何列表与统计
    static var activeFilter: Predicate<Bill> {
        #Predicate<Bill> { $0.deletedAt == nil }
    }

    var isInTrash: Bool { deletedAt != nil }

    /// 回收站里还剩几天被彻底清掉
    var trashDaysLeft: Int {
        guard let deletedAt else { return 0 }
        let deadline = Calendar.current.date(byAdding: .day, value: Trash.retentionDays, to: deletedAt) ?? deletedAt
        let days = Calendar.current.dateComponents([.day], from: Date(), to: deadline).day ?? 0
        return max(0, days)
    }

    var type: RecordType {
        get { RecordType(rawValue: typeRaw) ?? .expense }
        set { typeRaw = newValue.rawValue }
    }

    var reimbursement: ReimbursementState {
        get { ReimbursementState(rawValue: reimbursementRaw) ?? .none }
        set { reimbursementRaw = newValue.rawValue }
    }

    /// 是否计入个人实际支出：已到账报销不再由个人承担。
    var countsAsExpense: Bool { type == .expense && netCost > 0 }

    /// 是否占用「待报销」额度。
    /// 账单页、报销页、「我的」页统一用它，避免三处各写一遍过滤条件后口径走偏。
    var isPendingReimbursement: Bool {
        type == .expense && reimbursement == .pending
    }

    /// 首页、趋势图和分类统计统一使用净成本；收入保留原始金额。
    var accountingAmount: Double {
        type == .expense ? netCost : (amount.isFinite ? max(0, amount) : 0)
    }

    /// 是否有截图凭证
    var hasReceipt: Bool {
        receiptData?.isEmpty == false
    }

    /// 识别时排第二、第三的金额
    var reviewAlternatives: [Double] {
        reviewAlternativesRaw
            .split(separator: ",")
            .compactMap { Double($0) }
            .filter { abs($0 - amount) >= 0.01 }
    }

    /// 确认金额无误后清掉待核对标记
    func markReviewed() {
        needsReview = false
        reviewAlternativesRaw = ""
    }

    var category: Category {
        Catalog.find(type, categoryID)
    }

    var title: String {
        note.isEmpty ? category.name : note
    }

    /// 实际成本：已报销为 0，其余按金额
    var netCost: Double {
        let safeAmount = amount.isFinite ? max(0, amount) : 0
        guard type == .expense else { return safeAmount }
        if reimbursement == .done { return 0 }
        return safeAmount
    }

    var signedAmountText: String {
        type.sign + Fmt.money(amount)
    }
}
