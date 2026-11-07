import XCTest
import UIKit
import SwiftData
@testable import MonoLedger

final class MonoLedgerCoreTests: XCTestCase {
    private func makeBill(type: RecordType = .expense, amount: Double = 100,
                          reimbursement: ReimbursementState = .none) -> Bill {
        Bill(type: type, amount: amount, categoryID: "more", note: "测试",
             date: Date(), reimbursement: reimbursement)
    }

    func testReimbursementAccounting() {
        XCTAssertEqual(makeBill(reimbursement: .done).accountingAmount, 0)
        XCTAssertEqual(makeBill(reimbursement: .pending).accountingAmount, 100)
        XCTAssertEqual(makeBill(reimbursement: .none).accountingAmount, 100)
    }

    func testIncomeRemainsIncomeAmount() {
        XCTAssertEqual(makeBill(type: .income, amount: 88).accountingAmount, 88)
    }

    func testDecimalAmountWithoutCurrencySymbol() {
        let result = BillParser.parse(text: "午饭 32.00")
        XCTAssertEqual(result.amount, 32, accuracy: 0.001)
    }

    func testDateAndTimeDigitsAreNotTreatedAsAmount() {
        let result = BillParser.parse(text: "2026-11-05 18:30 午饭 32")
        XCTAssertEqual(result.amount, 32, accuracy: 0.001)
    }

    /// 退款是「钱退回来」，记成收入才和月结余自洽：
    /// 买 300 + 退款 300 = 结余 0。若记成支出 + refunded，结余会变成 -300。
    func testRefundPhraseIsIncomeUnderRefundCategory() {
        let phrases = ["退款 32", "收到退款 32 元", "退回 32", "退货 199", "退款成功 ¥32.00", "原路退回 66"]
        for phrase in phrases {
            let r = BillParser.parse(text: phrase)
            XCTAssertEqual(r.type, .income, "「\(phrase)」应识别为收入")
            XCTAssertEqual(r.categoryID, "refund", "「\(phrase)」应归到退款分类")
            XCTAssertGreaterThan(r.amount, 0, "「\(phrase)」应识别出金额")
        }
    }

    /// 还没退到账的不能当收入，否则当月收入虚高
    func testPendingRefundStaysExpense() {
        for phrase in ["退款失败 32", "申请退款 199", "退款中 88", "退款处理中 45"] {
            XCTAssertEqual(BillParser.parse(text: phrase).type, .expense, "「\(phrase)」钱还没退到，应算支出")
        }
    }

    func testSalaryPhrasesAreIncome() {
        for phrase in ["收到工资 8000", "发工资了 12000", "薪资到账 9500"] {
            let r = BillParser.parse(text: phrase)
            XCTAssertEqual(r.type, .income, "「\(phrase)」应识别为收入")
        }
        XCTAssertEqual(BillParser.parse(text: "收到工资 8000").categoryID, "salary")
    }

    func testReceivingParcelIsNotIncome() {
        XCTAssertEqual(BillParser.parse(text: "收到快递 20 运费").type, .expense)
    }

    func testEverydayPhrasesHitRightCategory() {
        let cases: [(String, String)] = [
            ("午饭 32", "food"), ("打车 25", "transit"), ("买书 59", "study"),
            ("教材 120", "study"), ("买药 35", "health"), ("买衣服 299", "shop"),
            ("酒店 480", "transit"), ("理发 30", "health"), ("话费 50", "phone"),
            ("房租 2500", "home"), ("看电影 45", "fun"), ("奖金 5000", "bonus")
        ]
        for (phrase, want) in cases {
            XCTAssertEqual(BillParser.parse(text: phrase).categoryID, want, "「\(phrase)」分类不对")
        }
    }

