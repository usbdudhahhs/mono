//
//  BillParser.swift
//  MonoLedger
//
//  截图解析：把 OCR 出来的文字还原成一笔账单
//
//  设计取舍：
//  - 金额靠「字号 + 货币符号 + 上下文关键词」三重打分，不依赖固定模板，
//    所以微信、支付宝、银行短信、美团订单页都能读
//  - 分类靠商户关键词最长匹配，结果可解释，不上传任何数据
//

import UIKit
import Foundation

// MARK: - 解析结果

struct ParseResult {
    var amount: Double = 0
    var type: RecordType = .expense
    var categoryID: String = "more"
    var merchant: String = ""
    var account: String = "其他"
    var date: Date = Date()
    var confidence: Double = 0
    var matchedKeyword: String = ""
    var rawText: String = ""
    var evidence: [String] = []

    var category: Category { Catalog.find(type, categoryID) }
    var isValid: Bool { amount > 0 }
}

// MARK: - 解析器

enum BillParser {

    // MARK: 入口

    static func parse(image: UIImage) async throws -> ParseResult {
        let lines = try await OCRService.recognize(image)
        return parse(lines: lines)
    }

    static func parse(lines: [OCRLine]) -> ParseResult {
        var result = ParseResult()
        guard !lines.isEmpty else { return result }

        let texts = lines.map { normalize($0.text) }
        let joined = texts.joined(separator: "\n")
        result.rawText = joined

        let type = detectType(joined)
        result.type = type

        guard let amount = detectAmount(lines, type: type) else {
            result.evidence = ["没能定位到金额"]
            return result
        }
        result.amount = amount
        result.evidence.append("金额 ¥" + Fmt.money(amount))

        let merchant = detectMerchant(lines)
        result.merchant = merchant
        if !merchant.isEmpty { result.evidence.append("商户 " + merchant) }

        // 分类：先用商户名匹配，命中不了再用全页文字兜底
        if let hit = MerchantRules.match(merchant, type: type) {
            result.categoryID = hit.categoryID
            result.matchedKeyword = hit.keyword
            result.confidence = merchant.isEmpty ? 0.78 : 0.93
            result.evidence.append("命中「\(hit.keyword)」")
        } else if let hit = MerchantRules.match(joined, type: type) {
            result.categoryID = hit.categoryID
            result.matchedKeyword = hit.keyword
            result.confidence = 0.78
            result.evidence.append("命中「\(hit.keyword)」")
        } else {
            result.categoryID = type == .income ? "moreIn" : "more"
            result.confidence = 0.5
            result.evidence.append("没认出消费类型，先归到其他")
        }

        result.account = detectAccount(joined)
        if let date = detectDate(joined) { result.date = date }

        return result
    }

    // MARK: 文本清洗

