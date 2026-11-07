#!/usr/bin/env python3
# 不变量校验：不看「该得多少」，只看「结果不可能违反的硬性质」
import json, re, sys, math

FW = {ord('０')+i: ord('0')+i for i in range(10)}
FW.update({ord('．'): ord('.'), ord('，'): ord(','), ord('：'): ord(':')})

LEGAL_CATS = {"food","transit","shop","fun","home","health","study","social","phone","more",
              "salary","bonus","invest","part","red","refund","claim","giftIn","moreIn"}
LEGAL_TIERS = {"high","medium","low"}

def norm_text(t):
    t = t.translate(FW)
    t = t.replace("\u200b", "").replace("\ufeff", "")
    return t

def candidates(t):
    """原文里所有可能被读成金额的数，含各种归一化变体"""
    t = norm_text(t)
    out = set()
    def add(v):
        try:
            f = float(v)
            if f >= 0: out.add(round(f, 4))
        except ValueError:
            pass
    for tok in re.findall(r'[\d][\d,\. ]*[\d]|[\d]', t):
        tok = tok.strip()
        add(tok); add(tok.replace(",", "")); add(tok.replace(" ", ""))
        add(tok.replace(" ", "").replace(",", ""))
        add(tok.replace(",", "."))
        # 逐段拆开：「1,2,3,4」「1.2.3.4」也要能取到每一段与相邻两位组合
        parts = re.split(r'[,.]', tok)
        for p in parts:
            add(p)
        for i in range(len(parts) - 1):
            add(parts[i] + "." + parts[i + 1])
        # 单逗号两位小数「45,00」
        m = re.fullmatch(r'(\d+),(\d{2})', tok)
        if m: add(m.group(1) + "." + m.group(2))
        # 千分位逗号被 OCR 读成点「1.234.56」→ 解析器会拼成 1234.56。
        # 这一条仍是原文数字的重组（不是凭空造数），所以放进候选集；
        # 只认「1~3 位 . 3 位 . 1~2 位」这一种形状，避免把任意拼接都放过
        m = re.fullmatch(r'(\d{1,3})\.(\d{3})\.(\d{1,2})', tok)
        if m: add(m.group(1) + m.group(2) + "." + m.group(3))
    return out

rows = [json.loads(l) for l in open(sys.argv[1], encoding="utf-8")]
fails = []
stats = {}

def bad(kind, r, extra=""):
    fails.append((kind, r["i"], r["amount"], r["tier"], r["type"], r["cat"], r["text"][:120].replace("\n","⏎"), extra))
    stats[kind] = stats.get(kind, 0) + 1

for r in rows:
    a = r["amount"]
    if not math.isfinite(a) or a < 0:
        bad("A1 金额非法", r, str(a))
    if not (0.0 <= r["conf"] <= 1.0) or not math.isfinite(r["conf"]):
        bad("A2 置信度越界", r, str(r["conf"]))
    if any((not math.isfinite(x)) or x < 0 for x in r["alts"]):
        bad("A3 备选金额非法", r, str(r["alts"]))
    if r["cat"] not in LEGAL_CATS:
        bad("A4 分类越界", r, r["cat"])
    if r["tier"] not in LEGAL_TIERS:
        bad("A5 档位越界", r, r["tier"])
    if r["type"] not in {"expense", "income"}:
        bad("A6 收支越界", r, r["type"])
    if not r["det"]:
        bad("A7 同输入结果不一致", r)
    if not r["tail"]:
        bad("A8 尾部空行改变金额", r)
    if r["ms"] > 200:
        bad("A9 单次超 200ms", r, f'{r["ms"]:.1f}ms')
    # 反幻觉：金额必须来自原文
    if a > 0:
        cs = candidates(r["text"])
        if not any(abs(a - c) < 0.005 for c in cs):
            bad("A10 金额不在原文中", r, f"候选={sorted(cs)[:8]}")
    for x in r["alts"]:
        if x > 0:
            cs = candidates(r["text"])
            if not any(abs(x - c) < 0.005 for c in cs):
                bad("A11 备选不在原文中", r, f"{x} 候选={sorted(cs)[:8]}")

print(f"样本 {len(rows)} 条")
if not fails:
    print("✅ 全部不变量通过")
else:
    print(f"❌ {len(fails)} 条违规\n")
    for kind, cnt in sorted(stats.items(), key=lambda kv: -kv[1]):
        print(f"  {kind}: {cnt}")
    print()
    seen = {}
    for f in fails:
        if seen.get(f[0], 0) >= 4:
            continue
        seen[f[0]] = seen.get(f[0], 0) + 1
        print(f"[{f[0]}] #{f[1]} amount={f[2]} tier={f[3]} type={f[4]} cat={f[5]} {f[7]}")
        print(f"    {f[6]}")
    sys.exit(1)
