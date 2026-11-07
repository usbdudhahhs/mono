# MONO 记账 · 原生 iOS 工程

SwiftUI + SwiftData 写的本地记账 App，核心能力是**截图识别自动分类**：
截屏 → 认出金额和商户 → 分好类 → 记一笔，全程在手机上完成。
截图原图会随账单一起存档，配合**报销**把垫付的钱单独拎出来看。
不想截图时，也可以直接打一句话：**「午饭 32」「打车 25」**，本地解析后自动填好金额和分类。

- 最低系统版本：**iOS 17.0**（SwiftData 与 App Intents 要求）
- 设备：iPhone（竖屏）/ iPad 自适应
- 依赖：仅系统框架，无第三方库，无网络请求

---

## 本次修复（稳定性更新）

- OCR 金额正则补齐捕获组，修复无货币符号的两位小数金额漏识别；金额候选同时参考识别置信度。
- 自然语言金额解析改为上下文评分，排除日期、时刻、人数/数量、订单编号及优惠数字干扰。
- 退款识别为收入（分类「退款」），买 300 + 退款 300 = 结余 0；「退款失败 / 申请退款 / 退款中」不算退款，仍按支出计。
- 支出统计统一按个人净成本计算：待报销仍计入，报销到账不计入。
- 相册截图检索按时间窗口和截图媒体类型过滤，不再固定只查最近 16 张，并跳过降级预览图。
- 数据保存失败会回滚未提交变更并显示错误；持久化容器创建失败时尝试以明确警告的临时内存模式启动。
- 备份恢复支持缺省 metadata、`records` 别名、旧版日期编码及旧版 DTO 数组；恢复失败回滚，合并导入按 UUID/内容键去重。
- 新增 XCTest target 和 13 项核心逻辑回归用例。

## 打开与运行

```bash
open MonoLedger.xcodeproj
```

1. Xcode 中选中 `MonoLedger` target → **Signing & Capabilities**
2. Team 选择你的开发者账号（免费账号也可以真机运行，7 天有效期）
3. 如需改名，改 `PRODUCT_BUNDLE_IDENTIFIER`（当前为 `com.mono.ledger`）
4. 选择模拟器或真机，⌘R

首次启动是**空账本**，不会写入任何示例数据，直接开始记就行。

> 识别功能要真机才好用：模拟器没有相机，相册也需要手动拖图进去。

---

## 没有 Mac 怎么办（云端编译出 ipa）

仓库里已带 `.github/workflows/ios-build.yml`：推到 GitHub 后会自动在 macOS 云服务器上

1. **先跑工程自检**——检查磁盘上的每个 `.swift` 是否都在编译列表里、有没有悬空引用、
   scheme 指向的 target 是否存在。任何一项不过就直接停，不会白等五分钟；
2. 编译真机版（免签名，打包成 `MonoLedger-unsigned.ipa` 供 SideStore / TrollStore 安装）；
3. 编译模拟器版（确认 UI 代码本身没问题）。

失败时 `error:` 那几行会自动写进任务页面的 **Summary**，中文标题下直接看，
不用翻几百行日志。跑完在 **Artifacts** 里下载 ipa。

本地想复现同样的产物：

```bash
xcodebuild -project MonoLedger.xcodeproj -scheme MonoLedger \
  -configuration Release -sdk iphoneos -destination 'generic/platform=iOS' \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO build
mkdir -p Payload && cp -R build/Build/Products/Release-iphoneos/MonoLedger.app Payload/
zip -qry MonoLedger-unsigned.ipa Payload
```

安装与签名步骤见随包的 `MONO装机指南.html`。

---

## 编译验证做到哪一步

当前执行环境是 Linux，没有 Xcode 或 iOS SDK，因此**无法在这里执行 `xcodebuild`，也没有声称 XCTest 已经运行通过**。已完成的验证如下：

| 检查项 | 结果 |
|---|---|
| Swift 语法解析 | 26 个 Swift 文件全部通过 `swiftc -frontend -parse` |
| 工程引用自检 | 26 个 Swift 文件与 26 个 Sources 条目一致；无重复 UUID / 悬空文件引用 |
| Scheme | XML 结构有效；App 与 `MonoLedgerTests` 测试 target 均已加入 scheme |
| XCTest | 已新增 12 项核心回归测试；需在 macOS/Xcode 中执行 `xcodebuild test` |

