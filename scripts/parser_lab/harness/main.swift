import Foundation

// 变异测试用的判定器：金标准 + 蜕变 + 随机不变量，三路同时判。
// 输出固定格式 RESULT pass=x fail=y，失败即退出码 1。

struct Seed {
    let name: String
    let text: String
    let amount: String
    let expected: Double
    let type: RecordType
}

let seeds: [Seed] = [
    Seed(name: "微信转账", text: "微信支付\n转账给 张三\n-29.70\n零钱\n2024年11月6日 08:39", amount: "29.70", expected: 29.70, type: .expense),
    Seed(name: "支付宝账单", text: "账单详情\n星巴克\n-45.00\n付款方式 余额宝\n交易成功", amount: "45.00", expected: 45.00, type: .expense),
    Seed(name: "小票合计", text: "全家便利店\n可乐 3.50\n面包 12.00\n合计 15.50\n微信支付", amount: "15.50", expected: 15.50, type: .expense),
    Seed(name: "小票找零", text: "超市\n合计 88.00\n找零 12.00\n现金", amount: "88.00", expected: 88.00, type: .expense),
    Seed(name: "医院自费", text: "门诊缴费\n市第一医院\n总金额 320.00\n个人自费 96.00", amount: "96.00", expected: 96.00, type: .expense),
    Seed(name: "签购单小费", text: "签购单\n商户名称 海底捞\n消费金额 128.00\n小费 15.00\n交易金额 143.00", amount: "143.00", expected: 143.00, type: .expense),
    Seed(name: "信用卡应还", text: "信用卡账单\n本期应还 3,280.50\n最低还款 328.05", amount: "3,280.50", expected: 3280.50, type: .expense),
    Seed(name: "外卖实付", text: "订单已完成\n美团外卖\n实付 ¥32.80", amount: "32.80", expected: 32.80, type: .expense),
    Seed(name: "打车", text: "本次行程 28.60 元\n滴滴出行\n已支付", amount: "28.60", expected: 28.60, type: .expense),
    Seed(name: "充电宝押金", text: "共享充电宝\n押金 99.00\n归还后原路退回", amount: "99.00", expected: 99.00, type: .expense),
    Seed(name: "红包收入", text: "收到红包 ¥8.88\n李四", amount: "8.88", expected: 8.88, type: .income),
    Seed(name: "发票字距", text: "电子发票\n合　计 ¥1,234.56", amount: "1,234.56", expected: 1234.56, type: .expense),
    Seed(name: "转账支出", text: "转账至 李四 ¥500.00\n转账成功", amount: "500.00", expected: 500.00, type: .expense),
    Seed(name: "两笔实付", text: "订单A\n实付 12.00\n订单B\n实付 18.00", amount: "12.00", expected: 12.00, type: .expense),
    Seed(name: "千分位空格", text: "账单\n合计 ¥1 234.56", amount: "1 234.56", expected: 1234.56, type: .expense),
    Seed(name: "O当零", text: "账单\n实付 ¥1O0.00", amount: "1O0.00", expected: 100.00, type: .expense),
    Seed(name: "零元订单", text: "兑换成功\n实付 ¥0.00\n积分抵扣", amount: "0.00", expected: 0.00, type: .expense),
    Seed(name: "无锚点多候选", text: "账单\n商品 120.00\n运费 120.50", amount: "120.00", expected: 120.00, type: .expense),
    Seed(name: "收款词干扰", text: "已转账 500.00 给张三\n对方已收款", amount: "500.00", expected: 500.00, type: .expense),
    Seed(name: "转账无负号", text: "转账给 张三 500.00", amount: "500.00", expected: 500.00, type: .expense),
    Seed(name: "备选不吞近邻", text: "账单\n实付 100.00\n商品 100.30", amount: "100.00", expected: 100.00, type: .expense),
    Seed(name: "还款", text: "还款成功\n本期应还 2,000.00\n花呗", amount: "2,000.00", expected: 2000.00, type: .expense),
]

var pass = 0, fail = 0
var fails: [String] = []

func ok(_ cond: Bool, _ label: String) {
    if cond { pass += 1 }
    else { fail += 1; if fails.count < 12 { fails.append(label) } }
}

