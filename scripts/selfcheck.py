#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
MonoLedger 工程自检

在编译之前先确认「工程文件」和「磁盘文件」是一致的。
漏加文件、删了文件没清引用、scheme 指向不存在的 target——
这几种错误 xcodebuild 只会给一句含糊的报错，看着像代码写错了，
其实只是工程配置没跟上。这里提前拦住，并说清楚是哪一处。

用法：python3 scripts/selfcheck.py
退出码 0 = 通过，1 = 有问题（CI 会因此中断，不会白等五分钟）
"""

import glob
import os
import re
import sys

PBX = "MonoLedger.xcodeproj/project.pbxproj"
SCHEME = "MonoLedger.xcodeproj/xcshareddata/xcschemes/MonoLedger.xcscheme"

problems = []


def fail(msg):
    problems.append(msg)
    print("✗ " + msg)


def _ids(block):
    return re.findall(r'Category\(id:\s*"([^"]+)"', block)


def check_categories():
    """Category 目录 / 规则表 / 测试 Stub 三处分类 ID 必须一致"""
    cat_path = "MonoLedger/Models/Category.swift"
    rules_path = "MonoLedger/Support/MerchantRules.swift"
    if not (os.path.exists(cat_path) and os.path.exists(rules_path)):
        return

    src = open(cat_path, encoding="utf-8").read()
    try:
        exp_ids = set(_ids(src.split("static let expense")[1].split("static let income")[0]))
        inc_ids = set(_ids(src.split("static let income")[1].split("static func list")[0]))
    except IndexError:
        fail("Category.swift 结构变了，无法解析支出/收入分类表")
        return
    if not exp_ids or not inc_ids:
        fail("Category.swift 里没解析出分类 ID，请确认格式：Category(id: \"food\", ...)")
        return

    # 8.1 规则表：支出表只能给支出分类，收入表只能给收入分类
    rules = open(rules_path, encoding="utf-8").read()
    if "incomeTable" not in rules:
        fail("MerchantRules 里找不到 incomeTable")
        return
    exp_rules = re.findall(r'\("([A-Za-z]+)",\s*\[', rules.split("incomeTable")[0])
    inc_rules = re.findall(r'\("([A-Za-z]+)",\s*\[',
                           rules.split("incomeTable")[1].split("static func match")[0])

    for name in exp_rules:
        if name not in exp_ids:
            fail(f"支出规则表用了不存在的分类 {name}（Catalog.expense 里没有）→ 账本会静默归到「其他」")
    for name in inc_rules:
        if name not in inc_ids:
            fail(f"收入规则表用了不存在的分类 {name}（Catalog.income 里没有）→ 账本会静默归到「其他」")

    # 8.2 代码里硬编码的分类字面量必须是真实分类
    all_ids = exp_ids | inc_ids
    for swift_path in glob.glob("MonoLedger/**/*.swift", recursive=True):
        if os.path.basename(swift_path) in ("Category.swift", "MerchantRules.swift"):
            continue
        source = open(swift_path, encoding="utf-8").read()
        for lit in set(re.findall(r'categoryID\s*[:=]\s*"([A-Za-z]+)"', source)):
            if lit not in all_ids:
                fail(f"{swift_path} 硬编码了不存在的分类 {lit}")

    # 8.3 测试脚手架的 Stub 必须使用同一套词，否则测试在错的词表上判定通过
    stub_path = "scripts/parser_lab/harness/Stub.swift"
    if os.path.exists(stub_path):
        stub = open(stub_path, encoding="utf-8").read()
        m = re.search(r"ids\s*:\s*Set<String>\s*=\s*\[([^\]]*)\]", stub)
        if m:
            stub_ids = set(re.findall(r'"([A-Za-z]+)"', m.group(1)))
            missing = stub_ids - all_ids
            absent = all_ids - stub_ids
            if missing:
                fail("解析器测试的 Stub.Catalog.ids 里有 App 不存在的分类：" + "、".join(sorted(missing)))
            if absent:
                fail("解析器测试的 Stub.Catalog.ids 少了 App 已有的分类：" + "、".join(sorted(absent)))

    print(f"分类 ID：支出 {len(exp_ids)} 个 / 收入 {len(inc_ids)} 个，"
          f"规则表 支出 {len(exp_rules)} 组 / 收入 {len(inc_rules)} 组，全部对得上")


def check_pbxproj_syntax(pbx):
    """最小 OpenStep plist 语法校验（不依赖任何第三方库）。

    project.pbxproj 是 OpenStep 格式的 plist，不是 JSON 也不是 XML。
    花括号配平不代表合法：`productName = {APP};` 这种没替换掉的模板占位符
    会让 xcodebuild 直接报 `Unable to read project`，而括号计数完全正常——
    实际踩过这个坑，交付包里就是这么写的。
    """
    i, n = 0, len(pbx)

    def skip(i):
        while i < n:
            if pbx[i] in " \t\r\n":
                i += 1
            elif pbx.startswith("/*", i):
                j = pbx.find("*/", i + 2)
                if j < 0:
                    raise ValueError(f"块注释未闭合 @ {i}")
                i = j + 2
            elif pbx.startswith("//", i):
                j = pbx.find("\n", i)
                i = n if j < 0 else j + 1
            else:
                break
        return i

    def line_at(i):
        return pbx[:i].count("\n") + 1

    def value(i):
        i = skip(i)
        if i >= n:
            raise ValueError("文件意外结束，缺少值")
        c = pbx[i]
        if c == "{":
            return dictionary(i)
        if c == "(":
            return array(i)
        if c == '"':
            return quoted(i)
        start = i
        while i < n and pbx[i] not in " \t\r\n=;,'\"(){}":
            i += 1
        if i == start:
            raise ValueError(f"第 {line_at(i)} 行出现非法字符 {pbx[i]!r}")
        return i

    def quoted(i):
        i += 1
        while i < n:
            if pbx[i] == "\\":
                i += 2
                continue
            if pbx[i] == '"':
                return i + 1
            i += 1
        raise ValueError("字符串引号未闭合")

    def dictionary(i):
        i += 1
        while True:
            i = skip(i)
            if i >= n:
                raise ValueError("花括号未闭合")
            if pbx[i] == "}":
                return i + 1
            i = value(i)
            i = skip(i)
            if i >= n or pbx[i] != "=":
                raise ValueError(f"第 {line_at(i)} 行：键后面缺少 =（可能是占位符没替换，"
                                 f"附近内容 {pbx[max(0, i - 40):i + 20]!r}）")
            i = value(i + 1)
            i = skip(i)
            if i >= n or pbx[i] != ";":
                raise ValueError(f"第 {line_at(i)} 行：值后面缺少分号")
            i += 1

    def array(i):
        i += 1
        while True:
            i = skip(i)
            if i >= n:
                raise ValueError("圆括号未闭合")
            if pbx[i] == ")":
                return i + 1
            i = value(i)
            i = skip(i)
            if i >= n or pbx[i] != ",":
                raise ValueError(f"第 {line_at(i)} 行：数组元素后面缺少逗号")
            i += 1

    try:
        end = skip(value(0))
        if end != n:
            raise ValueError(f"第 {line_at(end)} 行：根对象之后还有多余内容")
    except ValueError as exc:
        return str(exc)

    leftover = re.search(r"=\s*\{[A-Za-z_][A-Za-z0-9_]*\}\s*;", pbx)
    if leftover:
        return f"第 {line_at(leftover.start())} 行存在未替换的模板占位符 {leftover.group(0)!r}"
    return None


def main():
    if not os.path.exists(PBX):
        print("✗ 找不到 project.pbxproj，请确认在工程根目录执行")
        return 1

    pbx = open(PBX, encoding="utf-8").read()

    # 1) 括号平衡：最常见的工程文件损坏
    if pbx.count("{") != pbx.count("}"):
        fail(f"project.pbxproj 花括号不平衡（{pbx.count('{')} 个 {{ vs {pbx.count('}')} 个 }}）")
    else:
        # 配平不等于合法：占位符、缺分号都会让 xcodebuild 读不了整个工程
        syntax_error = check_pbxproj_syntax(pbx)
        if syntax_error:
            fail(f"project.pbxproj 语法不合法，xcodebuild 会报 Unable to read project：{syntax_error}")

    # 2) 磁盘上的 Swift 文件 vs 编译列表
    #    两个 target 分开比：混在一起只算总数，会把「文件加错 target」漏过去
    phase_files = {}
    for m in re.finditer(
        r"([0-9A-F]{24}) /\* [^*]+? \*/ = \{\s*isa = PBXSourcesBuildPhase;", pbx
    ):
        pid = m.group(1)
        end = pbx.index("};", m.end())
        phase_files[pid] = {
            name.strip()
            for _, name in re.findall(
                r"([0-9A-F]{24}) /\* (.+?) in Sources \*/,", pbx[m.end():end]
            )
        }

    target_sources = {}
    for m in re.finditer(
        r"([0-9A-F]{24}) /\* (\w+) \*/ = \{\s*isa = PBXNativeTarget;", pbx
    ):
        tname = m.group(2)
        block = pbx[m.start():pbx.index("};", m.start())]
        bp = re.search(r"buildPhases = \((.*?)\);", block, re.S)
        ids = re.findall(r"([0-9A-F]{24})", bp.group(1)) if bp else []
        files = set()
        for pid in ids:
            files |= phase_files.get(pid, set())
        target_sources[tname] = files

    disk_app = {
        os.path.basename(p) for p in glob.glob("MonoLedger/**/*.swift", recursive=True)
    }
    disk_test = {
        os.path.basename(p)
        for p in glob.glob("MonoLedgerTests/**/*.swift", recursive=True)
    }

    for tname, disk in (("MonoLedger", disk_app), ("MonoLedgerTests", disk_test)):
        listed = target_sources.get(tname)
        if listed is None:
            fail(f"工程里找不到 target {tname}")
            continue
        print(f"{tname}：磁盘 {len(disk)} 个 / 编译列表 {len(listed)} 个")
        missing = disk - listed
        extra = listed - disk
        if missing:
            fail(f"{tname} 里这些文件没加进编译列表，会被忽略：" + "、".join(sorted(missing)))
        if extra:
            fail(f"{tname} 的编译列表引用了不存在的文件（会报 cannot find file）：" + "、".join(sorted(extra)))

    # App 源码混进测试 target，打包出来的 App 里就没有这部分代码
    for name in sorted(target_sources.get("MonoLedgerTests", set()) - {"MonoLedgerCoreTests.swift"}):
        fail(f"{name} 被加进了测试 target，App 编译时不会有它")

    # 3) 悬空引用：buildFile 指向的 fileRef 必须存在
    refs = set(
        re.findall(
            r"^[ \t]*([0-9A-F]{24}) /\* .+? \*/ = \{isa = PBXFileReference",
            pbx,
            re.M,
        )
    )
    dangling = [u for u in re.findall(r"fileRef = ([0-9A-F]{24})", pbx) if u not in refs]
    if dangling:
        fail(f"有 {len(dangling)} 处 fileRef 指向不存在的文件引用")

    # 4) UUID 重复定义：只看真正的定义行（带 "= {isa = ..."），
    #    列表里的引用行也会以 UUID 开头，不能算进来
    defs = re.findall(r"^[ \t]*([0-9A-F]{24}) /\*[^*]*\*/ = \{isa =", pbx, re.M)
    if len(defs) != len(set(defs)):
        dup = {u for u in defs if defs.count(u) > 1}
        fail(f"有 {len(dup)} 个 UUID 被重复定义：{', '.join(sorted(dup)[:3])}")

    # 5) scheme 指向的 target 必须真实存在
    if os.path.exists(SCHEME):
        scheme = open(SCHEME, encoding="utf-8").read()
        blueprint = set(re.findall(r'BlueprintIdentifier = "(\w+)"', scheme))
        targets = set(
            re.findall(
                r"([0-9A-F]{24}) /\* \w+ \*/ = \{\s*isa = PBXNativeTarget;", pbx
            )
        )
        if not blueprint <= targets:
            fail("scheme 指向的 target 在工程里不存在，xcodebuild -scheme 会直接失败")
    else:
        fail("找不到共享 scheme，xcodebuild 无法按 -scheme 编译")

    # 6) 资源目录必须在 Resources 阶段，否则装出来是白图标。
    #    注意要查「阶段块内部」，pbxproj 里还有一行同名的 PBXBuildFile 定义，
    #    只搜全文会误判成已加入。
    if "isa = PBXResourcesBuildPhase" not in pbx:
        fail("project.pbxproj 里找不到 PBXResourcesBuildPhase")
    else:
        rs = pbx.index("isa = PBXResourcesBuildPhase")
        re_end = pbx.index("};", rs)
        if "Assets.xcassets in Resources" not in pbx[rs:re_end]:
            fail("Assets.xcassets 没加进 Resources 阶段，App 装上会没有图标")
        if not os.path.exists("MonoLedger/Assets.xcassets/AppIcon.appiconset/AppIcon.png"):
            fail("找不到 AppIcon.png，打包时会报 app icon 缺失")

    # 7) 关键记账逻辑回归守卫
    bill_src = open("MonoLedger/Models/Bill.swift", encoding="utf-8").read()
    parser_src = open("MonoLedger/Support/BillParser.swift", encoding="utf-8").read()
    screenshot_src = open("MonoLedger/Support/LatestScreenshot.swift", encoding="utf-8").read()
    backup_src = open("MonoLedger/Support/BackupService.swift", encoding="utf-8").read()
    intent_src = open("MonoLedger/Intents/ScreenshotIntent.swift", encoding="utf-8").read()

    merchant_src = open("MonoLedger/Support/MerchantRules.swift", encoding="utf-8").read()

    if "type == .expense ? netCost" not in bill_src:
        fail("统计金额没有统一使用支出净成本")
    if '("(-?[0-9,]+\\\\.[0-9]{1,2})(?![0-9.])", 1.0)' not in parser_src:
        fail("OCR 两位小数金额正则缺少捕获组")
    if "static func isRefund(" not in parser_src:
        fail("解析器缺少退款语义识别（退款应记成收入）")
    if "refundBlockers" not in parser_src:
        fail("解析器缺少「退款失败 / 退款中」的排除逻辑")
    if '("refund", ["退款", "退货", "退回"])' not in merchant_src:
        fail("收入分类表缺少退款分类")
    if ".deferredToDate" not in backup_src:
        fail("备份恢复缺少旧版日期格式兼容")
    if "fetchLimit = 16" in screenshot_src:
        fail("截图查询仍固定限制 16 张")

    # 金额识别的三道保险：拆字合并、置信度分级、低置信入账后待核对
    if "mergeAmountFragments" not in parser_src:
        fail("解析器缺少 OCR 拆字合并（¥ / 29 / .70 会被拆成三个框）")
    if "amountTier" not in parser_src:
        fail("解析器没有输出金额置信度，低置信账单无法标注待核对")
    if "enum AmountTier" not in parser_src:
        fail("缺少 AmountTier 定义")
    if "needsReview" not in bill_src:
        fail("Bill 缺少 needsReview 字段，识别错了会悄悄留在账本里")
    if "markReviewed" not in bill_src:
        fail("Bill 缺少 markReviewed()，核对完无法清除标记")
    if "needsReview" not in intent_src:
        fail("快捷指令入账时没有写入待核对标记")
    if "needsReview" not in backup_src:
        fail("备份没有保留待核对状态，换机后待核对会丢")
    if "reviewBanner" not in open("MonoLedger/Views/BillsView.swift", encoding="utf-8").read():
        fail("账单首页缺少待核对入口，识别错了用户看不到")

    # 页面保存必须走 AppData.save：它会统一 rollback，各写一套容易漏
    for swift_path in glob.glob("MonoLedger/Views/**/*.swift", recursive=True):
        source = open(swift_path, encoding="utf-8").read()
        if "try context.save()" in source:
            fail(f"{swift_path} 绕过了 AppData.save 统一保存入口")

    for swift_path in (glob.glob("MonoLedger/**/*.swift", recursive=True)
                       + glob.glob("MonoLedgerTests/**/*.swift", recursive=True)):
        source = open(swift_path, encoding="utf-8").read()
        if "try? context.save()" in source:
            fail(f"{swift_path} 仍存在静默忽略的 SwiftData 保存错误")

    # 8) 分类 ID 一致性
    #    分类 ID 是跨文件的隐式契约：规则表给什么，账本就存什么，Catalog 找不到就
    #    静默掉到「其他」—— 界面上看着正常，实际分类全丢，而且不报错。
    #    测试脚手架的 Stub 用的是另一套词（transport / shopping / pet …），
    #    它一旦被谁用上，测试就会在错误的词表上判定通过。这里把三处对齐。
    check_categories()

    # 9) Bundle ID 一致性
    #    App 有 Debug / Release 两套配置：CI 打真机包走 Release，跑模拟器走 Debug。
    #    只改一处的话，两个包身份不同——装到手机上会变成两个 App，覆盖不掉旧版。
    #    测试 target 的 ID 必须挂在 App ID 下面，否则 TEST_HOST 注入进程会失败。
    all_ids = re.findall(r"PRODUCT_BUNDLE_IDENTIFIER = ([^;]+);", pbx)
    app_ids = [i for i in all_ids if not i.endswith(".tests")]
    test_ids = [i for i in all_ids if i.endswith(".tests")]
    if len(app_ids) != 2:
        fail(f"PRODUCT_BUNDLE_IDENTIFIER 应有两处（Debug / Release），实际 {len(app_ids)} 处")
    elif len(set(app_ids)) != 1:
        fail(f"Debug 与 Release 的 Bundle ID 不一致：{' / '.join(sorted(set(app_ids)))}")
    elif test_ids and set(test_ids) != {app_ids[0] + ".tests"}:
        fail(f"测试 target 的 Bundle ID 应为 {app_ids[0]}.tests，实际 {' / '.join(sorted(set(test_ids)))}")

    # 10) 版本号只能有一个来源
    #     pbxproj 里是 2.0.6，「我的」页脚写死成 2.0.5，用户看到的就是过期号。
    #     这种漂移不会报错、不会崩，只会让人怀疑装错了版本。界面层一律从 Bundle 读。
    marketing = sorted(set(re.findall(r"MARKETING_VERSION = ([^;]+);", pbx)))
    if len(set(marketing)) > 1:
        fail(f"Debug 与 Release 的 MARKETING_VERSION 不一致：{' / '.join(marketing)}")
    for swift_path in glob.glob("MonoLedger/Views/**/*.swift", recursive=True):
        source = open(swift_path, encoding="utf-8").read()
        for hit in re.finditer(r'"[^"\n]*?\b(\d+\.\d+\.\d+)\b', source):
            fail(f"{swift_path} 里硬编码了版本号 {hit.group(1)}，"
                 f"应改为从 Bundle 读取")

    # 结果
    print()
    if problems:
        print(f"✗ 自检失败，共 {len(problems)} 处问题")
        return 1
    print("✓ 自检通过：工程引用完整，可以编译")
    return 0


if __name__ == "__main__":
    sys.exit(main())
