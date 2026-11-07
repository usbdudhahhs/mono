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

// MARK: - 可缩放大图

/// 凭证图查看器：双指放大、拖动、双击复位。
///
/// 截图压到长边 1200 后，在手机屏上按宽度铺满只剩三百多点，
/// 报销对账时要看清商户名和订单号必须能放大 —— 只给 ScrollView 是不够的。
struct ZoomableImage: View {
    let image: UIImage
    var maxScale: CGFloat = 4

    @State private var scale: CGFloat = 1
    @State private var baseScale: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var baseOffset: CGSize = .zero

    var body: some View {
        GeometryReader { geo in
            Image(uiImage: image)
                .resizable()
                .scaledToFit()
                .frame(width: geo.size.width, height: geo.size.height)
                .scaleEffect(scale)
                .offset(offset)
                .gesture(magnify)
                .simultaneousGesture(drag(in: geo.size), including: scale > 1 ? .all : .none)
                .onTapGesture(count: 2) { toggleZoom() }
        }
        .clipped()
    }

    private var magnify: some Gesture {
        MagnifyGesture()
            .onChanged { value in
                scale = min(maxScale, max(1, baseScale * value.magnification))
            }
            .onEnded { _ in
                baseScale = scale
                if scale <= 1.01 { reset() }
            }
    }

    /// 放大后拖动，但不能把图拖出屏幕外 —— 拖飞了只能双击复位，很难受
    private func drag(in size: CGSize) -> some Gesture {
        DragGesture()
            .onChanged { value in
                guard scale > 1 else { return }
                let limitX = size.width * (scale - 1) / 2
                let limitY = size.height * (scale - 1) / 2
                offset = CGSize(
                    width: min(limitX, max(-limitX, baseOffset.width + value.translation.width)),
                    height: min(limitY, max(-limitY, baseOffset.height + value.translation.height))
                )
            }
            .onEnded { _ in baseOffset = offset }
    }

    private func toggleZoom() {
        if scale > 1.01 {
            reset()
        } else {
            withAnimation(.easeOut(duration: 0.22)) {
                scale = 2.4
                baseScale = 2.4
            }
        }
    }

    private func reset() {
        withAnimation(.easeOut(duration: 0.22)) {
            scale = 1
            baseScale = 1
            offset = .zero
            baseOffset = .zero
        }
    }
}
