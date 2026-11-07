//
//  BillsView.swift
//  MonoLedger
//
//  账单首页：月份切换、本月支出、预算进度、按日分组的流水
//

import SwiftUI
import SwiftData

struct BillsView: View {
    @Environment(\.modelContext) private var context

    @Query(filter: Bill.activeFilter,
           sort: [SortDescriptor(\Bill.date, order: .reverse),
                  SortDescriptor(\Bill.createdAt, order: .reverse)])
    private var allBills: [Bill]

    @AppStorage("mono.budget") private var budget: Double = 6000

    @State private var month: Date = Date()
    @State private var sheet: BillsSheet?
    @State private var toastText: String?
    @State private var saveError: String?

    // MARK: - 计算

    private var monthBills: [Bill] {
        allBills.filter { Dates.inMonth($0.date, month) }
    }

    private var totalExpense: Double {
        monthBills.filter { $0.type == .expense }.reduce(0) { $0 + $1.accountingAmount }
    }

    /// 已垫付、还没报销回来的钱
    private var pendingReimbursement: Double {
        monthBills.filter { $0.isPendingReimbursement }
            .reduce(0) { $0 + $1.amount }
    }

    /// 本月已经报销到账的钱
    private var doneReimbursement: Double {
        monthBills.filter { $0.type == .expense && $0.reimbursement == .done }
            .reduce(0) { $0 + $1.amount }
    }

    private var totalIncome: Double {
        monthBills.filter { $0.type == .income }.reduce(0) { $0 + $1.amount }
    }

    private var balance: Double { totalIncome - totalExpense }

    /// 截图识别出来、还没被人眼确认过的账单。
    /// 这是「识别错了也不会错账」的兜底：错的会被一直顶在首页最上面。
    private var reviewBills: [Bill] {
        allBills.filter { $0.needsReview }
    }

    private var groups: [(day: Date, items: [Bill])] {
        let dict = Dictionary(grouping: monthBills) {
            Calendar.current.startOfDay(for: $0.date)
        }
        return dict
            .map { (day: $0.key, items: $0.value.sorted { $0.createdAt > $1.createdAt }) }
            .sorted { $0.day > $1.day }
    }

    // MARK: - Body

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                monthBar
                    .padding(.top, 8)

                hero
                    .padding(.top, 26)

                if !reviewBills.isEmpty {
                    reviewBanner
                }

                if budget > 0 {
                    budgetBlock
                        .padding(.top, 22)
                }

