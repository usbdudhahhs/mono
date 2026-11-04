//
//  AddRecordView.swift
//  MonoLedger
//
//  记账面板：自定义键盘、分类网格、追踪 / 报销 / 凭证
//

import SwiftUI
import SwiftData
import PhotosUI
import UIKit

struct AddRecordView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss

    var editing: Bill? = nil

    @State private var type: RecordType = .expense
    @State private var amountText: String = ""
    @State private var categoryID: String = "food"
    @State private var note: String = ""
    @State private var date: Date = Date()
    @State private var account: String = "微信"
    @State private var tracked: Bool = false
    @State private var reimbursement: ReimbursementState = .none
    @State private var receiptData: Data?
    @State private var receiptItem: PhotosPickerItem?
    @State private var showDatePicker = false

    @FocusState private var noteFocused: Bool

    init(editing: Bill? = nil) {
        self.editing = editing
    }

    // MARK: - 计算

    private var amount: Double { Double(amountText) ?? 0 }
    private var canSave: Bool { amount > 0 }
    private var categories: [Category] { Catalog.list(type) }

    private var displayAmount: String {
        guard !amountText.isEmpty else { return "0.00" }
        if amountText.hasSuffix(".") { return amountText + "00" }
        if let dot = amountText.firstIndex(of: ".") {
            let decimals = amountText.distance(from: dot, to: amountText.endIndex) - 1
            return amountText + String(repeating: "0", count: max(0, 2 - decimals))
        }
        return amountText + ".00"
    }

    private var dateChipText: String {
        if Calendar.current.isDateInToday(date) { return "今天" }
        if Calendar.current.isDateInYesterday(date) { return "昨天" }
        return Dates.shortDate(date)
    }

    // MARK: - Body

    var body: some View {
        VStack(spacing: 0) {
            header

            SegmentedBar(items: RecordType.allCases, title: { $0.title }, selection: $type)
                .frame(width: 168)
                .padding(.top, 6)

            amountBlock
                .padding(.top, 18)

            categoryGrid
                .padding(.top, 10)

            Spacer(minLength: 0)

            metaBlock
                .padding(.horizontal, T.hPadding)

            if !noteFocused {
                keypad
                    .padding(.horizontal, 10)
                    .padding(.top, 10)
                    .padding(.bottom, 4)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .background(T.bg)
        .animation(.easeOut(duration: 0.22), value: noteFocused)
        .animation(.easeOut(duration: 0.2), value: type)
        .onChange(of: type) { _, newValue in
            // 只有当前分类不属于新类型时才切换，避免编辑已有账单时被覆盖
            if !Catalog.list(newValue).contains(where: { $0.id == categoryID }) {
                categoryID = Catalog.list(newValue).first?.id ?? "more"
            }
            if newValue == .income {
                tracked = false
                reimbursement = .none
            }
        }
        .onChange(of: receiptItem) { _, item in
            guard let item else { return }
            Task { await loadReceipt(item) }
        }
        .onAppear(perform: loadInitial)
        .sheet(isPresented: $showDatePicker) {
            datePickerSheet
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

            Button {
                save()
            } label: {
                Text("保存")
                    .font(.system(size: 14.5, weight: .semibold))
                    .foregroundStyle(canSave ? T.text : T.text3)
                    .padding(.horizontal, 4)
                    .frame(height: 32)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!canSave)
        }
        .padding(.horizontal, T.hPadding)
        .padding(.top, 14)
    }

    // MARK: - 金额

    private var amountBlock: some View {
        HStack(alignment: .firstTextBaseline, spacing: 3) {
            Text("¥")
                .font(.system(size: 20, weight: .medium))
                .foregroundStyle(amountText.isEmpty ? T.text3 : T.text2)
            Text(displayAmount)
                .font(.system(size: amountFontSize, weight: .semibold))
                .tracking(-1.6)
                .foregroundStyle(amountText.isEmpty ? T.text3 : T.text)
                .lineLimit(1)
                .minimumScaleFactor(0.5)
                .contentTransition(.numericText())
        }
        .frame(maxWidth: .infinity, alignment: .center)
        .animation(.snappy(duration: 0.2), value: amountText)
    }

    private var amountFontSize: CGFloat {
        switch displayAmount.count {
        case 0...6:  return 46
        case 7...8:  return 40
        case 9...10: return 34
        default:     return 28
        }
    }

    // MARK: - 分类

    private var categoryGrid: some View {
        let columns = Array(repeating: GridItem(.flexible(), spacing: 4), count: 5)
        return LazyVGrid(columns: columns, spacing: 6) {
            ForEach(categories) { cat in
                Button {
                    Haptic.tap()
                    categoryID = cat.id
                } label: {
                    VStack(spacing: 6) {
                        CategoryBadge(category: cat, size: 42)
                        Text(cat.name)
                            .font(.system(size: 10.5, weight: categoryID == cat.id ? .semibold : .regular))
                            .foregroundStyle(categoryID == cat.id ? T.text : T.text2)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 7)
                    .background(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .fill(categoryID == cat.id ? T.fill : Color.clear)
                    )
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 12)
    }

    // MARK: - 元信息

    private var metaBlock: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                chip(icon: "calendar", text: dateChipText) {
                    noteFocused = false
                    showDatePicker = true
                }

                if type == .expense {
                    chip(icon: "clock.arrow.circlepath", text: "追踪", active: tracked) {
                        Haptic.tap()
                        tracked.toggle()
                    }

                    Menu {
                        ForEach(ReimbursementState.allCases) { st in
                            Button {
                                Haptic.tap()
                                reimbursement = st
                            } label: {
                                Label(st.title, systemImage: st == .done ? "checkmark.circle" : "banknote")
                            }
                        }
                    } label: {
                        chipLabel(icon: "banknote",
                                  text: reimbursement == .none ? "报销" : reimbursement.title,
                                  active: reimbursement != .none,
                                  activeTint: reimbursement.tint)
                    }
                }

                Menu {
                    ForEach(Catalog.accounts, id: \.self) { a in
                        Button(a) { account = a }
                    }
                } label: {
                    chipLabel(icon: "creditcard", text: account, active: false)
                }

                Spacer(minLength: 0)
            }

            HStack(spacing: 7) {
                Image(systemName: "square.and.pencil")
                    .font(.system(size: 12))
                    .foregroundStyle(T.text3)
                TextField("写点备注…", text: $note)
                    .font(.system(size: 13.5))
                    .foregroundStyle(T.text)
                    .focused($noteFocused)
                    .submitLabel(.done)
                    .onSubmit { noteFocused = false }
            }
            .padding(.horizontal, 12)
            .frame(height: 36)
            .background(T.fill, in: RoundedRectangle(cornerRadius: 11, style: .continuous))

            receiptRow
        }
        .padding(.bottom, 2)
    }

    /// 凭证：从相册挑一张截图，压缩后跟着这笔账一起存下来
    private var receiptRow: some View {
        HStack(spacing: 8) {
            PhotosPicker(selection: $receiptItem, matching: .images, photoLibrary: .shared()) {
                HStack(spacing: 8) {
                    if let data = receiptData, let img = UIImage(data: data) {
                        Image(uiImage: img)
                            .resizable()
                            .scaledToFill()
                            .frame(width: 32, height: 32)
                            .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                        Text("已附凭证")
                            .font(.system(size: 12.5, weight: .medium))
                            .foregroundStyle(T.text)
                        Text("更换")
                            .font(.system(size: 11.5))
                            .foregroundStyle(T.text3)
                    } else {
                        Image(systemName: "paperclip")
                            .font(.system(size: 11, weight: .medium))
                        Text("添加截图凭证")
                            .font(.system(size: 12.5, weight: .medium))
                    }
                    Spacer(minLength: 0)
                }
                .foregroundStyle(T.text2)
                .padding(.horizontal, 12)
                .frame(height: 36)
                .background(T.fill, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
            }
            .buttonStyle(.plain)

            if receiptData != nil {
                Button {
                    Haptic.tap()
                    receiptData = nil
                    receiptItem = nil
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(T.text3)
                        .frame(width: 36, height: 36)
                        .background(T.fill, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func chip(icon: String, text: String, active: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            chipLabel(icon: icon, text: text, active: active)
        }
        .buttonStyle(.plain)
    }

    private func chipLabel(icon: String,
                           text: String,
                           active: Bool,
                           activeTint: Color? = nil) -> some View {
        let fg: Color = active ? (activeTint == nil ? T.bg : .white) : T.text2
        return HStack(spacing: 5) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .medium))
            Text(text)
                .font(.system(size: 12.5, weight: .medium))
        }
        .foregroundStyle(fg)
        .padding(.horizontal, 10)
        .frame(height: 32)
        .background(active ? (activeTint ?? T.text) : T.fill,
                    in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    // MARK: - 键盘

    private let keys: [[String]] = [
        ["1", "2", "3"],
        ["4", "5", "6"],
        ["7", "8", "9"],
        [".", "0", "⌫"]
    ]

    private var keypad: some View {
        VStack(spacing: 6) {
            ForEach(keys, id: \.self) { row in
                HStack(spacing: 6) {
                    ForEach(row, id: \.self) { key in
                        keyButton(key)
                    }
                }
            }
        }
    }

    private func keyButton(_ key: String) -> some View {
        Button {
            press(key)
        } label: {
            Group {
                if key == "⌫" {
                    Image(systemName: "delete.left")
                        .font(.system(size: 19, weight: .regular))
                } else {
                    Text(key)
                        .font(.system(size: 23, weight: .regular))
                        .tracking(-0.3)
                }
            }
            .foregroundStyle(T.text)
            .frame(maxWidth: .infinity)
            .frame(height: 50)
            .background(T.bg, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(KeypadStyle())
    }

    private func press(_ key: String) {
        Haptic.tap()
        switch key {
        case "⌫":
            if !amountText.isEmpty { amountText.removeLast() }
        case ".":
            if amountText.isEmpty {
                amountText = "0."
            } else if !amountText.contains(".") {
                amountText += "."
            }
        default:
            if let dot = amountText.firstIndex(of: ".") {
                let decimals = amountText.distance(from: dot, to: amountText.endIndex) - 1
                if decimals >= 2 { return }
            }
            if amountText == "0" {
                amountText = key
                return
            }
            let digits = amountText.replacingOccurrences(of: ".", with: "").count
            if digits >= 9 { return }
            amountText += key
        }
    }

    // MARK: - 日期选择

    private var datePickerSheet: some View {
        VStack(spacing: 0) {
            HStack {
                Text("选择日期")
                    .font(.system(size: 15, weight: .semibold))
                Spacer()
                Button("完成") { showDatePicker = false }
                    .font(.system(size: 14.5, weight: .semibold))
            }
            .padding(.horizontal, T.hPadding)
            .padding(.top, 18)

            DatePicker("", selection: $date, in: ...Date(), displayedComponents: .date)
                .datePickerStyle(.graphical)
                .labelsHidden()
                .padding(.horizontal, 8)
                .tint(T.text)

            Spacer(minLength: 0)
        }
        .presentationDetents([.medium])
        .presentationDragIndicator(.visible)
        .background(T.bg)
    }

    // MARK: - 数据

    private func loadInitial() {
        guard let bill = editing else {
            type = .expense
            categoryID = "food"
            date = Date()
            return
        }
        type = bill.type
        categoryID = bill.categoryID
        note = bill.note
        date = bill.date
        account = bill.account
        tracked = bill.isTracked && bill.type == .expense
        reimbursement = bill.type == .expense ? bill.reimbursement : .none
        receiptData = bill.receiptData

        // 回填金额文本，保持小数结构
        let raw = String(format: "%.2f", bill.amount)
        amountText = raw.hasSuffix(".00") ? String(raw.dropLast(3)) : raw
    }

    private func loadReceipt(_ item: PhotosPickerItem) async {
        guard let data = try? await item.loadTransferable(type: Data.self),
              let image = UIImage(data: data),
              let compressed = ReceiptStore.compress(image) else { return }
        await MainActor.run { receiptData = compressed }
    }

    private func save() {
        guard canSave else { return }
        noteFocused = false

        let rounded = (amount * 100).rounded() / 100
        let trimmed = note.trimmingCharacters(in: .whitespacesAndNewlines)
        let reimb: ReimbursementState = (type == .expense) ? reimbursement : .none

        if let bill = editing {
            bill.type = type
            bill.amount = rounded
            bill.categoryID = categoryID
            bill.note = trimmed
            bill.date = date
            bill.account = account
            bill.isTracked = (type == .expense) ? tracked : false
            bill.reimbursement = reimb
            bill.receiptData = receiptData
            if bill.isTracked && bill.status == .done {
                bill.status = .active
            }
        } else {
            let bill = Bill(type: type,
                            amount: rounded,
                            categoryID: categoryID,
                            note: trimmed,
                            date: date,
                            account: account,
                            isTracked: (type == .expense) ? tracked : false,
                            status: (type == .expense && tracked) ? .active : .done,
                            reimbursement: reimb,
                            receiptData: receiptData)
            context.insert(bill)
        }

        try? context.save()
        Haptic.success()
        dismiss()
    }
}

// MARK: - 键盘按钮样式

struct KeypadStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(configuration.isPressed ? T.fill : Color.clear)
            )
            .animation(.easeOut(duration: 0.08), value: configuration.isPressed)
    }
}
