//
//  RecordDetailView.swift
//  MonoLedger
//
//  账单详情：报销、凭证、状态切换、日均推演
//

import SwiftUI
import SwiftData
import PhotosUI
import UIKit

struct RecordDetailView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss

    let bill: Bill

    @State private var showDeleteConfirm = false
    @State private var showResaleInput = false
    @State private var resaleText = ""
    @State private var showReceipt = false
    @State private var showEdit = false
    @State private var showShare = false
    @State private var receiptItem: PhotosPickerItem?

    init(bill: Bill) {
        self.bill = bill
    }

    private var projectionDays: [Int] {
        [90, 180, 365, 730].filter { $0 > bill.daysUsed }
    }

    /// 只有「消费追踪」的账单才展示日均那一套
    private var isTrackedBill: Bool {
        bill.isTracked && bill.type == .expense
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                header

                VStack(spacing: 12) {
                    CategoryBadge(category: bill.category, size: 54)

                    VStack(spacing: 5) {
                        Text(bill.title)
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(T.text)
                        Text(bill.category.name)
                            .font(.system(size: 11.5))
                            .foregroundStyle(T.text3)
                    }

                    Text("¥" + Fmt.money(bill.amount))
                        .font(.system(size: 34, weight: .semibold))
                        .tracking(-1.2)
                        .foregroundStyle(T.text)
                        .monospacedDigit()
                        .padding(.top, 2)

                    if bill.reimbursement == .done {
                        Text("已报销 · 不计入个人支出")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(ReimbursementState.done.tint)
                            .padding(.horizontal, 9)
                            .padding(.vertical, 4)
                            .background(ReimbursementState.done.tint.opacity(0.12), in: Capsule())
                    }
                }
                .padding(.top, 18)

                if isTrackedBill {
                    metrics
                        .padding(.top, 22)

                    statusPills
                        .padding(.top, 24)

                    Text(bill.status.hint)
                        .font(.system(size: 11.5))
                        .foregroundStyle(T.text3)
                        .multilineTextAlignment(.center)
                        .lineSpacing(2)
                        .padding(.horizontal, 24)
                        .padding(.top, 10)
                }

                if bill.type == .expense {
                    reimbursementBlock
                        .padding(.top, isTrackedBill ? 24 : 22)
                }

                if isTrackedBill && bill.status == .active && !projectionDays.isEmpty {
                    projectionBlock
                        .padding(.top, 22)
                }

                receiptBlock
                    .padding(.top, 22)

                infoBlock
                    .padding(.top, 24)

                Button {
                    showDeleteConfirm = true
                } label: {
                    Text("删除这笔账单")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(T.red)
                        .frame(maxWidth: .infinity)
                        .frame(height: 46)
                        .background(T.fill, in: RoundedRectangle(cornerRadius: 13, style: .continuous))
                }
                .buttonStyle(.plain)
                .padding(.top, 22)
            }
            .padding(.horizontal, T.hPadding)
            .padding(.bottom, 30)
        }
        .scrollIndicators(.hidden)
        .background(T.bg)
        .presentationDragIndicator(.visible)
        .confirmationDialog("删除后无法恢复",
                            isPresented: $showDeleteConfirm,
                            titleVisibility: .visible) {
            Button("删除这笔账单", role: .destructive) {
                context.delete(bill)
                try? context.save()
                dismiss()
            }
            Button("取消", role: .cancel) {}
        }
        .alert("转售价格", isPresented: $showResaleInput) {
            TextField("金额", text: $resaleText)
                .keyboardType(.decimalPad)
            Button("确定") {
                let v = Double(resaleText) ?? 0
                bill.resalePrice = max(0, (v * 100).rounded() / 100)
                try? context.save()
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("填 0 表示没有卖出去")
        }
        .sheet(isPresented: $showEdit) {
            AddRecordView(editing: bill)
        }
        .onChange(of: receiptItem) { _, item in
            guard let item else { return }
            Task { await attachReceipt(item) }
        }
        .fullScreenCover(isPresented: $showReceipt) {
            receiptViewer
                .sheet(isPresented: $showShare) {
                    if let img = ReceiptStore.image(from: bill.receiptData) {
                        ShareSheet(items: [img])
                    }
                }
        }
    }

    // MARK: - 顶部

    private var header: some View {
        HStack {
            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(T.text2)
                    .frame(width: 32, height: 32)
                    .background(T.fill, in: Circle())
            }
            .buttonStyle(.plain)

            Spacer()

            Text(isTrackedBill ? "消费详情" : "账单详情")
                .font(.system(size: 14.5, weight: .semibold))
                .foregroundStyle(T.text)

            Spacer()

            Menu {
                Button {
                    showEdit = true
                } label: {
                    Label("编辑这一笔", systemImage: "pencil")
                }
                Button(role: .destructive) {
                    showDeleteConfirm = true
                } label: {
                    Label("删除", systemImage: "trash")
                }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(T.text2)
                    .frame(width: 32, height: 32)
                    .background(T.fill, in: Circle())
            }
        }
        .padding(.top, 14)
    }

    // MARK: - 指标

    private var metrics: some View {
        HStack(spacing: 0) {
            metric(title: "已用天数", value: "\(bill.daysUsed)", unit: "天")
            divider
            metric(title: "日均成本",
                   value: (bill.status == .refunded || bill.status == .done) ? "—" : Fmt.money1(bill.dailyCost),
                   unit: (bill.status == .refunded || bill.status == .done) ? "" : "元")
            divider
            metric(title: "实际成本", value: Fmt.money0(bill.netCost), unit: "元")
        }
        .padding(.vertical, 14)
        .background(T.grouped, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private var divider: some View {
        Rectangle()
            .fill(T.line)
            .frame(width: 0.6, height: 30)
    }

    private func metric(title: String, value: String, unit: String) -> some View {
        VStack(spacing: 5) {
            Text(title)
                .font(.system(size: 10.5))
                .foregroundStyle(T.text2)
            HStack(alignment: .firstTextBaseline, spacing: 1) {
                Text(value)
                    .font(.system(size: 17, weight: .semibold))
                    .tracking(-0.4)
                    .foregroundStyle(T.text)
                    .monospacedDigit()
                if !unit.isEmpty {
                    Text(unit)
                        .font(.system(size: 9.5))
                        .foregroundStyle(T.text3)
                }
            }
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - 状态

    private var statusPills: some View {
        HStack(spacing: 6) {
            ForEach(TrackStatus.allCases) { st in
                Button {
                    Haptic.tap()
                    withAnimation(.easeOut(duration: 0.2)) {
                        bill.status = st
                        if st == .resold && bill.resalePrice == nil {
                            bill.resalePrice = 0
                        }
                    }
                    try? context.save()
                } label: {
                    Text(st.title)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(bill.status == st ? T.bg : T.text2)
                        .frame(maxWidth: .infinity)
                        .frame(height: 32)
                        .background(
                            RoundedRectangle(cornerRadius: 9, style: .continuous)
                                .fill(bill.status == st ? st.tint : T.fill)
                        )
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: - 报销

    private var reimbursementBlock: some View {
        VStack(spacing: 8) {
            SectionLabel(text: "报销")

            HStack(spacing: 6) {
                ForEach(ReimbursementState.allCases) { st in
                    Button {
                        Haptic.tap()
                        withAnimation(.easeOut(duration: 0.2)) {
                            bill.reimbursement = st
                        }
                        try? context.save()
                    } label: {
                        Text(st.title)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(bill.reimbursement == st ? .white : T.text2)
                            .frame(maxWidth: .infinity)
                            .frame(height: 32)
                            .background(
                                RoundedRectangle(cornerRadius: 9, style: .continuous)
                                    .fill(bill.reimbursement == st ? st.tint : T.fill)
                            )
                    }
                    .buttonStyle(.plain)
                }
            }

            Text(bill.reimbursement.hint)
                .font(.system(size: 11.5))
                .foregroundStyle(T.text3)
                .lineSpacing(2)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 4)
                .padding(.top, 2)
        }
    }

    // MARK: - 凭证

    private var receiptBlock: some View {
        VStack(spacing: 8) {
            HStack {
                SectionLabel(text: "凭证")
                Spacer()
                if bill.hasReceipt {
                    PhotosPicker(selection: $receiptItem, matching: .images, photoLibrary: .shared()) {
                        Text("更换")
                            .font(.system(size: 11.5, weight: .medium))
                            .foregroundStyle(T.text2)
                    }
                }
            }

            if let img = ReceiptStore.image(from: bill.receiptData) {
                Button {
                    showReceipt = true
                } label: {
                    Image(uiImage: img)
                        .resizable()
                        .scaledToFill()
                        .frame(maxWidth: .infinity)
                        .frame(height: 210)
                        .clipped()
                        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .stroke(T.line, lineWidth: 1)
                        )
                        .overlay(alignment: .bottomTrailing) {
                            Image(systemName: "arrow.up.left.and.arrow.down.right")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(.white)
                                .padding(7)
                                .background(.black.opacity(0.42), in: Circle())
                                .padding(9)
                        }
                }
                .buttonStyle(.plain)
            } else {
                PhotosPicker(selection: $receiptItem, matching: .images, photoLibrary: .shared()) {
                    HStack(spacing: 8) {
                        Image(systemName: "paperclip")
                            .font(.system(size: 12, weight: .medium))
                        Text("添加截图凭证")
                            .font(.system(size: 12.5, weight: .medium))
                        Spacer()
                    }
                    .foregroundStyle(T.text2)
                    .padding(.horizontal, 14)
                    .frame(height: 46)
                    .background(T.grouped, in: RoundedRectangle(cornerRadius: 13, style: .continuous))
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var receiptViewer: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if let img = ReceiptStore.image(from: bill.receiptData) {
                ScrollView([.horizontal, .vertical]) {
                    Image(uiImage: img)
                        .resizable()
                        .scaledToFit()
                        .frame(maxWidth: .infinity)
                }
                .ignoresSafeArea(edges: .bottom)
            }

            VStack {
                HStack {
                    Spacer()
                    Button {
                        showReceipt = false
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(width: 34, height: 34)
                            .background(.white.opacity(0.16), in: Circle())
                    }
                    .padding(.trailing, 18)
                    .padding(.top, 8)
                }

                Spacer()

                Button {
                    showShare = true
                } label: {
                    Label("分享或存到相册", systemImage: "square.and.arrow.up")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 16)
                        .frame(height: 40)
                        .background(.white.opacity(0.16), in: Capsule())
                }
                .padding(.bottom, 30)
            }
        }
    }

    private func attachReceipt(_ item: PhotosPickerItem) async {
        guard let data = try? await item.loadTransferable(type: Data.self),
              let image = UIImage(data: data),
              let compressed = ReceiptStore.compress(image) else { return }
        await MainActor.run {
            bill.receiptData = compressed
            try? context.save()
            Haptic.success()
        }
    }

    // MARK: - 推演

    private var projectionBlock: some View {
        VStack(spacing: 7) {
            SectionLabel(text: "如果继续用下去")

            HStack(spacing: 7) {
                ForEach(projectionDays.prefix(3), id: \.self) { d in
                    VStack(spacing: 5) {
                        Text("用满 \(d) 天")
                            .font(.system(size: 10))
                            .foregroundStyle(T.text2)
                        HStack(alignment: .firstTextBaseline, spacing: 1) {
                            Text("¥" + Fmt.money1(bill.netCost / Double(d)))
                                .font(.system(size: 14, weight: .semibold))
                                .tracking(-0.3)
                                .foregroundStyle(T.text)
                                .monospacedDigit()
                            Text("/天")
                                .font(.system(size: 8.5))
                                .foregroundStyle(T.text3)
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 11)
                    .background(T.grouped, in: RoundedRectangle(cornerRadius: 13, style: .continuous))
                }
            }
        }
    }

    // MARK: - 信息

    private var infoBlock: some View {
        VStack(spacing: 0) {
            infoRow("购买日期", Dates.fullDate(bill.date))
            RowDivider(leading: 14)

            if bill.status == .resold {
                Button {
                    resaleText = String(format: "%.0f", bill.resalePrice ?? 0)
                    showResaleInput = true
                } label: {
                    HStack {
                        Text("转售价格")
                            .font(.system(size: 13.5))
                            .foregroundStyle(T.text2)
                        Spacer()
                        Text("¥" + Fmt.money(bill.resalePrice ?? 0))
                            .font(.system(size: 13.5, weight: .medium))
                            .foregroundStyle(T.blue)
                            .monospacedDigit()
                        Image(systemName: "chevron.right")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(T.text3)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                RowDivider(leading: 14)

                infoRow("净亏损", "¥" + Fmt.money(bill.netCost))
                RowDivider(leading: 14)
            }

            infoRow("分类", bill.category.name)
            RowDivider(leading: 14)

            infoRow("支付账户", bill.account)

            if bill.type == .expense && bill.reimbursement != .none {
                RowDivider(leading: 14)
                infoRow("报销", bill.reimbursement.title)
            }

            if !bill.note.isEmpty && bill.note != bill.category.name {
                RowDivider(leading: 14)
                infoRow("备注", bill.note)
            }
        }
        .background(T.card, in: RoundedRectangle(cornerRadius: T.cardRadius, style: .continuous))
    }

    private func infoRow(_ key: String, _ value: String) -> some View {
        HStack {
            Text(key)
                .font(.system(size: 13.5))
                .foregroundStyle(T.text2)
            Spacer()
            Text(value)
                .font(.system(size: 13.5, weight: .medium))
                .foregroundStyle(T.text)
                .lineLimit(1)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }
}