    /// 全角转半角、去掉零宽字符
    static func normalize(_ text: String) -> String {
        let full = "０１２３４５６７８９．，－＋￥：（）"
        let half = "0123456789.,-+¥:()"
        var map: [Character: Character] = [:]
        for (a, b) in zip(full, half) { map[a] = b }

        var out = ""
        out.reserveCapacity(text.count)
        for ch in text {
            if ch == "\u{200B}" || ch == "\u{FEFF}" { continue }
            out.append(map[ch] ?? ch)
        }
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: 支出 / 收入

    private static func detectType(_ text: String) -> RecordType {
        // 强信号先判定，避免「收款方」这类中性词把支出读成收入
        let strongIncome = ["收款成功", "收款到账", "已收款", "退款成功", "已退款",
                            "收到转账", "红包到账", "入账", "转入"]
        let strongExpense = ["支付成功", "已支付", "付款成功", "转账给", "付款给", "消费"]

        for hint in strongIncome where text.contains(hint) { return .income }
        for hint in strongExpense where text.contains(hint) { return .expense }

        let weakIncome = ["收入", "到账", "收款"]
        let weakExpense = ["支出", "付款", "支付"]

        var income = 0
        var expense = 0
        for hint in weakIncome where text.contains(hint) { income += 1 }
        for hint in weakExpense where text.contains(hint) { expense += 1 }

        return income > expense ? .income : .expense
    }

    // MARK: 金额

    /// 这些词所在的行不可能是「这笔花了多少钱」
    private static let amountNoise = [
        "余额", "可用", "额度", "零钱", "优惠", "立减", "折扣", "积分", "手续费",
        "服务费", "汇率", "还款", "待还", "最低还款", "年费", "利息", "原价",
        "已省", "满减", "抵扣", "券"
    ]

    private static let amountBoost = ["实付", "支付金额", "付款金额", "交易金额", "消费", "合计", "总计"]

    private static func detectAmount(_ lines: [OCRLine], type: RecordType) -> Double? {
        struct Candidate {
            let value: Double
            let score: Double
        }

        let maxHeight = lines.map { $0.height }.max() ?? 1
        var candidates: [Candidate] = []

        for line in lines {
            let text = normalize(line.text)
            let sizeScore = Double(line.height / maxHeight) * 2.6
            let boost: Double = amountBoost.contains(where: { text.contains($0) }) ? 1.8 : 0

            // 余额、优惠、原价这类行扣分而不是直接丢掉：
            // 主金额字号远大于其他文字，真金额不会因为带一个噪声词就被判死
            let isGiantText = line.height / maxHeight > 0.86
            let penalty: Double = (!isGiantText && amountNoise.contains(where: { text.contains($0) })) ? -2.4 : 0

            for (pattern, patternScore) in moneyPatterns {
                for (index, raw) in captures(pattern, in: text).enumerated() {
                    let cleaned = raw.replacingOccurrences(of: ",", with: "")
                    guard let signed = Double(cleaned) else { continue }
                    // 微信、支付宝的主金额都是「-29.70」这种带负号写法，
                    // 支不支出由 detectType 判断，这里只取大小
                    let value = abs(signed)
                    guard value > 0, value < 10_000_000 else { continue }
                    // 纯整数行只在字号很大时才可能是金额（避免把年份、卡号当钱）
                    if !raw.contains(".") && sizeScore < 1.6 && patternScore < 1.4 { continue }

                    var score = sizeScore + patternScore + boost + penalty + Double(index) * 0.25
                    if type == .expense && text.contains("-") { score += 0.5 }
                    if type == .income && text.contains("+") { score += 0.5 }
                    candidates.append(Candidate(value: value, score: score))
                }
            }
        }

        return candidates.max(by: { $0.score < $1.score })?.value
    }

    /// pattern 与对应权重
    private static let moneyPatterns: [(String, Double)] = [
        ("[¥￥]\\s*(-?[0-9,]+(?:\\.[0-9]{1,2})?)", 1.7),
        ("(?:人民币|RMB|CNY)\\s*(-?[0-9,]+(?:\\.[0-9]{1,2})?)", 1.5),
        ("-?[0-9,]+\\.[0-9]{2}", 1.0),
        ("^(-?[0-9,]+)$", 0.3)
    ]

    // MARK: 商户

    private static let merchantLabels = [
        "商户全称", "商户名称", "收款方全称", "收款方", "付款给", "转账给",
        "转账对方", "商家名称", "交易对方", "对方账户"
    ]

    private static let goodsLabels = ["商品说明", "商品", "交易摘要", "备注"]

    private static let noiseLines = [
        "支付成功", "交易成功", "已支付", "当前状态", "账单详情", "交易详情", "订单详情",
        "查看更多", "联系商家", "对此订单有疑问", "账单服务", "支付方式", "付款方式",
        "支付时间", "交易时间", "订单号", "交易单号", "商户全称", "商户名称", "收款方",
        "商品说明", "余额", "零钱", "优惠", "合计", "总计", "实付", "支付金额",
        "付款金额", "交易金额", "退款", "微信支付", "支付宝", "云闪付", "银行卡",
        "钱包", "账单", "账单分类", "记一笔"
    ]

    private static func detectMerchant(_ lines: [OCRLine]) -> String {
        let texts = lines.map { normalize($0.text) }

        // 1. 「商户全称」这类标签后面的内容最可靠
        for (index, text) in texts.enumerated() {
            guard merchantLabels.contains(where: { text.contains($0) }) else { continue }
            if let inline = valueAfterColon(text), isMerchantLike(inline) { return sanitize(inline) }
            if index + 1 < texts.count {
                let next = texts[index + 1]
                if isMerchantLike(next) { return sanitize(next) }
            }
        }

        // 2. 商品名次之，通常比「支付成功」更有信息量
        for (index, text) in texts.enumerated() {
            guard goodsLabels.contains(where: { text.contains($0) }) else { continue }
            if let inline = valueAfterColon(text), isMerchantLike(inline) { return sanitize(inline) }
            if index + 1 < texts.count {
                let next = texts[index + 1]
                if isMerchantLike(next) { return sanitize(next) }
            }
        }

        // 3. 兜底：最长的一条「像名字」的行
        return texts
            .filter { isMerchantLike($0) }
            .max(by: { $0.count < $1.count })
            .map { sanitize($0) } ?? ""
    }

    private static func sanitize(_ text: String) -> String {
        var t = text.trimmingCharacters(in: .whitespaces)
        for prefix in ["来自", "收款方", "付款方", "商户"] where t.hasPrefix(prefix) {
            t = String(t.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
        }
        return t
    }

    private static func valueAfterColon(_ text: String) -> String? {
        guard let idx = text.firstIndex(where: { $0 == ":" || $0 == "：" }) else { return nil }
        let value = text[text.index(after: idx)...].trimmingCharacters(in: .whitespaces)
        return value.isEmpty ? nil : String(value)
    }

    private static func isMerchantLike(_ text: String) -> Bool {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (2...26).contains(t.count) else { return false }
        guard t.rangeOfCharacter(from: .decimalDigits) == nil else { return false }
        guard !t.contains("¥"), !t.contains("￥") else { return false }
        guard !noiseLines.contains(where: { t.contains($0) }) else { return false }
        // 至少包含一个汉字，或者是一串英文单词
        let hasChinese = t.range(of: "\\p{Han}", options: .regularExpression) != nil
        let isEnglish = t.range(of: "^[A-Za-z0-9 &'\\-\\.]{3,}$", options: .regularExpression) != nil
        return hasChinese || isEnglish
    }

    // MARK: 账户

    private static func detectAccount(_ text: String) -> String {
        if text.contains("微信") || text.contains("零钱") { return "微信" }
        if text.contains("支付宝") || text.contains("余额宝") || text.contains("花呗") { return "支付宝" }
        if text.contains("信用卡") { return "信用卡" }
        if text.contains("储蓄卡") || text.contains("借记卡") || text.contains("银行卡") { return "储蓄卡" }
        if text.contains("现金") { return "现金" }
        return "其他"
    }

    // MARK: 日期

    private static func detectDate(_ text: String) -> Date? {
        let cal = Calendar.current
        var components = DateComponents()

        // 2026年11月4日 15:23
        if let g = regexGroups("(\\d{4})\\s*年\\s*(\\d{1,2})\\s*月\\s*(\\d{1,2})\\s*日(?:\\s*(\\d{1,2}):(\\d{2}))?", text) {
            components.year = Int(g[1])
            components.month = Int(g[2])
            components.day = Int(g[3])
            components.hour = g.count > 4 ? Int(g[4]) : 0
            components.minute = g.count > 5 ? Int(g[5]) : 0
            return cal.date(from: components)
        }

        // 2026/11/04 或 2026-11-04
        if let g = regexGroups("(\\d{4})[-/](\\d{1,2})[-/](\\d{1,2})(?:\\s*(\\d{1,2}):(\\d{2}))?", text) {
            components.year = Int(g[1])
            components.month = Int(g[2])
            components.day = Int(g[3])
            components.hour = g.count > 4 ? Int(g[4]) : 0
            components.minute = g.count > 5 ? Int(g[5]) : 0
            return cal.date(from: components)
        }

        // 11月4日（默认今年）
        if let g = regexGroups("(\\d{1,2})\\s*月\\s*(\\d{1,2})\\s*日", text) {
            components.year = cal.component(.year, from: Date())
            components.month = Int(g[1])
            components.day = Int(g[2])
            return cal.date(from: components)
        }

        if text.contains("今天") { return Date() }
        if text.contains("昨天") { return Dates.addDays(Date(), -1) }

        return nil
    }

    // MARK: 正则工具

    private static func captures(_ pattern: String, in text: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let ns = text as NSString
        let matches = regex.matches(in: text, range: NSRange(location: 0, length: ns.length))
        return matches.compactMap { match in
            guard match.numberOfRanges > 1, match.range(at: 1).location != NSNotFound else { return nil }
            return ns.substring(with: match.range(at: 1))
        }
    }

    private static func regexGroups(_ pattern: String, _ text: String) -> [String]? {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let ns = text as NSString
        guard let match = regex.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)) else {
            return nil
        }
        var groups: [String] = []
        for index in 0..<match.numberOfRanges {
            let range = match.range(at: index)
            groups.append(range.location == NSNotFound ? "" : ns.substring(with: range))
        }
        return groups
    }
}
