//
//  AttachmentGalleryView.swift
//  MonoLedger
//
//  凭证墙：所有截图按月摊开，报销对账时一屏翻完
//

import SwiftUI
import SwiftData
import ImageIO
import UIKit

struct AttachmentGalleryView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss

    @Query(filter: Bill.activeFilter,
           sort: [SortDescriptor(\Bill.date, order: .reverse)])
    private var allBills: [Bill]

    @State private var preview: Bill?
    @State private var toastText: String?
    @State private var showSlimConfirm = false
    @State private var isSlimming = false

    private var bills: [Bill] {
        allBills.filter { $0.hasReceipt }
    }

    private var totalBytes: Int {
        bills.reduce(0) { $0 + ($1.receiptData?.count ?? 0) }
    }

    // MARK: - 分组

    private struct MonthGroup: Identifiable {
        let id: String
        let month: Date
        let items: [Bill]
    }

    private var groups: [MonthGroup] {
        let calendar = Calendar.current
        let dict = Dictionary(grouping: bills) { bill in
            calendar.dateComponents([.year, .month], from: bill.date)
        }
        return dict.compactMap { comps, items -> MonthGroup? in
            guard let year = comps.year, let month = comps.month,
                  let date = calendar.date(from: DateComponents(year: year, month: month, day: 1)) else {
                return nil
            }
            return MonthGroup(id: String(format: "%04d-%02d", year, month),
                              month: date,
                              items: items.sorted { $0.date > $1.date })
        }
        .sorted { $0.month > $1.month }
    }

    // MARK: - Body

    var body: some View {
        ScrollView {
            VStack(spacing: 18) {
                if !bills.isEmpty {
                    summary
                }

                if bills.isEmpty {
                    EmptyStateView(title: "还没有凭证图",
                                   detail: "用快捷指令截图记账，或记账时加一张图，这里就会按月排开",
                                   symbol: "photo.on.rectangle.angled")
                        .padding(.top, 24)
                } else {
                    ForEach(groups) { group in
                        monthSection(group)
                    }
                }
            }
            .padding(.horizontal, T.hPadding)
            .padding(.top, 6)
            .padding(.bottom, 30)
        }
        .scrollIndicators(.hidden)
        .background(T.bg)
        .navigationTitle("凭证")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button("关闭") { dismiss() }
                    .foregroundStyle(T.text2)
            }
            if !bills.isEmpty {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(isSlimming ? "压缩中…" : "压缩") { showSlimConfirm = true }
                        .font(.system(size: 13.5))
                        .foregroundStyle(isSlimming ? T.text3 : T.text2)
                        .disabled(isSlimming)
                }
            }
        }
        .toast($toastText)
        .confirmationDialog("压缩已有凭证图？",
                            isPresented: $showSlimConfirm,
                            titleVisibility: .visible) {
            Button("压缩到长边 1200") { slimReceipts() }
            Button("取消", role: .cancel) {}
        } message: {
            Text("共 \(bills.count) 张，当前 \(ReceiptStore.sizeText(totalBytes))。压缩后放大仍能看清商户和金额，够报销对账，通常还能再省一半。")
        }
        .sheet(item: $preview) { bill in
            AttachmentPreview(bill: bill)
        }
    }

    // MARK: - 汇总

    private var summary: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text("\(bills.count) 张凭证")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(T.text)
                Text(ReceiptStore.sizeText(totalBytes) + " · 点开可看原图")
                    .font(.system(size: 11.5))
                    .foregroundStyle(T.text3)
            }

            Spacer()

            if let first = bills.first, let last = bills.last {
                Text(Dates.shortDate(last.date) + "–" + Dates.shortDate(first.date))
                    .font(.system(size: 11))
                    .foregroundStyle(T.text3)
                    .monospacedDigit()
            }
        }
        .padding(14)
        .background(T.grouped, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    // MARK: - 月份区块

    private func monthSection(_ group: MonthGroup) -> some View {
        VStack(spacing: 8) {
            HStack {
                Text(Dates.monthTitle(group.month))
                    .font(.system(size: 13.5, weight: .semibold))
                    .foregroundStyle(T.text)
                Text("\(group.items.count) 张")
                    .font(.system(size: 11))
                    .foregroundStyle(T.text3)
                Spacer()
            }

            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 3), count: 3),
                      spacing: 3) {
                ForEach(group.items) { bill in
                    Button {
                        Haptic.tap()
                        preview = bill
                    } label: {
                        thumb(bill)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private func thumb(_ bill: Bill) -> some View {
        ZStack(alignment: .bottom) {
            if let image = ReceiptStore.thumbnail(bill.receiptData, key: bill.uuid) {
                GeometryReader { geo in
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                        .frame(width: geo.size.width, height: geo.size.height)
                        .clipped()
                }
            } else {
                T.fill
            }

            LinearGradient(colors: [.clear, .black.opacity(0.55)],
                           startPoint: .center, endPoint: .bottom)

            HStack(spacing: 3) {
                Text(bill.type.sign + "¥" + Fmt.money(bill.amount))
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(.white)
                    .monospacedDigit()
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 5)
            .padding(.bottom, 4)
        }
        .aspectRatio(3.0 / 4.0, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
    }

    // MARK: - 压缩

    /// 只压「明显还很大」的图，已经是新规格的不再二次编码，避免白白损失画质。
    ///
    /// 解码 + 重编码一张图要几十毫秒，一百张就是好几秒。放主线程会整屏冻住，
    /// 所以先把图片字节拷出来（Data 是值类型，跨线程安全），后台压完再回主线程写库。
    private func slimReceipts() {
        guard !isSlimming else { return }

        // 主线程取快照：不能把 Bill 对象带到后台线程。
        // 键用 persistentModelID 而不是 uuid —— 从老备份恢复的账单 uuid 可能是空串，
        // 拿空串当键会让几十张图互相覆盖，最后全变成同一张。
        let snapshot: [(key: String, data: Data)] = bills.compactMap { bill in
            guard let data = bill.receiptData else { return nil }
            return (String(describing: bill.persistentModelID), data)
        }
        guard !snapshot.isEmpty else {
            showToast("凭证图已经是最省的状态")
            return
        }

        isSlimming = true
        showToast("正在压缩 \(snapshot.count) 张…")

        DispatchQueue.global(qos: .userInitiated).async {
            var packed: [String: Data] = [:]
            var saved = 0

            for item in snapshot {
                // 只读图片头拿像素尺寸，不整张解码；已经是新规格的直接跳过
                guard let source = CGImageSourceCreateWithData(item.data as CFData, nil),
                      let raw = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) else { continue }
                let props = raw as NSDictionary
                let w = (props[kCGImagePropertyPixelWidth] as? NSNumber)?.doubleValue ?? 0
                let h = (props[kCGImagePropertyPixelHeight] as? NSNumber)?.doubleValue ?? 0
                if max(w, h) <= 1240 && item.data.count <= 200_000 { continue }

                guard let image = UIImage(data: item.data),
                      let small = ReceiptStore.compress(image),
                      small.count < item.data.count else { continue }

                saved += item.data.count - small.count
                packed[item.key] = small
            }

            // 交给主线程的是不可变副本，避免后台写、前台读同一个变量
            let result = packed
            let savedBytes = saved

            Task { @MainActor in
                isSlimming = false

                guard !result.isEmpty else {
                    showToast("凭证图已经是最省的状态")
                    return
                }

                for bill in bills {
                    if let data = result[String(describing: bill.persistentModelID)] {
                        bill.receiptData = data
                    }
                }

                if let error = AppData.save(context) {
                    showToast("压缩失败：\(error)")
                } else {
                    showToast("已压缩 \(result.count) 张，省下 " + ReceiptStore.sizeText(savedBytes))
                }
            }
        }
    }

    private func showToast(_ text: String) {
        withAnimation(.spring(duration: 0.3)) { toastText = text }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.7) {
            withAnimation(.easeOut(duration: 0.2)) { toastText = nil }
        }
    }
}

// MARK: - 大图

private struct AttachmentPreview: View {
    @Environment(\.dismiss) private var dismiss

    let bill: Bill

    @State private var showShare = false

    var body: some View {
        ZStack(alignment: .top) {
            Color.black.ignoresSafeArea()

            if let image = ReceiptStore.image(from: bill.receiptData) {
                ZoomableImage(image: image)
                    .padding(.vertical, 70)
            } else {
                Text("这张凭证图读不出来")
                    .font(.system(size: 13))
                    .foregroundStyle(.white.opacity(0.7))
            }

            HStack {
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 34, height: 34)
                        .background(.white.opacity(0.16), in: Circle())
                }
                .buttonStyle(.plain)

                Spacer()

                if bill.hasReceipt {
                    Button {
                        showShare = true
                    } label: {
                        Image(systemName: "square.and.arrow.up")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(width: 34, height: 34)
                            .background(.white.opacity(0.16), in: Circle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)

            VStack {
                Spacer()
                info
            }
        }
        .sheet(isPresented: $showShare) {
            if let image = ReceiptStore.image(from: bill.receiptData) {
                ShareSheet(items: [image])
            }
        }
    }

    private var info: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(bill.title)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)

                Spacer(minLength: 6)

                Text(bill.type.sign + "¥" + Fmt.money(bill.amount))
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(.white)
                    .monospacedDigit()
            }

            HStack(spacing: 8) {
                Text(Dates.fullDate(bill.date))
                Text("·")
                Text(bill.category.name)
                if bill.reimbursement != .none {
                    Text("·")
                    Text(bill.reimbursement.title)
                }
                Spacer(minLength: 0)
            }
            .font(.system(size: 11.5))
            .foregroundStyle(.white.opacity(0.65))
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
        .background(.black.opacity(0.55))
    }
}