func fw(_ s: String) -> String {
    var o = ""
    for ch in s {
        if let a = ch.asciiValue, a >= 48, a <= 57 { o.append(Character(UnicodeScalar(0xFF10 + UInt32(a - 48))!)) }
        else if ch == "." { o.append("．") }
        else if ch == "," { o.append("，") }
        else if ch == "¥" { o.append("￥") }
        else { o.append(ch) }
    }
    return o
}
func hw(_ s: String) -> String {
    var o = ""
    for ch in s {
        if let v = ch.unicodeScalars.first?.value, v >= 0xFF10, v <= 0xFF19 { o.append(Character(UnicodeScalar(v - 0xFF10 + 48)!)) }
        else if ch == "．" { o.append(".") }
        else if ch == "，" { o.append(",") }
        else if ch == "￥" { o.append("¥") }
        else { o.append(ch) }
    }
    return o
}

// 1) 金标准（金额 + 收支 + 档位 + 零元标记，四项一起判，缺一项就测不出降级 bug）
let expectTier: [String: AmountTier] = [
    "微信转账": .medium, "充电宝押金": .medium, "红包收入": .medium,
    "两笔实付": .medium, "零元订单": .high, "转账无负号": .medium, "收款词干扰": .high, "无锚点多候选": .medium
]
let expectZero: Set<String> = ["零元订单"]
for s in seeds {
    let r = BillParser.parse(text: s.text)
    let want = expectTier[s.name] ?? .high
    ok(abs(r.amount - s.expected) < 0.005, "GOLD \(s.name) 金额得 \(r.amount)")
    ok(r.type == s.type, "GOLD \(s.name) 收支得 \(r.type.rawValue)")
    ok(r.amountTier == want, "GOLD \(s.name) 档位得 \(r.amountTier.rawValue) 期望 \(want.rawValue)")
    ok(r.zeroPaid == expectZero.contains(s.name), "GOLD \(s.name) zeroPaid=\(r.zeroPaid)")
    if s.name == "签购单小费" {
        ok(r.alternatives.count == 2, "GOLD 签购单备选数量=\(r.alternatives.count)")
    }
    if s.name == "无锚点多候选" {
        ok(r.alternatives.contains { abs($0 - 120.50) < 0.005 }, "GOLD 无锚点备选 \(r.alternatives)")
    }
    if s.name == "备选不吞近邻" {
        ok(r.alternatives.contains { abs($0 - 100.30) < 0.005 }, "GOLD 备选被吞 \(r.alternatives)")
    }
}

// 1b) 几何路径
runGeo()

// 2) 蜕变
for s in seeds {
    let base = BillParser.parse(text: s.text)
    func same(_ t: String, _ tag: String) {
        let m = BillParser.parse(text: t)
        let good = abs(m.amount - base.amount) < 0.005 && m.type == base.type
        if !good {
            // 失败时把两边的「喂进解析器的行」打出来：MR 不成立要么是行不一样，
            // 要么是同样的行得出了不同结论，这两种原因的修法完全不同
            func rows(_ x: String) -> [String] {
                x.components(separatedBy: .newlines)
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                    .filter { !$0.isEmpty }
            }
            let a = rows(s.text), b = rows(t)
            print("DBG \(s.name)/\(tag) base=\(base.amount) got=\(m.amount) 行数 \(a.count)→\(b.count) 行相同=\(a == b)")
            if a != b {
                print("DBG   base: \(a)")
                print("DBG   mut : \(b)")
            }
        }
        ok(good, "MR \(s.name)/\(tag) 得 \(m.amount)")
    }
    same(fw(s.text), "T1全角")
    var lines = s.text.components(separatedBy: "\n")
    lines.insert("订单号 202411060001234567", at: 0)
    lines.append("客服电话 400-820-8820")
    same(lines.joined(separator: "\n"), "T2噪声")
    same(s.text.replacingOccurrences(of: s.amount, with: "¥" + s.amount), "T3加¥")
    same(s.text.replacingOccurrences(of: s.amount, with: s.amount + " 元"), "T3加元")
    same(s.text.replacingOccurrences(of: s.amount, with: "￥" + s.amount), "T3全角¥")
    same(s.text.components(separatedBy: "\n").map { "   " + $0 + "\t " }.joined(separator: "\r\n"), "T4空白")
    same(s.text + "\n支付成功", "T5尾注")
    same(s.text + "\n" + s.text, "T6重复")
    same(hw(s.text), "T7半角")
}

