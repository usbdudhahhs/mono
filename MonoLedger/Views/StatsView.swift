//
//  StatsView.swift
//  MonoLedger
//
//  统计：每日趋势、分类占比、排行
//

import SwiftUI
import SwiftData

struct StatsView: View {
    @Query(filter: Bill.activeFilter,
           sort: [SortDescriptor(\Bill.date, order: .reverse)])
    private var allBills: [Bill]

    @State private var month: Date = Date()
    @State private var type: RecordType = .expense

    // MARK: - 数据

    private var monthBills: [Bill] {
        allBills.filter { Dates.inMonth($0.date, month) && $0.type == type }
    }

    private var total: Double {
        monthBills.reduce(0) { $0 + $1.accountingAmount }
    }

    private var totalDays: Int { Dates.daysInMonth(month) }

    /// 已经报销回来的钱不算个人支出，统计里会被扣掉。
    /// 不说明的话，用户看到「共 5 笔支出 ¥200」而列表加起来 500，会以为算错了
    private var reimbursedOut: Double {
        guard type == .expense else { return 0 }
        return monthBills
            .filter { $0.reimbursement == .done }
            .reduce(0) { $0 + $1.amount }
    }

    private var shownDays: Int {
        if Dates.isSameMonth(month, Date()) {
            return min(Calendar.current.component(.day, from: Date()), totalDays)
        }
        return totalDays
    }

    private var dailyValues: [Double] {
        var values = Array(repeating: 0.0, count: totalDays + 1)
        for b in monthBills {
            let d = Calendar.current.component(.day, from: b.date)
            if d >= 1 && d <= totalDays { values[d] += b.accountingAmount }
        }
        return values
    }

    private var breakdown: [(category: Category, amount: Double)] {
        let dict = Dictionary(grouping: monthBills) { $0.categoryID }
        return dict
            .map { (category: Catalog.find(type, $0.key),
                    amount: $0.value.reduce(0) { $0 + $1.accountingAmount }) }
            .filter { $0.amount > 0 }
            .sorted { $0.amount > $1.amount }
    }

    private var segments: [(id: String, color: Color, start: Double, end: Double)] {
        let sum = max(total, 0.0001)
        var acc = 0.0
        var result: [(id: String, color: Color, start: Double, end: Double)] = []
        for item in breakdown {
            let s = acc
            let e = acc + item.amount / sum
            result.append((id: item.category.id, color: item.category.color, start: s, end: e))
            acc = e
        }
        return result
    }

    // MARK: - Body

    var body: some View {
        ScrollView {
            VStack(spacing: 22) {
                monthBar

                VStack(spacing: 12) {
                    SegmentedBar(items: RecordType.allCases, title: { $0.title }, selection: $type)
                        .frame(width: 168)
                        .frame(maxWidth: .infinity)

                    summary
                }

                barCard
                donutCard
                rankCard
            }
            .padding(.horizontal, T.hPadding)
            .padding(.top, 8)
            .padding(.bottom, 30)
        }
        .scrollIndicators(.hidden)
        .background(T.bg)
    }

    // MARK: - 月份

    private var monthBar: some View {
        HStack {
            Button {
                withAnimation(.easeOut(duration: 0.2)) { month = Dates.addMonths(month, -1) }
            } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(T.text2)
                    .frame(width: 34, height: 30)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Spacer()

            Text(Dates.monthTitle(month))
                .font(.system(size: 14.5, weight: .semibold))
                .foregroundStyle(T.text)

            Spacer()

            Button {
                withAnimation(.easeOut(duration: 0.2)) { month = Dates.addMonths(month, 1) }
            } label: {
                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Dates.isSameMonth(month, Date()) ? T.text3.opacity(0.4) : T.text2)
                    .frame(width: 34, height: 30)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(Dates.isSameMonth(month, Date()))
        }
        .padding(.top, 4)
    }

    // MARK: - 汇总

