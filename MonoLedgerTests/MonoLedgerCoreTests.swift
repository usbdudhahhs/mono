import XCTest
import UIKit
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