    /// 「待报销」的口径：三个页面共用 isPendingReimbursement
    func testPendingReimbursementRules() {
        XCTAssertTrue(makeBill(reimbursement: .pending).isPendingReimbursement)
        XCTAssertFalse(makeBill(reimbursement: .done).isPendingReimbursement)
        XCTAssertFalse(makeBill(reimbursement: .none).isPendingReimbursement)
        XCTAssertFalse(makeBill(type: .income, reimbursement: .pending).isPendingReimbursement)
    }


    func testOCRFindsPlainTwoDecimalAmountWithoutCurrency() {
        let line = OCRLine(text: "32.00", confidence: 1, height: 0.12,
                           box: CGRect(x: 0, y: 0, width: 1, height: 0.12))
        XCTAssertEqual(BillParser.parse(lines: [line]).amount, 32, accuracy: 0.001)
    }

    func testOCRFindsSingleDecimalAmountWithoutCurrency() {
        let line = OCRLine(text: "32.5", confidence: 1, height: 0.12,
                           box: CGRect(x: 0, y: 0, width: 1, height: 0.12))
        XCTAssertEqual(BillParser.parse(lines: [line]).amount, 32.5, accuracy: 0.001)
    }

    func testOCRFindsCurrencyAmountWithThousandsSeparator() {
        let line = OCRLine(text: "实付 ¥1,238.50", confidence: 1, height: 0.12,
                           box: CGRect(x: 0, y: 0, width: 1, height: 0.12))
        XCTAssertEqual(BillParser.parse(lines: [line]).amount, 1238.5, accuracy: 0.001)
    }

    func testNaturalLanguagePrefersAmountAndRejectsDiscountNumber() {
        let result = BillParser.parse(text: "买咖啡花了32元，优惠10元")
        XCTAssertEqual(result.amount, 32, accuracy: 0.001)
    }

    func testLegacyBackupWithoutMetadataDecodes() throws {
        let json = """
        {"bills":[{"type":"expense","amount":18.5,"categoryID":"food","note":"午饭","date":0}]}
        """
        let payload = try BackupService.decode(Data(json.utf8))
        XCTAssertEqual(payload.version, 1)
        XCTAssertEqual(payload.bills.count, 1)
        XCTAssertEqual(payload.bills[0].amount, 18.5)
    }

    func testLegacyBackupArrayDecodes() throws {
        let json = """
        [{"type":"expense","amount":18.5,"categoryID":"food","note":"午饭","date":0}]
        """
        let payload = try BackupService.decode(Data(json.utf8))
        XCTAssertEqual(payload.version, 1)
        XCTAssertEqual(payload.bills.count, 1)
    }

    // MARK: - 金额置信度与待核对

    private func ocrLine(_ text: String, height: CGFloat, y: CGFloat,
                         x: CGFloat = 0.1, width: CGFloat = 0.8) -> OCRLine {
        OCRLine(text: text, confidence: 0.95, height: height,
                box: CGRect(x: x, y: y, width: width, height: height))
    }

    /// 微信 / 支付宝凭证页：主金额字号最大 + 上下有「支付成功」，应直接判定为高置信
    func testAmountTierIsHighOnPaymentPage() {
        let lines = [
            ocrLine("支付成功", height: 0.022, y: 0.870),
            ocrLine("-29.70", height: 0.044, y: 0.800),
            ocrLine("商户全称", height: 0.013, y: 0.610),
            ocrLine("瑞幸咖啡", height: 0.014, y: 0.580),
            ocrLine("支付时间", height: 0.013, y: 0.410),
            ocrLine("2026年11月5日 12:30", height: 0.014, y: 0.380)
        ]
        let result = BillParser.parse(lines: lines)
        XCTAssertEqual(result.amount, 29.7, accuracy: 0.001)
        XCTAssertEqual(result.amountTier, .high, "凭证页应给出高置信，避免每笔都要人工核对")
    }

    /// 光秃秃一个金额，没有任何上下文，不能假装很确定
    func testAmountTierDropsWithoutContext() {
        let result = BillParser.parse(lines: [ocrLine("¥12.00", height: 0.020, y: 0.500)])
        XCTAssertEqual(result.amount, 12, accuracy: 0.001)
        XCTAssertEqual(result.amountTier, .medium)
        XCTAssertTrue(result.amountTier.needsReview)
    }

