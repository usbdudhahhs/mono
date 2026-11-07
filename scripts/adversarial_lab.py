#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""对抗性语料 + 差分对拍。

之前跑过的三套（金标准 / 蜕变 / 模糊）都是「喂正常文本」。
这两套换角度：

1. **对抗性语料**：喂不会出现在正常小票里的字符 —— 全角、同形字（西里尔 О、希腊 Ο）、
   零宽字符、双向控制符、超长页、极端数值。目标是压出「静默错」而不是「崩」：
   崩了还能看见，错了看不见。

2. **差分对拍**：另写一个完全独立的金额提取器（手写扫描，不抄任何一条正则），
   和 App 里那套正则管线在同一批**只含一个金额**的随机句子上比对。
   这类句子里两个实现没有「取第一还是取最后一个」的解释空间，
   不一致就一定是其中一方错了。

用法：python3 scripts/adversarial_lab.py
退出码 0 = 全部通过
"""

import os
import random
import re
import sys
import time

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))

# 只执行 amount_lab.py 的「抽取 + 定义」部分，跳过它自己的用例打印
_lab_src = open(os.path.join(ROOT, "scripts", "amount_lab.py"), encoding="utf-8").read()
_head = _lab_src.split("# ---------- 4. 用例 ----------")[0]
_ns = {"__name__": "amount_lab_core", "__file__": os.path.join(ROOT, "scripts", "amount_lab.py")}
exec(compile(_head, "amount_lab.py", "exec"), _ns)
normalize = _ns["normalize"]
amount_in = _ns["amount_in"]

problems = []
notes = []
checked = 0


def fail(msg):
    problems.append(msg)
    print("  ✗ " + msg)


def note(msg):
    notes.append(msg)


# ============================================================
# 一、对抗性语料
# ============================================================

def case(name, text, want, allow_zero=False, hard=True):
    """hard=True 断言精确值；hard=False 只记录现状（已知局限，不算失败）"""
    global checked
    checked += 1
    norm = normalize(text)
    got = amount_in(norm, allow_zero=allow_zero)
    ok = (got is not None and want is not None and abs(got - want) < 0.005) \
         or (got is None and want is None)
    mark = "✓" if ok else ("✗" if hard else "…")
    shown = text if len(text) <= 36 else text[:33] + "…"
    print(f"  {mark} {name:22s} {shown!r:40s} → {got}"
          + ("" if ok else f"　（期望 {want}）"))
    if not ok:
        if hard:
            fail(f"{name}：{text!r} 取到 {got}，期望 {want}")
        else:
            note(f"{name}：{text!r} 取到 {got}（期望 {want}），属已知局限")


print("=== 1. 字符集对抗（全角 / 同形字 / 零宽 / 双向控制符）===")

case("全角数字", "￥１ ２３４．５６", 1234.56)
case("全角小数点", "¥１２．５０", 12.50)
case("不换行空格", "¥1\u00a0234.56", 1234.56)
case("窄空格千分位", "¥1\u2009234.56", 1234.56)
case("零宽空格插在数中", "¥1\u200b234.56", 1234.56)
case("零宽连接符", "¥45\u200d.00", 45.00)
case("BOM 在行首", "\ufeff¥45.00", 45.00)
case("双向隔离符", "\u2066¥45.00\u2069", 45.00)
case("RLM 夹在金额里", "¥4\u200f5.00", 45.00)
case("全角符号打头", "￥２９９．００", 299.00)
case("西里尔 О 冒充零", "¥1О0.00", None, hard=False)
case("希腊 Ο 冒充零", "¥1Ο0.00", None, hard=False)
case("阿拉伯-印度数字", "¥٤٥.٠٠", None, hard=False)
case("上标数字", "¥4⁵.00", None, hard=False)
case("字母 o 冒充零", "¥1o0.00", 100.00)

print("\n=== 2. 数值边界 ===")

case("最小正数", "¥0.01", 0.01)
case("千分位无小数", "¥1,000", 1000.00)
case("超过一千万", "¥10000000.01", None)
case("刚好一千万", "¥10000000.00", 10000000.00)
case("十九位整数", "9" * 19, None)
case("负号 + 金额", "退款前 -¥45.00", 45.00)
case("金额后跟百分号", "折扣 8.5% 实付 ¥91.50", 91.50)
case("金额后跟年月日", "¥45.00 2026-11-05", 45.00)
case("纯日期不取金额", "2026年11月5日", None)

print("\n=== 3. 结构对抗（超长 / 重复 / 嵌套）===")

# 一万行的小票：不能爆栈、不能超时
long_text = "\n".join(f"第{i}行 商品 {i}.00" for i in range(1, 10001))
t0 = time.time()
long_amount = amount_in(normalize(long_text))
elapsed = time.time() - t0
checked += 1
if long_amount is None:
    fail("一万行文本取不到金额")
elif elapsed > 5:
    fail(f"一万行文本耗时 {elapsed:.1f}s，超过 5s 预算")
else:
    print(f"  ✓ {'一万行小票':22s} 耗时 {elapsed*1000:.0f}ms，取到 {long_amount}")

case("同一金额重复二十次", "¥45.00 " * 20, 45.00)
case("金额被括号包住", "（¥45.00）", 45.00)
case("金额后有单位文字", "¥45.00元整", 45.00)
case("三个金额取首个", "原价 ¥99.00 优惠 ¥30.00 实付 ¥69.00", 99.00)

print("\n=== 4. 幂等性与确定性 ===")

IDEMPOTENT = [
    "¥45.00", "实付 ¥0.00", "¥1 234.56", "¥1O0.00", "￥１２．５０",
    "退款成功 ¥32.00", "¥1.234.56", "2026.11.05 记一笔", "¥45.00 元整",
]
for text in IDEMPOTENT:
    checked += 1
    a, b = normalize(text), normalize(normalize(text))
    if a != b:
        fail(f"normalize 不幂等：{text!r} → {a!r} → {b!r}")
print(f"  ✓ 归一化幂等性（{len(IDEMPOTENT)} 条）")

for text in IDEMPOTENT:
    checked += 1
    if amount_in(normalize(text)) != amount_in(normalize(text)):
        fail(f"同一输入两次结果不同：{text!r}")
print("  ✓ 解析确定性（同一输入 100% 同结果）")


# ============================================================
# 二、差分对拍
# ============================================================

class RefParser:
    """独立实现：字符扫描 + 规则判断，不引用 App 的任何正则。

    刻意用另一种思路：先切出「看起来像数字」的连续片段，再逐个判定
    是否像日期 / 时间 / 电话 / 订单号，剩下的才当金额。
    两种实现思路不同，才会在边界上互相拆台。
    """

    NUM = set("0123456789")
    SEP = set("., ")
    CURRENCY = set("¥￥$")

    @classmethod
    def extract(cls, text):
        cands = []
        i, n = 0, len(text)
        while i < n:
            if text[i] in cls.NUM:
                j = i
                while j < n and (text[j] in cls.NUM or text[j] in cls.SEP):
                    j += 1
                raw = text[i:j].strip()
                i = j
                if cls._looks_like_amount(raw):
                    value = cls._to_double(raw)
                    if value is not None:
                        cands.append((value, text[max(0, i - len(raw) - 1)] in cls.CURRENCY))
            else:
                i += 1
        for value, has_symbol in cands:
            if value > 0:
                return value
        return None

    @classmethod
    def _looks_like_amount(cls, raw):
        digits = [c for c in raw if c in cls.NUM]
        if not digits:
            return False
        # 日期 2026-11-05 / 时间 18:30 已经在切分阶段被 ':' '-' 断开，
        # 这里只排掉「点分日期」2026.11.05 与「点分时间」18.30.00
        if re.fullmatch(r"\d{4}\.\d{1,2}\.\d{1,2}", raw):
            return False
        if re.fullmatch(r"\d{1,2}\.\d{2}\.\d{2}", raw):
            return False
        # 电话 / 订单号：连续数字太长
        if len(digits) >= 12:
            return False
        # 小数点后超过两位的，只有「千分位被读成点」一种合理解释
        if raw.count(".") > 2:
            return False
        return True

    @classmethod
    def _to_double(cls, raw):
        s = raw.replace(" ", "")
        # 千分位：1,234,567.89
        if re.fullmatch(r"\d{1,3}(,\d{3})+(\.\d+)?", s):
            s = s.replace(",", "")
        elif re.fullmatch(r"\d{1,3}(\.\d{3})+(,\d+)?", s):
            # 欧式写法 1.234.567,89
            s = s.replace(".", "").replace(",", ".")
        elif s.count(".") > 1:
            # 1.234.56 → 最后一段是小数，前面的点是千分位
            head, _, tail = s.rpartition(".")
            s = head.replace(".", "") + "." + tail
        elif s.count(",") == 1 and "." not in s:
            left, _, right = s.partition(",")
            if len(right) == 2:
                s = left + "." + right
            else:
                s = s.replace(",", "")
        else:
            s = s.replace(",", "")
        try:
            value = abs(float(s))
        except ValueError:
            return None
        if value > 10_000_000:
            return None
        return round(value * 100) / 100


def make_sentence(rng):
    """生成只含一个金额、但周围噪声很花的句子。

    关键约束：整句有且只有一个数字串，这样两个实现没有「取哪个」的
    解释空间 —— 不一致就是错。
    """
    symbol = rng.choice(["¥", "￥", ""])
    # 没有货币符号时必须带单位：OCR 路径（moneyPatterns）的约定就是
    # 「符号 / 单位 / 两位小数」三选一，裸整数归一句话路径管。
    # 差分只在两条实现都承诺覆盖的范围内比对，否则测的是设计差异，不是缺陷。
    if symbol == "":
        unit = rng.choice(["元", "元整"])
    else:
        unit = rng.choice(["", "元", "元整"])
    intpart = rng.randint(0, 99999)
    decimals = rng.choice([None, 1, 2, 2, 2])
    if decimals is None:
        num = str(intpart)
    else:
        num = f"{intpart}." + "".join(str(rng.randint(0, 9)) for _ in range(decimals))
    # 千分位写法（只在 4 位以上、且随机决定是否加）
    if intpart >= 1000 and rng.random() < 0.35 and decimals is not None:
        head = str(intpart)
        groups = []
        while len(head) > 3:
            groups.insert(0, head[-3:])
            head = head[:-3]
        groups.insert(0, head)
        num = ",".join(groups) + "." + num.split(".")[1]

    words = rng.choice([
        "实付", "支付成功", "合计", "共", "应付", "消费", "订单金额", "付款",
    ])
    tail = rng.choice(["", " ", " 元", "（已优惠）", " 已支付"])
    return f"{words} {symbol}{num}{unit}{tail}"


print("\n=== 5. 差分对拍（独立实现 vs 正则管线，5000 条单金额句）===")

rng = random.Random(20261108)
mismatch = []
agree = 0
for _ in range(5000):
    text = make_sentence(rng)
    checked += 1
    a = amount_in(normalize(text))          # App 的正则管线
    b = RefParser.extract(text)             # 独立实现
    if a is None and b is None:
        agree += 1
        continue
    if a is not None and b is not None and abs(a - b) < 0.005:
        agree += 1
        continue
    mismatch.append((text, a, b))

if mismatch:
    print(f"  ✗ {len(mismatch)} 条不一致（一致 {agree} 条）")
    # 归类，避免刷屏
    seen = set()
    shown = 0
    for text, a, b in mismatch:
        key = (a is None, b is None)
        if key in seen and shown > 6:
            continue
        seen.add(key)
        shown += 1
        print(f"       {text!r} → 管线 {a} / 独立 {b}")
    fail(f"差分对拍出现 {len(mismatch)} 条不一致")
else:
    print(f"  ✓ 5000 条全部一致（管线与独立实现结果相同）")

print("\n=== 6. 分层差异（不算失败，但要知道）===")

LAYER = ["共 6784", "支付成功 91680", "实付 45", "支付成功 45481块"]
for text in LAYER:
    checked += 1
    got = amount_in(normalize(text))
    print(f"  · {text!r:26s} OCR 路径 → {got}；一句话路径由 lastAmountToken 接管")
note("裸整数金额（无符号 / 无单位 / 无小数）与口语单位「块」：OCR 路径取不到，"
     "一句话路径能取到。小票几乎都带 ¥ 或两位小数，实际影响小。")

print()
if notes:
    print("=== 已知局限（不计失败，供判断是否值得修）===")
    for item in notes:
        print("  · " + item)

print()
if problems:
    print(f"✗ 共 {len(problems)} 处问题（检查 {checked} 条）")
    sys.exit(1)
print(f"✓ 全部通过（检查 {checked} 条）")
