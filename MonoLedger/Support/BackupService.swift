//
//  BackupService.swift
//  MonoLedger
//
//  全量备份：账单 + 凭证图 + 报销状态
//

import Foundation
import SwiftData
import UIKit

struct BillDTO: Codable {
    var uuid: String?
    var type: String?
    var amount: Double?
    var categoryID: String?
    var note: String?
    var date: Date?
    var reimbursement: String?
    var receipt: String?
    var createdAt: Date?
    /// 老备份里没有这两个字段，解码成 nil 时不启用待核对
    var needsReview: Bool?
    var reviewAlternatives: String?
    /// 回收站里的账单也要进备份：删掉不等于不要，
    /// 换机恢复后才发现少了几笔，那时原图已经找不回来了
    var deletedAt: Date?

    init(bill: Bill, includeReceipt: Bool = true) {
        uuid = bill.uuid
        type = bill.typeRaw
        amount = bill.amount
        categoryID = bill.categoryID
        note = bill.note
        date = bill.date
        reimbursement = bill.reimbursementRaw
        receipt = includeReceipt ? bill.receiptData.flatMap(BackupService.compressedReceiptBase64) : nil
        createdAt = bill.createdAt
        needsReview = bill.needsReview
        reviewAlternatives = bill.reviewAlternativesRaw.isEmpty ? nil : bill.reviewAlternativesRaw
        deletedAt = bill.deletedAt
    }

    var contentIdentityKey: String {
        let day = Int((date ?? Date(timeIntervalSince1970: 0)).timeIntervalSince1970 / 86_400)
        return "c:" + [type ?? "expense", String(format: "%.2f", amount ?? 0), note ?? "", String(day)].joined(separator: "|")
    }

    func makeBill() -> Bill {
        let rawType = (type ?? "expense").lowercased()
        let recordType: RecordType = ["income", "in", "收入"].contains(rawType) ? .income : .expense
        let reimbursementValue = ReimbursementState(rawValue: reimbursement ?? "none") ?? .none
        let rawAmount = amount ?? 0
        let safeAmount = rawAmount.isFinite ? max(0, rawAmount) : 0

        let bill = Bill(type: recordType,
                        amount: safeAmount,
                        categoryID: categoryID ?? (recordType == .income ? "moreIn" : "more"),
                        note: note ?? "",
                        date: date ?? Date(),
                        reimbursement: reimbursementValue,
                        receiptData: receipt.flatMap { Data(base64Encoded: $0) })
        bill.uuid = (uuid?.isEmpty == false) ? uuid! : UUID().uuidString
        bill.createdAt = createdAt ?? Date()
        bill.needsReview = needsReview ?? false
        bill.reviewAlternativesRaw = reviewAlternatives ?? ""
        bill.deletedAt = deletedAt
        return bill
    }
}

struct BackupPayload: Codable {
    var app: String
    var version: Int
    var exportedAt: Date
    var bills: [BillDTO]

    private enum CodingKeys: String, CodingKey { case app, version, exportedAt, bills, records }

    init(app: String = "MONO", version: Int = 2, exportedAt: Date = Date(), bills: [BillDTO] = []) {
        self.app = app
        self.version = version
        self.exportedAt = exportedAt
        self.bills = bills
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        app = try c.decodeIfPresent(String.self, forKey: .app) ?? "MONO"
        version = try c.decodeIfPresent(Int.self, forKey: .version) ?? 1
        exportedAt = try c.decodeIfPresent(Date.self, forKey: .exportedAt) ?? Date(timeIntervalSince1970: 0)
        bills = try c.decodeIfPresent([BillDTO].self, forKey: .bills)
            ?? c.decodeIfPresent([BillDTO].self, forKey: .records)
            ?? []
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(app, forKey: .app)
        try c.encode(version, forKey: .version)
        try c.encode(exportedAt, forKey: .exportedAt)
        try c.encode(bills, forKey: .bills)
    }
}

