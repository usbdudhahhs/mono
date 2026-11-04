# MONO 记账 · 原生 iOS 工程

SwiftUI + SwiftData 写的本地记账 App，核心能力是**截图识别自动分类**：
截屏 → 认出金额和商户 → 分好类 → 记一笔，全程在手机上完成。
截图原图会随账单一起存档，配合**报销**把垫付的钱单独拎出来看。

- 最低系统版本：**iOS 17.0**（SwiftData 与 App Intents 要求）
- 设备：iPhone（竖屏）/ iPad 自适应
- 依赖：仅系统框架，无第三方库，无网络请求

---

## 打开与运行

```bash
open MonoLedger.xcodeproj
```

1. Xcode 中选中 `MonoLedger` target → **Signing & Capabilities**
2. Team 选择你的开发者账号（免费账号也可以真机运行，7 天有效期）
3. 如需改名，改 `PRODUCT_BUNDLE_IDENTIFIER`（当前为 `com.mono.ledger`）
4. 选择模拟器或真机，⌘R

首次启动会写入一批示例数据（近三个月账单、6 件追踪物品、3 笔报销），
点「我的 → 清空所有数据」即可从零开始。

> 识别功能要真机才好用：模拟器没有相机，相册也需要手动拖图进去。

---

## 编译验证做到哪一步

工程是在 Linux 上生成的，没有 Xcode 和 iOS SDK，所以**没有跑过 `xcodebuild`**。
能做的静态验证都做了：

| 检查项 | 工具 | 结果 |
|---|---|---|
| 语法解析 | `swiftc` 5.10 `-parse` | 24 个文件，0 错误 0 警告 |
| 纯逻辑类型检查 | `swiftc -typecheck` | `Formatters.swift`、`MerchantRules.swift` 通过 |
| 语法树 | tree-sitter-swift | 0 个 ERROR 节点 |
| 工程引用 | 脚本 | 24 个 Sources 条目、UUID、括号全部自洽 |
| 符号交叉引用 | 脚本 | 无未定义类型、无重复定义 |
| SF Symbols | 人工比对 | 全部为有效符号名 |

SwiftUI / SwiftData / Vision / Photos 这些框架只有苹果平台才有，
在 Linux 上连 `import` 都过不去，所以类型检查只能覆盖不依赖 UI 的部分。

打开工程后唯一需要手动做的一步：**Signing & Capabilities 里选你的 Team**。
其余构建配置（Bundle ID、权限文案、图标、部署目标）都已写进 `project.pbxproj`。

---

## 截图识别怎么做的

不调用任何云端 OCR，全部走系统原生能力。

```
截屏 / 相册选图
      ↓
Vision（VNRecognizeTextRequest）逐行识别，带字号和位置
      ↓
BillParser 三重打分定位金额
      ↓
商户关键词最长匹配 → 分类
      ↓
SwiftData 落库
```

**金额定位**不是靠固定模板，而是给每个候选打分：

| 信号 | 作用 |
|---|---|
| 字号占比 | 账单详情页的主金额永远是最大的字，权重最高 |
| 货币符号 `¥ ￥` | 加分 |
| 上下文词 | 「实付」「支付金额」加分；「余额」「优惠」「原价」减分 |
| 正负号 | 匹配当前收支方向时加分 |
| 同行位置 | 一行有多个金额时取靠后的（「原价 100 实付 80」→ 80） |

所以微信支付、支付宝、银行短信、美团订单页这些排版完全不同的截图，都能读出同一个结果。

**分类**用 300 多个商户关键词做最长匹配，长词优先：

```
"美团单车" → 交通（而不是 美团 → 餐饮）
"京东读书" → 学习（而不是 京东 → 购物）
```

命中哪个词、为什么这样分类，界面上都会写出来（「识别依据」），
猜错了也能一眼看出原因，而不是黑箱。

---

## 轻点背面怎么配

iOS 不允许 App 在后台截取别的 App 的屏幕，所以「截屏」这一步只能由快捷指令完成。
两条路，按省事的程度选：

**方式一 · 零配置**（先截屏，再点背面）

App 装好后，`Intents/ScreenshotIntent.swift` 里的 `MonoAppShortcuts` 已经把
「截图记账」注册成系统快捷指令，不需要新建任何东西：

```
设置 → 辅助功能 → 触控 → 轻点背面 → 轻点两下 → 选「MONO 截图记账」
```

用法：付款页按 **侧边键 + 音量上键** 截屏 → 轻点两下背面。
`image` 参数留空时，会走 `LatestScreenshot` 自动取相册里 15 分钟内最新的那张截图。

**方式二 · 全自动**（配一次，之后连截屏都不用按）

1. 打开「快捷指令」App，右上角 **+** 新建
2. 添加动作 **「截屏」**
3. 添加动作 **「截图记账」**（搜索 MONO），截图会自动传进去
4. 点动作右侧箭头，关闭 **「运行前询问」**
5. 命名为「记账」，绑到 `设置 → 辅助功能 → 触控 → 轻点背面`

之后轻点两下背面 = 截屏 → 识别 → 自动入账，一步到位。

对应的代码在 `Intents/ScreenshotIntent.swift`：

```swift
struct ScreenshotBookkeepingIntent: AppIntent {
    // 留空时自动去相册拿刚截的图，所以「点背面」不配截屏动作也能用
    @Parameter(title: "截图", supportedContentTypes: [.image])
    var image: IntentFile?
    ...
}
```

