//
//  TextRecordSheet.swift
//  MonoLedger
//
//  打一句话记账：「午饭 32」「打车 25」「昨天买咖啡花了 28」
//  解析全在本地，用的是和截图识别同一套 BillParser
//

import SwiftUI
import Foundation

struct TextRecordSheet: View {
    @Environment(\.dismiss) private var dismiss

    /// 解析成功后回填到记账面板
    var onApply: (ParseResult) -> Void = { _ in }

    /// 首页直接打开时，允许「记下」一步入库，不用再进记账面板
    var allowsDirectSave: Bool = false
    /// 入库成功后的提示文案，交给首页弹 toast
    var onSaved: ((String) -> Void)? = nil

    @State private var text: String = ""
    @State private var parsed: ParseResult? = nil
    @State private var saveError: String? = nil
    /// 垫付的钱，一句话记完就直接挂上待报销
    @State private var markPending = false
    /// 用户手点过这个开关后，就不再跟着文字自动改
    @State private var pendingTouched = false
    @FocusState private var focused: Bool

    private let samples = ["午饭 32", "打车 25", "昨天买咖啡花了 28"]

    // MARK: - 计算

    private var trimmed: String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 只算一次：每敲一个字都会走这里，正文渲染时直接读缓存，避免同一帧里跑两遍正则
    private func reparse(_ value: String) {
        let t = value.trimmingCharacters(in: .whitespacesAndNewlines)
        parsed = t.isEmpty ? nil : BillParser.parse(text: t)
        // 「打车 45 待报销」这种写法，顺手把报销标记也打开。
        // 没手动点过时要跟着文字走：把「报销」两个字删掉，勾也得跟着取消，
        // 否则用户改完文案还以为没标待报销，实际已经标上了
        if !pendingTouched {
            markPending = t.contains("待报销") || t.contains("报销")
        }
    }

    private var canApply: Bool {
        parsed?.isValid == true
    }

    // MARK: - Body

    var body: some View {
        VStack(spacing: 0) {
            header
            editor
            resultBlock
            if allowsDirectSave, parsed?.type == .expense {
                reimburseChip
            }
            samplesRow
            Spacer(minLength: 0)
        }
        .background(T.bg)
        .presentationDragIndicator(.visible)
        .onChange(of: text) { _, newValue in
            reparse(newValue)
        }
        .onAppear {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { focused = true }
        }
        .alert("没能记下", isPresented: Binding(get: { saveError != nil },
                                              set: { if !$0 { saveError = nil } })) {
            Button("好", role: .cancel) { saveError = nil }
        } message: {
            Text(saveError ?? "请稍后重试。")
        }
    }

    private var header: some View {
        HStack {
            Button {
                dismiss()
            } label: {
                Text("取消")
                    .font(.system(size: 14.5))
                    .foregroundStyle(T.text2)
                    .frame(height: 32)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Spacer()

            Text("打一句话")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(T.text)

            Spacer()

            Button {
                commit()
            } label: {
                Text(allowsDirectSave ? "记下" : "填入")
                    .font(.system(size: 14.5, weight: .semibold))
                    .foregroundStyle(canApply ? T.text : T.text3)
                    .frame(height: 32)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!canApply)
        }
        .padding(.horizontal, T.hPadding)
        .padding(.top, 18)
        .padding(.bottom, 14)
    }

    // MARK: - 提交

    private func commit() {
        guard let result = parsed, result.isValid else { return }

        guard allowsDirectSave else {
            onApply(result)
            dismiss()
            return
        }

        let note = result.merchant.isEmpty ? result.category.name : result.merchant
        // 先输入支出、勾了待报销，再改成「收到工资」这类收入时，
        // markPending 还留着；收入不该带报销状态，这里兜一道
        let reimbursement: ReimbursementState =
            (result.type == .expense && markPending) ? .pending : .none
        let bill = Bill(type: result.type,
                        amount: result.amount,
                        categoryID: result.categoryID,
                        note: note,
                        date: result.date,
                        reimbursement: reimbursement)
        do {
            try AppData.insert(bill)
            Haptic.success()
            onSaved?("已记一笔 · \(result.category.name) ¥\(Fmt.money(result.amount))")
            dismiss()
        } catch {
            saveError = error.localizedDescription
        }
    }

    private var editor: some View {
        ZStack(alignment: .topLeading) {
            if text.isEmpty {
                Text("比如：午饭 32、打车 25、昨天买咖啡花了 28")
                    .font(.system(size: 14.5))
                    .foregroundStyle(T.text3)
                    .padding(.horizontal, 17)
                    .padding(.vertical, 15)
                    .allowsHitTesting(false)
            }

            TextEditor(text: $text)
                .focused($focused)
                .font(.system(size: 15.5))
                .foregroundStyle(T.text)
                .scrollContentBackground(.hidden)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
        }
        .frame(height: 112)
        .background(T.grouped, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .padding(.horizontal, T.hPadding)
    }

    @ViewBuilder
    private var resultBlock: some View {
        if let preview = parsed, preview.isValid {
            HStack(spacing: 9) {
                Text("¥" + Fmt.money(preview.amount))
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(T.text)
                    .monospacedDigit()

                Text(preview.category.name)
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(T.text)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(T.fill, in: Capsule())

                if !preview.merchant.isEmpty {
                    Text(preview.merchant)
                        .font(.system(size: 12.5))
                        .foregroundStyle(T.text2)
                        .lineLimit(1)
                }

                Spacer(minLength: 4)

                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 15))
                    .foregroundStyle(T.green)
            }
            .padding(.horizontal, 15)
            .frame(height: 52)
            .background(T.grouped, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .padding(.horizontal, T.hPadding)
            .padding(.top, 10)

        } else if !trimmed.isEmpty {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.circle")
                    .font(.system(size: 13))
                    .foregroundStyle(T.text3)
                Text("没找到金额。加上数字试试，比如「午饭 32」。")
                    .font(.system(size: 12.5))
                    .foregroundStyle(T.text2)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 15)
            .frame(height: 52)
            .background(T.grouped, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .padding(.horizontal, T.hPadding)
            .padding(.top, 10)
        }
    }

    // MARK: - 报销

    private var reimburseChip: some View {
        Button {
            Haptic.tap()
            pendingTouched = true
            markPending.toggle()
        } label: {
            HStack(spacing: 5) {
                Image(systemName: markPending ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 12, weight: .medium))
                Text("这笔是垫付，记成待报销")
                    .font(.system(size: 12))
            }
            .foregroundStyle(markPending ? ReimbursementState.pending.tint : T.text2)
            .padding(.horizontal, 12)
            .frame(height: 34)
            .background(markPending ? ReimbursementState.pending.tint.opacity(0.12) : T.fill,
                        in: Capsule())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, T.hPadding)
        .padding(.top, 10)
    }

    private var samplesRow: some View {        HStack(spacing: 7) {
            ForEach(samples, id: \.self) { sample in
                Button {
                    text = sample
                    focused = true
                } label: {
                    Text(sample)
                        .font(.system(size: 11.5))
                        .foregroundStyle(T.text2)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 6)
                        .background(T.fill, in: Capsule())
                        .lineLimit(1)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, T.hPadding)
        .padding(.top, 10)
    }
}
