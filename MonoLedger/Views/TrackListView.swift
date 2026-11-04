//
//  TrackListView.swift
//  MonoLedger
//
//  消费追踪总览：在用物品、日均合计、分组列表
//

import SwiftUI
import SwiftData

struct TrackListView: View {
    @Query(sort: [SortDescriptor(\Bill.date, order: .reverse)])
    private var allBills: [Bill]

    @State private var detailBill: Bill?
    @State private var showDetail = false

    private var tracked: [Bill] {
        allBills.filter { $0.isTracked && $0.type == .expense }
    }

    private var activeItems: [Bill] {
        tracked.filter { $0.status == .active }
    }

    private var invested: Double {
        activeItems.reduce(0) { $0 + $1.amount }
    }

    private var dailySum: Double {
        activeItems.reduce(0) { $0 + $1.dailyCost }
    }

    private var sections: [(status: TrackStatus, items: [Bill])] {
        let order: [TrackStatus] = [.active, .resold, .refunded, .done]
        return order.compactMap { st in
            let items = tracked
                .filter { $0.status == st }
                .sorted { $0.date > $1.date }
            return items.isEmpty ? nil : (status: st, items: items)
        }
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 18) {
                summaryCard

                if tracked.isEmpty {
                    EmptyStateView(title: "还没有追踪中的物品",
                                   detail: "记账时点一下「追踪」，就能看到它的每日成本",
                                   symbol: "clock.arrow.circlepath")
                } else {
                    ForEach(sections, id: \.status) { section in
                        VStack(spacing: 7) {
                            SectionLabel(text: "\(section.status.title) · \(section.items.count)")
                            GroupCard {
                                ForEach(Array(section.items.indices), id: \.self) { i in
                                    row(section.items[i])
                                    if i < section.items.count - 1 {
                                        RowDivider()
                                    }
                                }
                            }
                        }
                    }

                    Text("日均成本 = 实际成本 ÷ 已用天数。用得越久，数字越小。")
                        .font(.system(size: 10.5))
                        .foregroundStyle(T.text3)
                        .multilineTextAlignment(.center)
                        .padding(.top, 4)
                }
            }
            .padding(.horizontal, T.hPadding)
            .padding(.top, 6)
            .padding(.bottom, 28)
        }
        .scrollIndicators(.hidden)
        .background(T.bg)
        .navigationTitle("消费追踪")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showDetail) {
            if let bill = detailBill {
                RecordDetailView(bill: bill)
            }
        }
    }

    // MARK: - 汇总

    private var summaryCard: some View {
        HStack(spacing: 0) {
            stat("在用物品", "\(activeItems.count)", "件")
            divider
            stat("累计投入", Fmt.money0(invested), "元")
            divider
            stat("日均合计", Fmt.money1(dailySum), "元")
        }
        .padding(.vertical, 15)
        .background(T.grouped, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private var divider: some View {
        Rectangle().fill(T.line).frame(width: 0.6, height: 28)
    }

    private func stat(_ title: String, _ value: String, _ unit: String) -> some View {
        VStack(spacing: 4) {
            Text(title)
                .font(.system(size: 10.5))
                .foregroundStyle(T.text2)
            HStack(alignment: .firstTextBaseline, spacing: 1) {
                Text(value)
                    .font(.system(size: 17, weight: .semibold))
                    .tracking(-0.4)
                    .foregroundStyle(T.text)
                    .monospacedDigit()
                Text(unit)
                    .font(.system(size: 9.5))
                    .foregroundStyle(T.text3)
            }
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - 行

    private func row(_ bill: Bill) -> some View {
        Button {
            detailBill = bill
            showDetail = true
        } label: {
            HStack(spacing: 12) {
                CategoryBadge(category: bill.category, size: 38)

                VStack(alignment: .leading, spacing: 2) {
                    Text(bill.title)
                        .font(.system(size: 14.5, weight: .medium))
                        .foregroundStyle(T.text)
                        .lineLimit(1)
                    Text("\(Dates.fullDate(bill.date)) · 已用 \(bill.daysUsed) 天")
                        .font(.system(size: 11))
                        .foregroundStyle(T.text3)
                }

                Spacer(minLength: 6)

                VStack(alignment: .trailing, spacing: 2) {
                    Text("¥" + Fmt.money(bill.netCost))
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(T.text)
                        .monospacedDigit()
                    Text(bill.status == .active
                         ? "日均 ¥\(Fmt.money1(bill.dailyCost))"
                         : "实际成本")
                        .font(.system(size: 9.5))
                        .foregroundStyle(T.text3)
                        .monospacedDigit()
                }
            }
            .padding(.vertical, 11)
            .padding(.horizontal, 13)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
