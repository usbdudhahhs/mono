//
//  Components.swift
//  MonoLedger
//
//  复用组件
//

import SwiftUI
import UIKit

// MARK: - 分类图标

struct CategoryBadge: View {
    let category: Category
    var size: CGFloat = 38

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.31, style: .continuous)
                .fill(category.color.opacity(0.13))
            Image(systemName: category.symbol)
                .font(.system(size: size * 0.44, weight: .medium))
                .foregroundStyle(category.color)
        }
        .frame(width: size, height: size)
    }
}

// MARK: - 追踪徽标

struct TrackBadge: View {
    let status: TrackStatus
    var days: Int = 0

    var body: some View {
        Text(status.shortLabel(days: days))
            .font(.system(size: 9.5, weight: .semibold))
            .foregroundStyle(status.tint)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(status.tint.opacity(0.13), in: Capsule())
    }
}

// MARK: - 分段控件

struct SegmentedBar<Value: Hashable>: View {
    let items: [Value]
    let title: (Value) -> String
    @Binding var selection: Value

    var body: some View {
        HStack(spacing: 0) {
            ForEach(items, id: \.self) { item in
                Button {
                    withAnimation(.easeOut(duration: 0.18)) { selection = item }
                } label: {
                    Text(title(item))
                        .font(.system(size: 13.5, weight: .medium))
                        .foregroundStyle(selection == item ? T.bg : T.text2)
                        .frame(maxWidth: .infinity)
                        .frame(height: 32)
                        .background {
                            if selection == item {
                                RoundedRectangle(cornerRadius: 9, style: .continuous)
                                    .fill(T.text)
                            }
                        }
                }
                .buttonStyle(.plain)
            }
        }
        .padding(3)
        .background(T.fill, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
    }
}

// MARK: - 区块标题

struct SectionLabel: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.system(size: 11.5, weight: .medium))
            .foregroundStyle(T.text3)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 4)
            .padding(.bottom, 2)
    }
}

// MARK: - 进度条

struct ProgressLine: View {
    var progress: Double      // 0...1
    var tint: Color = T.text
    var height: CGFloat = 5

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(T.fill)
                Capsule()
                    .fill(tint)
                    .frame(width: max(0, min(1, progress)) * geo.size.width)
            }
        }
        .frame(height: height)
    }
}

// MARK: - 空状态

struct EmptyStateView: View {
    let title: String
    let detail: String
    var symbol: String = "circle.dashed"

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 30, weight: .ultraLight))
                .foregroundStyle(T.text3)
            Text(title)
                .font(.system(size: 14.5, weight: .medium))
                .foregroundStyle(T.text)
            Text(detail)
                .font(.system(size: 11.5))
                .foregroundStyle(T.text3)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 56)
    }
}

// MARK: - 列表行容器（圆角分组卡片）

struct GroupCard<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        VStack(spacing: 0) { content }
            .background(T.card, in: RoundedRectangle(cornerRadius: T.cardRadius, style: .continuous))
    }
}

/// 行内分隔线（从图标右侧开始，模仿 iOS 列表）
struct RowDivider: View {
    var leading: CGFloat = 64
    var body: some View {
        Rectangle()
            .fill(T.line)
            .frame(height: 0.6)
            .padding(.leading, leading)
    }
}

// MARK: - 轻提示

struct ToastModifier: ViewModifier {
    @Binding var text: String?

    func body(content: Content) -> some View {
        content.overlay(alignment: .bottom) {
            if let text {
                Text(text)
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(T.bg)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 9)
                    .background(T.text, in: Capsule())
                    .shadow(color: .black.opacity(0.12), radius: 12, y: 4)
                    .padding(.bottom, 18)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
    }
}

extension View {
    func toast(_ text: Binding<String?>) -> some View {
        modifier(ToastModifier(text: text))
    }
}

// MARK: - 系统分享

struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}

// MARK: - 触感反馈

enum Haptic {
    static func tap() {
        let g = UIImpactFeedbackGenerator(style: .light)
        g.impactOccurred()
    }

    static func success() {
        let g = UINotificationFeedbackGenerator()
        g.notificationOccurred(.success)
    }
}
