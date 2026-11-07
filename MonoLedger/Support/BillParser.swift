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

/// 金额有多确定。只有 high 才适合静默入账，其余一律标记「待核对」
enum AmountTier: String {
    case high
    case medium
    case low

    var needsReview: Bool { self != .high }

    var label: String {
        switch self {
        case .high:   return "已确认"
        case .medium: return "建议核对"
        case .low:    return "请核对"
        }
    }
}

struct ParseResult {
    var amount: Double = 0
    var type: RecordType = .expense
    var categoryID: String = "more"
    var merchant: String = ""
    var date: Date = Date()
    var confidence: Double = 0
    var matchedKeyword: String = ""
    var rawText: String = ""
    var evidence: [String] = []

    /// 金额判定强度
    var amountTier: AmountTier = .low
    /// 备选金额（识别时排名第二、第三的数字），核对时一键替换
    var alternatives: [Double] = []
    /// 读到的实付确实是 0（积分 / 优惠券全额抵扣）。
    /// 这不是「没读出金额」，提示要分开，不然用户对着一张写着 ¥0.00 的图会懵
    var zeroPaid: Bool = false

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
        if type == .income && isRefund(joined) {
            result.evidence.append("识别为退款，计入收入")
        }

        guard let pick = detectAmount(lines, type: type) else {
            result.evidence = ["没能定位到金额"]
            return result
        }
        result.amount = pick.value
        result.amountTier = pick.tier
        result.alternatives = pick.alternatives
        result.zeroPaid = pick.value <= 0
        result.evidence.append("金额 ¥" + Fmt.money(pick.value) + "（" + pick.tier.label + "）")

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

        if let date = detectDate(joined) { result.date = date }

