//
//  RecordDetailView.swift
//  MonoLedger
//
//  账单详情：报销、凭证
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
    @State private var showReceipt = false
    @State private var showEdit = false
    @State private var showShare = false
    @State private var receiptItem: PhotosPickerItem?
    @State private var saveError: String?

    init(bill: Bill) {
        self.bill = bill
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

                    // 金额直接可点：识别错了不用翻菜单，一下就能改
                    Button {
                        Haptic.tap()
                        showEdit = true
                    } label: {
                        HStack(alignment: .firstTextBaseline, spacing: 7) {
                            Text("¥" + Fmt.money(bill.amount))
                                .font(.system(size: 34, weight: .semibold))
                                .tracking(-1.2)
                                .foregroundStyle(T.text)
                                .monospacedDigit()

                            Image(systemName: "pencil")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(T.text3)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
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

                if bill.needsReview {
                    reviewBlock
                        .padding(.top, 18)
                }

                if bill.type == .expense {
                    reimbursementBlock
                        .padding(.top, 22)
                }

                receiptBlock
                    .padding(.top, 22)

                infoBlock
                    .padding(.top, 24)

                Button {
                    showDeleteConfirm = true
                } label: {
                    Text("移到回收站")
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
        .confirmationDialog("移到回收站？",
                            isPresented: $showDeleteConfirm,
                            titleVisibility: .visible) {
            Button("移到回收站", role: .destructive) {
                if let error = Trash.move(bill, in: context) {
                    saveError = error
                } else {
                    dismiss()
                }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("30 天内可以在「我的 → 回收站」找回，之后自动彻底删除。")
        }
        .sheet(isPresented: $showEdit) {
            AddRecordView(editing: bill)
        }
        .onChange(of: receiptItem) { _, item in
            guard let item else { return }
            Task { await attachReceipt(item) }
        }
        .fullScreenCover(isPresented: $showReceipt) {
            receiptViewer.sheet(isPresented: $showShare) {
                if let img = ReceiptStore.image(from: bill.receiptData) { ShareSheet(items: [img]) }
            }
        }
        .alert("保存失败", isPresented: Binding(get: { saveError != nil }, set: { if !$0 { saveError = nil } })) {
            Button("好", role: .cancel) { saveError = nil }
        } message: { Text(saveError ?? "请稍后重试。") }
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

            Text("账单详情")
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

    // MARK: - 待核对

    /// 识别出两个以上候选金额时，最省事的做法是把候选摆出来让人点一下
    private var reviewBlock: some View {
        VStack(alignment: .leading, spacing: 11) {
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 10))
                Text("这个金额是截图认出来的，请核对一下")
                    .font(.system(size: 11.5, weight: .medium))
            }
            .foregroundStyle(T.orange)

            if !bill.reviewAlternatives.isEmpty {
                HStack(spacing: 8) {
                    ForEach(bill.reviewAlternatives, id: \.self) { value in
                        Button {
                            resolveReview(value)
                        } label: {
                            Text("¥" + Fmt.money(value))
                                .font(.system(size: 13, weight: .medium))
                                .foregroundStyle(T.text)
                                .frame(maxWidth: .infinity)
                                .frame(height: 34)
                                .background(T.bg, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                                        .stroke(T.line, lineWidth: 1)
                                )
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            HStack(spacing: 8) {
                Button {
                    showEdit = true
                } label: {
                    Text("手动改")
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundStyle(T.text2)
                        .frame(maxWidth: .infinity)
                        .frame(height: 34)
                        .background(T.bg, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                }
                .buttonStyle(.plain)

                Button {
                    resolveReview(nil)
                } label: {
                    Text("金额没问题")
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(T.bg)
                        .frame(maxWidth: .infinity)
                        .frame(height: 34)
                        .background(T.text, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                }
                .buttonStyle(.plain)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(T.orange.opacity(0.09), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private func resolveReview(_ newAmount: Double?) {
        Haptic.success()
        if let newAmount { bill.amount = newAmount }
        bill.markReviewed()
        persistChanges()
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
                        persistChanges()
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
                // 能捏合放大：报销对账时要看清商户名和订单号
                ZoomableImage(image: img)
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

    @discardableResult
    private func persistChanges() -> Bool {
        if let error = AppData.save(context) {
            saveError = error
            return false
        }
        return true
    }

    private func attachReceipt(_ item: PhotosPickerItem) async {
        guard let data = try? await item.loadTransferable(type: Data.self),
              let image = UIImage(data: data),
              let compressed = ReceiptStore.compress(image) else { return }
        await MainActor.run {
            bill.receiptData = compressed
            if persistChanges() { Haptic.success() }
        }
    }

    // MARK: - 信息

    private var infoBlock: some View {
        VStack(spacing: 0) {
            infoRow("购买日期", Dates.fullDate(bill.date))
            RowDivider(leading: 14)

            infoRow("分类", bill.category.name)

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
