//
//  ReimburseListView.swift
//  MonoLedger
//
//  报销：把垫付的钱和已经到账的钱放在一处看
//

import SwiftUI
import SwiftData

struct ReimburseListView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss

    @Query(filter: Bill.activeFilter,
           sort: [SortDescriptor(\Bill.date, order: .reverse)])
    private var allBills: [Bill]

    @State private var selected: Bill?
    @State private var toastText: String?
    @State private var showSettleConfirm = false

    // MARK: - 数据

    private var pending: [Bill] {
        allBills.filter { $0.isPendingReimbursement }
    }

    private var done: [Bill] {
        allBills.filter { $0.type == .expense && $0.reimbursement == .done }
    }

    private var pendingTotal: Double { pending.reduce(0) { $0 + $1.amount } }
    private var doneTotal: Double { done.reduce(0) { $0 + $1.amount } }

    // MARK: - Body

    var body: some View {
        ScrollView {
            VStack(spacing: 18) {
                summary

                if pending.isEmpty && done.isEmpty {
                    EmptyStateView(title: "还没有报销中的账单",
                                   detail: "记账时点「报销」，或长按账单标记为待报销",
                                   symbol: "banknote")
                        .padding(.top, 30)
                } else {
                    if !pending.isEmpty {
                        section(title: "待报销 · \(pending.count) 笔", bills: pending, isPending: true)
                    }
                    if !done.isEmpty {
                        section(title: "已报销 · \(done.count) 笔", bills: done, isPending: false)
                    }
                }
            }
            .padding(.horizontal, T.hPadding)
            .padding(.top, 6)
            .padding(.bottom, 30)
        }
        .scrollIndicators(.hidden)
        .background(T.bg)
        .navigationTitle("报销")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button("关闭") { dismiss() }
                    .foregroundStyle(T.text2)
            }
        }
        .toast($toastText)
        .confirmationDialog("把这 \(pending.count) 笔全部标记为已报销？",
                            isPresented: $showSettleConfirm,
                            titleVisibility: .visible) {
            Button("全部标记到账", role: .destructive) { settleAll() }
            Button("取消", role: .cancel) {}
        } message: {
            Text("标记后这些钱会从本月支出里扣除。要反悔，逐笔点左边的箭头改回待报销即可。")
        }
        .sheet(item: $selected) { bill in
            RecordDetailView(bill: bill)
        }
    }

    // MARK: - 汇总

    private var summary: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("待报销")
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(T.text2)

            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text("¥")
                    .font(.system(size: 19, weight: .medium))
                    .foregroundStyle(T.text2)
                Text(Fmt.money(pendingTotal))
                    .font(.system(size: 34, weight: .semibold))
                    .tracking(-1.3)
                    .foregroundStyle(T.text)
                    .monospacedDigit()
                    .contentTransition(.numericText())
            }
            .padding(.top, 5)

            HStack(spacing: 24) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("垫付笔数")
                        .font(.system(size: 10.5))
                        .foregroundStyle(T.text3)
                    Text("\(pending.count) 笔")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(T.text)
                        .monospacedDigit()
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text("已到账")
                        .font(.system(size: 10.5))
                        .foregroundStyle(T.text3)
                    Text("¥" + Fmt.money0(doneTotal))
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(T.text)
                        .monospacedDigit()
                }
                Spacer()
            }
            .padding(.top, 16)

            if pending.count > 1 {
                Button {
                    showSettleConfirm = true
                } label: {
                    Text("全部标记到账")
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundStyle(T.bg)
                        .frame(maxWidth: .infinity)
                        .frame(height: 38)
                        .background(T.text, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                }
                .buttonStyle(.plain)
                .padding(.top, 14)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 18)
        .padding(.horizontal, 16)
        .background(T.grouped, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    // MARK: - 分组

    private func section(title: String, bills: [Bill], isPending: Bool) -> some View {
        VStack(spacing: 7) {
            SectionLabel(text: title)

            GroupCard {
                ForEach(bills) { bill in
                    row(bill, isPending: isPending)
                    if bill.persistentModelID != bills.last?.persistentModelID {
                        RowDivider()
                    }
                }
            }
        }
    }

    private func row(_ bill: Bill, isPending: Bool) -> some View {
        HStack(spacing: 12) {
            Button {
                selected = bill
            } label: {
                HStack(spacing: 12) {
                    CategoryBadge(category: bill.category, size: 38)

                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 4) {
                            Text(bill.title)
                                .font(.system(size: 14.5, weight: .medium))
                                .foregroundStyle(T.text)
                                .lineLimit(1)
                            if bill.hasReceipt {
                                Image(systemName: "paperclip")
                                    .font(.system(size: 9.5, weight: .medium))
                                    .foregroundStyle(T.text3)
                            }
                        }
                        Text(Dates.shortDate(bill.date))
                            .font(.system(size: 11))
                            .foregroundStyle(T.text3)
                    }

                    Spacer(minLength: 6)

                    Text("¥" + Fmt.money(bill.amount))
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(isPending ? T.text : T.text3)
                        .strikethrough(!isPending, color: T.text3)
                        .monospacedDigit()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Button {
                toggle(bill, toPending: !isPending)
            } label: {
                Image(systemName: isPending ? "checkmark" : "arrow.uturn.backward")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(isPending ? ReimbursementState.done.tint : T.text3)
                    .frame(width: 30, height: 30)
                    .background(T.fill, in: Circle())
            }
            .buttonStyle(.plain)
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 13)
    }

    // MARK: - 操作

    private func toggle(_ bill: Bill, toPending: Bool) {
        Haptic.tap()
        withAnimation(.easeOut(duration: 0.2)) {
            bill.reimbursement = toPending ? .pending : .done
        }
        if let error = AppData.save(context) {
            showToast("保存失败：\(error)")
        } else {
            showToast(toPending ? "已退回待报销" : "已标记到账")
        }
    }

    private func settleAll() {
        Haptic.success()
        withAnimation(.easeOut(duration: 0.25)) {
            for bill in pending { bill.reimbursement = .done }
        }
        if let error = AppData.save(context) {
            showToast("保存失败：\(error)")
        } else {
            showToast("已全部标记到账")
        }
    }

    private func showToast(_ text: String) {
        withAnimation(.spring(duration: 0.3)) { toastText = text }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) {
            withAnimation(.easeOut(duration: 0.2)) { toastText = nil }
        }
    }
}
