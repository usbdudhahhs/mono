#!/usr/bin/env python3
# 变异测试：往解析器里注入语义缺陷，看判定器能不能抓到。
# 抓不到 = 这块逻辑没有任何用例覆盖（测试盲区），比「跑绿了」更值得看。
import os, shutil, subprocess, sys, time

HERE = os.path.dirname(os.path.abspath(__file__))
SWIFTC = shutil.which("swiftc") or "/usr/bin/swiftc"
ENV = dict(os.environ)
BASE = os.path.join(HERE, "build")
SRC = open(os.path.join(BASE, "Core.swift"), encoding="utf-8").read()

MUTANTS = [
    ("M01", "零元判定 <= 变 <",            "result.zeroPaid = pick.value <= 0", "result.zeroPaid = pick.value < 0"),
    ("M02", "同行坐标容差 0.02 放宽到 0.2",  "other.box.minX >= row.box.maxX - 0.02", "other.box.minX >= row.box.maxX - 0.2"),
    ("M03", "基准字号分位 28% 改 88%",      "Int(Double(heights.count) * 0.28)", "Int(Double(heights.count) * 0.88)"),
    ("M04", "页面中部加分失效",             "if midY >= 0.42 && midY <= 0.92 { base += 0.7 }", "if midY >= 0.42 && midY <= 0.92 { base += 0.0 }"),
    ("M05", "high 档门限 5.2 降到 4.2",     "best.score >= 5.2 && gap >= 1.1", "best.score >= 4.2 && gap >= 1.1"),
    ("M06", "medium 档门限 3.6 降到 2.6",   "} else if best.score >= 3.6 {", "} else if best.score >= 2.6 {"),
    ("M07", "大字判定 1.25 抬高到 2.5",     "let isGiant = sizeRatio >= 1.25", "let isGiant = sizeRatio >= 2.5"),
    ("M08", "重复金额容差 0.005 放大到 0.5", "let duplicated = unique.contains { abs($0.value - item.value) < 0.005 }", "let duplicated = unique.contains { abs($0.value - item.value) < 0.5 }"),
    ("M09", "备选过滤阈值 0.01 变 0.99",    ".filter { abs($0 - best.value) >= 0.01 }", ".filter { abs($0 - best.value) >= 0.99 }"),
    ("M10", "金额上限 1000 万降到 1000",    "value < 10_000_000", "value < 1_000"),
    ("M11", "同一行判定 h*0.6 收紧 10 倍",  "abs(a.box.midY - b.box.midY) < h * 0.6", "abs(a.box.midY - b.box.midY) < h * 0.06"),
    ("M12", "千分位空格合并失效",           '#"(?<=[0-9])\\s+(?=[0-9]{3}(?:[.,][0-9]{1,2})?(?![0-9]))"#', '#"(?<=[0-9])\\s+(?=[0-9]{6}(?:[.,][0-9]{1,2})?(?![0-9]))"#'),
    ("M13", "O 当零规则失效",               '#"(?<=[¥￥])[Oo](?=[0-9.,])"#', '#"(?<=[¥￥])[Qq](?=[0-9.,])"#'),
    ("M14", "「个人自费」锚点失效",          '"个人自费", "自费金额",', '"个人自费X", "自费金额X",'),
    ("M15", "「找零」排除失效",              'private static let changeLabels = ["找零", "找钱", "应找"]', 'private static let changeLabels = ["找零X", "找钱X", "应找X"]'),
    ("M16", "「本期应还」锚点失效",          '"本期应还", "应还金额", "应还",', '"本期应还X", "应还金额X", "应还X",'),
    ("M17", "「45,00」逗号小数点失效",       "cleaned.distance(from: cleaned.index(after: comma), to: cleaned.endIndex) == 2", "cleaned.distance(from: cleaned.index(after: comma), to: cleaned.endIndex) == 3"),
    ("M18", "转账优先判支出失效",            "private static let outgoingSignals = [\"转账给\", \"转账至\", \"付款给\", \"转给对方\", \"已转账\"]", "private static let outgoingSignals: [String] = []"),
]

def build_and_run(tag):
    d = os.path.join(BASE, f"mut_{tag}")
    shutil.rmtree(d, ignore_errors=True)
    os.makedirs(d)
    for f in ("Stub.swift", "MerchantRules.swift", "Geo.swift", "main.swift"):
        shutil.copy(f"{BASE}/{f}", d)
    return d

# 基线必须先全绿，否则后面所有「杀死」都是假的
BASE_RUN = subprocess.run([os.path.join(BASE, "judge")], capture_output=True, text=True, timeout=180)
if BASE_RUN.returncode != 0:
    print("基线未通过，变异测试无效：")
    print(BASE_RUN.stdout)
    sys.exit(2)
print("基线通过：", BASE_RUN.stdout.strip().split("\n")[0], "\n")

results = []
for tag, desc, old, new in MUTANTS:
    if old not in SRC:
        results.append((tag, desc, "PATTERN-MISS", ""))
        print(f"{tag} 模式未命中：{desc}", flush=True)
        continue
    d = build_and_run(tag)
    mutated = SRC.replace(old, new, 1)
    open(f"{d}/Core.swift", "w", encoding="utf-8").write(mutated)
    t0 = time.time()
    cp = subprocess.run([SWIFTC, "-O", "Core.swift", "Stub.swift", "MerchantRules.swift", "Geo.swift", "main.swift", "-o", "run"],
                        cwd=d, capture_output=True, text=True, env=ENV, timeout=300)
    if cp.returncode != 0:
        results.append((tag, desc, "BUILD-FAIL", ""))
        print(f"{tag} 编译失败 {desc}", flush=True)
        continue
    cp = subprocess.run(["./run"], cwd=d, capture_output=True, text=True, timeout=180)
    out = (cp.stdout or "").strip().split("\n")
    summary = next((l for l in out if l.startswith("RESULT")), "RESULT ?")
    reasons = [l.strip() for l in out if l.strip().startswith("·")][:2]
    status = "KILLED" if cp.returncode != 0 else "SURVIVED"
    results.append((tag, desc, status, summary + ("  ||  " + " / ".join(reasons) if reasons else "")))
    print(f"{tag} {status:8s} {desc}  ({time.time()-t0:.1f}s)  {summary}", flush=True)

print("\n=== 汇总 ===")
k = sum(1 for r in results if r[2] == "KILLED")
s = sum(1 for r in results if r[2] == "SURVIVED")
e = len(results) - k - s
for tag, desc, st, info in results:
    print(f"{tag} {st:10s} {desc}")
    if info: print(f"      {info}")
print(f"\n杀死 {k} / 存活 {s} / 无效 {e}   杀死率 {k/(k+s)*100:.0f}%" if k + s else "")