    /// OCR 把「¥29.70」拆成三个框时，要拼回来再算
    func testSplitAmountFragmentsAreMerged() {
        let lines = [
            ocrLine("支付成功", height: 0.022, y: 0.870),
            ocrLine("¥", height: 0.042, y: 0.800, x: 0.300, width: 0.040),
            ocrLine("29", height: 0.042, y: 0.800, x: 0.355, width: 0.060),
            ocrLine(".70", height: 0.042, y: 0.800, x: 0.425, width: 0.070)
        ]
        XCTAssertEqual(BillParser.parse(lines: lines).amount, 29.7, accuracy: 0.001)
    }

    /// 号码、余额、优惠不能顶替真实金额
    func testNoiseNumbersDoNotWin() {
        let lines = [
            ocrLine("支付成功", height: 0.022, y: 0.876),
            ocrLine("-18.50", height: 0.044, y: 0.800),
            ocrLine("零钱余额 ¥8,888.88", height: 0.015, y: 0.700, width: 0.46),
            ocrLine("订单号 2026110522001234567890", height: 0.014, y: 0.640, width: 0.62)
        ]
        XCTAssertEqual(BillParser.parse(lines: lines).amount, 18.5, accuracy: 0.001)
    }

    /// 核对机制：确认后标记要清掉，候选也要清空
    func testNeedsReviewClearsAfterConfirm() {
        let bill = Bill(type: .expense, amount: 29.7, categoryID: "food", note: "咖啡",
                        date: Date(), needsReview: true, alternatives: [29.7, 297])
        XCTAssertTrue(bill.needsReview)
        XCTAssertEqual(bill.reviewAlternatives, [297], "与当前金额相同的候选应被过滤")

        bill.markReviewed()
        XCTAssertFalse(bill.needsReview)
        XCTAssertTrue(bill.reviewAlternatives.isEmpty)
    }

    /// 换机恢复后待核对状态要跟着回来，否则错账会被悄悄接受
    func testBackupKeepsReviewState() throws {
        let bill = Bill(type: .expense, amount: 12, categoryID: "more", note: "",
                        date: Date(), needsReview: true, alternatives: [120])
        let data = try JSONEncoder().encode(BillDTO(bill: bill, includeReceipt: false))
        let restored = try JSONDecoder().decode(BillDTO.self, from: data).makeBill()

        XCTAssertTrue(restored.needsReview)
        XCTAssertEqual(restored.reviewAlternatives, [120])
    }

    // MARK: - 实付金额优先

    private func line(_ text: String, _ height: CGFloat, _ y: CGFloat,
                      _ x: CGFloat = 0.10, _ width: CGFloat = 0.70) -> OCRLine {
        OCRLine(text: text, confidence: 0.95, height: height,
                box: CGRect(x: x, y: y, width: width, height: height))
    }

    /// 支付宝账单详情：顶部大字是原价，实付在下面的小字里。
    /// 按字号选必然选成 45，用户实际花的是 40。
    func testPaidAmountBeatsOriginalPrice() {
        let lines = [
            line("-45.00", 0.046, 0.836, 0.40, 0.22),
            line("交易成功", 0.015, 0.790, 0.43, 0.14),
            line("瑞幸咖啡（国贸店）", 0.013, 0.680, 0.42, 0.40),
            line("优惠", 0.012, 0.460, 0.10, 0.10),
            line("-5.00", 0.013, 0.460, 0.78, 0.14),
            line("实付金额", 0.012, 0.404, 0.10, 0.14),
            line("40.00", 0.013, 0.404, 0.76, 0.16)
        ]
        let result = BillParser.parse(lines: lines)
        XCTAssertEqual(result.amount, 40, accuracy: 0.001)
    }