                listBlock
                    .padding(.top, 26)
            }
            .padding(.horizontal, T.hPadding)
            .padding(.bottom, 30)
        }
        .scrollIndicators(.hidden)
        .background(T.bg)
        .toast($toastText)
        .alert("操作未保存", isPresented: Binding(get: { saveError != nil }, set: { if !$0 { saveError = nil } })) {
            Button("好", role: .cancel) { saveError = nil }
        } message: { Text(saveError ?? "请稍后重试。") }
        .sheet(item: $sheet) { route in
            switch route {
            case .add(let bill):
                if let bill {
                    AddRecordView(editing: bill)
                } else {
                    AddRecordView()
                }
            case .detail(let bill):
                RecordDetailView(bill: bill)
            case .scan:
                ScanView { message in showToast(message) }
            case .text:
                TextRecordSheet(allowsDirectSave: true,
                                onSaved: { message in showToast(message) })
            case .search:
                SearchView()
            case .reimburse:
                NavigationStack { ReimburseListView() }
            }
        }
    }

    // MARK: - 月份栏

    private var monthBar: some View {
        ZStack {
            HStack(spacing: 0) {
                Button {
                    withAnimation(.easeOut(duration: 0.2)) {
                        month = Dates.addMonths(month, -1)
                    }
                } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(T.text2)
                        .frame(width: 34, height: 30)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                Spacer()

                HStack(spacing: 2) {
                    Button {
                        withAnimation(.easeOut(duration: 0.2)) {
                            month = Dates.addMonths(month, 1)
                        }
                    } label: {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(Dates.isSameMonth(month, Date()) ? T.text3.opacity(0.4) : T.text2)
                            .frame(width: 34, height: 30)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(Dates.isSameMonth(month, Date()))

                    Button {
                        Haptic.tap()
                        sheet = .search
                    } label: {
                        Image(systemName: "magnifyingglass")
                            .font(.system(size: 13.5, weight: .semibold))
                            .foregroundStyle(T.text2)
                            .frame(width: 34, height: 30)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }

            Menu {
                ForEach(0..<6, id: \.self) { i in
                    let m = Dates.addMonths(Date(), -i)
                    Button {
                        withAnimation(.easeOut(duration: 0.2)) { month = m }
                    } label: {
                        Text(i == 0 ? "\(Dates.monthOnly(m))（本月）" : Dates.monthTitle(m))
                    }
                }
            } label: {
                HStack(spacing: 4) {
                    Text(Dates.monthTitle(month))
                        .font(.system(size: 14.5, weight: .semibold))
                        .foregroundStyle(T.text)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(T.text3)
                }
                .padding(.vertical, 4)
                .padding(.horizontal, 8)
                .contentShape(Rectangle())
            }
        }
        .frame(height: 32)
    }

    // MARK: - 主数字

    private var hero: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(doneReimbursement > 0 ? "本月实际支出" : "本月支出")
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(T.text2)
                .tracking(0.3)

            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text("¥")
                    .font(.system(size: 21, weight: .medium))
                    .foregroundStyle(T.text2)
                Text(Fmt.money(totalExpense))
                    .font(.system(size: 44, weight: .semibold))
                    .tracking(-1.8)
                    .foregroundStyle(T.text)
                    .contentTransition(.numericText())
                    .animation(.snappy(duration: 0.3), value: totalExpense)
            }
            .padding(.top, 4)
            .lineLimit(1)
            .minimumScaleFactor(0.6)

            HStack(spacing: 26) {
                miniStat("收入", Fmt.money(totalIncome))
                miniStat("结余", (balance < 0 ? "-¥" : "¥") + Fmt.money(abs(balance)))
                Spacer()

                HStack(spacing: 6) {
                    Button {
                        Haptic.tap()
                        sheet = .text
                    } label: {
                        heroChip(icon: "text.alignleft", title: "手记")
                    }
                    .buttonStyle(.plain)

                    Button {
                        Haptic.tap()
                        sheet = .scan
                    } label: {
                        heroChip(icon: "doc.text.viewfinder", title: "识别")
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.top, 16)

            if pendingReimbursement > 0 || doneReimbursement > 0 {
                HStack(spacing: 7) {
                    if pendingReimbursement > 0 {
                        Button {
                            Haptic.tap()
                            sheet = .reimburse
                        } label: {
                            reimbChip("待报销 ¥" + Fmt.money(pendingReimbursement),
                                      tint: ReimbursementState.pending.tint)
                        }
                        .buttonStyle(.plain)
                    }
                    if doneReimbursement > 0 {
                        Button {
                            Haptic.tap()
                            sheet = .reimburse
                        } label: {
                            reimbChip("已报销 ¥" + Fmt.money(doneReimbursement),
                                      tint: ReimbursementState.done.tint)
                        }
                        .buttonStyle(.plain)
                    }
                    Spacer()
                }
                .padding(.top, 10)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// 识别待核对：只做一件事 —— 让人一眼看到、一下点进去
    private var reviewBanner: some View {
        Button {
            Haptic.tap()
            if let first = reviewBills.first { sheet = .detail(first) }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "exclamationmark.circle.fill")
                    .font(.system(size: 15))
                    .foregroundStyle(T.orange)

                VStack(alignment: .leading, spacing: 1) {
                    Text("\(reviewBills.count) 笔截图识别待核对")
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(T.text)
                    Text("金额没十足把握，点进去对一眼")
                        .font(.system(size: 10.5))
                        .foregroundStyle(T.text3)
                }

                Spacer()

                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(T.text3)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 11)
            .background(T.orange.opacity(0.10), in: RoundedRectangle(cornerRadius: 13, style: .continuous))
        }
        .buttonStyle(.plain)
        .padding(.top, 16)
    }

    private func heroChip(icon: String, title: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
                .font(.system(size: 11.5, weight: .semibold))
            Text(title)
                .font(.system(size: 11.5, weight: .medium))
        }
        .foregroundStyle(T.text2)
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(T.grouped, in: Capsule())
    }

    private func reimbChip(_ text: String, tint: Color) -> some View {
        HStack(spacing: 4) {
            Circle().fill(tint).frame(width: 4, height: 4)
            Text(text)
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(tint)
                .monospacedDigit()
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(tint.opacity(0.11), in: Capsule())
    }

    private func miniStat(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.system(size: 10.5))
                .foregroundStyle(T.text3)
            Text(value)
                .font(.system(size: 13.5, weight: .medium))
                .foregroundStyle(T.text)
                .monospacedDigit()
        }
    }

    // MARK: - 预算

    private var budgetBlock: some View {
        let used = totalExpense / budget
        let over = totalExpense > budget
        return VStack(spacing: 8) {
            HStack {
                Text("月预算")
                    .font(.system(size: 11.5))
                    .foregroundStyle(T.text2)
                Spacer()
                Text(over
                     ? "超支 ¥\(Fmt.money(totalExpense - budget))"
                     : "剩余 ¥\(Fmt.money(budget - totalExpense))")
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(over ? T.red : T.text2)
            }
            ProgressLine(progress: used, tint: over ? T.red : T.text, height: 4)
            HStack {
                Text("¥\(Fmt.money0(budget)) 预算")
                    .font(.system(size: 10.5))
                    .foregroundStyle(T.text3)
                Spacer()
                Text("\(Int(min(used, 9.99) * 100))%")
                    .font(.system(size: 10.5))
                    .foregroundStyle(T.text3)
                    .monospacedDigit()
            }
        }
        .padding(.horizontal, 2)
    }

    // MARK: - 流水

    @ViewBuilder
    private var listBlock: some View {
        if groups.isEmpty {
            EmptyStateView(title: "这个月还没有账单",
                           detail: "点中间的 + 记下第一笔",
                           symbol: "tray")
        } else {
            VStack(spacing: 16) {
                ForEach(groups, id: \.day) { group in
                    VStack(spacing: 6) {
                        dayHeader(group.day, items: group.items)
                        GroupCard {
                            ForEach(group.items) { bill in
                                row(bill)
                                if bill.persistentModelID != group.items.last?.persistentModelID {
                                    RowDivider()
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    private func dayHeader(_ day: Date, items: [Bill]) -> some View {
        // 跟当天列表逐行显示的数字保持一致：这里若扣掉已报销的，
        // 会出现「小计 100、下面两行各 100」的对不上
        let out = items.filter { $0.type == .expense }.reduce(0) { $0 + $1.amount }
        let income = items.filter { $0.type == .income }.reduce(0) { $0 + $1.amount }
        return HStack {
            Text(Dates.dayTitle(day))
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(T.text3)
            Spacer()
            if out > 0 {
                Text("支出 \(Fmt.money(out))")
                    .font(.system(size: 10.5))
                    .foregroundStyle(T.text3)
                    .monospacedDigit()
            } else if income > 0 {
                Text("收入 \(Fmt.money(income))")
                    .font(.system(size: 10.5))
                    .foregroundStyle(T.text3)
                    .monospacedDigit()
            }
        }
        .padding(.horizontal, 4)
    }

    private func row(_ bill: Bill) -> some View {
        Button {
            sheet = .detail(bill)
        } label: {
            HStack(spacing: 12) {
                ZStack(alignment: .bottomTrailing) {
                    CategoryBadge(category: bill.category, size: 38)
                    if bill.hasReceipt {
                        Image(systemName: "paperclip")
                            .font(.system(size: 7, weight: .bold))
                            .foregroundStyle(T.text2)
                            .frame(width: 14, height: 14)
                            .background(T.card, in: Circle())
                            .overlay(Circle().stroke(T.line, lineWidth: 0.6))
                            .offset(x: 3, y: 3)
                    }
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(bill.title)
                        .font(.system(size: 14.5, weight: .medium))
                        .foregroundStyle(T.text)
                        .lineLimit(1)
                    HStack(spacing: 0) {
                        Text(bill.category.name)
                            .foregroundStyle(T.text3)
                        if bill.type == .expense && bill.reimbursement != .none {
                            Text(" · ")
                                .foregroundStyle(T.text3)
                            Text(bill.reimbursement.title)
                                .foregroundStyle(bill.reimbursement.tint)
                        }
                    }
                    .font(.system(size: 11))
                    .lineLimit(1)
                }

                Spacer(minLength: 6)

                VStack(alignment: .trailing, spacing: 2) {
                    Text(bill.signedAmountText)
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(bill.reimbursement == .done ? T.text3 : T.text)
                        .strikethrough(bill.reimbursement == .done, color: T.text3)
                        .monospacedDigit()
                    if bill.reimbursement == .pending {
                        Text("垫付中")
                            .font(.system(size: 9.5))
                            .foregroundStyle(ReimbursementState.pending.tint)
                    }
                }
            }
            .padding(.vertical, 11)
            .padding(.horizontal, 13)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button {
                openEdit(bill)
            } label: {
                Label("编辑这一笔", systemImage: "pencil")
            }
            if bill.type == .expense && bill.reimbursement != .pending {
                Button {
                    markReimbursement(bill, .pending)
                } label: {
                    Label("标记为待报销", systemImage: "banknote")
                }
            }
            if bill.type == .expense && bill.reimbursement != .done {
                Button {
                    markReimbursement(bill, .done)
                } label: {
                    Label("标记为已报销", systemImage: "checkmark.circle")
                }
            }
            Button {
                duplicate(bill)
            } label: {
                Label("复制到今天", systemImage: "doc.on.doc")
            }
            Button(role: .destructive) {
                delete(bill)
            } label: {
                Label("移到回收站", systemImage: "trash")
            }
        }
    }

    // MARK: - 操作

    private func openEdit(_ bill: Bill) {
        // 等确认框收起再拉起面板，避免手势冲突
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
            sheet = .add(bill)
        }
    }

    private func markReimbursement(_ bill: Bill, _ state: ReimbursementState) {
        Haptic.tap()
        bill.reimbursement = state
        if let error = AppData.save(context) {
            saveError = error
        } else {
            showToast(state == .done ? "已标记报销到账" : "已标记待报销")
        }
    }

    private func duplicate(_ bill: Bill) {
        let copy = Bill(type: bill.type,
                        amount: bill.amount,
                        categoryID: bill.categoryID,
                        note: bill.note,
                        date: Date())
        context.insert(copy)
        if let error = AppData.save(context) {
            saveError = error
        } else {
            showToast("已复制到今天的账单")
        }
    }

    private func delete(_ bill: Bill) {
        if let error = Trash.move(bill, in: context) {
            saveError = error
        } else {
            showToast("已移到回收站，30 天内可找回")
        }
    }

    private func showToast(_ text: String) {
        withAnimation(.spring(duration: 0.3)) { toastText = text }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.7) {
            withAnimation(.easeOut(duration: 0.2)) { toastText = nil }
        }
    }
}

// MARK: - 面板路由

enum BillsSheet: Identifiable {
    case add(Bill?)
    case detail(Bill)
    case scan
    case text
    case search
    case reimburse

    var id: String {
        switch self {
        case .add(let bill):
            return "add-\(bill?.persistentModelID.hashValue ?? 0)"
        case .detail(let bill):
            return "detail-\(bill.persistentModelID.hashValue)"
        case .scan:
            return "scan"
        case .text:
            return "text"
        case .search:
            return "search"
        case .reimburse:
            return "reimburse"
        }
    }
}
