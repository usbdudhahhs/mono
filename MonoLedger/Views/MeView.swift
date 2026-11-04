//
//  MeView.swift
//  MonoLedger
//
//  我的：本月概览、预算、主题、导出
//

import SwiftUI
import SwiftData

struct MeView: View {
    @Environment(\.modelContext) private var context

    @Query private var bills: [Bill]

    @AppStorage("mono.budget") private var budget: Double = 6000
    @AppStorage("mono.theme") private var themeMode: String = "system"

    @State private var showBudgetAlert = false
    @State private var budgetText = ""
    @State private var showClearConfirm = false
    @State private var meSheet: MeSheet?
    @State private var toastText: String?

    // MARK: - 数据

    private var monthBills: [Bill] {
        bills.filter { Dates.inMonth($0.date, Date()) }
    }

    private var expense: Double {
        monthBills.filter { $0.type == .expense }.reduce(0) { $0 + $1.accountingAmount }
    }

    private var pendingBills: [Bill] {
        bills.filter { $0.type == .expense && $0.reimbursement == .pending }
    }

    private var pendingTotal: Double {
        pendingBills.reduce(0) { $0 + $1.amount }
    }

    private var income: Double {
        monthBills.filter { $0.type == .income }.reduce(0) { $0 + $1.amount }
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
                menuList
                Text("MONO 记账 · 1.0.0\n数据存储在本机，不上传服务器")
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
        .sheet(item: $meSheet) { route in
            switch route {
            case .scan:
                ScanView { message in showToast(message) }
            case .guide:
                ShortcutGuideView()
            case .reimburse:
                NavigationStack { ReimburseListView() }
            case .share(let url):
                ShareSheet(items: [url])
            }
        }
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
        var csv = "日期,类型,分类,金额,账户,报销,备注\n"
        let sorted = bills.sorted { $0.date > $1.date }
        for b in sorted {
            let note = b.note.replacingOccurrences(of: ",", with: "，")
            csv += "\(Dates.fullDate(b.date)),\(b.type.title),\(b.category.name),\(String(format: "%.2f", b.amount)),\(b.account),\(b.reimbursement.title),\(note)\n"
        }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("MONO账单.csv")
        do {
            try csv.write(to: url, atomically: true, encoding: .utf8)
            meSheet = .share(url)
        } catch {
            showToast("导出失败")
        }
    }

    private func clearAll() {
        for b in bills { context.delete(b) }
        try? context.save()
        showToast("已清空")
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
    case share(URL)

    var id: String {
        switch self {
        case .scan:  return "scan"
        case .guide: return "guide"
        case .reimburse: return "reimburse"
        case .share(let url): return "share-\(url.absoluteString)"
        }
    }
}
