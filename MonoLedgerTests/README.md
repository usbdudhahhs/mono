# MonoLedger 核心回归测试

`MonoLedgerCoreTests.swift` 是 XCTest 测试源，覆盖退款、报销、转售、收入、无货币符号小数金额、日期/时间数字排除及退款识别。

原始工程没有 Unit Testing Bundle。本次没有擅自改变现有 App Target 的签名和构建配置；将此目录加入 Xcode 的 `MonoLedgerTests` Unit Testing Bundle（Host Application 选择 MonoLedger）后，可通过 Product → Test 执行。