在 Mac 上可运行：

```bash
xcodebuild test -project MonoLedger.xcodeproj -scheme MonoLedger \
  -destination 'platform=iOS Simulator,name=iPhone 16' \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO
```

SwiftUI / SwiftData / Vision / Photos 等 Apple 框架只能在 Apple 平台完成完整类型检查和运行验证。打开工程后仍需在 Signing & Capabilities 中选择自己的 Team，才能进行真机签名安装。

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
├── .github/workflows/ios-build.yml   云端编译（含编译前自检）
├── scripts/selfcheck.py              工程引用自检，可在本地直接跑
├── MonoLedgerTests/                   XCTest 核心逻辑回归测试（12 项）
├── MonoLedger.xcodeproj
└── MonoLedger/
    ├── App/
    │   └── MonoLedgerApp.swift        应用入口
    ├── Models/
    │   ├── Bill.swift                 账单 + 消费生命周期
    │   ├── Category.swift             十个支出分类、八个收入分类
    ├── Design/
    │   └── Theme.swift                颜色令牌、圆角、字号
    ├── Support/
    │   ├── AppData.swift              共享 ModelContainer（App 与 Intent 共用）
    │   ├── ReceiptStore.swift         凭证图片压缩与读取
    │   ├── LatestScreenshot.swift     取相册里刚截的那张图
    │   ├── OCRService.swift           Vision 文字识别
    │   ├── BillParser.swift           金额 / 商户 / 日期 / 账户解析
    │   ├── MerchantRules.swift        商户关键词 → 分类
    │   ├── BackupService.swift        全量备份 / 恢复（含凭证图）
    │   └── Formatters.swift           金额与日期格式化
    ├── Intents/
    │   └── ScreenshotIntent.swift     快捷指令调用的 App Intent
    ├── Views/
    │   ├── RootView.swift             主框架 + 自定义底部导航
    │   ├── BillsView.swift            账单首页（含识别入口）
    │   ├── AddRecordView.swift        记账面板（自定义键盘）
    │   ├── ScanView.swift             截图识别与确认
    │   ├── TextRecordSheet.swift      打一句话记账
    │   ├── ShortcutGuideView.swift    快捷指令配置引导
    │   ├── StatsView.swift            统计
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
| 截图识别 | Vision OCR + 规则解析，可改金额/分类/日期后入账 |
| 打字记账 | 面板顶部「打一句话」，一句话解析金额 / 分类 / 日期，不上传 |
| 快捷指令 | 截屏即记账，支持轻点背面、操作按钮、Siri |
| 凭证存档 | 识别用的截图会压缩后存进账单，详情页可看原图 |
| 报销 | 待报销 / 已报销两档，已报销自动从个人支出里剔除 |
| 记账面板 | 自定义键盘 + 分类网格 |
| 统计 | 每日趋势柱状图、分类环形图 |
| 数据存储 | SwiftData（本地 SQLite） |
| 主题 | 跟随系统 / 浅色 / 深色 |
| 导出 | CSV（给 Excel）+ JSON 全量备份（含凭证图） |
| 恢复 | 从备份合并，按 uuid 去重，重复导入不会产生副本 |

---

## 数据模型

```swift
@Model final class Bill {
    var typeRaw: String       // expense / income
    var amount: Double
    var categoryID: String
    var note: String
    var date: Date
    var reimbursementRaw: String  // none / pending / done
    var receiptData: Data?    // 截图凭证，externalStorage 存文件
    var createdAt: Date
    var uuid: String          // 备份去重用
}
```

核心计算在 `Bill` 的扩展里：

```swift
var netCost: Double        // 已报销为 0，其余按金额
var accountingAmount: Double  // 计入统计的金额
var isPendingReimbursement: Bool  // 三个页面共用的待报销口径
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
导出的 CSV 编码为 UTF-8，含日期、类型、分类、金额、报销、备注六列。

**卸载 App 会连数据一起删掉**，免费签名 7 天到期也需要重装一次。
所以「我的 → 导出备份」会打一个 `MONO备份_日期.json`，里面是全部账单 + 凭证图 + 报销状态。
换机或重装后，用「从备份恢复」读回来即可 —— 按 uuid 去重，反复导入不会产生副本。