        return result
    }

    // MARK: 文本清洗

    /// 全角转半角、去掉零宽字符，并把 OCR 常见的断字修补回来
    static func normalize(_ text: String) -> String {
        let full = "０１２３４５６７８９．，－＋￥：（）"
        let half = "0123456789.,-+¥:()"
        var map: [Character: Character] = [:]
        for (a, b) in zip(full, half) { map[a] = b }

        var out = ""
        out.reserveCapacity(text.count)
        for ch in text {
            if ch == "\u{200B}" || ch == "\u{FEFF}" { continue }
            // 各种破折号统一成负号，微信的「-29.70」常被读成长横线
            if ch == "\u{2014}" || ch == "\u{2013}" || ch == "\u{2212}" { out.append("-"); continue }
            out.append(map[ch] ?? ch)
        }

        var cleaned = out.trimmingCharacters(in: .whitespacesAndNewlines)
        // 发票、小票的打印体常把标签拉开字距：「合　计」「实 付」「总  计」。
        // 不合并的话语义锚点一个都认不出，只能退回按字号猜 ——
        // 发票上「金额 100 / 税额 13 / 合计 113」三行同字号时就会猜错
        for word in ["合计", "总计", "共计", "应收", "应付", "实付", "金额", "小计"] {
            let spaced = word.map(String.init).joined(separator: "\\s*")
            cleaned = replacing(spaced, with: word, in: cleaned)
        }
        // 「29. 70」「29 .70」「29 . 70」都是 OCR 把小数点切开了，补回「29.70」
        cleaned = replacing(#"(?<=[0-9])\s*\.\s*(?=[0-9])"#, with: ".", in: cleaned)
        // OCR 常把 0 认成字母 O：¥1O0.00 会让正则只吃到「¥1」，100 记成 1 块。
        // 只在金额上下文（货币符号后、数字/小数点包围）里替换，别把 O2O、iOS 改坏。
        //
        // 后视字符集里必须带上 O 自己：遇到「¥OO.00」这种连续两个 O，
        // 前一个 O 后面不是数字、后一个 O 前面不是 ¥/数字，原来两条规则谁也匹配不上，
        // 跑几遍都改不动（注释里说的「连跑两遍能处理」并不成立）。
        // 带上 O 之后，整串 O 会从右往左一轮吃掉一个，四轮覆盖到 4 个 O，再长就不是 OCR 误差了
        for _ in 0..<4 {
            cleaned = replacing(#"(?<=[¥￥Oo])[Oo](?=[0-9.,])"#, with: "0", in: cleaned)
            cleaned = replacing(#"(?<=[0-9Oo])[Oo](?=[0-9.,])"#, with: "0", in: cleaned)
            cleaned = replacing(#"(?<=[.,])[Oo](?=[0-9])"#, with: "0", in: cleaned)
        }
        // 「- 29.70」负号被空格顶开
        cleaned = replacing(#"(?<=[¥￥])\s+(?=[0-9])"#, with: "", in: cleaned)
        cleaned = replacing(#"(^|\s)-\s+(?=[0-9])"#, with: "$1-", in: cleaned)
        // 「2026.11.05」这种用点分隔的日期：后两段正好长得像金额，
        // 会被金额正则读成「11.05」，一张只写了日期的小票就凭空多出 11 块 5。
        // 先统一成横线 —— 顺带让 detectDate 也能认出这种写法
        cleaned = replacing(
            #"(?<![0-9.])([0-9]{4})\.(0?[1-9]|1[0-2])\.(0?[1-9]|[12][0-9]|3[01])(?![0-9.])"#,
            with: "$1-$2-$3", in: cleaned)
        // 「¥1 234.56」：千分位字距窄，OCR 常把逗号读成空格。
        // 不合并的话正则会只吃到「¥1」，1234 记成 1 块，比不识别更糟
        cleaned = replacing(#"(?<=[0-9])\s+(?=[0-9]{3}(?:[.,][0-9]{1,2})?(?![0-9]))"#, with: "", in: cleaned)
        // 「¥1.234.56」：同一个千分位，逗号被读成点。只能吃到后段「234.56」，
        // 1234.56 变成 234.56 —— 少一位数，而且金额大小看着还挺正常，最难发现。
        // 中间那段正好三位时，把前一个点当千分位吃掉
        cleaned = replacing(#"(?<![0-9.])([0-9]{1,3})\.([0-9]{3})\.([0-9]{1,2})(?![0-9])"#,
                            with: "$1$2.$3", in: cleaned)
        // 「¥299.」OCR 多送了一个点，会卡住金额匹配
        cleaned = replacing(#"(?<=[0-9])\.(?=\s|$)"#, with: "", in: cleaned)
        return cleaned
    }

    private static func replacing(_ pattern: String, with template: String, in text: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }
        let range = NSRange(location: 0, length: (text as NSString).length)
        return regex.stringByReplacingMatches(in: text, range: range, withTemplate: template)
    }

    // MARK: 支出 / 收入

    /// 退款类词：钱退回来了，对账本来说是收入，分类归「退款」
    private static let refundSignals = ["退款", "退货", "退回", "退费", "退还", "返还", "原路退回"]

    /// 出现这些组合说明钱还没退到，「退款」只是流程状态或条件说明，不能当收入
    private static let refundBlockers = ["退款失败", "申请退款", "退款申请", "退款中",
                                         "待退款", "退款处理中", "退款审核", "退货申请",
                                         // 「归还后押金原路退回」是租借说明，「退款将于 3 个工作日退回」
                                         // 是还没发生的事 —— 这类页面真正扣的钱是「本次扣费」
                                         "归还后", "后退回", "将原路退回", "将退回", "会原路退回", "预计"]

    /// 收货类语句里的「收到」不是收入
    private static let receiveBlockers = ["快递", "包裹", "账单", "短信", "通知", "邮件", "消息"]

    /// 是否为一笔退款（钱已回到账上）
    static func isRefund(_ text: String) -> Bool {
        guard refundSignals.contains(where: { text.contains($0) }) else { return false }
        return !refundBlockers.contains(where: { text.contains($0) })
    }

    /// 「收到 500」「收到红包 200」是收入，「收到快递 20」不是
    private static func receiveMeansIncome(_ text: String) -> Bool {
        guard let range = text.range(of: "收到") else { return false }
        let after = String(text[range.upperBound...].prefix(6))
        return !receiveBlockers.contains(where: { after.contains($0) })
    }

    /// 钱从自己这里出去的说法。这几句出现时方向已定，
    /// 不能再被「已收款 / 到账 / 充值到账」这类词拉成收入 ——
    /// 转账页的「已收款」说的是对方收到了，不是自己进账。
    private static let outgoingSignals = ["转账给", "转账至", "付款给", "转给对方", "已转账"]

    private static func detectType(_ text: String) -> RecordType {
        // 退款优先：这类句子常含「到账」「收到」，不先判定会被读成收入或反向支出
        if isRefund(text) { return .income }

        // 方向词比「到账」可靠：先定方向，再谈别的
        if outgoingSignals.contains(where: { text.contains($0) }) { return .expense }

        // 强信号先判定，避免「收款方」这类中性词把支出读成收入
        let strongIncome = ["收款成功", "收款到账", "已收款", "收到转账", "收到红包", "红包到账",
                            "入账", "转入", "进账", "回款",
                            "工资", "薪资", "薪水", "奖金", "年终奖", "绩效", "提成",
                            "分红", "利息收入", "报销到账", "收入"]
        // 「充值 / 还款 / 缴费」都是自己掏钱，页面上多半还写着「到账」，
        // 只靠弱信号会把它们全记成收入
        let strongExpense = ["支付成功", "已支付", "付款成功", "转账给", "付款给", "消费",
                             "花了", "花费", "买了", "付了", "支出",
                             "充值", "还款", "缴费", "缴纳", "发出红包", "发红包"]

        for hint in strongIncome where text.contains(hint) { return .income }
        for hint in strongExpense where text.contains(hint) { return .expense }

        let weakIncome = ["到账", "收款"]
        let weakExpense = ["支出", "付款", "支付"]

        var income = 0
        var expense = 0
        for hint in weakIncome where text.contains(hint) { income += 1 }
        for hint in weakExpense where text.contains(hint) { expense += 1 }
        if receiveMeansIncome(text) { income += 1 }

        return income > expense ? .income : .expense
    }

    // MARK: 金额

    struct AmountPick {
        let value: Double
        let tier: AmountTier
        let alternatives: [Double]
    }

    /// 这些词紧挨着数字，说明那个数字是编号、额度、优惠，不是这笔的钱
    private static let hardNoise = [
        "订单号", "订单编号", "交易单号", "商户单号", "流水号", "退款单号", "支付单号",
        "卡号", "尾号", "手机号", "证件号", "编号", "单号", "有效期", "积分",
        "优惠券", "优惠", "券码", "兑换码", "汇率", "手续费", "服务费", "已省", "满减",
        "抵扣", "折扣", "立减", "还款", "待还", "最低还款", "年费", "利息"
    ]

    /// 偏噪声，但「余额支付 32」「零钱付了 25」里跟着的数字仍是真花销
    private static let softNoise = ["余额", "零钱", "额度", "可用", "原价"]

    private static let payVerbs = ["支付", "付款", "付了", "消费", "扣款", "扣了", "花了",
                                   "实付", "转账", "收款", "充值"]

    /// 小票上的找零
    private static let changeLabels = ["找零", "找钱", "应找"]
    /// 顾客递过去的钱：有找零时它们不是消费额，没找零时「实收」就是实付
    private static let tenderLabels = ["实收", "收款", "现金", "付现"]

    /// 这个金额行是不是「找零」或「递过去的整钱」
    private static func excludedByChange(_ index: Int, lines: [OCRLine], texts: [String]) -> Bool {
        if changeLabels.contains(where: { texts[index].contains($0) }) { return true }

        let hasChange = texts.contains { text in changeLabels.contains { text.contains($0) } }
        let labels = hasChange ? (changeLabels + tenderLabels) : changeLabels
        let row = lines[index]
        for (j, other) in lines.enumerated() where j != index {
            guard labels.contains(where: { texts[j].contains($0) }) else { continue }
            if abs(other.box.midY - row.box.midY) < max(row.height, other.height) * 0.9 {
                return true
            }
        }
        return false
    }

    /// 紧贴金额的付款动作，比「支付成功」这种状态词更可信
    private static let actionWords = ["消费", "实付", "付款", "付了", "扣款", "扣了",
                                      "花了", "转账", "支付", "收款", "共计"]

    private static let amountBoost = ["实付", "支付金额", "付款金额", "交易金额", "订单金额",
                                      "消费金额", "合计", "总计", "共计", "应付", "实收款"]

    /// 和金额同屏出现，说明这就是一笔交易的凭证页
    private static let paymentContext = ["支付成功", "付款成功", "交易成功", "收款成功", "已支付",
                                         "已收款", "交易完成", "付款完成", "到账", "退款成功",
                                         "订单已支付", "扣款成功", "转账成功", "支付凭证"]

    /// 「实付 / 应付 / 支付金额」这类字段的语义最明确：它就是这笔钱。
    /// 字号在优惠页面上反而会骗人 —— 外卖、打车、支付宝账单顶部那个大字是原价，
    /// 真正的实付藏在下面的小字里，按字号选必然选错。
    private static let finalAmountLabels = [
        // 「个人自费」排在总金额前面：医院缴费页上，医保那部分不是自己掏的钱
        "个人自费", "自费金额",
        "实付金额", "实付款", "实付", "实际支付", "实际付款",
        "应付金额", "支付金额", "付款金额",
        // 信用卡、白条、花呗账单页用的是「本期应还」，
        // 旁边常并排一个「最低还款」，那是可以只还的最小额，不是这期要还的钱
        "本期应还", "应还金额", "应还",
        // 纸质小票没有「实付款」，只有「合计 / 总计 / 应收」。
        // 排在实付类之后：有实付时以实付为准，没有才用合计。
        "合计金额", "合计", "总计", "共计", "应收金额", "应收",
        // 「交易金额」放最后：签购单上它只是刷卡的货价，
        // 加上小费之后的「总计」才是真正扣走的钱
        "交易金额"
    ]

    /// 「商品合计 / 原价合计 / 菜品合计」都是优惠前的数
    private static func isPreDiscountTotal(_ text: String) -> Bool {
        guard let range = text.range(of: "合计") else { return false }
        let before = String(text[..<range.lowerBound])
        let modifiers = ["商品", "原价", "菜品", "货品", "菜价", "商品总"]
        return modifiers.contains { before.hasSuffix($0) }
    }

    /// 先找语义锚点，命中就直接采信，不再和字号竞争。
    /// 外层按标签优先级走，不按行：一行里同时有「应付」和「实付」时，实付才算数。
    private static func anchoredAmount(_ lines: [OCRLine], texts: [String]) -> (value: Double, duplicated: Bool)? {
        for label in finalAmountLabels {
            for (index, text) in texts.enumerated() where text.contains(label) {
                // 小票上「商品合计 / 原价合计」是优惠前的价格，
                // 真正的应付在下面那行单独的「合计」里，不能先撞上哪个用哪个
                if label == "合计", isPreDiscountTotal(text) { continue }

                // 同一个标签出现多次、而且金额各不相同，多半是订单列表 / 一屏多笔，
                // 锚点只能取到第一笔 —— 这种页面不能当成「已确认」，否则少记一半钱。
                // 微信、支付宝的详情页常把「实付」印两遍，那是同一笔，金额一样，不降级
                // 标签经常和金额被 OCR 拆成两个框：左边「实付」、右边数字。
                // 只按行内文本取会全部落空，Set 空掉之后 duplicated 恒为 false，
                // 一屏两笔时就静默按第一笔入账，第二笔直接丢
                let taggedAmounts = (0..<texts.count).compactMap { i -> Double? in
                    guard texts[i].contains(label) else { return nil }
                    if label == "合计", isPreDiscountTotal(texts[i]) { return nil }
                    return amountIn(texts[i], allowZero: true)
                        ?? amountOnSameRow(i, lines: lines, texts: texts)
                }
                let duplicated = Set(taggedAmounts.map { Int(($0 * 100).rounded()) }).count > 1

                // 1) 标签和金额在同一行。注意取「标签之后」的金额 ——
                //    「支付成功 -¥45.00 优惠 ¥15.00 实付 ¥30.00」里，行首那个是原价
                if let range = text.range(of: label) {
                    let after = String(text[range.upperBound...])
                    if let value = amountIn(after, allowZero: true) { return (value, duplicated) }
                }
                // 标签在数值后面（「¥30.00 实付」），退回整行第一个
                if let value = amountIn(text, allowZero: true) { return (value, duplicated) }

                // 2) 同一水平带、在标签右边：左标签右数值，国内 App 最常见
                if let hit = amountOnSameRow(index, lines: lines, texts: texts) {
                    return (hit, duplicated)
                }

                // 3) 标签在上、数值在下一行
                if index + 1 < lines.count,
                   isAmountOnly(texts[index + 1]),
                   let value = amountIn(texts[index + 1], allowZero: true) {
                    return (value, duplicated)
                }
            }
        }
        return nil
    }

    /// 同一水平带上、位于第 index 行右侧的那个金额。
    /// 左标签右数值是国内 App 最常见的排版，标签和数字常被 OCR 拆成两个框。
    private static func amountOnSameRow(_ index: Int, lines: [OCRLine], texts: [String]) -> Double? {
        guard lines.indices.contains(index) else { return nil }
        let row = lines[index]
        var rightmost: (value: Double, x: CGFloat)?
        for (j, other) in lines.enumerated() where j != index {
            let dy = abs(other.box.midY - row.box.midY)
            guard dy < max(row.height, other.height) * 0.6 else { continue }
            // 坐标是归一化的（0...1），容差只能给 0.02；
            // 写成 -1 会让这个条件恒成立，把标签左边的「优惠」也收进来
            guard other.box.minX >= row.box.maxX - 0.02 else { continue }
            if let value = amountIn(texts[j], allowZero: true) {
                if rightmost == nil || other.box.minX < rightmost!.x {
                    rightmost = (value, other.box.minX)
                }
            }
        }
        return rightmost?.value
    }

    /// 一行里第一个像金额的数字
    private static func amountIn(_ text: String, allowZero: Bool = false) -> Double? {
        let ns = text as NSString
        for (pattern, _) in moneyPatterns {
            for match in moneyMatches(pattern, in: text, ns: ns) {
                // 锚点场景要允许 0：积分或优惠券全额抵扣时，实付就是 ¥0.00，
                // 把它当成没读到金额，就会退回去记商品原价，反而记错账
                if let value = moneyValue(match.text, allowZero: allowZero),
                   allowZero ? value >= 0 : value > 0 {
                    return value
                }
            }
        }
        return nil
    }

    /// 整行就是个金额（允许带符号、千分位、货币符号、口语的「元 / 块」）
    private static func isAmountOnly(_ text: String) -> Bool {
        let stripped = text
            .replacingOccurrences(of: "¥", with: "")
            .replacingOccurrences(of: "￥", with: "")
            .replacingOccurrences(of: "-", with: "")
            .replacingOccurrences(of: "+", with: "")
            .replacingOccurrences(of: ",", with: "")
            .replacingOccurrences(of: "元", with: "")
            .replacingOccurrences(of: "块", with: "")
            .trimmingCharacters(in: .whitespaces)
        guard !stripped.isEmpty else { return false }
        return stripped.allSatisfy { $0.isNumber || $0 == "." }
    }

    private static func detectAmount(_ rawLines: [OCRLine], type: RecordType) -> AmountPick? {
        let lines = mergeAmountFragments(rawLines)
        guard !lines.isEmpty else { return nil }

        let texts = lines.map { normalize($0.text) }

        // 语义锚点优先于一切：页面上写着「实付」，就以那个数为准。
        // 只对支出启用：退款页也会印着原订单的「实付」，但那不是这次到账的钱。
        let anchored: (value: Double, duplicated: Bool)? = (type == .expense) ? anchoredAmount(lines, texts: texts) : nil

        // 用 28 分位当基准：一屏里正文行最多，拿它做「正常字号」才准。
        // 之前用 88 分位，页面元素少于十来个时它会退化成最大值，
        // 等于拿主金额自己当分母，ratio 永远是 1，反而把分数压低到中档。
        let heights = lines.map { $0.height }.sorted()
        let pivot = heights[max(0, min(heights.count - 1, Int(Double(heights.count) * 0.28)))]
        let baseline = max(pivot, 0.008)

        var candidates: [(value: Double, score: Double)] = []

        for (index, line) in lines.enumerated() {
            let text = texts[index]
            if text.contains("%") { continue }

            // 整行就是一条「订单号」「卡号」标签，下面跟的数字是编号
            if hardNoise.contains(where: { text.hasPrefix($0) }) { continue }

            // 小票的「找零」是顾客拿回去的钱，「实收」是递过来的整钱，
            // 两者都不是消费额。金额常单独成行，只能看同一水平带上的标签
            if excludedByChange(index, lines: lines, texts: texts) { continue }

            let sizeRatio = min(3.0, Double(line.height / baseline))
            let sizeScore = sizeRatio * 1.9
            let isGiant = sizeRatio >= 1.25
            let hasCurrency = text.contains("¥") || text.contains("￥")

            var base = sizeScore
            // 行级只给弱加分；真正强的加分留给「紧贴金额」的词，见下面的局部判断
            base += amountBoost.contains(where: { text.contains($0) }) ? 1.2 : 0

            // 上下两行里有「支付成功」这类字样 —— 微信、支付宝的凭证页几乎必然命中
            let context = contextText(texts, around: index, span: 2)
            if paymentContext.contains(where: { context.contains($0) }) { base += 2.2 }

            // 主金额通常在页面中上部，底部是按钮区
            let midY = Double(line.box.midY)
            if midY >= 0.42 && midY <= 0.92 { base += 0.7 }
            else if midY < 0.30 { base -= 0.9 }

            base += Double(min(1, max(0, line.confidence))) * 0.3
            if type == .expense && text.contains("-") { base += 0.6 }
            if type == .income && text.contains("+") { base += 0.6 }

            let ns = text as NSString

            for (pattern, patternScore) in moneyPatterns {
                for (order, match) in moneyMatches(pattern, in: text, ns: ns).enumerated() {
                    let raw = match.text
                    guard let value = moneyValue(raw) else { continue }
                    let isDecimal = raw.contains(".")

                    // 没有小数点的裸数字，只有字号够大或带货币符号才算钱
                    if !isDecimal && !hasCurrency && sizeScore < 1.2 && patternScore < 1.5 { continue }
                    // 6 位以上不带小数点的整数，多半是订单号 / 卡号
                    if !isDecimal && raw.filter(\.isNumber).count >= 6 && !hasCurrency { continue }

                    // 看这个数字紧邻的前文：是编号、余额、优惠就丢掉
                    let lead = prefix(before: match.range, in: ns, length: 14)
                    let tail = lead.trimmingCharacters(in: .whitespaces)
                    if hardNoise.contains(where: { tail.hasSuffix($0) || tail.suffix(10).contains($0) }),
                       !(hasCurrency && isGiant) {
                        continue
                    }
                    var penalty: Double = 0
                    if softNoise.contains(where: { tail.suffix(6).contains($0) }) {
                        if payVerbs.contains(where: { tail.suffix(6).contains($0) }) {
                            penalty = -1.8
                        } else if !(hasCurrency && isGiant) {
                            continue
                        }
                    }

                    // 「实付 ¥30.00」比同屏的「优惠 ¥15.00」更该被选中
                    var localBoost: Double = 0
                    if amountBoost.contains(where: { tail.suffix(12).contains($0) }) { localBoost += 2.4 }
                    if actionWords.contains(where: { tail.suffix(6).contains($0) }) { localBoost += 1.0 }

                    var total = base + patternScore + penalty + localBoost - Double(order) * 0.2
                    if patternScore >= 1.5 { total += 0.4 }  // 带 ¥ / 人民币前缀
                    candidates.append((value, total))
                }
            }
        }

        candidates.sort { $0.score > $1.score }

        // 同一笔金额经常在页面上出现两次，去重
        var unique: [(value: Double, score: Double)] = []
        for item in candidates {
            let duplicated = unique.contains { abs($0.value - item.value) < 0.005 }
            if !duplicated { unique.append(item) }
        }
        // 锚点命中：金额以它为准，页面上其他数字照样列成候选，
        // 万一哪张截图的「实付」不是这单的钱，用户还能一键换。
        //
        // 这段必须排在候选池判空之前：积分 / 优惠券全额抵扣的订单只印着
        // 「实付 ¥0.00」，候选池不收 0，一个数都攒不出来。先判空就会退回
        // 「没能定位到金额」，0 元订单反而记不成账，zeroPaid 也永远亮不起来
        if let anchored {
            var others: [Double] = []
            for item in unique where abs(item.value - anchored.value) >= 0.01 {
                if !others.contains(where: { abs($0 - item.value) < 0.005 }) {
                    others.append(item.value)
                }
                if others.count == 3 { break }
            }
            // 标签重复出现时降成中档：金额本身可信，但这页可能不止一笔
            return AmountPick(value: anchored.value,
                              tier: anchored.duplicated ? .medium : .high,
                              alternatives: others)
        }

        guard let best = unique.first else { return nil }

        let second = unique.dropFirst().first
        let gap = second.map { best.score - $0.score } ?? 99

        let tier: AmountTier
        if best.score >= 5.2 && gap >= 1.1 {
            tier = .high
        } else if best.score >= 3.6 {
            tier = .medium
        } else {
            tier = .low
        }

        let alternatives = unique.dropFirst()
            .prefix(3)
            .map { $0.value }
            .filter { abs($0 - best.value) >= 0.01 }

        return AmountPick(value: best.value, tier: tier, alternatives: Array(alternatives))
    }

    private static func moneyValue(_ raw: String, allowZero: Bool = false) -> Double? {
        var cleaned = raw.replacingOccurrences(of: " ", with: "")
        // 「¥45,00」：小数点被 OCR 读成了逗号，直接去掉逗号会变成 4500，差 100 倍。
        // 只有一个逗号、后面正好两位、整串又没小数点时，按小数点处理；
        // 「1,234」「1,234.56」这类真千分位不受影响
        if !cleaned.contains("."),
           cleaned.filter({ $0 == "," }).count == 1,
           let comma = cleaned.firstIndex(of: ","),
           cleaned.distance(from: cleaned.index(after: comma), to: cleaned.endIndex) == 2 {
            cleaned = cleaned.replacingOccurrences(of: ",", with: ".")
        }
        cleaned = cleaned.replacingOccurrences(of: ",", with: "")
        guard let signed = Double(cleaned) else { return nil }
        // 微信、支付宝的主金额写作「-29.70」，支不支出由 detectType 判断，这里只取大小
        let value = abs(signed)
        guard allowZero ? value >= 0 : value > 0, value < 10_000_000 else { return nil }
        return (value * 100).rounded() / 100
    }

    private static func prefix(before range: NSRange, in ns: NSString, length: Int) -> String {
        let start = max(0, range.location - length)
        guard range.location > start else { return "" }
        return ns.substring(with: NSRange(location: start, length: range.location - start))
    }

    /// 取某一行前后若干行的文字，用来判断上下文
    private static func contextText(_ texts: [String], around index: Int, span: Int) -> String {
        let lower = max(0, index - span)
        let upper = min(texts.count - 1, index + span)
        guard lower <= upper else { return "" }
        return texts[lower...upper].joined(separator: " ")
    }

    /// OCR 会把「¥29.70」拆成「¥」「29」「.70」三个框。
    /// 只合并「纯数字 / 金额符号」的片段，避免把「支付方式 零钱」和金额拼进同一行。
    private static func mergeAmountFragments(_ lines: [OCRLine]) -> [OCRLine] {
        guard lines.count > 1 else { return lines }

        let numeric = CharacterSet(charactersIn: "0123456789.,¥￥-+")
        var pool = lines
        var result: [OCRLine] = []

        while !pool.isEmpty {
            var current = pool.removeFirst()
            var didMerge = true
            while didMerge {
                didMerge = false
                for (i, other) in pool.enumerated() {
                    guard sameVisualRow(current, other),
                          isAmountFragment(current, other, numeric: numeric) else { continue }
                    current = combine(current, other)
                    pool.remove(at: i)
                    didMerge = true
                    break
                }
            }
            result.append(current)
        }
        return result.sorted { $0.box.midY > $1.box.midY }
    }

    private static func sameVisualRow(_ a: OCRLine, _ b: OCRLine) -> Bool {
        let h = max(min(a.height, b.height), 0.001)
        guard abs(a.box.midY - b.box.midY) < h * 0.6 else { return false }
        let gap = max(b.box.minX - a.box.maxX, a.box.minX - b.box.maxX)
        return gap >= -h * 0.4 && gap <= h * 1.6
    }

    private static func isAmountFragment(_ a: OCRLine, _ b: OCRLine, numeric: CharacterSet) -> Bool {
        let symbolOnly = CharacterSet(charactersIn: "¥￥-+")
        let digits = CharacterSet(charactersIn: "0123456789,")

        func isSymbol(_ s: String) -> Bool {
            !s.isEmpty && s.count <= 2 && s.unicodeScalars.allSatisfy { symbolOnly.contains($0) }
        }
        func isDecimalTail(_ s: String) -> Bool {
            s.hasPrefix(".") && s.count >= 2 && s.dropFirst().unicodeScalars.allSatisfy { digits.contains($0) }
        }
        func isNumeric(_ s: String) -> Bool {
            !s.isEmpty && s.count <= 12 && s.unicodeScalars.allSatisfy { numeric.contains($0) }
        }

        // 只补两种断字：「¥」+「29.70」 和 「29」+「.70」
        if isSymbol(a.text) && isNumeric(b.text) { return true }
        if isSymbol(b.text) && isNumeric(a.text) { return true }
        if isDecimalTail(b.text) && isNumeric(a.text) { return true }
        if isDecimalTail(a.text) && isNumeric(b.text) { return true }

        // 「¥1 234.56」：千分位的空格让 OCR 切成「1」和「234.56」两个框。
        // 行内文本的千分位规则救不了跨框的情况，不补这条就会把 1234.56 记成 1 块
        if isThousandsHead(a.text) && isThousandsTail(b.text) { return true }
        if isThousandsHead(b.text) && isThousandsTail(a.text) { return true }
        return false
    }

    /// 千分位的第一段：1~3 位纯数字，允许前面已经并上了货币符号（「¥1」）
    private static func isThousandsHead(_ s: String) -> Bool {
        let body = s.drop(while: { "¥￥-+".contains($0) })
        return !body.isEmpty && body.count <= 3 && body.allSatisfy(\.isNumber)
    }

    /// 千分位的后续段：正好 3 位数字，可带 1~2 位小数（234 / 234.56）
    private static func isThousandsTail(_ s: String) -> Bool {
        let parts = s.split(separator: ".", maxSplits: 1, omittingEmptySubsequences: false)
        guard let head = parts.first, head.count == 3, head.allSatisfy(\.isNumber) else { return false }
        if parts.count == 2 {
            let tail = parts[1]
            return (1...2).contains(tail.count) && tail.allSatisfy(\.isNumber)
        }
        return true
    }

    private static func combine(_ a: OCRLine, _ b: OCRLine) -> OCRLine {
        let aLeft = a.box.minX <= b.box.minX
        let left = aLeft ? a : b
        let right = aLeft ? b : a
        // 中间不留空格，「¥ 29 . 70」才能拼回「¥29.70」
        return OCRLine(text: left.text + right.text,
                       confidence: min(left.confidence, right.confidence),
                       height: max(left.height, right.height),
                       box: left.box.union(right.box))
    }

    /// 带位置的金额匹配，便于检查数字紧邻的前文
    private static func moneyMatches(_ pattern: String, in text: String, ns: NSString) -> [(text: String, range: NSRange)] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        return regex.matches(in: text, range: NSRange(location: 0, length: ns.length)).compactMap { match in
            guard match.numberOfRanges > 1, match.range(at: 1).location != NSNotFound else { return nil }
            return (ns.substring(with: match.range(at: 1)), match.range(at: 1))
        }
    }

    /// pattern 与对应权重
    private static let moneyPatterns: [(String, Double)] = [
        ("[¥￥]\\s*(-?[0-9,]+(?:\\.[0-9]{1,2})?)(?![0-9.])", 1.7),
        ("(?:人民币|RMB|CNY)\\s*(-?[0-9,]+(?:\\.[0-9]{1,2})?)(?![0-9.])", 1.5),
        ("(-?[0-9,]+\\.[0-9]{1,2})(?![0-9.])", 1.0),
        // 「共 45 元」「充值金额 100 元」：整句口语、小票、短信里都是这个写法，
        // 没有 ¥ 也没有小数点。分值压到 0.9 —— 只能兜底，不能盖过带符号的金额
        ("([0-9,]+(?:\\.[0-9]{1,2})?)\\s*元(?![0-9])", 0.9),
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

    // MARK: 打字记账（自然语言）

    /// 把一段手打或粘贴的文字解析成一笔账单。
    /// 多行走和截图完全相同的 OCR 管线；单行走口语短句管线。
    static func parse(text: String) -> ParseResult {
        let raw = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return ParseResult() }

        if !raw.contains("\n"), let quick = parseSentence(raw) {
            return quick
        }

        let lines: [OCRLine] = raw
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .enumerated()
            .map { index, value in
                OCRLine(text: value,
                        confidence: 1,
                        height: 0.02,
                        box: CGRect(x: 0,
                                    y: max(0, 0.95 - CGFloat(index) * 0.04),
                                    width: 1,
                                    height: 0.02))
            }

        var result = parse(lines: lines)
        result.rawText = raw
        return result
    }

    /// 「午饭 32」「打车25」「昨天买咖啡花了28」这类一句话
    private static func parseSentence(_ sentence: String) -> ParseResult? {
        guard let token = lastAmountToken(in: sentence) else { return nil }

        var result = ParseResult()
        result.rawText = sentence
        result.amount = token.value
        // 一句话里只有一个数字，用户本来就看得见，给中档即可
        result.amountTier = .medium
        result.type = detectType(sentence)
        if result.type == .income && isRefund(sentence) {
            result.evidence.append("识别为退款，计入收入")
        }

        if let hit = MerchantRules.match(sentence, type: result.type) {
            result.categoryID = hit.categoryID
            result.matchedKeyword = hit.keyword
            result.confidence = 0.9
            result.evidence.append("命中「\(hit.keyword)」")
        } else {
            result.categoryID = result.type == .income ? "moreIn" : "more"
            result.confidence = 0.55
            result.evidence.append("没认出消费类型，先归到其他")
        }

        if let date = detectDate(sentence) { result.date = date }
        result.merchant = cleanSentence(sentence, removing: token.text)
        result.evidence.insert("金额 ¥" + Fmt.money(token.value), at: 0)
        return result
    }

    private struct AmountToken {
        let value: Double
        let text: String
    }

    /// 识别口语金额，排除日期、时间、数量单位和订单号。
    private static func lastAmountToken(in text: String) -> AmountToken? {
        let normalized = normalize(text)
        let pattern = "(?<![\\d.,])([¥￥]?\\s*-?\\d{1,3}(?:,\\d{3})+(?:\\.\\d{1,2})?|[¥￥]?\\s*-?\\d+(?:\\.\\d{1,2})?)(?:元|块钱|块)?(?![\\d])"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let ns = normalized as NSString
        var best: (token: AmountToken, score: Int, location: Int)?

        let blockedAfter = Set(["月", "日", "号", "时", "分", "秒", "年", "折", "%", "个", "人",
                                "楼", "层", "杯", "件", "张", "份", "岁", "次", "公", "升", "米", "斤", "公里"])
        let amountHints = ["花了", "花费", "支付", "付款", "实付", "消费", "金额", "共计", "总计", "转账", "收入", "收到"]
        let identifierHints = ["订单号", "交易单号", "订单编号", "流水号", "卡号", "尾号", "编号", "单号", "手机号"]

        for match in regex.matches(in: normalized, range: NSRange(location: 0, length: ns.length)) {
            let rawMatch = ns.substring(with: match.range)
            let cleaned = rawMatch
                .replacingOccurrences(of: "¥", with: "")
                .replacingOccurrences(of: "￥", with: "")
                .replacingOccurrences(of: "元", with: "")
                .replacingOccurrences(of: "块钱", with: "")
                .replacingOccurrences(of: "块", with: "")
                .replacingOccurrences(of: ",", with: "")
                .trimmingCharacters(in: .whitespaces)
            guard let value = Double(cleaned), value > 0, value < 10_000_000 else { continue }

            let prefix = ns.substring(to: match.range.location)
            let suffix = ns.substring(from: match.range.location + match.range.length)
            let before = prefix.trimmingCharacters(in: .whitespaces)
            let after = suffix.trimmingCharacters(in: .whitespaces)
            let tail = before.isEmpty ? "" : String(before.suffix(1))
            let head = after.isEmpty ? "" : String(after.prefix(1))

            if blockedAfter.contains(head) { continue }
            if [":", "/", "#", "-"].contains(tail) || [":", "/", "-"].contains(head) { continue }
            if ["优惠", "立减", "折扣", "积分", "订单号", "交易单号", "编号"].contains(where: { prefix.suffix(10).contains($0) }) { continue }
            // 「余额 / 零钱」只有在没有付款动作时才是余额查询；
            // 「余额支付 32」「零钱付了 25」是真花出去的钱，不能当噪声丢掉
            let payVerbs = ["支付", "付款", "付了", "消费", "花了", "扣款", "扣了"]
            if ["余额", "零钱"].contains(where: { prefix.suffix(10).contains($0) }),
               !payVerbs.contains(where: { normalized.contains($0) }) { continue }
            let trimmedPrefix = prefix.trimmingCharacters(in: .whitespaces)
            if identifierHints.contains(where: { trimmedPrefix.hasSuffix($0) }) { continue }

            var score = 0
            if rawMatch.contains("¥") || rawMatch.contains("￥") { score += 8 }
            if rawMatch.contains("元") || rawMatch.contains("块") { score += 7 }
            if amountHints.contains(where: { prefix.suffix(12).contains($0) }) { score += 4 }
            if !rawMatch.contains(".") && score == 0 { score -= 1 }
            if best == nil || score > best!.score || (score == best!.score && match.range.location > best!.location) {
                best = (AmountToken(value: value, text: rawMatch), score, match.range.location)
            }
        }
        return best?.token
    }

    /// 把金额和口头动词从备注里去掉，留下「午饭」「加油」这种干净词
    private static func cleanSentence(_ text: String, removing amountText: String) -> String {
        var t = text
        if !amountText.isEmpty, let range = t.range(of: amountText) {
            t.removeSubrange(range)
        }
        // 长词在前，避免「块钱」被「块」先吃掉
        for word in ["花了", "花掉", "用了", "付了", "支付了", "消费了", "买了",
                     "今天", "昨天", "前天", "刚刚", "刚才",
                     "元钱", "块钱", "元", "块"] {
            t = t.replacingOccurrences(of: word, with: " ")
        }
        while t.contains("  ") { t = t.replacingOccurrences(of: "  ", with: " ") }
        t = t.replacingOccurrences(of: "¥", with: " ").replacingOccurrences(of: "￥", with: " ")
        t = t.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.trimmingCharacters(in: CharacterSet(charactersIn: " ，,。.、:：-—~·"))
    }
}