enum BackupError: LocalizedError {
    case invalidFormat
    case unsupportedApp(String)
    case unsupportedVersion(Int)
    case tooManyRecords

    var errorDescription: String? {
        switch self {
        case .invalidFormat: return "备份文件格式无法识别或已损坏。"
        case .unsupportedApp(let app): return "这不是 MONO 备份文件（来源：\(app)）。"
        case .unsupportedVersion(let version): return "备份版本 \(version) 高于当前支持版本，暂不能导入。"
        case .tooManyRecords: return "备份记录数量异常，已停止导入以保护现有数据。"
        }
    }
}

enum BackupService {
    enum Mode { case merge, replace }

    /// 恢复结果。分开报数是因为回收站里的账单不会出现在首页，
    /// 只说「恢复 20 条」而列表只多 18 条，用户会以为丢了数据。
    struct RestoreResult {
        var added: Int = 0
        var reactivated: Int = 0
        var trashed: Int = 0
        var total: Int { added + reactivated }
    }

    static func suggestedName(includeReceipts: Bool = true) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        let suffix = includeReceipts ? "" : "_无图"
        return "MONO备份_" + formatter.string(from: Date()) + suffix
    }

    /// 凭证图统一降采样后再转 base64。
    /// 原图动辄 300KB–1MB，base64 还要再涨三分之一；
    /// 压到长边 1200 / JPEG 0.62 后通常只剩一百多 KB，肉眼几乎看不出差别。
    static func compressedReceiptBase64(_ data: Data) -> String? {
        guard !data.isEmpty else { return nil }
        let raw = data.base64EncodedString()
        // 本来就小的图不再二次压缩，避免无谓的画质损失
        if data.count <= 200_000 { return raw }
        guard let image = UIImage(data: data), image.cgImage != nil else { return raw }
        // 与记账时同一条缩放路径：竖拍的图按 orientation 摆正，否则会压成横图
        let size = ReceiptStore.pixelSize(of: image)
        let pixelW = size.width, pixelH = size.height
        guard pixelW > 0, pixelH > 0 else { return raw }

        let scale = min(1, 1200 / max(pixelW, pixelH))
        let target = CGSize(width: max(1, (pixelW * scale).rounded()),
                            height: max(1, (pixelH * scale).rounded()))
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        format.opaque = true
        let rendered = UIGraphicsImageRenderer(size: target, format: format).image { ctx in
            // 不透明画布必须自己铺白底，否则带透明通道的 PNG 会被填成黑块
            UIColor.white.setFill()
            ctx.fill(CGRect(origin: .zero, size: target))
            image.draw(in: CGRect(origin: .zero, size: target))
        }
        guard let jpeg = rendered.jpegData(compressionQuality: 0.62),
              jpeg.count < data.count else { return raw }
        return jpeg.base64EncodedString()
    }

    static func encode(_ bills: [Bill], includeReceipts: Bool = true) throws -> Data {
        let payload = BackupPayload(bills: bills.map { BillDTO(bill: $0, includeReceipt: includeReceipts) })
        return try encode(payload)
    }

    /// 已经组装好的条目直接编码。界面层可以在后台线程先把凭证图压完，
    /// 再回到这里落 JSON，避免几十张图的重编码把主线程卡住。
    static func encode(_ bills: [BillDTO]) throws -> Data {
        try encode(BackupPayload(bills: bills))
    }

    private static func encode(_ payload: BackupPayload) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(payload)
    }

    static func decode(_ data: Data) throws -> BackupPayload {
        let strategies: [JSONDecoder.DateDecodingStrategy] = [.iso8601, .deferredToDate, .secondsSince1970, .millisecondsSince1970]
        var lastError: Error?
        for strategy in strategies {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = strategy
            do {
                let payload = try decoder.decode(BackupPayload.self, from: data)
                guard payload.app == "MONO" || payload.app.isEmpty else { throw BackupError.unsupportedApp(payload.app) }
                guard payload.version <= 2 else { throw BackupError.unsupportedVersion(payload.version) }
                guard payload.bills.count <= 1_000_000 else { throw BackupError.tooManyRecords }
                return payload
            } catch let error as BackupError {
                throw error
            } catch {
                lastError = error
            }
        }

        // 最早期版本可能直接导出 BillDTO 数组，而非带 metadata 的对象。
        for strategy in strategies {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = strategy
            if let rows = try? decoder.decode([BillDTO].self, from: data) {
                guard rows.count <= 1_000_000 else { throw BackupError.tooManyRecords }
                return BackupPayload(version: 1, bills: rows)
            }
        }
        throw lastError ?? BackupError.invalidFormat
    }

    static func writeTempFile(_ data: Data, includeReceipts: Bool = true) -> URL? {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(suggestedName(includeReceipts: includeReceipts))
            .appendingPathExtension("json")
        do {
            try data.write(to: url, options: .atomic)
            return url
        } catch {
            return nil
        }
    }

    @discardableResult
    static func restore(_ payload: BackupPayload, mode: Mode, in context: ModelContext) throws -> RestoreResult {
        do {
            let existing = try context.fetch(FetchDescriptor<Bill>())
            switch mode {
            case .replace:
                for bill in existing { context.delete(bill) }
                for dto in payload.bills { context.insert(dto.makeBill()) }
                try context.save()
                var result = RestoreResult()
                result.added = payload.bills.count
                result.trashed = payload.bills.filter { $0.deletedAt != nil }.count
                return result

            case .merge:
                var knownUUIDs = Set(existing.compactMap { $0.uuid.isEmpty ? nil : $0.uuid })
                var knownContentKeys = Set(existing.map { bill -> String in
                    let day = Int(bill.date.timeIntervalSince1970 / 86_400)
                    return "c:" + [bill.typeRaw, String(format: "%.2f", bill.amount), bill.note, String(day)].joined(separator: "|")
                })
                let legacyContentKeys = Set(existing.filter { $0.uuid.isEmpty }.map { bill -> String in
                    let day = Int(bill.date.timeIntervalSince1970 / 86_400)
                    return "c:" + [bill.typeRaw, String(format: "%.2f", bill.amount), bill.note, String(day)].joined(separator: "|")
                })

                // 回收站里的账单按 uuid 建索引：恢复备份时要把它们捞回来，
                // 否则用户会看到「备份里明明有，恢复完却少了一笔」
                var trashedByUUID: [String: Bill] = [:]
                for bill in existing where bill.deletedAt != nil && !bill.uuid.isEmpty {
                    trashedByUUID[bill.uuid] = bill
                }

                var added = 0
                var reactivated = 0
                var trashedIncoming = 0
                for dto in payload.bills {
                    let contentKey = dto.contentIdentityKey
                    if let uuid = dto.uuid, !uuid.isEmpty {
                        // UUID 精确去重；仅当本机旧记录没有 UUID 时才退回内容键。
                        if knownUUIDs.contains(uuid) || legacyContentKeys.contains(contentKey) {
                            if let trashed = trashedByUUID[uuid] {
                                trashed.deletedAt = nil
                                trashedByUUID.removeValue(forKey: uuid)
                                reactivated += 1
                            }
                            continue
                        }
                    } else if knownContentKeys.contains(contentKey) {
                        continue
                    }

                    context.insert(dto.makeBill())
                    if dto.deletedAt != nil { trashedIncoming += 1 }
                    if let uuid = dto.uuid, !uuid.isEmpty { knownUUIDs.insert(uuid) }
                    knownContentKeys.insert(contentKey)
                    added += 1
                }
                try context.save()
                return RestoreResult(added: added, reactivated: reactivated, trashed: trashedIncoming)
            }
        } catch {
            context.rollback()
            throw error
        }
    }
}
