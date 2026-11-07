//
//  ScanView.swift
//  MonoLedger
//
//  识别账单：选一张截图，端上认出金额和商户，确认后入账
//

import SwiftUI
import SwiftData
import PhotosUI
import UIKit

struct ScanView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context

    /// 记账成功后的回调，用来在上一页弹提示
    var onSaved: (String) -> Void = { _ in }

    @State private var pickedItem: PhotosPickerItem?
    @State private var image: UIImage?
    @State private var isRecognizing = false
    @State private var errorText: String?
    @State private var result: ParseResult?
    @State private var showCamera = false

    // 可编辑字段
    @State private var amountText = ""
    @State private var note = ""
    @State private var categoryID = "more"
    @State private var date = Date()

    @FocusState private var amountFocused: Bool

    init(onSaved: @escaping (String) -> Void = { _ in }) {
        self.onSaved = onSaved
    }

    private var recordType: RecordType { result?.type ?? .expense }
    private var category: Category { Catalog.find(recordType, categoryID) }

    private var amount: Double {
        let value = Double(amountText.replacingOccurrences(of: ",", with: "")) ?? 0
        return value.isFinite ? value : 0
    }

    private var canSave: Bool { amount.isFinite && amount > 0 }

    /// 页面写着「实付 ¥0.00」：积分或优惠券抵完了，不是识别失败
    private var isZeroPaid: Bool { (result?.zeroPaid ?? false) && !canSave }

    /// 识别结果本身的把握程度，还要看用户有没有亲手改过：
    /// 改过就说明已经人工核对，不该再顶着「待核对」进账本
    private var needsReviewOnSave: Bool {
        guard let result, result.amountTier.needsReview else { return false }
        let untouched = amountText == String(format: "%.2f", result.amount)
        return untouched
    }

    // MARK: - Body

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    if let image {
                        preview(image)
                    } else {
                        picker
                    }

                    if isRecognizing {
                        recognizingCard
                    } else if let result {
                        resultCard(result)
                        evidenceCard(result)
                    } else if let errorText {
                        errorCard(errorText)
                    }

                    if image != nil && !isRecognizing {
                        changeRow
                        receiptHint
                    }
                }
                .padding(.horizontal, T.hPadding)
                .padding(.top, 8)
                .padding(.bottom, 24)
            }
            .background(T.bg)
            .navigationTitle("识别账单")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("关闭") { dismiss() }
                        .foregroundStyle(T.text2)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    if let result, !isRecognizing, result.isValid {
                        Button("记一笔") { save() }
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(canSave ? T.text : T.text3)
                            .disabled(!canSave)
                    }
                }
            }
            .safeAreaInset(edge: .bottom) {
                if result != nil && !isRecognizing {
                    saveBar
                }
            }
            .onChange(of: pickedItem) { _, item in
                guard let item else { return }
                Task { await load(item) }
            }
            .sheet(isPresented: $showCamera) {
                CameraPicker { uiImage in Task { await recognize(uiImage) } }
                    .ignoresSafeArea()
            }
            .alert("保存失败", isPresented: Binding(get: { errorText?.hasPrefix("保存失败：") == true }, set: { if !$0 { errorText = nil } })) {
                Button("好", role: .cancel) { errorText = nil }
            } message: { Text(errorText ?? "请稍后重试。") }
        }
    }

    // MARK: - 选择图片

    private var picker: some View {
        VStack(spacing: 18) {
            VStack(spacing: 10) {
                Image(systemName: "doc.text.viewfinder")
                    .font(.system(size: 38, weight: .light))
                    .foregroundStyle(T.text2)
                Text("选一张账单截图")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(T.text)
                Text("微信、支付宝的付款成功页，或银行扣款短信截图都可以")
                    .font(.system(size: 12.5))
                    .foregroundStyle(T.text3)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 30)
            }
            .padding(.top, 46)

            VStack(spacing: 10) {
                PhotosPicker(selection: $pickedItem, matching: .images, photoLibrary: .shared()) {
                    HStack {
                        Image(systemName: "photo.on.rectangle")
                        Text("从相册选择")
                    }
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(T.bg)
                    .frame(maxWidth: .infinity)
                    .frame(height: 50)
                    .background(T.text, in: RoundedRectangle(cornerRadius: 15, style: .continuous))
                }

                if UIImagePickerController.isSourceTypeAvailable(.camera) {
                    Button {
                        showCamera = true
                    } label: {
                        HStack {
                            Image(systemName: "camera")
                            Text("拍一张")
                        }
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(T.text)
                        .frame(maxWidth: .infinity)
                        .frame(height: 50)
                        .background(T.grouped, in: RoundedRectangle(cornerRadius: 15, style: .continuous))
                    }
                }
            }
            .padding(.top, 8)

            Text("图片只在这台手机上识别，不会上传")
                .font(.system(size: 11.5))
                .foregroundStyle(T.text3)
                .padding(.top, 4)
        }
    }

    private func preview(_ image: UIImage) -> some View {
        Image(uiImage: image)
            .resizable()
            .scaledToFit()
            .frame(maxHeight: 240)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(T.line, lineWidth: 1)
            )
    }

    private var changeRow: some View {
        HStack(spacing: 12) {
            PhotosPicker(selection: $pickedItem, matching: .images, photoLibrary: .shared()) {
                Label("换一张", systemImage: "arrow.triangle.2.circlepath")
                    .font(.system(size: 13.5, weight: .medium))
                    .foregroundStyle(T.text2)
            }
            if result != nil {
                Button {
                    reset()
                } label: {
                    Label("重新识别", systemImage: "arrow.counterclockwise")
                        .font(.system(size: 13.5, weight: .medium))
                        .foregroundStyle(T.text2)
                }
            }
        }
        .padding(.top, 2)
    }

    /// 告诉用户截图不会被丢掉
    private var receiptHint: some View {
        HStack(spacing: 6) {
            Image(systemName: "paperclip")
                .font(.system(size: 10, weight: .medium))
            Text("这张截图会随账单一起保存，之后在详情里能翻出来")
                .font(.system(size: 11.5))
            Spacer()
        }
        .foregroundStyle(T.text3)
        .padding(.horizontal, 4)
    }

    // MARK: - 状态卡片

    private var recognizingCard: some View {
        HStack(spacing: 12) {
            ProgressView()
                .controlSize(.small)
            Text("正在读取截图…")
                .font(.system(size: 14))
                .foregroundStyle(T.text2)
            Spacer()
        }
        .padding(16)
        .background(T.grouped, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private func errorCard(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("没认出来", systemImage: "exclamationmark.triangle")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(T.orange)
            Text(message)
                .font(.system(size: 12.5))
                .foregroundStyle(T.text2)
                .lineSpacing(2)
            Text("可以换一张截得更完整的图，或者直接手动记一笔。")
                .font(.system(size: 12))
                .foregroundStyle(T.text3)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(T.grouped, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private func resultCard(_ result: ParseResult) -> some View {
        VStack(spacing: 0) {
            // 头部：分类 + 商户 + 金额
            HStack(alignment: .top, spacing: 12) {
                CategoryBadge(category: category, size: 40)

                VStack(alignment: .leading, spacing: 3) {
                    Menu {
                        ForEach(Catalog.list(recordType)) { item in
                            Button {
                                categoryID = item.id
                            } label: {
                                Label(item.name, systemImage: item.symbol)
                            }
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Text(category.name)
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(T.text)
                            Image(systemName: "chevron.down")
                                .font(.system(size: 8, weight: .bold))
                                .foregroundStyle(T.text3)
                        }
                    }

                    TextField("备注", text: $note)
                        .font(.system(size: 12.5))
                        .foregroundStyle(T.text2)
                        .textInputAutocapitalization(.never)
                        .submitLabel(.done)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                VStack(alignment: .trailing, spacing: 2) {
                    HStack(alignment: .firstTextBaseline, spacing: 2) {
                        Text("¥")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(T.text2)
                        TextField("0.00", text: $amountText)
                            .font(.system(size: 24, weight: .semibold))
                            .foregroundStyle(T.text)
                            .monospacedDigit()
                            .multilineTextAlignment(.trailing)
                            .keyboardType(.decimalPad)
                            .focused($amountFocused)
                            .frame(minWidth: 64, maxWidth: 118)
                    }
                    if result.amountTier.needsReview {
                        Text("请核对")
                            .font(.system(size: 10))
                            .foregroundStyle(T.orange)
                    }
                }
            }
            .padding(16)

            if !result.alternatives.isEmpty {
                RowDivider(leading: 16)

                HStack(spacing: 8) {
                    Text("也可能是")
                        .font(.system(size: 11.5))
                        .foregroundStyle(T.text3)

                    ForEach(result.alternatives, id: \.self) { value in
                        Button {
                            Haptic.tap()
                            amountText = String(format: "%.2f", value)
                        } label: {
                            Text("¥" + Fmt.money(value))
                                .font(.system(size: 11.5, weight: .medium))
                                .foregroundStyle(T.text2)
                                .padding(.horizontal, 9)
                                .frame(height: 26)
                                .background(T.fill, in: Capsule())
                        }
                        .buttonStyle(.plain)
                    }

                    Spacer()
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
            }

            RowDivider(leading: 16)

            // 日期
            HStack {
                Text("日期")
                    .font(.system(size: 13.5))
                    .foregroundStyle(T.text2)
                Spacer()
                DatePicker("", selection: $date, displayedComponents: .date)
                    .labelsHidden()
                    .datePickerStyle(.compact)
                    .tint(T.text)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)

        }
        .background(T.card, in: RoundedRectangle(cornerRadius: T.cardRadius, style: .continuous))
    }

    private func evidenceCard(_ result: ParseResult) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("识别依据")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(T.text3)
                .tracking(0.4)

            ForEach(Array(result.evidence.indices), id: \.self) { i in
                HStack(alignment: .top, spacing: 6) {
                    Text("·")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(T.text3)
                    Text(result.evidence[i])
                        .font(.system(size: 11.5))
                        .foregroundStyle(T.text2)
                        .lineSpacing(1)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 4)
    }

    // MARK: - 底部按钮

    private var saveBar: some View {
        VStack(spacing: 0) {
            Divider().overlay(T.line)
            Button {
                save()
            } label: {
                Text(canSave ? "记一笔 ¥" + Fmt.money(amount) : (isZeroPaid ? "实付 ¥0，无需记账" : "填个金额"))
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(canSave ? T.bg : T.text3)
                    .frame(maxWidth: .infinity)
                    .frame(height: 52)
                    .background(canSave ? T.text : T.grouped,
                                in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            }
            .disabled(!canSave)
            .padding(.horizontal, T.hPadding)
            .padding(.top, 10)
            .padding(.bottom, 6)
        }
        .background(T.bg)
    }

    // MARK: - 识别流程

    private func load(_ item: PhotosPickerItem) async {
        guard let data = try? await item.loadTransferable(type: Data.self),
              let uiImage = UIImage(data: data) else {
            await MainActor.run { errorText = "图片读取失败" }
            return
        }
        await recognize(uiImage)
    }

    @MainActor
    private func recognize(_ uiImage: UIImage) async {
        image = uiImage
        isRecognizing = true
        errorText = nil
        result = nil

        do {
            let parsed = try await BillParser.parse(image: uiImage)
            isRecognizing = false
            if parsed.isValid {
                result = parsed
                amountText = String(format: "%.2f", parsed.amount)
                note = parsed.merchant
                categoryID = parsed.categoryID
                date = parsed.date
            } else {
                errorText = "没找到明确的金额。整页截图（含「支付成功」和金额）通常识别率最高。"
            }
        } catch {
            isRecognizing = false
            errorText = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    private func reset() {
        result = nil
        errorText = nil
        amountText = ""
        note = ""
    }

    private func save() {
        guard canSave else { return }
        // 识别没十足把握、用户又没改过金额时，把「待核对」带进账本，
        // 首页会一直提示到确认，避免错账悄悄混进去
        let bill = Bill(type: recordType,
                        amount: amount,
                        categoryID: categoryID,
                        note: note.trimmingCharacters(in: .whitespaces),
                        date: date,
                        receiptData: image.flatMap { ReceiptStore.compress($0) },
                        needsReview: needsReviewOnSave,
                        alternatives: needsReviewOnSave ? (result?.alternatives ?? []) : [])
        context.insert(bill)
        if let error = AppData.save(context) {
            errorText = "保存失败：\(error)"
        } else {
            Haptic.success()
            onSaved("已记一笔 · \(category.name) ¥\(Fmt.money(amount))")
            dismiss()
        }
    }
}

// MARK: - 相机

struct CameraPicker: UIViewControllerRepresentable {
    var onPick: (UIImage) -> Void

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ controller: UIImagePickerController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        private let parent: CameraPicker

        init(_ parent: CameraPicker) { self.parent = parent }

        func imagePickerController(_ picker: UIImagePickerController,
                                   didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            if let image = info[.originalImage] as? UIImage {
                parent.onPick(image)
            }
            picker.dismiss(animated: true)
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            picker.dismiss(animated: true)
        }
    }
}
