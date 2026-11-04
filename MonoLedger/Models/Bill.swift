//
//  Bill.swift
//  MonoLedger
//
//  账单与消费生命周期
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

/// 消费生命周期：这是 MONO 的招牌
enum TrackStatus: String, Codable, CaseIterable, Identifiable {
    case active     // 使用中
    case done       // 已完成（普通消费，不追踪）
    case resold     // 已转售
    case refunded   // 已退款

    var id: String { rawValue }

    var title: String {
        switch self {
        case .active:   return "使用中"
        case .done:     return "已完成"
        case .resold:   return "已转售"
        case .refunded: return "已退款"
        }
    }

    var hint: String {
        switch self {
        case .active:   return "还在用。天数会继续累计，日均成本随使用时间被摊薄。"
        case .done:     return "普通消费记录，不再计算均摊成本。"
        case .resold:   return "转手卖出后，实际成本 = 买入价 − 转售价。"
        case .refunded: return "全额退回，这笔支出不计入实际成本。"
        }
    }

    /// 徽标配色
    var tint: Color {
        switch self {
        case .active:   return Color(hex: "#30D158")
        case .done:     return Color(hex: "#8E8E93")
        case .resold:   return Color(hex: "#0A84FF")
        case .refunded: return Color(hex: "#FF9F0A")
        }
    }

    /// 列表中的短标签（使用中带天数）
    func shortLabel(days: Int) -> String {
        switch self {
        case .active:   return "使用中 \(days)天"
        case .done:     return "已完成"
        case .resold:   return "已转售"
        case .refunded: return "已退款"
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
    var account: String

    // 消费追踪
    var isTracked: Bool
    var statusRaw: String
    var resalePrice: Double?

    // 报销
    var reimbursementRaw: String = ReimbursementState.none.rawValue

    /// 截图凭证。图片存成文件，不塞进数据库主表
    @Attribute(.externalStorage) var receiptData: Data?

    var createdAt: Date

    init(type: RecordType,
         amount: Double,
         categoryID: String,
         note: String,
         date: Date,
         account: String,
         isTracked: Bool = false,
         status: TrackStatus = .done,
         resalePrice: Double? = nil,
         reimbursement: ReimbursementState = .none,
         receiptData: Data? = nil) {
        self.typeRaw = type.rawValue
        self.amount = amount
        self.categoryID = categoryID
        self.note = note
        self.date = Calendar.current.startOfDay(for: date)
        self.account = account
        self.isTracked = isTracked
        self.statusRaw = status.rawValue
        self.resalePrice = resalePrice
        self.reimbursementRaw = reimbursement.rawValue
        self.receiptData = receiptData
        self.createdAt = Date()
    }
}

// MARK: - 派生属性

extension Bill {
    var type: RecordType {
        get { RecordType(rawValue: typeRaw) ?? .expense }
        set { typeRaw = newValue.rawValue }
    }

    var status: TrackStatus {
        get { TrackStatus(rawValue: statusRaw) ?? .done }
        set { statusRaw = newValue.rawValue }
    }

    var reimbursement: ReimbursementState {
        get { ReimbursementState(rawValue: reimbursementRaw) ?? .none }
        set { reimbursementRaw = newValue.rawValue }
    }

    /// 是否计入个人支出：已报销的那笔钱不是自己出的
    var countsAsExpense: Bool {
        !(type == .expense && reimbursement == .done)
    }

    /// 计入统计的金额
    var accountingAmount: Double {
        countsAsExpense ? amount : 0
    }

    /// 是否有截图凭证
    var hasReceipt: Bool {
        receiptData?.isEmpty == false
    }

    var category: Category {
        Catalog.find(type, categoryID)
    }

    var title: String {
        note.isEmpty ? category.name : note
    }

    /// 已使用天数（含购买当天）
    var daysUsed: Int {
        let d = Dates.days(from: date, to: Date())
        return max(1, d + 1)
    }

    /// 实际成本：已报销为 0，退款为 0，转售为差价
    var netCost: Double {
        if type == .expense && reimbursement == .done { return 0 }
        switch status {
        case .refunded: return 0
        case .resold:   return max(0, amount - (resalePrice ?? 0))
        default:        return amount
        }
    }

    /// 日均成本
    var dailyCost: Double {
        guard daysUsed > 0 else { return netCost }
        return netCost / Double(daysUsed)
    }

    /// 只有「使用中」才展示日均
    var showsDailyCost: Bool {
        isTracked && type == .expense && status == .active
    }

    var signedAmountText: String {
        type.sign + Fmt.money(amount)
    }
}
