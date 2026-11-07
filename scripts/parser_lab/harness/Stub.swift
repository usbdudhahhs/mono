import Foundation
// CGRect 的类型本身由 Foundation 带出来（CoreFoundation），但 midY / width 这些成员
// 是 CoreGraphics overlay 里的 extension。只 import Foundation 时，类型认得、成员不认，
// 编译会报 “value of type 'CGRect' has no member 'midY'”。
// App 里因为有 import UIKit 顺带引入了 CoreGraphics，所以这个问题只在脚手架暴露。
import CoreGraphics

enum RecordType: String { case expense, income
    var sign: String { self == .expense ? "-" : "+" }
    var title: String { self == .expense ? "支出" : "收入" }
}
struct Category { let id: String; let name: String }
enum Catalog {
    /// 必须与 MonoLedger/Models/Category.swift 完全一致。
    /// 之前这里是另一套词（transport / shopping / pet / travel …），
    /// 谁要是拿它做断言，测试就会在错的词表上判通过。scripts/selfcheck.py 会盯这一行。
    static let ids: Set<String> = [
        // 支出
        "food", "transit", "shop", "fun", "home", "health", "study", "social", "phone", "more",
        // 收入
        "salary", "bonus", "invest", "part", "red", "refund", "claim", "giftIn", "moreIn"
    ]
    static func find(_ t: RecordType, _ id: String) -> Category { Category(id: id, name: id) }
}
enum Fmt { static func money(_ v: Double) -> String { String(format: "%.2f", v) } }
struct OCRLine: Identifiable {
    let id = UUID()
    let text: String
    let confidence: Float
    let height: CGFloat
    let box: CGRect
    func isLarge(comparedTo maxHeight: CGFloat) -> Bool { maxHeight > 0 && height / maxHeight > 0.72 }
}
enum Dates {
    static func addDays(_ d: Date, _ n: Int) -> Date { Calendar.current.date(byAdding: .day, value: n, to: d) ?? d }
    static func days(from: Date, to: Date) -> Int { Calendar.current.dateComponents([.day], from: from, to: to).day ?? 0 }
}