    /// 外卖页：配送费、包装费、红包都在，只有实付是这次真扣的钱
    func testDeliveryTakesPaidAmount() {
        let lines = [
            line("¥28.80", 0.042, 0.828, 0.38, 0.24),
            line("配送费", 0.012, 0.744, 0.10, 0.12),
            line("¥3.00", 0.013, 0.744, 0.78, 0.14),
            line("红包", 0.012, 0.656, 0.10, 0.10),
            line("-¥5.00", 0.013, 0.656, 0.77, 0.15),
            line("实付", 0.012, 0.590, 0.10, 0.08),
            line("¥27.80", 0.014, 0.590, 0.75, 0.17)
        ]
        let result = BillParser.parse(lines: lines)
        XCTAssertEqual(result.amount, 27.8, accuracy: 0.001)
    }

    /// 退款页也会印着原订单的「实付款」，但那不是这次到账的钱。
    /// 锚点只对支出启用，收入仍按字号+语境判断。
    func testRefundPageIgnoresOriginalPaidAmount() {
        let lines = [
            line("+20.00", 0.046, 0.836, 0.40, 0.22),
            line("退款成功", 0.015, 0.790, 0.42, 0.14),
            line("实付款", 0.012, 0.706, 0.10, 0.12),
            line("45.00", 0.013, 0.706, 0.78, 0.14),
            line("退款金额", 0.012, 0.652, 0.10, 0.14),
            line("20.00", 0.013, 0.652, 0.78, 0.14)
        ]
        let result = BillParser.parse(lines: lines)
        XCTAssertEqual(result.type, .income)
        XCTAssertEqual(result.amount, 20, accuracy: 0.001)
    }
}

// MARK: - 账本状态机测试
//
// 前面所有测试都只碰「纯字符串 → 金额」。账本真正的坑在状态迁移：
// 删除 → 回收站 → 恢复 / 到期清理 / 备份 → 合并恢复。
// 这些路径组合起来有十几种，手写用例覆盖不全，所以这里换两种跑法：
//
// 1) 定点：把最容易错的四条边界单独钉死（回收站到期、备份往返、合并幂等、复活）
// 2) 随机：用确定性随机数跑 200 步操作，每步都验不变量
//
// 用的是真 SwiftData（内存库），不是替身；跑在模拟器上，和 App 同一套代码。

@MainActor
final class LedgerStateMachineTests: XCTestCase {

