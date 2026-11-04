//
//  Category.swift
//  MonoLedger
//
//  分类目录：图标用 SF Symbols，颜色为克制的系统色
//

import SwiftUI

struct Category: Identifiable, Hashable {
    let id: String
    let name: String
    let symbol: String
    let colorHex: String

    var color: Color { Color(hex: colorHex) }
}

enum Catalog {
    static let expense: [Category] = [
        Category(id: "food",    name: "餐饮", symbol: "fork.knife",              colorHex: "#FF9F0A"),
        Category(id: "transit", name: "交通", symbol: "tram.fill",               colorHex: "#0A84FF"),
        Category(id: "shop",    name: "购物", symbol: "bag.fill",                colorHex: "#BF5AF2"),
        Category(id: "fun",     name: "娱乐", symbol: "gamecontroller.fill",     colorHex: "#FF375F"),
        Category(id: "home",    name: "居住", symbol: "house.fill",              colorHex: "#30D158"),
        Category(id: "health",  name: "医疗", symbol: "cross.case.fill",         colorHex: "#FF453A"),
        Category(id: "study",   name: "学习", symbol: "book.fill",               colorHex: "#5E5CE6"),
        Category(id: "social",  name: "人情", symbol: "gift.fill",               colorHex: "#FFD60A"),
        Category(id: "phone",   name: "通讯", symbol: "antenna.radiowaves.left.and.right", colorHex: "#64D2FF"),
        Category(id: "more",    name: "其他", symbol: "ellipsis",                colorHex: "#8E8E93")
    ]

    static let income: [Category] = [
        Category(id: "salary",  name: "工资", symbol: "yensign.circle.fill",     colorHex: "#30D158"),
        Category(id: "bonus",   name: "奖金", symbol: "star.fill",               colorHex: "#FFD60A"),
        Category(id: "invest",  name: "理财", symbol: "chart.line.uptrend.xyaxis", colorHex: "#0A84FF"),
        Category(id: "red",     name: "红包", symbol: "gift.fill",               colorHex: "#FF375F"),
        Category(id: "refund",  name: "退款", symbol: "arrow.uturn.backward.circle.fill", colorHex: "#64D2FF"),
        Category(id: "claim",   name: "报销", symbol: "creditcard.fill",         colorHex: "#32ADE6"),
        Category(id: "giftIn",  name: "礼金", symbol: "heart.fill",              colorHex: "#FF9F0A"),
        Category(id: "moreIn",  name: "其他", symbol: "ellipsis",                colorHex: "#8E8E93")
    ]

    static func list(_ type: RecordType) -> [Category] {
        type == .expense ? expense : income
    }

    static func find(_ type: RecordType, _ id: String) -> Category {
        let pool = list(type)
        return pool.first(where: { $0.id == id }) ?? pool[pool.count - 1]
    }

    static func name(_ type: RecordType, _ id: String) -> String {
        find(type, id).name
    }

    static var accounts: [String] { ["微信", "支付宝", "储蓄卡", "信用卡", "现金"] }
}
