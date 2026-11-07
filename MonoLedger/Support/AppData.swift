//
//  AppData.swift
//  MonoLedger
//
//  全局数据容器与统一保存入口
//

import Foundation
import SwiftData

extension Notification.Name {
    static let monoSaveFailed = Notification.Name("MonoLedger.saveFailed")
}

enum AppData {
    private static let bootstrap: (container: ModelContainer, warning: String?) = {
        let schema = Schema([Bill.self])
        let persistent = ModelConfiguration(schema: schema, isStoredInMemoryOnly: false)
        do {
            return (try ModelContainer(for: schema, configurations: [persistent]), nil)
        } catch {
            // 持久化容器损坏/不可用时仍允许打开应用；明确提示当前为临时内存模式。
            let message = "本机账本数据库暂时无法打开，当前进入临时模式。请先导出可用备份并联系支持。\n\(error.localizedDescription)"
            let memory = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
            do {
                return (try ModelContainer(for: schema, configurations: [memory]), message)
            } catch {
                // 两种容器均无法创建时，SwiftData 无可用容器，启动无法安全继续。
                fatalError("无法创建 MONO 数据容器（持久化与内存模式均失败）：\(error)")
            }
        }
    }()

    static let container: ModelContainer = bootstrap.container
    static var storageWarning: String? { bootstrap.warning }

    /// 统一保存入口：失败时回滚未提交变更，把错误文案交给调用方就地展示。
    /// 页面里的保存动作都应该走这里，避免各写一套 do/catch 时漏掉回滚。
    /// - Returns: 成功为 nil，失败为可直接展示的错误描述。
    @MainActor
    static func save(_ context: ModelContext) -> String? {
        do {
            try context.save()
            return nil
        } catch {
            context.rollback()
            return error.localizedDescription
        }
    }

    /// 统一保存入口（全局提示版）：失败时回滚并向根界面广播，由 RootView 弹窗。
    @MainActor
    @discardableResult
    static func saveSafely(_ context: ModelContext) -> Bool {
        guard let message = save(context) else { return true }
        NotificationCenter.default.post(
            name: .monoSaveFailed,
            object: nil,
            userInfo: ["message": message]
        )
        return false
    }

    @MainActor
    static func insert(_ bill: Bill) throws {
        let context = container.mainContext
        context.insert(bill)
        do {
            try context.save()
        } catch {
            context.rollback()
            NotificationCenter.default.post(
                name: .monoSaveFailed,
                object: nil,
                userInfo: ["message": error.localizedDescription]
            )
            throw error
        }
    }
}

// MARK: - 回收站

enum Trash {
    /// 保留天数。够把误删的一笔捞回来，又不会让账本越积越大
    static let retentionDays = 30

    /// 清掉超过保留期的账单。App 启动时跑一次，不必等用户点进回收站
    @MainActor
    static func purgeExpired(_ context: ModelContext) {
        guard let cutoff = Calendar.current.date(byAdding: .day,
                                                 value: -retentionDays,
                                                 to: Date()) else { return }

        // 只捞回收站里的：账本用了几年之后，正常账单是几万条，回收站可能只有几条，
        // 全表捞出来再在内存里挑，等于每次启动都白读一遍全集。
        // 时间比较仍放在内存里做 —— 谓词里做日期比较更省事，但一旦系统版本换了
        // 谓词翻译方式，失败会静默变成「一条都不清」，宁可多走一步保险
        let trashed = FetchDescriptor<Bill>(predicate: #Predicate<Bill> { $0.deletedAt != nil })
        guard let candidates = try? context.fetch(trashed) else { return }

        let expired = candidates.filter { bill in
            guard let deletedAt = bill.deletedAt else { return false }
            return deletedAt < cutoff
        }
        guard !expired.isEmpty else { return }

        for bill in expired { context.delete(bill) }
        _ = AppData.save(context)
    }

    /// 移到回收站
    @MainActor
    static func move(_ bill: Bill, in context: ModelContext) -> String? {
        bill.deletedAt = Date()
        return AppData.save(context)
    }
}
