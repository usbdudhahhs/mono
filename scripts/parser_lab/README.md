# 解析器测试台

不依赖 Xcode，直接用 `swiftc` 跑三套测试。测的是 `Support/BillParser.swift` 本身的副本，
由 `make_core.py` 现场生成（去掉 `import UIKit` 和 `parse(image:)`，其余一行不改）。

```bash
./run.sh          # 判定器 → 模糊测试 → 变异测试
```

需要 `swiftc`（macOS 自带 Xcode Command Line Tools，或 Linux 装 Swift 6 工具链）。

## 三套测试在测什么

| 文件 | 方法 | 断言什么 |
|---|---|---|
| `harness/main.swift` | 金标准 + 蜕变 + 随机不变量 | 35 个种子的金额/收支/档位/零元标记；18 种子 × 9 类等价改写结果不变；400 条随机文本的硬性质 |
| `harness/Geo.swift` | 几何路径 | 用真实 Vision 坐标（原点左下）测字号、左右、上下、分栏这些 `parse(text:)` 里被 fake 掉的分支 |
| `fuzz/main.swift` + `fuzz_check.py` | 模糊测试 | 3000 条随机 OCR 文本：金额非负、置信度在区间、**金额必须出现在原文里**、结果确定性、尾空行不变、耗时不超 200ms |
| `mutate.py` | 变异测试 | 往解析器注入 18 个语义缺陷，看判定器能抓到几个 |

## 为什么要有变异测试

用例写得再多，也只覆盖写用例的人想得到的情况。变异测试反过来问：**这段代码改坏了，测试会响吗？**

第一版判定器只抓到 3/18（18%），补完用例到 16/18（89%）。两个存活者已在 `修复说明.md` 里逐条说明。

`mutate.py` 第一步会先跑原版，`fail != 0` 直接中止 —— 基线不绿，后面所有「杀死」都是假的。

## 注意

- `build/` 是生成物，不要提交。
- 这套跑在 Linux Swift 6.0.3 上验证过；macOS 上原理相同（`CGRect`/`CGFloat` 由 Foundation 提供），但未实测。
