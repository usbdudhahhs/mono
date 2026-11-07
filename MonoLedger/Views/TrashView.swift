//
//  TrashView.swift
//  MonoLedger
//
//  回收站：删错的账单在这儿躺 30 天，随时能捞回来
//

import SwiftUI
import SwiftData

struct TrashView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss

    @Query private var allBills: [Bill]

    @State private var toastText: String?
    @State private var showEmptyConfirm = false

    private var items: [Bill] {
        allBills
            .filter { $0.isInTrash }
            .sorted { ($0.deletedAt ?? .distantPast) > ($1.deletedAt ?? .distantPast) }
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                hint

                if items.isEmpty {
                    EmptyStateView(title: "回收站是空的",
                                   detail: "删掉的账单会先放这儿，30 天后自动彻底清除",
                                   symbol: "trash")
                        .padding(.top, 24)
                } else {
                    list
                }
            }
            .padding(.horizontal, T.hPadding)
            .padding(.top, 6)
            .padding(.bottom, 30)
        }
        .scrollIndicators(.hidden)
        .background(T.bg)
        .navigationTitle("回收站")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button("关闭") { dismiss() }
                    .foregroundStyle(T.text2)
            }
            if !items.isEmpty {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("清空") { showEmptyConfirm = true }
                        .font(.system(size: 13.5))
                        .foregroundStyle(T.red)
                }
            }
        }
        .toast($toastText)
        .confirmationDialog("彻底删除这 \(items.count) 笔？",
                            isPresented: $showEmptyConfirm,
                            titleVisibility: .visible) {
            Button("彻底删除", role: .destructive) { emptyAll() }
            Button("取消", role: .cancel) {}
        } message: {
            Text("删除后无法恢复，凭证图也会一起清掉。")
        }
    }

    // MARK: - 说明

    private var hint: some View {
        HStack(spacing: 9) {
            Image(systemName: "clock.arrow.circlepath")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(T.text3)

            Text("删除的账单保留 \(Trash.retentionDays) 天，到期自动清除。恢复后会回到原来的日期和分类。")
                .font(.system(size: 11.5))
                .foregroundStyle(T.text2)
                .lineSpacing(2)

            Spacer(minLength: 0)
        }
        .padding(13)
        .background(T.grouped, in: RoundedRectangle(cornerRadius: 13, style: .continuous))
    }

    // MARK: - 列表

    private var list: some View {
        VStack(spacing: 7) {
            SectionLabel(text: "\(items.count) 笔已删除")

            GroupCard {
                // 用账单自己的 id，不要用数组下标：恢复一笔之后数组会缩短，
                // 下标做标识会让 SwiftUI 把后面的行错配到前一行上
                ForEach(items) { bill in
                    row(bill)
                    if bill.persistentModelID != items.last?.persistentModelID {
                        RowDivider()
                    }
                }
            }
        }
    }

    private func row(_ bill: Bill) -> some View {
        HStack(spacing: 10) {
            CategoryBadge(category: bill.category, size: 36)

            VStack(alignment: .leading, spacing: 2) {
                Text(bill.title)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(T.text)
                    .lineLimit(1)

                Text("\(Dates.shortDate(bill.date)) · 还剩 \(bill.trashDaysLeft) 天")
                    .font(.system(size: 10.5))
                    .foregroundStyle(T.text3)
            }

            Spacer(minLength: 4)

            Text(bill.type.sign + Fmt.money(bill.amount))
                .font(.system(size: 14.5, weight: .medium))
                .foregroundStyle(T.text2)
                .monospacedDigit()

            HStack(spacing: 6) {
                Button {
                    restore(bill)
                } label: {
                    Image(systemName: "arrow.uturn.backward")
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundStyle(T.text2)
                        .frame(width: 28, height: 28)
                        .background(T.fill, in: Circle())
                }
                .buttonStyle(.plain)

                Button {
                    deleteForever(bill)
                } label: {
                    Image(systemName: "trash")
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundStyle(T.red)
                        .frame(width: 28, height: 28)
                        .background(T.red.opacity(0.10), in: Circle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 12)
    }

    // MARK: - 操作

    private func restore(_ bill: Bill) {
        Haptic.success()
        bill.deletedAt = nil
        if let error = AppData.save(context) {
            showToast("恢复失败：\(error)")
        } else {
            showToast("已恢复「\(bill.title)」")
        }
    }

    private func deleteForever(_ bill: Bill) {
        Haptic.tap()
        context.delete(bill)
        if let error = AppData.save(context) {
            showToast("删除失败：\(error)")
        } else {
            showToast("已彻底删除")
        }
    }

    private func emptyAll() {
        Haptic.tap()
        for bill in items { context.delete(bill) }
        if let error = AppData.save(context) {
            showToast("清空失败：\(error)")
        } else {
            showToast("回收站已清空")
        }
    }

    private func showToast(_ text: String) {
        withAnimation(.spring(duration: 0.3)) { toastText = text }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) {
            withAnimation(.easeOut(duration: 0.2)) { toastText = nil }
        }
    }
}
