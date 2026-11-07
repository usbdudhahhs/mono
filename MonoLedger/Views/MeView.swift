//
//  MeView.swift
//  MonoLedger
//
//  我的：本月概览、预算、主题、导出
//

import SwiftUI
import SwiftData
import UIKit
import UniformTypeIdentifiers

struct MeView: View {
    @Environment(\.modelContext) private var context

    @Query(filter: Bill.activeFilter)
    private var bills: [Bill]

    /// 含回收站的查询，只用来数回收站里有几笔
    @Query private var everyBill: [Bill]

    @AppStorage("mono.budget") private var budget: Double = 6000
    @AppStorage("mono.theme") private var themeMode: String = "system"
    @AppStorage("mono.lastBackupAt") private var lastBackupAt: Double = 0

    @State private var showBudgetAlert = false
    @State private var budgetText = ""
    @State private var showClearConfirm = false
    @State private var meSheet: MeSheet?
    @State private var toastText: String?
    @State private var showImporter = false
    @State private var showExportOptions = false

    // MARK: - 数据

    private var monthBills: [Bill] {
        bills.filter { Dates.inMonth($0.date, Date()) }
    }

    private var expense: Double {
        monthBills.filter { $0.type == .expense }.reduce(0) { $0 + $1.accountingAmount }
    }

    private var pendingBills: [Bill] {
        bills.filter { $0.isPendingReimbursement }
    }

    private var pendingTotal: Double {
        pendingBills.reduce(0) { $0 + $1.amount }
    }

    private var income: Double {
        monthBills.filter { $0.type == .income }.reduce(0) { $0 + $1.amount }
    }

    /// 带凭证图的账单与总占用，用来回答「截图到底吃了多少内存」
    ///
    /// 要连回收站一起算：删掉的账单据还在库里，图片也还占着空间，
    /// 只报在用的那些，用户会以为清空回收站没效果
    private var receiptBills: [Bill] {
        everyBill.filter { $0.hasReceipt }
    }

    private var receiptBytes: Int {
        receiptBills.reduce(0) { $0 + ($1.receiptData?.count ?? 0) }
    }

    private var receiptSummary: String {
        guard !receiptBills.isEmpty else { return "暂无" }
        return "\(receiptBills.count) 张 · " + ReceiptStore.sizeText(receiptBytes)
    }

    private var trashed: [Bill] {
        everyBill
            .filter { $0.isInTrash }
            .sorted { ($0.deletedAt ?? .distantPast) > ($1.deletedAt ?? .distantPast) }
    }

    /// 页脚版本号直接从 Info.plist 读，不要在源码里写死。
    /// 之前这里写死成 2.0.5，工程里已经升到 2.0.6 了，用户看到的是过期版本号。
    private var versionText: String {
        let v = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        return "MONO 记账 · " + (v ?? "—")
    }

    private var themeLabel: String {
        switch themeMode {
        case "light": return "浅色"
        case "dark":  return "深色"
        default:      return "跟随系统"
        }
    }

