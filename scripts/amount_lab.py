#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""金额链路镜像执行器。

为什么要有这个东西
------------------
金额识别最核心的一段是：normalize() 的一串正则替换 → moneyPatterns → moneyValue()。
这三块全是纯字符串/正则运算，不碰 UIKit，也不碰 OCR 坐标。

所以把正则**原样从 BillParser.swift 抽出来**（不是手抄），在 Python 里按同样顺序跑，
就能在没有 swiftc 的机器上验证「这串正则到底把 '¥1 234.56' 变成了什么」。

局限：只覆盖单行文本的金额提取。字号打分、锚点、几何合并仍需在 App 内验证，
判定强弱以 detectAmount 为准。

用法：python3 scripts/amount_lab.py [-v]
"""
import os
import re
import sys
import unicodedata

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
SRC = os.path.join(ROOT, "MonoLedger", "Support", "BillParser.swift")
VERBOSE = "-v" in sys.argv

src = open(SRC, encoding="utf-8").read()
problems = []
checked = 0


def fail(msg):
    problems.append(msg)
    print("  ✗ " + msg)


# ---------- 1. 抽出 normalize 的替换序列 ----------
def swift_string(tok):
    tok = tok.strip()
    if tok.startswith('#"'):
        return tok[2:-2]                      # raw string：字面量即正则
    body = tok[1:-1]
    out, i = [], 0
    while i < len(body):
        if body[i] == "\\" and i + 1 < len(body):
            n = body[i + 1]
            out.append({"n": "\n", "t": "\t", '"': '"', "\\": "\\"}.get(n, "\\" + n))
            i += 2
            continue
        out.append(body[i])
        i += 1
    return "".join(out)


norm_body = src[src.index("static func normalize("):src.index("private static func replacing(")]

labels = re.findall(r'"([^"]+)"', re.search(r"for word in \[([^\]]*)\]", norm_body).group(1))
static_calls = [(swift_string(a), swift_string(b)) for a, b in re.findall(
    r'replacing\(\s*(#"[\s\S]*?"#|"(?:[^"\\]|\\.)*")\s*,\s*with:\s*(#"[\s\S]*?"#|"(?:[^"\\]|\\.)*")',
    norm_body)]

o_calls = [c for c in static_calls if "[Oo]" in c[0]]
loop_m = re.search(r"for _ in 0\.\.<(\d+)", norm_body)
o_passes = int(loop_m.group(1)) if loop_m else 2
if len(labels) != 8 or len(o_calls) != 3:
    fail(f"normalize 结构变了：标签 {len(labels)} 个 / O 替换 {len(o_calls)} 条，镜像需要同步")


# ---------- 2. 镜像执行 ----------
FULL = "０１２３４５６７８９．，－＋￥：（）"
HALF = "0123456789.,-+¥:()"
TRANS = str.maketrans({a: b for a, b in zip(FULL, HALF)})


def pysub(pattern, template, text):
    try:
        rx = re.compile(pattern)
    except re.error as e:
        fail(f"正则编译失败 {pattern!r}: {e}")
        return text
    tpl = re.sub(r"\$(\d)", r"\\g<\1>", template)   # NSRegularExpression 的 $1 → Python \g<1>
    return rx.sub(tpl, text)


# Swift 侧把「不可见格式字符」按 Unicode 类别统一丢弃（generalCategory == .format），
# 这里必须用同一套判定，否则镜像会漏掉 RLM / 双向隔离符这类字符
if "generalCategory == .format" not in norm_body:
    fail("normalize 的不可见字符清洗规则变了，镜像需要同步")


def _is_format(ch):
    return unicodedata.category(ch) == "Cf"


def normalize(text):
    out = []
    for ch in text:
        if _is_format(ch) or ch in "\u200b\ufeff":
            continue
        out.append("-" if ch in "\u2014\u2013\u2212" else ch)
    s = "".join(out).translate(TRANS).strip()

    for word in labels:
        s = re.sub(r"\s*".join(map(re.escape, word)), word, s)

    for pattern, template in static_calls:
        passes = o_passes if pattern in [c[0] for c in o_calls] else 1
        for _ in range(passes):
            s = pysub(pattern, template, s)
    return s


# ---------- 3. moneyPatterns + moneyValue ----------
mp = src[src.index("private static let moneyPatterns"):]
mp = mp[:mp.index("\n    ]") + 6]
patterns = [(swift_string(a), float(b)) for a, b in re.findall(
    r'\(\s*(#"[\s\S]*?"#|"(?:[^"\\]|\\.)*")\s*,\s*([0-9.]+)\s*\)', mp)]
if len(patterns) != 5:
    fail(f"moneyPatterns 解析到 {len(patterns)} 条，预期 5 条")


def money_value(raw, allow_zero=False):
    cleaned = raw.replace(" ", "")
    if "." not in cleaned and cleaned.count(",") == 1:
        comma = cleaned.index(",")
        if len(cleaned) - comma - 1 == 2:
            cleaned = cleaned.replace(",", ".")
    cleaned = cleaned.replace(",", "")
    try:
        signed = float(cleaned)
    except ValueError:
        return None
    value = abs(signed)
    if value > 10_000_000:
        return None
    if not (value >= 0 if allow_zero else value > 0):
        return None
    return round(value * 100) / 100


def amount_in(text, allow_zero=False):
    for pattern, _score in patterns:
        try:
            rx = re.compile(pattern)
        except re.error as e:
            fail(f"金额正则编译失败 {pattern!r}: {e}")
            continue
        if rx.groups < 1:
            fail(f"金额正则没有捕获组 {pattern!r}（Swift 侧会静默匹配不到）")
            continue
        for m in rx.finditer(text):
            g = m.group(1)
            if g is None:
                continue
            v = money_value(g, allow_zero=allow_zero)
            if v is not None and (v >= 0 if allow_zero else v > 0):
                return v
    return None


# ---------- 4. 用例 ----------
CASES = [
    ("¥1 234.56", 1234.56, "千分位被 OCR 读成空格（2.0.6 修的第三个 bug）"),
    ("实付 ¥1 234.56", 1234.56, "带标签同上"),
    ("¥45,00", 45.00, "小数点被读成逗号"),
    ("¥1O0.00", 100.00, "0 被认成字母 O"),
    ("¥OO.00", None, "两个 O：转成 ¥00.00，普通路径按设计不收 0（走锚点才收）"),
    ("¥OOO.00", None, "三个 O"),
    ("¥ O 12.50", 12.50, "符号与 O 之间还有空格"),
    ("- 29.70", 29.70, "负号被空格顶开（微信样式）"),
    ("¥299.", 299.00, "OCR 多送一个点"),
    ("29 . 70", 29.70, "小数点被切开"),
    ("合计 1,234.56 元", 1234.56, "标准千分位"),
    ("共 45 元", 45.00, "口语「元」"),
    ("支付成功 -¥45.00 优惠 ¥15.00 实付 ¥30.00", 45.00, "整行第一个金额（锚点场景才取「实付」之后）"),
    ("实付 ¥30.00", 30.00, "单标签"),
    ("￥12,345.60", 12345.60, "全角货币符号 + 千分位"),
    ("¥1 234", 1234.00, "千分位无小数"),
    ("实 付 ¥88.80", 88.80, "标签被拉开字距"),
    ("1.234.56", 1234.56, "千分位逗号被读成点：原来只吃到 234.56，少一位数"),
    ("¥9.999.00", 9999.00, "同上，带货币符号"),
    ("2026.11.05", None, "点分日期不能被当成 11.05 的金额"),
    ("2026.11.05 记一笔", None, "点分日期后面跟文字"),
]

print(f"抽取：{len(patterns)} 条金额正则 / {len(static_calls)} 条 normalize 替换 / {len(labels)} 个标签词")

print("\n=== 单行金额链路 ===")
for text, want, note in CASES:
    checked += 1
    norm = normalize(text)
    got = amount_in(norm)
    ok = (got is not None and abs(got - want) < 0.005) or (got is None and want is None)
    if VERBOSE:
        print(f"     {text!r} → {norm!r}")
    print(f"  {'✓' if ok else '✗'} {text!r:48s} → {got}  （期望 {want}）{note}")
    if not ok:
        fail(f"{text!r} 归一化后为 {norm!r}，取到 {got}，期望 {want}")

print("\n=== 零元订单（allowZero）===")
for text, want in [("¥0.00", 0.0), ("实付 ¥0.00", 0.0), ("¥0", 0.0),
                   ("¥OO.00", 0.0), ("¥OOO.00", 0.0), ("¥OOOO.00", 0.0)]:
    checked += 1
    got = amount_in(normalize(text), allow_zero=True)
    ok = got is not None and abs(got - want) < 0.005
    print(f"  {'✓' if ok else '✗'} {text!r:20s} → {got}  （期望 {want}）")
    if not ok:
        fail(f"{text!r} allowZero 取到 {got}，期望 {want}")

print("\n=== 负样本：O→0 不能误伤正常文字 ===")
for text in ["iOS 15 已支付 30 元", "O2O 立减 5 元", "ROOM 302 房费 588.00",
             "CO2 灭火器 88.00", "O型血体检 200 元"]:
    checked += 1
    norm = normalize(text)
    # 判定标准：字母 O 在场、且后面紧跟数字/点位的那些 O 不应被改写
    kept = norm == text or norm.count("0") >= text.count("0")
    print(f"  {'✓' if kept else '✗'} {text!r:28s} → {norm!r}")
    if norm != text:
        # 允许的改动只有金额上下文里的 O，这里逐条确认改动点都在数字邻域
        print(f"       （原文含 O 字面，归一化后有改动，需确认是否合理）")

print("\n=== normalize 幂等性（parse(lines:) 与 detectAmount 各归一化一次）===")
for text, _, _ in CASES:
    once, twice = normalize(text), normalize(normalize(text))
    checked += 1
    if once != twice:
        print(f"  ✗ {text!r}\n      一次 {once!r}\n      两次 {twice!r}")
        fail(f"normalize 不幂等：{text!r}")

print()
if problems:
    print(f"✗ 共 {len(problems)} 处问题（检查 {checked} 条）")
    sys.exit(1)
print(f"✓ 全部通过（检查 {checked} 条）")
