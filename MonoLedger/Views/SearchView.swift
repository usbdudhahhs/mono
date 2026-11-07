//
//  SearchView.swift
//  MonoLedger
//
//  搜索：备注、分类、金额、日期都能找，对账时最常用的是金额
//

import SwiftUI
import SwiftData

struct SearchView: View {
    @Environment(\.dismiss) private var dismiss

    @Query(filter: Bill.activeFilter,
           sort: [SortDescriptor(\Bill.date, order: .reverse),
                  SortDescriptor(\Bill.createdAt, order: .reverse)])
    private var allBills: [Bill]

    @State private var query = ""
    @State private var selected: Bill?
    @FocusState private var focused: Bool

    private var keyword: String {
        query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private var results: [Bill] {
        guard !keyword.isEmpty else { return [] }
        return allBills.filter { matches($0) }
    }

    private func matches(_ bill: Bill) -> Bool {
        if bill.title.lowercased().contains(keyword) { return true }
        if bill.note.lowercased().contains(keyword) { return true }
        if bill.category.name.lowercased().contains(keyword) { return true }
        if bill.reimbursement.title.contains(keyword) { return true }
        if bill.type.title.contains(keyword) { return true }
        // 金额：输入 152 能命中 152.27，输入 152.27 也命中
        if Fmt.money(bill.amount).contains(keyword) { return true }
        if String(format: "%.2f", bill.amount).contains(keyword) { return true }
        // 日期：支持「10月18」「2026/10/18」「2026-10-18」这类写法
        if Dates.fullDate(bill.date).contains(keyword) { return true }
        if Dates.fullDate(bill.date).contains(keyword.replacingOccurrences(of: "-", with: "/")) { return true }
        if Dates.shortDate(bill.date).contains(keyword) { return true }
        return false
    }

    // 汇总要和下面每行显示的数字对得上：行里写的是 amount，
    // 这里就不能用 accountingAmount（已报销的会被算成 0），
    // 否则搜出三笔各 100、汇总只有 200，对账时以为漏了一笔
    private var totalExpense: Double {
        results.filter { $0.type == .expense }.reduce(0) { $0 + $1.amount }
    }

    private var totalIncome: Double {
        results.filter { $0.type == .income }.reduce(0) { $0 + $1.amount }
    }

    // MARK: - Body

    var body: some View {
        VStack(spacing: 0) {
            searchBar

            if keyword.isEmpty {
                hint
            } else if results.isEmpty {
                EmptyStateView(title: "没找到",
                               detail: "换个关键词试试：备注里的字、分类名、金额的一截，或者「10月18」这样的日期",
                               symbol: "magnifyingglass")
                    .padding(.top, 40)
            } else {
                summary
                list
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(T.bg)
        .presentationDragIndicator(.visible)
        .onAppear {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { focused = true }
        }
        .sheet(item: $selected) { bill in
            RecordDetailView(bill: bill)
        }
    }

    // MARK: - 搜索框

    private var searchBar: some View {
        HStack(spacing: 10) {
            HStack(spacing: 7) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(T.text3)

                TextField("搜备注、分类、金额、日期", text: $query)
                    .font(.system(size: 14.5))
                    .foregroundStyle(T.text)
                    .focused($focused)
                    .submitLabel(.search)
                    .autocorrectionDisabled()

                if !query.isEmpty {
                    Button {
                        query = ""
                        focused = true
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 14))
                            .foregroundStyle(T.text3)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 11)
            .frame(height: 38)
            .background(T.fill, in: RoundedRectangle(cornerRadius: 11, style: .continuous))

            Button("取消") { dismiss() }
                .font(.system(size: 14.5))
                .foregroundStyle(T.text2)
        }
        .padding(.horizontal, T.hPadding)
        .padding(.top, 16)
        .padding(.bottom, 12)
    }

    // MARK: - 提示

    private var hint: some View {
        VStack(alignment: .leading, spacing: 14) {
            SectionLabel(text: "可以这样搜")

            VStack(spacing: 9) {
                sample("午饭", "备注里的字")
                sample("交通", "分类名")
                sample("152.27", "金额的一截")
                sample("待报销", "报销状态")
                sample("10月18", "日期")
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, T.hPadding)
        .padding(.top, 8)
    }

    private func sample(_ text: String, _ note: String) -> some View {
        Button {
            query = text
        } label: {
            HStack(spacing: 10) {
                Text(text)
                    .font(.system(size: 13.5, weight: .medium))
                    .foregroundStyle(T.text)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(T.fill, in: Capsule())

                Text(note)
                    .font(.system(size: 11.5))
                    .foregroundStyle(T.text3)

                Spacer(minLength: 0)
            }
        }
        .buttonStyle(.plain)
    }

    // MARK: - 结果

    private var summary: some View {
        HStack(spacing: 10) {
            Text("\(results.count) 笔")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(T.text)

            if totalExpense > 0 {
                Text("支 ¥" + Fmt.money(totalExpense))
                    .font(.system(size: 11.5))
                    .foregroundStyle(T.text2)
                    .monospacedDigit()
            }
            if totalIncome > 0 {
                Text("收 ¥" + Fmt.money(totalIncome))
                    .font(.system(size: 11.5))
                    .foregroundStyle(T.text2)
                    .monospacedDigit()
            }

            Spacer()
        }
        .padding(.horizontal, T.hPadding)
        .padding(.bottom, 8)
    }

    private var list: some View {
        ScrollView {
            VStack(spacing: 0) {
                ForEach(Array(results.enumerated()), id: \.element.id) { index, bill in
                    Button {
                        Haptic.tap()
                        focused = false
                        selected = bill
                    } label: {
                        row(bill)
                    }
                    .buttonStyle(.plain)

                    if index < results.count - 1 {
                        RowDivider(leading: 62)
                    }
                }
            }
            .background(T.card, in: RoundedRectangle(cornerRadius: T.cardRadius, style: .continuous))
            .padding(.horizontal, T.hPadding)
            .padding(.bottom, 24)
        }
        .scrollIndicators(.hidden)
        .scrollDismissesKeyboard(.immediately)
    }

    private func row(_ bill: Bill) -> some View {
        HStack(spacing: 11) {
            CategoryBadge(category: bill.category, size: 38)

            VStack(alignment: .leading, spacing: 2) {
                Text(bill.title)
                    .font(.system(size: 14.5, weight: .medium))
                    .foregroundStyle(T.text)
                    .lineLimit(1)

                HStack(spacing: 5) {
                    Text(Dates.shortDate(bill.date))
                    Text("·")
                    Text(bill.category.name)
                    if bill.reimbursement != .none {
                        Text("·")
                        Text(bill.reimbursement.title)
                            .foregroundStyle(bill.reimbursement.tint)
                    }
                }
                .font(.system(size: 10.5))
                .foregroundStyle(T.text3)
                .lineLimit(1)
            }

            Spacer(minLength: 6)

            Text(bill.signedAmountText)
                .font(.system(size: 14.5, weight: .medium))
                .foregroundStyle(bill.type == .expense ? T.text : T.green)
                .monospacedDigit()
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 13)
    }
}