    // MARK: - Body

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                overview
                if shouldRemindBackup { backupReminder }
                menuList
                Text("\(versionText)\n数据存储在本机，不上传服务器")
                    .font(.system(size: 10.5))
                    .foregroundStyle(T.text3)
                    .multilineTextAlignment(.center)
                    .lineSpacing(3)
                    .padding(.top, 8)
            }
            .padding(.horizontal, T.hPadding)
            .padding(.top, 6)
            .padding(.bottom, 30)
        }
        .scrollIndicators(.hidden)
        .background(T.bg)
        .navigationTitle("我的")
        .navigationBarTitleDisplayMode(.inline)
        .toast($toastText)
        .alert("设置月预算", isPresented: $showBudgetAlert) {
            TextField("金额", text: $budgetText)
                .keyboardType(.numberPad)
            Button("保存") {
                let v = Double(budgetText) ?? 0
                budget = max(0, v)
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("填 0 表示不设预算")
        }
        .confirmationDialog("清空所有数据？",
                            isPresented: $showClearConfirm,
                            titleVisibility: .visible) {
            Button("清空全部", role: .destructive) { clearAll() }
            Button("取消", role: .cancel) {}
        } message: {
            Text("账单会被全部删除，无法恢复。建议先导出备份。")
        }
        .confirmationDialog("导出备份", isPresented: $showExportOptions, titleVisibility: .visible) {
            Button("完整备份（含凭证图）") { exportBackup(includeReceipts: true) }
            Button("仅账目（体积最小）") { exportBackup(includeReceipts: false) }
            Button("取消", role: .cancel) {}
        } message: {
            Text("凭证图会压到长边 1200，一张截图约 100KB 上下。「仅账目」不含图片，几百 KB 就够。")
        }
        .fileImporter(isPresented: $showImporter,
                      allowedContentTypes: [.json],
                      allowsMultipleSelection: false) { result in
            handleImport(result)
        }
        .sheet(item: $meSheet) { route in
            switch route {
            case .scan:
                ScanView { message in showToast(message) }
            case .guide:
                ShortcutGuideView()
            case .reimburse:
                NavigationStack { ReimburseListView() }
            case .attachments:
                NavigationStack { AttachmentGalleryView() }
            case .trash:
                NavigationStack { TrashView() }
            case .share(let url):
                ShareSheet(items: [url])
            }
        }
    }

    // MARK: - 备份提醒

    private var daysSinceBackup: Int? {
        guard lastBackupAt > 0 else { return nil }
        let from = Date(timeIntervalSince1970: lastBackupAt)
        let days = Calendar.current.dateComponents([.day], from: from, to: Date()).day ?? 0
        return max(0, days)
    }

    /// 只在这两件事同时成立时提醒：有账单、且从未备份或已超过 7 天
    private var shouldRemindBackup: Bool {
        guard !bills.isEmpty else { return false }
        guard let days = daysSinceBackup else { return true }
        return days >= 7
    }

    private var backupReminder: some View {
        Button { showExportOptions = true } label: {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 13))
                    .foregroundStyle(T.orange)
                    .padding(.top, 1)

                VStack(alignment: .leading, spacing: 3) {
                    Text(daysSinceBackup == nil ? "还没有备份" : "该备份了")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(T.text)
                    Text(backupReminderDetail)
                        .font(.system(size: 12))
                        .foregroundStyle(T.text2)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 0)

                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(T.text3)
                    .padding(.top, 2)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 13)
            .background(T.grouped, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    private var backupReminderDetail: String {
        if let days = daysSinceBackup {
            return "上次导出在 \(days) 天前。免费签名 7 天一续，App 被删或重装，账本会一起消失。"
        }
        return "还没有导出过备份。数据只存在本机，删掉 App 就没了。"
    }

    // MARK: - 概览

    private var overview: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("本月结余")
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(T.text2)

            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(income - expense < 0 ? "-¥" : "¥")
                    .font(.system(size: 19, weight: .medium))
                    .foregroundStyle(T.text2)
                Text(Fmt.money(abs(income - expense)))
                    .font(.system(size: 34, weight: .semibold))
                    .tracking(-1.3)
                    .foregroundStyle(T.text)
                    .monospacedDigit()
                    .contentTransition(.numericText())
            }
            .padding(.top, 5)

            HStack(spacing: 24) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("支出")
                        .font(.system(size: 10.5))
                        .foregroundStyle(T.text3)
                    Text("¥" + Fmt.money0(expense))
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(T.text)
                        .monospacedDigit()
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text("收入")
                        .font(.system(size: 10.5))
                        .foregroundStyle(T.text3)
                    Text("¥" + Fmt.money0(income))
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(T.text)
                        .monospacedDigit()
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text("记录")
                        .font(.system(size: 10.5))
                        .foregroundStyle(T.text3)
                    Text("\(monthBills.count) 笔")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(T.text)
                        .monospacedDigit()
                }
                Spacer()
            }
            .padding(.top, 16)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 18)
        .padding(.horizontal, 16)
        .background(T.grouped, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    // MARK: - 列表

    private var menuList: some View {
        VStack(spacing: 12) {
            GroupCard {
                Button {
                    meSheet = .scan
                } label: {
                    MeRow(icon: "doc.text.viewfinder",
                          title: "识别账单",
                          value: "截图自动分类",
                          valueColor: T.text2,
                          showChevron: true)
                }
                .buttonStyle(.plain)

                RowDivider()

                Button {
                    meSheet = .guide
                } label: {
                    MeRow(icon: "bolt",
                          title: "快捷指令",
                          value: "截屏即记账",
                          valueColor: T.text2,
                          showChevron: true)
                }
                .buttonStyle(.plain)

                RowDivider()

                Button {
                    meSheet = .reimburse
                } label: {
                    MeRow(icon: "banknote",
                          title: "报销",
                          value: pendingBills.isEmpty
                                 ? "没有待报销"
                                 : "待报销 ¥" + Fmt.money0(pendingTotal),
                          valueColor: pendingBills.isEmpty ? T.text2 : ReimbursementState.pending.tint,
                          showChevron: true)
                }
                .buttonStyle(.plain)
            }

            GroupCard {
                Button {
                    budgetText = budget > 0 ? String(format: "%.0f", budget) : ""
                    showBudgetAlert = true
                } label: {
                    MeRow(icon: "target",
                          title: "月预算",
                          value: budget > 0 ? "¥" + Fmt.money0(budget) : "未设置",
                          valueColor: T.text2,
                          showChevron: true)
                }
                .buttonStyle(.plain)
            }

            GroupCard {
                Menu {
                    Button("跟随系统") { themeMode = "system" }
                    Button("浅色") { themeMode = "light" }
                    Button("深色") { themeMode = "dark" }
                } label: {
                    MeRow(icon: "circle.lefthalf.filled",
                          title: "外观",
                          value: themeLabel,
                          valueColor: T.text2,
                          showChevron: true)
                }

                RowDivider()

                Button {
                    exportCSV()
                } label: {
                    MeRow(icon: "square.and.arrow.up",
                          title: "导出账单",
                          value: "CSV",
                          valueColor: T.text2,
                          showChevron: true)
                }
                .buttonStyle(.plain)

                RowDivider()

                Button {
                    showExportOptions = true
                } label: {
                    MeRow(icon: "externaldrive",
                          title: "导出备份",
                          value: bills.isEmpty ? "暂无账单" : "\(bills.count) 笔",
                          valueColor: T.text2,
                          showChevron: true)
                }
                .buttonStyle(.plain)

                RowDivider()

                Button {
                    meSheet = .attachments
                } label: {
                    MeRow(icon: "photo.on.rectangle",
                          title: "凭证图",
                          value: receiptSummary,
                          valueColor: T.text2,
                          showChevron: true)
                }
                .buttonStyle(.plain)

                RowDivider()

                Button {
                    showImporter = true
                } label: {
                    MeRow(icon: "arrow.down.doc",
                          title: "从备份恢复",
                          value: "JSON",
                          valueColor: T.text2,
                          showChevron: true)
                }
                .buttonStyle(.plain)

                RowDivider()

                Button {
                    meSheet = .trash
                } label: {
                    MeRow(icon: "arrow.uturn.backward.circle",
                          title: "回收站",
                          value: trashed.isEmpty ? "空" : "\(trashed.count) 笔",
                          valueColor: T.text2,
                          showChevron: true)
                }
                .buttonStyle(.plain)

                RowDivider()

                Button {
                    showClearConfirm = true
                } label: {
                    MeRow(icon: "trash",
                          title: "清空所有数据",
                          value: "",
                          valueColor: T.text2,
                          showChevron: false,
                          titleColor: T.red)
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: - 操作

    private func exportCSV() {
        // 备注里的换行和逗号会把一行拆成两行，先压平再按 CSV 规矩加引号；
        // 开头补 BOM，否则 Windows 版 Excel / WPS 打开中文全是乱码
        func cell(_ raw: String) -> String {
            let flat = raw
                .replacingOccurrences(of: "\r", with: " ")
                .replacingOccurrences(of: "\n", with: " ")
                .replacingOccurrences(of: "\"", with: "”")
            return "\"" + flat + "\""
        }

        var csv = "\u{FEFF}日期,类型,分类,金额,报销,备注\n"
        let sorted = bills.sorted { $0.date > $1.date }
        for b in sorted {
            let row = [
                cell(Dates.fullDate(b.date)),
                cell(b.type.title),
                cell(b.category.name),
                cell(String(format: "%.2f", b.amount)),
                cell(b.reimbursement.title),
                cell(b.note)
            ]
            csv += row.joined(separator: ",") + "\n"
        }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("MONO账单.csv")
        do {
            try csv.write(to: url, atomically: true, encoding: .utf8)
            meSheet = .share(url)
        } catch {
            showToast("导出失败")
        }
    }

    private func exportBackup(includeReceipts: Bool) {
        // 回收站里的账单也要导：用户点了删除，不代表这笔账从未存在过，
        // 换机恢复时少几笔对不上，比多几笔更难查
        guard !everyBill.isEmpty else {
            showToast("还没有账单")
            return
        }
        showToast(includeReceipts ? "正在生成备份…" : "正在生成…")

        // 主线程只取不可变副本（Data 是值类型，跨线程安全），
        // 压缩凭证图 + 编码 JSON 都挪到后台：一百张图在主线程做要冻好几秒
        let snapshots: [(dto: BillDTO, receipt: Data?)] = everyBill.map { bill in
            (BillDTO(bill: bill, includeReceipt: false), bill.receiptData)
        }

        DispatchQueue.global(qos: .userInitiated).async {
            let dtos: [BillDTO] = snapshots.map { pair in
                var dto = pair.dto
                if includeReceipts, let data = pair.receipt {
                    dto.receipt = BackupService.compressedReceiptBase64(data)
                }
                return dto
            }

            let outcome: Result<URL, Error>
            do {
                let data = try BackupService.encode(dtos)
                if let url = BackupService.writeTempFile(data, includeReceipts: includeReceipts) {
                    outcome = .success(url)
                } else {
                    outcome = .failure(BackupError.invalidFormat)
                }
            } catch {
                outcome = .failure(error)
            }

            Task { @MainActor in
                switch outcome {
                case .success(let url):
                    lastBackupAt = Date().timeIntervalSince1970
                    meSheet = .share(url)
                case .failure:
                    showToast("备份生成失败")
                }
            }
        }
    }

    private func handleImport(_ result: Result<[URL], Error>) {
        switch result {
        case .failure:
            showToast("没有选择文件")

        case .success(let urls):
            guard let url = urls.first else { return }
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }

            do {
                let data = try Data(contentsOf: url)
                let payload = try BackupService.decode(data)
                let result = try BackupService.restore(payload, mode: .merge, in: context)
                if result.total == 0 {
                    showToast("没有新账单，都已存在")
                } else if result.trashed > 0 {
                    // 回收站里的记录不会出现在首页，得说清楚去了哪儿
                    showToast("已恢复 \(result.total) 条，其中 \(result.trashed) 条在回收站")
                } else {
                    showToast("已恢复 \(result.total) 条账单")
                }
            } catch {
                showToast("恢复失败：\(error.localizedDescription)")
            }
        }
    }

    private func clearAll() {
        for b in everyBill { context.delete(b) }
        if let error = AppData.save(context) {
            showToast("清空失败：\(error)")
        } else {
            showToast("已清空")
        }
    }

    private func showToast(_ text: String) {
        withAnimation(.spring(duration: 0.3)) { toastText = text }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) {
            withAnimation(.easeOut(duration: 0.2)) { toastText = nil }
        }
    }
}

// MARK: - 行

struct MeRow: View {
    let icon: String
    let title: String
    var value: String = ""
    var valueColor: Color = T.text2
    var showChevron: Bool = true
    var titleColor: Color = T.text

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(T.text2)
                .frame(width: 26, height: 26)
                .background(T.fill, in: RoundedRectangle(cornerRadius: 8, style: .continuous))

            Text(title)
                .font(.system(size: 14))
                .foregroundStyle(titleColor)

            Spacer()

            if !value.isEmpty {
                Text(value)
                    .font(.system(size: 12.5))
                    .foregroundStyle(valueColor)
                    .monospacedDigit()
            }

            if showChevron {
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(T.text3)
            }
        }
        .padding(.vertical, 12)
        .padding(.horizontal, 14)
        .contentShape(Rectangle())
    }
}

// MARK: - 面板路由

enum MeSheet: Identifiable {
    case scan
    case guide
    case reimburse
    case attachments
    case trash
    case share(URL)

    var id: String {
        switch self {
        case .scan:  return "scan"
        case .guide: return "guide"
        case .reimburse: return "reimburse"
        case .attachments: return "attachments"
        case .trash: return "trash"
        case .share(let url): return "share-\(url.absoluteString)"
        }
    }
}
