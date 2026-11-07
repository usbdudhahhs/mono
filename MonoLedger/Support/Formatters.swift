//
//  Formatters.swift
//  MonoLedger
//
//  数字 / 日期格式化
//

import Foundation

enum Fmt {
    /// 千分位分组。
    ///
    /// 这里不用 `NumberFormatter`：它是引用类型且不是线程安全的，
    /// 放成 static let 之后，快捷指令在后台线程解析账单时和主线程同时读，
    /// 轻则格式化出错字，重则直接崩。金额显示错一位，对账就全废了 ——
    /// 手写这点逻辑反而更稳、也更快。
    private static func grouped(_ digits: String) -> String {
        var out = ""
        var count = 0
        for ch in digits.reversed() {
            if count == 3 { out.append(","); count = 0 }
            out.append(ch)
            count += 1
        }
        return String(out.reversed())
    }

    private static func fixed(_ value: Double, decimals: Int) -> String {
        guard value.isFinite else { return decimals == 0 ? "0" : "0." + String(repeating: "0", count: decimals) }
        let unit = pow(10.0, Double(decimals))
        let scaled = (abs(value) * unit).rounded()
        // 四舍五入到 0 就别留负号：-0.00 看着像账目算错了
        let sign = (value < 0 && scaled > 0) ? "-" : ""
        // 超过 9 万亿就不用细算了，避免整数溢出
        guard scaled < 9_000_000_000_000 else {
            return sign + grouped(String(Int(scaled / unit)))
        }
        let total = Int(scaled)
        let divisor = Int(unit)
        let whole = total / divisor
        guard decimals > 0 else { return sign + grouped(String(whole)) }
        let fraction = total % divisor
        let text = String(format: "%0\(decimals)d", fraction)
        return sign + grouped(String(whole)) + "." + text
    }

    /// 12,345.60
    static func money(_ value: Double) -> String { fixed(value, decimals: 2) }

    /// 12,346
    static func money0(_ value: Double) -> String { fixed(value, decimals: 0) }

    /// 12.3
    static func money1(_ value: Double) -> String { fixed(value, decimals: 1) }

    /// 输入框中的实时数字：保留原始文本感觉
    static func fromInput(_ text: String) -> Double {
        Double(text) ?? 0
    }
}

enum Dates {
    static let cal = Calendar.current

    static var today: Date { cal.startOfDay(for: Date()) }

    static func isSameMonth(_ a: Date, _ b: Date) -> Bool {
        cal.isDate(a, equalTo: b, toGranularity: .month)
    }

    /// 2026 年 11 月
    static func monthTitle(_ date: Date) -> String {
        let c = cal.dateComponents([.year, .month], from: date)
        return "\(c.year ?? 2026) 年 \(c.month ?? 1) 月"
    }

    /// 11月4日 周二
    static func dayTitle(_ date: Date) -> String {
        let c = cal.dateComponents([.month, .day, .weekday], from: date)
        let names = ["周日", "周一", "周二", "周三", "周四", "周五", "周六"]
        let idx = max(0, min(6, (c.weekday ?? 1) - 1))
        return "\(c.month ?? 1)月\(c.day ?? 1)日 \(names[idx])"
    }

    /// 11月4日
    static func shortDate(_ date: Date) -> String {
        let c = cal.dateComponents([.month, .day], from: date)
        return "\(c.month ?? 1)月\(c.day ?? 1)日"
    }

    /// 2026/11/04
    static func fullDate(_ date: Date) -> String {
        let c = cal.dateComponents([.year, .month, .day], from: date)
        let m = String(format: "%02d", c.month ?? 1)
        let d = String(format: "%02d", c.day ?? 1)
        return "\(c.year ?? 2026)/\(m)/\(d)"
    }

    /// 11月（用于月份快选）
    static func monthOnly(_ date: Date) -> String {
        let c = cal.dateComponents([.month], from: date)
        return "\(c.month ?? 1)月"
    }

    static func addMonths(_ date: Date, _ n: Int) -> Date {
        cal.date(byAdding: .month, value: n, to: date) ?? date
    }

    static func addDays(_ date: Date, _ n: Int) -> Date {
        cal.date(byAdding: .day, value: n, to: date) ?? date
    }

    /// 距今天数：正数表示未来
    static func days(from: Date, to: Date) -> Int {
        let a = cal.startOfDay(for: from)
        let b = cal.startOfDay(for: to)
        return cal.dateComponents([.day], from: a, to: b).day ?? 0
    }

    static func startOfMonth(_ date: Date) -> Date {
        let c = cal.dateComponents([.year, .month], from: date)
        return cal.date(from: c) ?? date
    }

    /// 该月天数
    static func daysInMonth(_ date: Date) -> Int {
        cal.range(of: .day, in: .month, for: date)?.count ?? 30
    }

    /// 按月筛选
    static func inMonth(_ date: Date, _ month: Date) -> Bool {
        isSameMonth(date, month)
    }

    /// 是否是未来的月份
    static func isFutureMonth(_ month: Date) -> Bool {
        startOfMonth(month) > startOfMonth(Date())
    }
}
