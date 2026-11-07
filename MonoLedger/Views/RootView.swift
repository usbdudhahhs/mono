//
//  RootView.swift
//  MonoLedger
//
//  主框架：账单、统计、我的 + 中间凸起记账按钮
//

import SwiftUI

enum RootTab: Hashable {
    case bills
    case stats
    case me
}

struct RootView: View {
    @Environment(\.modelContext) private var context

    @State private var tab: RootTab = .bills
    @State private var showAdd = false
    @State private var saveFailureMessage: String?

    var body: some View {
        ZStack {
            T.bg.ignoresSafeArea()

            Group {
                switch tab {
                case .bills:
                    BillsView()
                case .stats:
                    StatsView()
                case .me:
                    NavigationStack { MeView() }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            MainTabBar(tab: $tab) {
                Haptic.tap()
                showAdd = true
            }
        }
        .sheet(isPresented: $showAdd) {
            AddRecordView()
        }
        .tint(T.text)
        .onReceive(NotificationCenter.default.publisher(for: .monoSaveFailed)) { notification in
            saveFailureMessage = notification.userInfo?["message"] as? String ?? "请检查设备存储空间后重试。"
        }
        .onAppear {
            // 回收站到期清理，启动时做一次就够，不用等用户点进去
            Trash.purgeExpired(context)

            if saveFailureMessage == nil, let warning = AppData.storageWarning {
                saveFailureMessage = warning
            }
        }
        .alert("MONO 提示", isPresented: Binding(
            get: { saveFailureMessage != nil },
            set: { if !$0 { saveFailureMessage = nil } }
        )) {
            Button("知道了", role: .cancel) { saveFailureMessage = nil }
        } message: {
            Text(saveFailureMessage ?? "账单未能保存，请重试。")
        }
    }
}

// MARK: - 底部导航

struct MainTabBar: View {
    @Binding var tab: RootTab
    var onAdd: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            item(.bills, "账单", "list.bullet.rectangle", "list.bullet.rectangle.fill")
            item(.stats, "统计", "chart.bar", "chart.bar.fill")
            addButton
            item(.me, "我的", "person", "person.fill")
        }
        .padding(.top, 9)
        .padding(.bottom, 4)
        .background {
            Rectangle()
                .fill(.regularMaterial)
                .overlay(alignment: .top) {
                    Rectangle().fill(T.line).frame(height: 0.6)
                }
                .ignoresSafeArea(edges: .bottom)
        }
    }

    private func item(_ value: RootTab, _ title: String, _ symbol: String, _ filled: String) -> some View {
        Button {
            if tab != value { Haptic.tap() }
            withAnimation(.easeOut(duration: 0.15)) { tab = value }
        } label: {
            VStack(spacing: 3) {
                Image(systemName: tab == value ? filled : symbol)
                    .font(.system(size: 19, weight: .regular))
                    .symbolRenderingMode(.hierarchical)
                Text(title)
                    .font(.system(size: 9.5, weight: .medium))
            }
            .foregroundStyle(tab == value ? T.text : T.text3)
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var addButton: some View {
        Button(action: onAdd) {
            ZStack {
                Circle()
                    .fill(T.text)
                    .frame(width: 50, height: 50)
                    .shadow(color: .black.opacity(0.16), radius: 10, x: 0, y: 4)
                Image(systemName: "plus")
                    .font(.system(size: 21, weight: .medium))
                    .foregroundStyle(T.bg)
            }
            .frame(maxWidth: .infinity)
            .offset(y: -6)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - 卡片式容器（页面统一底部留白）

struct PageContainer<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                content
            }
            .padding(.horizontal, T.hPadding)
            .padding(.top, 4)
            .padding(.bottom, 26)
        }
        .scrollIndicators(.hidden)
        .background(T.bg)
    }
}
