//
//  Theme.swift
//  MonoLedger
//
//  设计令牌：颜色、字号、圆角、间距
//

import SwiftUI
import UIKit

// MARK: - Color

extension Color {
    /// 从 #RRGGBB 创建颜色
    init(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("#") { s.removeFirst() }
        var v: UInt64 = 0
        Scanner(string: s).scanHexInt64(&v)
        let r = Double((v >> 16) & 0xFF) / 255.0
        let g = Double((v >> 8) & 0xFF) / 255.0
        let b = Double(v & 0xFF) / 255.0
        self.init(.sRGB, red: r, green: g, blue: b, opacity: 1)
    }

    /// 动态颜色：跟随系统深浅色
    init(light: UIColor, dark: UIColor) {
        self.init(uiColor: UIColor { trait in
            trait.userInterfaceStyle == .dark ? dark : light
        })
    }
}

// MARK: - Tokens

enum T {
    // 底色
    static let bg       = Color(light: .white,
                                dark: UIColor(white: 0.043, alpha: 1))
    static let card     = Color(light: .white,
                                dark: UIColor(white: 0.094, alpha: 1))
    static let grouped  = Color(light: UIColor(white: 0.957, alpha: 1),
                                dark: UIColor(white: 0.113, alpha: 1))
    static let fill     = Color(light: UIColor(white: 0.925, alpha: 1),
                                dark: UIColor(white: 0.165, alpha: 1))

    // 文字
    static let text     = Color(light: UIColor(white: 0.04, alpha: 1),
                                dark: UIColor(white: 0.965, alpha: 1))
    static let text2    = Color(light: UIColor(white: 0.42, alpha: 1),
                                dark: UIColor(white: 0.62, alpha: 1))
    static let text3    = Color(light: UIColor(white: 0.64, alpha: 1),
                                dark: UIColor(white: 0.43, alpha: 1))

    // 线与分隔
    static let line     = Color(light: UIColor(white: 0.0, alpha: 0.07),
                                dark: UIColor(white: 1.0, alpha: 0.10))

    // 语义色
    static let red      = Color(hex: "#FF3B30")
    static let orange   = Color(hex: "#FF8F1F")
    static let green    = Color(hex: "#34C759")
    static let blue     = Color(hex: "#0A84FF")

    // 尺寸
    static let radius: CGFloat = 16
    static let cardRadius: CGFloat = 18
    static let hPadding: CGFloat = 18
}

// MARK: - 字体

extension Font {
    /// 大金额：紧字距 + 等宽数字
    static func amount(_ size: CGFloat, _ weight: Font.Weight = .semibold) -> Font {
        .system(size: size, weight: weight, design: .default)
    }

    static func label(_ size: CGFloat = 12, _ weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight)
    }
}

// MARK: - 通用修饰

struct CardBackground: ViewModifier {
    var padding: CGFloat = 14
    var radius: CGFloat = T.cardRadius

    func body(content: Content) -> some View {
        content
            .padding(padding)
            .background(T.card, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
    }
}

extension View {
    func cardStyle(padding: CGFloat = 14, radius: CGFloat = T.cardRadius) -> some View {
        modifier(CardBackground(padding: padding, radius: radius))
    }

    /// 让数字在动画时保持等宽，不影响排版跳动
    func tabularNumbers() -> some View {
        self.monospacedDigit()
    }
}