`openAppWhenRun = false`，所以后台完成，不会打断你正在做的事。
识别完成后用一条系统提示回报结果，例如「已记一笔 · 交通 ¥29.70 · 滴滴出行」。

首次启动会请求一次相册权限（`LatestScreenshot.prepare()`）。这一步必须在 App 里完成——
快捷指令在后台运行时是弹不出授权框的，没授权就只能报错。

---

## 目录结构

```
MonoLedger/
├── MonoLedger.xcodeproj
└── MonoLedger/
    ├── App/
    │   └── MonoLedgerApp.swift        应用入口
    ├── Models/
    │   ├── Bill.swift                 账单 + 消费生命周期
    │   ├── Category.swift             十个支出分类、八个收入分类
    │   └── SeedData.swift             首次启动的示例数据
    ├── Design/
    │   └── Theme.swift                颜色令牌、圆角、字号
    ├── Support/
    │   ├── AppData.swift              共享 ModelContainer（App 与 Intent 共用）
    │   ├── ReceiptStore.swift         凭证图片压缩与读取
    │   ├── LatestScreenshot.swift     取相册里刚截的那张图
    │   ├── OCRService.swift           Vision 文字识别
    │   ├── BillParser.swift           金额 / 商户 / 日期 / 账户解析
    │   ├── MerchantRules.swift        商户关键词 → 分类
    │   └── Formatters.swift           金额与日期格式化
    ├── Intents/
    │   └── ScreenshotIntent.swift     快捷指令调用的 App Intent
    ├── Views/
    │   ├── RootView.swift             主框架 + 自定义底部导航
    │   ├── BillsView.swift            账单首页（含识别入口）
    │   ├── AddRecordView.swift        记账面板（自定义键盘）
    │   ├── ScanView.swift             截图识别与确认
    │   ├── ShortcutGuideView.swift    快捷指令配置引导
    │   ├── StatsView.swift            统计
    │   ├── TrackListView.swift        消费追踪
    │   ├── ReimburseListView.swift    报销清单
    │   ├── RecordDetailView.swift     账单详情（含凭证）
    │   ├── MeView.swift               我的
    │   └── Components.swift           复用组件
    └── Assets.xcassets
```

---

## 功能对照

| 模块 | 说明 |
|---|---|
| 账单首页 | 按日分组、日合计、预算进度、右上角一键识别 |
| 截图识别 | Vision OCR + 规则解析，可改金额/分类/账户/日期后入账 |
| 快捷指令 | 截屏即记账，支持轻点背面、操作按钮、Siri |
| 凭证存档 | 识别用的截图会压缩后存进账单，详情页可看原图 |
| 报销 | 待报销 / 已报销两档，已报销自动从个人支出里剔除 |
| 记账面板 | 自定义键盘 + 分类网格 |
| 统计 | 每日趋势柱状图、分类环形图 |
| 消费追踪 | 使用中 / 已转售 / 已退款，日均成本推演 |
| 数据存储 | SwiftData（本地 SQLite） |
| 主题 | 跟随系统 / 浅色 / 深色 |
| 导出 | CSV + 系统分享面板 |

---

## 数据模型

```swift
@Model final class Bill {
    var typeRaw: String       // expense / income
    var amount: Double
    var categoryID: String
    var note: String
    var date: Date
    var account: String
    var isTracked: Bool       // 是否进入消费追踪
    var statusRaw: String     // active / done / resold / refunded
    var resalePrice: Double?  // 转售价
    var reimbursementRaw: String  // none / pending / done
    var receiptData: Data?    // 截图凭证，externalStorage 存文件
    var createdAt: Date
}
```

核心计算在 `Bill` 的扩展里：

```swift
var daysUsed: Int          // 购买当天算第 1 天
var netCost: Double        // 已报销 0，退款 0，转售为差价
var dailyCost: Double      // 日均 = 净成本 ÷ 已用天数
var accountingAmount: Double  // 计入统计的金额，已报销为 0
```

---

## 识别不准时怎么调

规则都集中在两个文件里，改完直接重跑，不需要改别处：

- **认错分类** → `Support/MerchantRules.swift`，往对应分类的数组里加商户名
- **金额认错** → `Support/BillParser.swift` 的 `amountNoise` / `amountBoost`

`MerchantRules` 里加关键词时注意：匹配是「最长优先」，
所以加一个更长的词就能覆盖短词的误判，例如已有「京东」时，
加「京东读书」就能把它单独划到学习。

---

## 上架前还需要做的

1. **应用名称**：`INFOPLIST_KEY_CFBundleDisplayName` 现为 `MONO`
2. **图标**：`Assets.xcassets/AppIcon` 里是一张占位用的 1024 图，换成正式设计稿
3. **iCloud 同步**：给 `ModelConfiguration` 加 `cloudKitDatabase: .automatic` 并开启 Push Notifications 能力
4. **隐私清单**：本工程不采集任何数据，`PrivacyInfo.xcprivacy` 里声明「不追踪」即可

---

## 关于数据

所有数据保存在 App 沙盒内的 SQLite，卸载即清除。
识别全程在本机完成，图片不上传；作为凭证的截图会压缩后存进沙盒
（长边 1600、JPEG 0.72，一张约 200~400KB），删除账单时一并删除。
导出的 CSV 编码为 UTF-8，含日期、类型、分类、金额、账户、报销、备注七列。