// 3) 随机不变量（轻量版，只为覆盖广度）
struct LCG {
    var s: UInt64
    init(_ seed: UInt64) { s = seed &+ 0x9E3779B97F4A7C15 }
    mutating func next() -> UInt64 {
        s = s &* 6364136223846793005 &+ 1442695040888963407
        var z = s
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
    mutating func int(_ n: Int) -> Int { Int(next() % UInt64(max(1, n))) }
    mutating func chance(_ p: Int) -> Bool { int(100) < p }
    mutating func pick<T>(_ a: [T]) -> T { a[int(a.count)] }
}

let fuzzTemplates = [
    "微信支付\n转账给 {M}\n-{A}\n零钱", "账单详情\n{M}\n-{A}\n交易成功",
    "{M}\n可乐 {B}\n面包 {C}\n合计 {A}", "门诊缴费\n{M}\n总金额 {B}\n个人自费 {A}",
    "签购单\n商户名称 {M}\n消费金额 {A}\n小费 {C}\n交易金额 {B}",
    "信用卡账单\n{M}\n本期应还 {A}\n最低还款 {C}", "订单已完成\n{M}\n实付 ¥{A}",
    "本次行程 {A} 元\n{M}\n已支付", "共享充电宝\n{M}\n押金 {A}\n归还后原路退回",
    "收到红包 ¥{A}\n{M}", "电子发票\n{M}\n合　计 ¥{A}", "转账至 {M} ¥{A}",
    "外卖订单\n{M}\n商品小计 {B}\n配送费 {C}\n实付 {A}", "超市小票\n{M}\n合计 {A}\n找零 {C}",
    "{M}\n{A}", "支付成功 ¥{A}",
]
let fuzzMerchants = ["星巴克","全家便利店","滴滴出行","瑞幸咖啡","美团外卖","盒马鲜生","海底捞","中国移动","市第一医院","张三","李四"]
let fuzzNoise = ["订单号 202411060001234567","客服电话 400-820-8820","交易单号 420000123420241106","打印时间 2024-11-06 08:39:16","流水号 0011"]

func fmtMoney(_ v: Double) -> String {
    let cents = Int((v * 100).rounded())
    return String(cents / 100) + "." + String(format: "%02d", abs(cents % 100))
}

func numsIn(_ text: String) -> [Double] {
    var t = hw(text)
    t = t.replacingOccurrences(of: "O", with: "0")
    var out: [Double] = []
    let chars = Array(t)
    var i = 0
    while i < chars.count {
        if chars[i].isNumber {
            var j = i
            while j < chars.count, chars[j].isNumber || chars[j] == "." || chars[j] == "," || chars[j] == " " { j += 1 }
            var s = String(chars[i..<j]).trimmingCharacters(in: .whitespaces)
            s = s.replacingOccurrences(of: ",", with: "")
            s = s.replacingOccurrences(of: " ", with: "")
            if let v = Double(s) { out.append(v) }
            if let v = Double(String(chars[i..<j]).trimmingCharacters(in: .whitespaces).replacingOccurrences(of: " ", with: "")) { out.append(v) }
            i = j
        } else { i += 1 }
    }
    return out
}

var rng = LCG(20241106)
for _ in 0..<400 {
    var a = rng.pick([0.5, 3.5, 12.0, 28.6, 45.0, 99.0, 128.0, 320.0, 1234.56, 8888.88])
    if rng.chance(40) { a = Double(rng.int(99999)) / 100.0 }
    let b = a * Double(rng.int(3) + 2)
    let c = (a * 0.1 * 100).rounded() / 100
    var text = rng.pick(fuzzTemplates)
    var amtText = fmtMoney(a)
    if rng.chance(25) { amtText = fw(amtText) }
    text = text.replacingOccurrences(of: "{A}", with: amtText)
    text = text.replacingOccurrences(of: "{B}", with: fmtMoney(b))
    text = text.replacingOccurrences(of: "{C}", with: fmtMoney(c))
    text = text.replacingOccurrences(of: "{M}", with: rng.pick(fuzzMerchants))
    if rng.chance(40) {
        var ls = text.components(separatedBy: "\n")
        ls.insert(rng.pick(fuzzNoise), at: rng.int(ls.count + 1))
        text = ls.joined(separator: "\n")
    }
    let r = BillParser.parse(text: text)
    ok(r.amount.isFinite && r.amount >= 0, "FZ金额非法 \(r.amount)")
    ok(r.confidence >= 0 && r.confidence <= 1, "FZ置信度 \(r.confidence)")
    ok(r.alternatives.allSatisfy { $0.isFinite && $0 >= 0 }, "FZ备选 \(r.alternatives)")
    if r.amount > 0 {
        let cands = numsIn(text)
        ok(cands.contains { abs($0 - r.amount) < 0.005 }, "FZ幻觉金额 \(r.amount) 原文 \(text.replacingOccurrences(of: "\n", with: "⏎"))")
    }
    ok(abs(BillParser.parse(text: text).amount - r.amount) < 1e-9, "FZ不确定")
}

print("RESULT pass=\(pass) fail=\(fail)")
for f in fails { print("  · \(f)") }
exit(fail == 0 ? 0 : 1)