    private var summary: some View {
        VStack(spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text("¥")
                    .font(.system(size: 17, weight: .medium))
                    .foregroundStyle(T.text2)
                Text(Fmt.money(total))
                    .font(.system(size: 34, weight: .semibold))
                    .tracking(-1.3)
                    .foregroundStyle(T.text)
                    .monospacedDigit()
                    .contentTransition(.numericText())
                    .animation(.snappy(duration: 0.3), value: total)
            }
            HStack(spacing: 6) {
                Text(type == .expense ? "共 \(monthBills.count) 笔支出" : "共 \(monthBills.count) 笔收入")
                Text("·")
                Text("日均 ¥\(Fmt.money1(total / Double(max(shownDays, 1))))")
            }
            .font(.system(size: 11))
            .foregroundStyle(T.text3)

            if reimbursedOut > 0 {
                Text("已报销 ¥\(Fmt.money(reimbursedOut))，未计入")
                    .font(.system(size: 10.5))
                    .foregroundStyle(T.text3)
                    .padding(.top, 2)
            }
        }
    }

    // MARK: - 柱状图

    private var barCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionLabel(text: "每日趋势")
            barChart
                .frame(height: 104)
        }
        .cardStyle(padding: 14)
    }

    private var barChart: some View {
        let days = max(shownDays, 1)
        let spacing: CGFloat = days > 20 ? 3 : (days > 10 ? 6 : 10)
        let values = dailyValues
        let peak = max(values.max() ?? 0, 1)
        let todayDay = Calendar.current.component(.day, from: Date())
        let isCurrent = Dates.isSameMonth(month, Date())

        return GeometryReader { geo in
            let usable = geo.size.width - 4
            let barW = min(26, max(3, (usable - spacing * CGFloat(days - 1)) / CGFloat(days)))
            HStack(alignment: .bottom, spacing: spacing) {
                ForEach(1...days, id: \.self) { d in
                    VStack(spacing: 5) {
                        Spacer(minLength: 0)
                        RoundedRectangle(cornerRadius: 3, style: .continuous)
                            .fill(isCurrent && d == todayDay ? T.text : T.fill)
                            .frame(width: barW, height: max(0, values[d] / peak * 74))
                        Text(axisLabel(d, days: days))
                            .font(.system(size: 7.5))
                            .foregroundStyle(T.text3)
                            .frame(height: 9)
                    }
                    .frame(width: barW)
                }
            }
            .frame(maxWidth: .infinity, alignment: .center)
        }
    }

    private func axisLabel(_ day: Int, days: Int) -> String {
        if days <= 8 { return "\(day)" }
        if day == 1 || day % 5 == 0 { return "\(day)" }
        return ""
    }

    // MARK: - 环形图

    private var donutCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionLabel(text: "分类占比")

            if breakdown.isEmpty {
                EmptyStateView(title: "暂无数据", detail: "这个月还没有\(type.title)记录", symbol: "chart.pie")
            } else {
                HStack(spacing: 18) {
                    donut
                        .frame(width: 132, height: 132)

                    VStack(alignment: .leading, spacing: 9) {
                        ForEach(breakdown.prefix(4), id: \.category.id) { item in
                            HStack(spacing: 7) {
                                Circle()
                                    .fill(item.category.color)
                                    .frame(width: 7, height: 7)
                                Text(item.category.name)
                                    .font(.system(size: 11.5))
                                    .foregroundStyle(T.text2)
                                Spacer(minLength: 4)
                                Text(percentText(item.amount))
                                    .font(.system(size: 11.5, weight: .medium))
                                    .foregroundStyle(T.text)
                                    .monospacedDigit()
                            }
                        }
                        if breakdown.count > 4 {
                            Text("其他 \(breakdown.count - 4) 类")
                                .font(.system(size: 10.5))
                                .foregroundStyle(T.text3)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .cardStyle(padding: 14)
    }

    private var donut: some View {
        ZStack {
            Circle()
                .stroke(T.fill, lineWidth: 17)

            ForEach(Array(segments.indices), id: \.self) { i in
                Circle()
                    .trim(from: segments[i].start, to: max(segments[i].start, segments[i].end - 0.004))
                    .stroke(segments[i].color, style: StrokeStyle(lineWidth: 17, lineCap: .butt))
                    .rotationEffect(.degrees(-90))
            }

            VStack(spacing: 1) {
                Text(Fmt.money0(total))
                    .font(.system(size: 15, weight: .semibold))
                    .tracking(-0.4)
                    .foregroundStyle(T.text)
                    .monospacedDigit()
                Text(type.title)
                    .font(.system(size: 9.5))
                    .foregroundStyle(T.text3)
            }
        }
    }

    private func percentText(_ amount: Double) -> String {
        guard total > 0 else { return "0%" }
        return "\(Int((amount / total * 100).rounded()))%"
    }

    // MARK: - 排行

    private var rankCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            SectionLabel(text: "分类排行")

            if breakdown.isEmpty {
                Text("没有可排行的记录")
                    .font(.system(size: 12))
                    .foregroundStyle(T.text3)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 20)
            } else {
                ForEach(breakdown, id: \.category.id) { item in
                    VStack(spacing: 7) {
                        HStack(spacing: 9) {
                            CategoryBadge(category: item.category, size: 28)
                            Text(item.category.name)
                                .font(.system(size: 13, weight: .medium))
                                .foregroundStyle(T.text)
                            Spacer()
                            Text("¥" + Fmt.money(item.amount))
                                .font(.system(size: 13, weight: .medium))
                                .foregroundStyle(T.text)
                                .monospacedDigit()
                            Text(percentText(item.amount))
                                .font(.system(size: 10.5))
                                .foregroundStyle(T.text3)
                                .monospacedDigit()
                                .frame(width: 34, alignment: .trailing)
                        }
                        ProgressLine(progress: total > 0 ? item.amount / total : 0,
                                     tint: item.category.color.opacity(0.85),
                                     height: 3)
                    }
                }
            }
        }
        .cardStyle(padding: 14)
    }
}