    private func makeContext() throws -> ModelContext {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: Bill.self, configurations: config)
        return ModelContext(container)
    }

    private func allBills(_ context: ModelContext) throws -> [Bill] {
        try context.fetch(FetchDescriptor<Bill>())
    }

    private func activeBills(_ context: ModelContext) throws -> [Bill] {
        try context.fetch(FetchDescriptor<Bill>(predicate: Bill.activeFilter))
    }

    private func makeBill(amount: Double, note: String,
                          daysAgo: Int = 0,
                          reimbursement: ReimbursementState = .none) -> Bill {
        let date = Calendar.current.date(byAdding: .day, value: -daysAgo, to: Date()) ?? Date()
        return Bill(type: .expense, amount: amount, categoryID: "home", note: note,
                    date: date, reimbursement: reimbursement)
    }

    // MARK: 定点

    /// 回收站到期清理的边界：31 天前删的走，29 天前删的留。
    /// 差一天就会「昨天还在的账，今天打开没了」或者「清不干净」。
    func testTrashPurgeKeepsRecentAndDropsExpired() throws {
        let context = try makeContext()
        let fresh = makeBill(amount: 100, note: "刚删的")
        let old = makeBill(amount: 200, note: "删了一个多月")
        context.insert(fresh)
        context.insert(old)
        fresh.deletedAt = Calendar.current.date(byAdding: .day, value: -29, to: Date())
        old.deletedAt = Calendar.current.date(byAdding: .day, value: -31, to: Date())
        try context.save()

        Trash.purgeExpired(context)

        let left = try allBills(context)
        XCTAssertEqual(left.count, 1, "只应剩下 29 天前删的那条")
        XCTAssertEqual(left.first?.note, "刚删的")
    }

    /// 回收站里的账不能出现在首页查询里，恢复后要回到原日期
    func testTrashHidesFromActiveListAndRestoreKeepsDate() throws {
        let context = try makeContext()
        let bill = makeBill(amount: 88, note: "误删", daysAgo: 5)
        context.insert(bill)
        try context.save()

        let originalDay = bill.date
        // Trash.move 成功时返回 nil（错误文案才非空），别写成 NotNil
        XCTAssertNil(Trash.move(bill, in: context), "移入回收站应成功")
        XCTAssertEqual(try activeBills(context).count, 0, "回收站里的不该出现在首页")

        bill.deletedAt = nil
        try context.save()
        XCTAssertEqual(try activeBills(context).count, 1)
        XCTAssertEqual(bill.date, originalDay, "恢复后日期不能被改成今天")
    }

    /// 备份 → 解码 → 恢复到空库：uuid、金额、报销状态、待核对标记全都要在
    func testBackupRoundTripPreservesFields() throws {
        let context = try makeContext()
        let bills = [
            makeBill(amount: 5600, note: "房贷", daysAgo: 30),
            makeBill(amount: 32.5, note: "午饭", daysAgo: 1, reimbursement: .pending),
            makeBill(amount: 199, note: "报销到账", daysAgo: 2, reimbursement: .done),
        ]
        for bill in bills { context.insert(bill) }
        bills[1].needsReview = true
        bills[1].reviewAlternativesRaw = "33.50,35.00"
        try context.save()

        let data = try BackupService.encode(bills.map { BillDTO(bill: $0, includeReceipt: false) })
        let payload = try BackupService.decode(data)

        let target = try makeContext()
        let result = try BackupService.restore(payload, mode: .merge, in: target)
        XCTAssertEqual(result.added, 3)

        let restored = try allBills(target)
        XCTAssertEqual(Set(restored.map(\Bill.uuid)), Set(bills.map(\Bill.uuid)), "uuid 必须原样保留")
        let lunch = restored.first { $0.note == "午饭" }
        XCTAssertEqual(lunch?.amount ?? 0, 32.5, accuracy: 0.001)
        XCTAssertEqual(lunch?.reimbursement, .pending)
        XCTAssertEqual(lunch?.needsReview, true, "待核对标记丢了，识别错的账就会悄悄混进去")
        let done = restored.first { $0.note == "报销到账" }
        XCTAssertEqual(done?.accountingAmount, 0, "已报销的净成本必须是 0")
    }

    /// 同一个备份连导两次，第二次必须一条都不加（否则用户重装一次账就翻倍）
    func testMergeIsIdempotent() throws {
        let context = try makeContext()
        for i in 0..<5 {
            context.insert(makeBill(amount: Double(i + 1), note: "账 \(i)", daysAgo: i))
        }
        try context.save()

        let payload = try BackupService.decode(
            try BackupService.encode(try allBills(context).map { BillDTO(bill: $0, includeReceipt: false) })
        )

        let first = try BackupService.restore(payload, mode: .merge, in: context)
        let second = try BackupService.restore(payload, mode: .merge, in: context)
        XCTAssertEqual(first.added, 0, "同一批数据不该重复进账")
        XCTAssertEqual(second.added, 0)
        XCTAssertEqual(try allBills(context).count, 5)
    }

    /// 本机删掉的账，从备份里恢复时要被「捞回来」，而不是新插一条
    func testMergeRevivesLocallyTrashedBill() throws {
        let context = try makeContext()
        let bill = makeBill(amount: 66, note: "删了但备份里有")
        context.insert(bill)
        try context.save()
        let uuid = bill.uuid

        let payload = try BackupService.decode(
            try BackupService.encode([BillDTO(bill: bill, includeReceipt: false)])
        )
        Trash.move(bill, in: context)
        XCTAssertEqual(try activeBills(context).count, 0)

        let result = try BackupService.restore(payload, mode: .merge, in: context)
        XCTAssertEqual(result.reactivated, 1, "应该复活而不是新增")
        XCTAssertEqual(result.added, 0)
        XCTAssertEqual(try activeBills(context).count, 1)
        XCTAssertEqual(try allBills(context).count, 1, "不能变成两条")
        XCTAssertEqual(try allBills(context).first?.uuid, uuid)
    }

    // MARK: 随机状态机

    /// 200 步随机操作，每步都验不变量。
    /// 随机数固定种子：失败了能原样复现，不会变成「偶发」。
    func testRandomOperationSequenceKeepsInvariants() throws {
        struct LCG {
            var state: UInt64
            mutating func next(_ bound: Int) -> Int {
                state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
                return Int((state >> 33) % UInt64(bound))
            }
        }
        var rng = LCG(state: 20_261_108)

        let context = try makeContext()
        var counter = 0

        func makeUniqueBill() -> Bill {
            counter += 1
            return makeBill(amount: Double(rng.next(10_000)) / 100 + 0.01,
                            note: "随机账 \(counter)",
                            daysAgo: rng.next(60),
                            reimbursement: [.none, .pending, .done][rng.next(3)])
        }

        for step in 0..<200 {
            let bills = try allBills(context)
            switch rng.next(6) {
            case 0, 1:                                  // 记账
                context.insert(makeUniqueBill())
                try context.save()

            case 2:                                     // 删除（进回收站）
                if !bills.isEmpty {
                    let victim = bills[rng.next(bills.count)]
                    victim.deletedAt = Calendar.current.date(
                        byAdding: .day, value: -rng.next(40), to: Date())
                    try context.save()
                }

            case 3:                                     // 恢复
                if let victim = bills.first(where: { $0.deletedAt != nil }) {
                    victim.deletedAt = nil
                    try context.save()
                }

            case 4:                                     // 到期清理
                Trash.purgeExpired(context)
                // 清理只在跑的时候承诺「不留过期垃圾」，所以断言放在这里，
                // 而不是每步都查 —— 否则会把「还没轮到清理」误判成 bug
                let cutoffAtPurge = Calendar.current.date(
                    byAdding: .day, value: -Trash.retentionDays - 1, to: Date()) ?? Date()
                XCTAssertFalse(try allBills(context).contains {
                    ($0.deletedAt ?? Date()) < cutoffAtPurge
                }, "第 \(step) 步清理后仍留着超过保留期的账单")

            default:                                    // 备份 → 合并恢复
                if !bills.isEmpty {
                    let payload = try BackupService.decode(
                        try BackupService.encode(bills.map { BillDTO(bill: $0, includeReceipt: false) })
                    )
                    _ = try BackupService.restore(payload, mode: .merge, in: context)
                }
            }

            // ---- 不变量 ----
            let snapshot = try allBills(context)
            let active = try activeBills(context)

            XCTAssertEqual(snapshot.count,
                           Set(snapshot.map(\Bill.uuid)).count,
                           "第 \(step) 步后出现重复 uuid，合并去重失效")
            XCTAssertEqual(active.count,
                           snapshot.filter { $0.deletedAt == nil }.count,
                           "第 \(step) 步后首页条数与「非回收站条数」对不上")
            for bill in snapshot {
                XCTAssertTrue(bill.amount.isFinite, "第 \(step) 步后金额变成 NaN/Inf")
                XCTAssertGreaterThanOrEqual(bill.amount, 0, "第 \(step) 步后出现负数金额")
                XCTAssertGreaterThanOrEqual(bill.netCost, 0)
                if bill.reimbursement == .done {
                    XCTAssertEqual(bill.accountingAmount, 0,
                                   "第 \(step) 步后已报销的仍在计入支出")
                }
            }
        }
    }
}
