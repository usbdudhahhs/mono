//
//  ShortcutGuideView.swift
//  MonoLedger
//
//  把「轻点背面 → 识别 → 记账」讲清楚，并尽量少的手动步骤
//

import SwiftUI
import UIKit

struct ShortcutGuideView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var toastText: String?
    @State private var authorized = LatestScreenshot.isAuthorized

    private struct Step: Identifiable {
        let id = UUID()
        let index: String
        let title: String
        let detail: String
        let symbol: String
    }

    /// 零配置：App 自带的快捷指令已经在系统里了
    private let quickSteps: [Step] = [
        Step(index: "1", title: "打开「轻点背面」",
             detail: "设置 → 辅助功能 → 触控 → 轻点背面 → 轻点两下", symbol: "hand.tap"),
        Step(index: "2", title: "选中「截图记账」",
             detail: "它挂在 MONO 名下，不用新建、不用加动作。列表里没有的话，就用下面的方式二", symbol: "checkmark.circle")
    ]

    /// 全自动：自己拼一条，连截屏都省了
    private let autoSteps: [Step] = [
        Step(index: "1", title: "新建一个快捷指令",
             detail: "打开「快捷指令」App，点右上角 +", symbol: "plus"),
        Step(index: "2", title: "添加「截屏」动作",
             detail: "搜索「截屏」，选中后它会截下当前屏幕", symbol: "camera.viewfinder"),
        Step(index: "3", title: "添加「截图记账」动作",
             detail: "搜索「MONO」，选中「截图记账」。上一步的截图会自动传进来", symbol: "doc.text.viewfinder"),
        Step(index: "4", title: "关掉运行前询问",
             detail: "点动作右侧的箭头，关闭「运行前询问」，截完就自动记", symbol: "bolt"),
        Step(index: "5", title: "命名并绑到轻点背面",
             detail: "命名为「记账」，再到 设置 → 辅助功能 → 触控 → 轻点背面 里选中它", symbol: "hand.draw")
    ]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    intro
                    section(title: "方式一 · 零配置",
                            caption: "先截屏，再点背面",
                            steps: quickSteps,
                            accent: T.blue)
                    section(title: "方式二 · 全自动",
                            caption: "配一次，之后连截屏都不用按",
                            steps: autoSteps,
                            accent: T.green)
                    usageCard
                    permissionCard
                }
                .padding(.horizontal, T.hPadding)
                .padding(.top, 6)
                .padding(.bottom, 30)
            }
            .background(T.bg)
            .navigationTitle("快捷指令")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("关闭") { dismiss() }
                        .foregroundStyle(T.text2)
                }
            }
            .safeAreaInset(edge: .bottom) {
                actions
            }
            .toast($toastText)
            .onAppear { authorized = LatestScreenshot.isAuthorized }
        }
    }

    // MARK: - 头部

    private var intro: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("点两下背面，账就记好了")
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(T.text)
            Text("识别、分类、入账全在手机上完成，不联网。截图会跟着这笔账一起存下来。")
                .font(.system(size: 12.5))
                .foregroundStyle(T.text2)
                .lineSpacing(3)
        }
        .padding(.top, 4)
    }

    // MARK: - 分组

    private func section(title: String,
                         caption: String,
                         steps: [Step],
                         accent: Color) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 7) {
                Circle()
                    .fill(accent)
                    .frame(width: 5, height: 5)
                Text(title)
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(T.text)
                Text(caption)
                    .font(.system(size: 11))
                    .foregroundStyle(T.text3)
            }

            VStack(spacing: 14) {
                ForEach(steps) { stepRow($0) }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(T.grouped, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private func stepRow(_ step: Step) -> some View {
        HStack(alignment: .top, spacing: 12) {
            ZStack {
                Circle()
                    .fill(T.text)
                    .frame(width: 22, height: 22)
                Text(step.index)
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(T.bg)
            }
            .padding(.top, 1)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 5) {
                    Text(step.title)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(T.text)
                    Image(systemName: step.symbol)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(T.text3)
                }
                Text(step.detail)
                    .font(.system(size: 12))
                    .foregroundStyle(T.text2)
                    .lineSpacing(2.5)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: - 用法

    private var usageCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("配好之后")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(T.text3)
                .tracking(0.4)

            VStack(alignment: .leading, spacing: 8) {
                bullet("微信或支付宝付款，页面停在「支付成功」")
                bullet("用方式一：先按侧边键 + 音量上键截个屏，再轻点两下背面")
                bullet("用方式二：直接轻点两下背面，连截屏都省了")
                bullet("金额、商户、分类自动填好，截图原图跟着账单存下来")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(T.grouped, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private func bullet(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Circle()
                .fill(T.text3)
                .frame(width: 3.5, height: 3.5)
                .padding(.top, 6)
            Text(text)
                .font(.system(size: 12.5))
                .foregroundStyle(T.text2)
                .lineSpacing(2)
        }
    }

    // MARK: - 相册权限

    private var permissionCard: some View {
        HStack(spacing: 10) {
            Image(systemName: authorized ? "checkmark.circle.fill" : "photo.on.rectangle")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(authorized ? T.green : T.orange)

            VStack(alignment: .leading, spacing: 2) {
                Text(authorized ? "相册已授权" : "还没允许读取相册")
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(T.text)
                Text(authorized
                     ? "后台能直接拿到你刚截的那张图"
                     : "不授权的话，轻点背面时取不到截图")
                    .font(.system(size: 11))
                    .foregroundStyle(T.text3)
            }

            Spacer(minLength: 4)

            if !authorized {
                Button("去开启") {
                    guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
                    UIApplication.shared.open(url)
                }
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(T.blue)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(T.fill, in: RoundedRectangle(cornerRadius: 13, style: .continuous))
    }

    // MARK: - 底部

    private var actions: some View {
        VStack(spacing: 0) {
            Divider().overlay(T.line)
            VStack(spacing: 8) {
                Button {
                    openShortcutsApp()
                } label: {
                    Text("打开快捷指令")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(T.bg)
                        .frame(maxWidth: .infinity)
                        .frame(height: 50)
                        .background(T.text, in: RoundedRectangle(cornerRadius: 15, style: .continuous))
                }

                Button {
                    copySteps()
                } label: {
                    Text("复制步骤说明")
                        .font(.system(size: 13.5, weight: .medium))
                        .foregroundStyle(T.text2)
                        .frame(maxWidth: .infinity)
                        .frame(height: 34)
                }
            }
            .padding(.horizontal, T.hPadding)
            .padding(.top, 10)
            .padding(.bottom, 4)
        }
        .background(T.bg)
    }

    private func openShortcutsApp() {
        guard let url = URL(string: "shortcuts://") else { return }
        UIApplication.shared.open(url)
    }

    private func copySteps() {
        let text = """
        MONO 点背面记账

        【方式一 · 零配置】
        App 装好后，快捷指令里就已经有「MONO 截图记账」了。
        设置 → 辅助功能 → 触控 → 轻点背面 → 轻点两下 → 选「MONO 截图记账」
        用法：付款页按侧边键 + 音量上键截屏，然后轻点两下背面。

        【方式二 · 全自动，配一次】
        1. 快捷指令 App，右上角 + 新建
        2. 加动作「截屏」
        3. 再加动作「截图记账」（搜 MONO）
        4. 点动作右侧箭头，关掉「运行前询问」
        5. 命名「记账」，绑到 设置 → 辅助功能 → 触控 → 轻点背面
        之后轻点背面就是：截屏 → 识别 → 自动入账。
        """
        UIPasteboard.general.string = text
        Haptic.success()
        withAnimation(.spring(duration: 0.3)) { toastText = "已复制" }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) {
            withAnimation(.easeOut(duration: 0.2)) { toastText = nil }
        }
    }
}
