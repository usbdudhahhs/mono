//
//  AppData.swift
//  MonoLedger
//
//  全局数据容器
//  App 主界面与 App Intent（快捷指令）共用同一份 SwiftData 容器
//

import Foundation
import SwiftData

enum AppData {
    /// 懒加载，App 与 Intent 谁先用到都会创建同一个实例
    static let container: ModelContainer = {
        let schema = Schema([Bill.self])
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: false)
        do {
            return try ModelContainer(for: schema, configurations: [configuration])
        } catch {
            fatalError("无法创建数据容器：\(error)")
        }
    }()

    /// 写入一笔账单（供 Intent 调用，主线程执行）
    @MainActor
    static func insert(_ bill: Bill) throws {
        let context = container.mainContext
        context.insert(bill)
        try context.save()
    }
}
