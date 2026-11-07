#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""从 Support/BillParser.swift 生成一份能脱离 UIKit 编译的副本。

只做两件事：去掉 import UIKit，删掉依赖 UIImage 的 parse(image:)。
其余一行不动 —— 测的必须是 App 里真正在跑的那份代码，不能是手工抄件。
"""
import os
import re
import sys

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
SRC = os.path.join(ROOT, "MonoLedger", "Support", "BillParser.swift")
OUT = sys.argv[1] if len(sys.argv) > 1 else os.path.join(os.path.dirname(__file__), "build", "Core.swift")

src = open(SRC, encoding="utf-8").read()
n0 = len(src.split("\n"))
src = src.replace("import UIKit\n", "")
src = re.sub(r"\n    static func parse\(image: UIImage\) async throws -> ParseResult \{.*?\n    \}\n", "\n", src, flags=re.S)

if "UIImage" in src:
    print("✗ 仍有 UIImage 残留，parse(image:) 的签名可能改过了")
    sys.exit(1)

os.makedirs(os.path.dirname(OUT), exist_ok=True)
open(OUT, "w", encoding="utf-8").write(src)
print(f"✓ 生成 {OUT}（源码 {n0} 行 → {len(src.split(chr(10)))} 行）")
