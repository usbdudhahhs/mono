//
//  SeedData.swift
//  MonoLedger
//
//  首次启动写入示例数据，让界面一打开就有内容
//

import Foundation
import SwiftData

enum SeedData {
    private static let flagKey = "mono.seeded.v1"

    static func runIfNeeded(_ context: ModelContext) {
        guard !UserDefaults.standard.bool(forKey: flagKey) else { return }

        let existing = (try? context.fetchCount(FetchDescriptor<Bill>())) ?? 0
        if existing == 0 {
            insertBills(context)
            try? context.save()
        }
        UserDefaults.standard.set(true, forKey: flagKey)
    }

    // MARK: - 账单

    private static func insertBills(_ context: ModelContext) {
        let cal = Calendar.current
        let now = Date()

        // 每个月的固定支出与收入
        for back in 0..<3 {
            let anchor = Dates.addMonths(now, -back)
            guard let monthStart = cal.date(from: cal.dateComponents([.year, .month], from: anchor)) else { continue }

            // 房租
            add(context, .expense, 2800, "home", "房租", monthStart, "储蓄卡")

            // 工资
            let payDay = cal.date(byAdding: .day, value: 9, to: monthStart) ?? monthStart
            if payDay <= now {
                add(context, .income, 18500, "salary", "工资", payDay, "储蓄卡")
            }

            // 日常消费：每 1~3 天一笔
            var day = 1
            let limit = back == 0 ? cal.component(.day, from: now) : Dates.daysInMonth(monthStart)
            while day <= limit {
                if let d = cal.date(byAdding: .day, value: day - 1, to: monthStart), d <= now {
                    let roll = Int.random(in: 0..<10)
                    if roll < 8 {
                        let item = everydayItem()
                        add(context, .expense, item.amount, item.cat, item.note, d, item.account)
                    }
                }
                day += Int.random(in: 1...3)
            }
        }

        // 消费追踪中的物品
        let tracked: [(Int, Double, String, String, String, TrackStatus, Double?)] = [
            (128, 8499, "shop",   "MacBook Air",  "储蓄卡", .active,   nil),
            (64,  1899, "fun",    "AirPods Pro",  "储蓄卡", .active,   nil),
            (23,   899, "shop",   "跑鞋",          "支付宝", .active,   nil),
            (9,   4680, "home",   "半自动咖啡机",  "储蓄卡", .active,   nil),
            (41,   329, "shop",   "机械键盘",      "微信",   .refunded, nil),
            (180, 2399, "fun",    "Switch",       "储蓄卡", .resold,   1800)
        ]
        for t in tracked {
            guard let d = cal.date(byAdding: .day, value: -t.0, to: Dates.today) else { continue }
            let bill = Bill(type: .expense, amount: t.1, categoryID: t.2, note: t.3,
                            date: d, account: t.4, isTracked: true, status: t.5, resalePrice: t.6)
            context.insert(bill)
        }

        // 报销示例：让「待报销 / 已报销」一眼能看懂
        let reimbursements: [(Int, Double, String, String, ReimbursementState)] = [
            (3,  486,  "transit", "差旅打车",  .pending),
            (8,  1280, "fun",     "客户招待",  .pending),
            (15, 320,  "study",   "行业会议",  .done)
        ]
        for r in reimbursements {
            guard let d = cal.date(byAdding: .day, value: -r.0, to: Dates.today) else { continue }
            let bill = Bill(type: .expense, amount: r.1, categoryID: r.2, note: r.3,
                            date: d, account: "储蓄卡", reimbursement: r.4)
            context.insert(bill)
        }
    }

    private static func add(_ context: ModelContext,
                            _ type: RecordType,
                            _ amount: Double,
                            _ cat: String,
                            _ note: String,
                            _ date: Date,
                            _ account: String) {
        context.insert(Bill(type: type,
                            amount: (amount * 100).rounded() / 100,
                            categoryID: cat,
                            note: note,
                            date: date,
                            account: account))
    }

    private static func everydayItem() -> (amount: Double, cat: String, note: String, account: String) {
        let pool: [(Double, Double, String, String, String)] = [
            (18, 38,  "food",    "咖啡",     "微信"),
            (22, 52,  "food",    "外卖",     "支付宝"),
            (6,  16,  "food",    "早餐",     "微信"),
            (12, 26,  "food",    "奶茶",     "微信"),
            (15, 45,  "food",    "水果",     "支付宝"),
            (18, 34,  "food",    "午饭",     "微信"),
            (68, 180, "food",    "聚餐",     "微信"),
            (4,  12,  "transit", "地铁",     "支付宝"),
            (12, 32,  "transit", "打车",     "支付宝"),
            (30, 120, "shop",    "日用品",   "支付宝"),
            (39, 199, "fun",     "电影",     "微信"),
            (20, 88,  "phone",   "话费",     "支付宝"),
            (60, 220, "home",    "水电费",   "支付宝"),
            (40, 130, "study",   "买书",     "微信")
        ]
        let p = pool.randomElement() ?? (20, 40, "food", "午饭", "微信")
        let amount = Double.random(in: p.0...p.1)
        return (amount, p.2, p.3, p.4)
    }
}
