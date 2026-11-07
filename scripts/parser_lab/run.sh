#!/usr/bin/env bash
# 一键跑三套测试：判定器（金标准+蜕变+不变量）→ 模糊测试 → 变异测试
# 需要 swiftc（macOS 自带，或 Linux 装 swift 6 工具链）
set -euo pipefail
cd "$(dirname "$0")"
ROOT="../.."
BUILD="build"
mkdir -p "$BUILD"

echo "── 0. 生成无 UIKit 副本 ─────────────────────────────"
python3 make_core.py "$BUILD/Core.swift"

echo
echo "── 1. 判定器（金标准 + 蜕变 + 随机不变量 + 几何）───"
cp harness/*.swift "$BUILD/"
swiftc -O "$BUILD/Core.swift" "$BUILD/Stub.swift" "$BUILD/MerchantRules.swift" \
       "$BUILD/Geo.swift" "$BUILD/main.swift" -o "$BUILD/judge"
"$BUILD/judge"

echo
echo "── 2. 模糊测试（3000 条，只断言不变量）─────────────"
mkdir -p "$BUILD/fz"
cp fuzz/main.swift "$BUILD/fz/main.swift"
cp "$BUILD/Core.swift" "$BUILD/Stub.swift" "$BUILD/MerchantRules.swift" "$BUILD/fz/"
swiftc -O "$BUILD/fz/Core.swift" "$BUILD/fz/Stub.swift" "$BUILD/fz/MerchantRules.swift" \
       "$BUILD/fz/main.swift" -o "$BUILD/fz/fuzz"
"$BUILD/fz/fuzz" > "$BUILD/fuzz_out.jsonl"
python3 fuzz_check.py "$BUILD/fuzz_out.jsonl"

echo
echo "── 3. 变异测试（注入 18 个缺陷，看能抓到几个）──────"
python3 mutate.py

echo
echo "全部完成。"
