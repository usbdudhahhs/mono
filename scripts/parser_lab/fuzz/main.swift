import Foundation

// 确定性随机源：同一种子每次重跑完全一致，出问题能原样复现
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
    mutating func chance(_ pct: Int) -> Bool { int(100) < pct }
    mutating func pick<T>(_ a: [T]) -> T { a[int(a.count)] }
}

func money(_ v: Double) -> String {
    let cents = Int((v * 100).rounded())
    return String(cents / 100) + "." + String(format: "%02d", abs(cents % 100))
}

// 真实截图里出现过的版式骨架。{A} 是主金额，{B}/{C} 是陪衬数字
let templates: [String] = [
    "微信支付\n转账给 {M}\n-{A}\n零钱\n{T}",
    "账单详情\n{M}\n-{A}\n付款方式 余额宝\n交易成功",
    "{M}\n可乐 {B}\n面包 {C}\n合计 {A}\n微信支付",
    "门诊缴费\n{M}\n总金额 {B}\n个人自费 {A}",
    "签购单\n商户名称 {M}\n消费金额 {A}\n小费 {C}\n交易金额 {B}",
    "信用卡账单\n{M}\n本期应还 {A}\n最低还款 {C}",
    "订单已完成\n{M}\n实付 ¥{A}",
    "本次行程 {A} 元\n{M}\n已支付",
    "共享充电宝\n{M}\n押金 {A}\n归还后原路退回",
    "收到红包 ¥{A}\n{M}",
    "电子发票\n{M}\n合　计 ¥{A}",
    "转账至 {M} ¥{A}\n转账成功",
    "外卖订单\n{M}\n商品小计 {B}\n配送费 {C}\n实付 {A}",
    "超市小票\n{M}\n合计 {A}\n找零 {C}",
    "酒店账单\n{M}\n房费 {B}\n服务费 {C}\n应付总额 {A}",
    "{M}\n{A}",
    "支付成功 ¥{A}",
    "还款成功\n本期应还 {A}",
]

let merchants = ["星巴克", "全家便利店", "滴滴出行", "瑞幸咖啡", "美团外卖", "盒马鲜生",
                 "海底捞", "中国移动", "国家电网", "市第一医院", "华住酒店", "张三", "李四"]

let noise = ["订单号 202411060001234567", "客服电话 400-820-8820",
             "交易单号 4200001234202411061234567890", "商户编号 898110158110001",
             "地址 上海市浦东新区世纪大道 100 号", "打印时间 2024-11-06 08:39:16",
             "流水号 0011", "备注 无"]

// 全角化：真实 OCR 偶尔吐全角
func toFullWidth(_ s: String) -> String {
    var out = ""
    for ch in s {
        if let a = ch.asciiValue, a >= 48, a <= 57 {
            out.append(Character(UnicodeScalar(0xFF10 + UInt32(a - 48))!))
        } else if ch == "." {
            out.append("．")
        } else if ch == "," {
            out.append("，")
        } else {
            out.append(ch)
        }
    }
    return out
}

func mutateAmountText(_ a: String, _ rng: inout LCG) -> String {
    switch rng.int(6) {
    case 0: return "¥" + a
    case 1: return a + " 元"
    case 2: return "￥" + a
    case 3: return toFullWidth(a)
    case 4: return a.replacingOccurrences(of: ".", with: " . ")
    default: return a
    }
}

func render(_ tpl: String, _ rng: inout LCG) -> String {
    var a = rng.pick([0.01, 0.5, 3.5, 12.0, 28.6, 45.0, 99.0, 128.0, 320.0, 1234.56, 8888.88])
    if rng.chance(40) { a = Double(rng.int(99999)) / 100.0 }
    let b = a * Double(rng.int(3) + 2)
    let c = (a * 0.1 * 100).rounded() / 100
    var s = tpl
    s = s.replacingOccurrences(of: "{A}", with: mutateAmountText(money(a), &rng))
    s = s.replacingOccurrences(of: "{B}", with: money(b))
    s = s.replacingOccurrences(of: "{C}", with: money(c))
    s = s.replacingOccurrences(of: "{M}", with: rng.pick(merchants))
    s = s.replacingOccurrences(of: "{T}", with: "2024年11月6日 08:39")
    if rng.chance(45) {
        let n = rng.pick(noise)
        var ls = s.components(separatedBy: "\n")
        ls.insert(n, at: rng.int(ls.count + 1))
        s = ls.joined(separator: "\n")
    }
    if rng.chance(12) {
        s = s.components(separatedBy: "\n").map { "  " + $0 + "  " }.joined(separator: "\r\n")
    }
    return s
}

func esc(_ s: String) -> String {
    var o = ""
    for ch in s.unicodeScalars {
        switch ch {
        case "\"": o += "\\\""
        case "\\": o += "\\\\"
        case "\n": o += "\\n"
        case "\r": o += "\\r"
        case "\t": o += "\\t"
        default:
            if ch.value < 0x20 { o += String(format: "\\u%04x", ch.value) } else { o.unicodeScalars.append(ch) }
        }
    }
    return o
}

var rng = LCG(20241106)
let total = 3000
var out: [String] = []
out.reserveCapacity(total)

for i in 0..<total {
    let tpl = rng.pick(templates)
    var text = render(tpl, &rng)
    // 8% 喂纯垃圾，验证不崩
    if rng.chance(8) {
        let junk = ["", "   ", "!!!", "¥¥¥", "0.00", "-", "1.2.3.4", "金额：", "￥ ￥ 100",
                    "\u{200B}\u{200B}", "a1b2c3", "999999999999999999999", "1,2,3,4"]
        text = rng.pick(junk)
    }
    let t0 = Date()
    let r = BillParser.parse(text: text)
    let ms = Date().timeIntervalSince(t0) * 1000

    // 确定性：同输入再跑一次，结果必须一模一样
    let r2 = BillParser.parse(text: text)
    let deterministic = abs(r.amount - r2.amount) < 1e-9
        && r.type == r2.type && r.categoryID == r2.categoryID
        && r.amountTier == r2.amountTier && r.confidence == r2.confidence

    // 尾空白不变性：多两个换行不应改变金额
    let r3 = BillParser.parse(text: text + "\n\n")
    let trailingStable = abs(r.amount - r3.amount) < 1e-9

    let alt = r.alternatives.map { String(format: "%.10g", $0) }.joined(separator: ",")
    let line = "{\"i\":\(i),\"text\":\"\(esc(text))\",\"amount\":\(String(format: "%.10g", r.amount)),"
        + "\"tier\":\"\(r.amountTier.rawValue)\",\"type\":\"\(r.type.rawValue)\","
        + "\"cat\":\"\(r.categoryID)\",\"conf\":\(String(format: "%.10g", r.confidence)),"
        + "\"alts\":[\(alt)],\"ms\":\(String(format: "%.3f", ms)),"
        + "\"det\":\(deterministic),\"tail\":\(trailingStable),"
        + "\"zero\":\(r.zeroPaid)}"
    out.append(line)
}

print(out.joined(separator: "\n"))
