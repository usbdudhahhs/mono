import Foundation

enum RecordType: String { case expense, income
    var sign: String { self == .expense ? "-" : "+" }
    var title: String { self == .expense ? "支出" : "收入" }
}
struct Category { let id: String; let name: String }
enum Catalog {
    static let ids: Set<String> = ["food","transport","shopping","home","fun","health","study","social","digital","pet","travel","beauty","clothes","car","part","more","refund","moreIn","salary","bonus"]
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
