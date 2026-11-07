#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
MonoLedger 静态编译性检查
不依赖 swiftc：建符号表 → 交叉校验类型/成员 → 扫描 API 可用性与 SwiftData 合规
"""
import os
import re
import sys
import glob
import json

ROOT = os.path.dirname(os.path.abspath(__file__))
APP = os.path.join(ROOT, "..")

problems = []   # (level, file, line, msg)


def add(level, f, line, msg):
    problems.append((level, f, line, msg))


# ---------- 1. 读文件 + 去注释/字符串（保留行号） ----------
def strip_code(src):
    out = []
    i, n = 0, len(src)
    in_line = in_block = in_str = False
    str_delim = ''
    while i < n:
        c = src[i]
        two = src[i:i + 2]
        three = src[i:i + 3]
        if in_line:
            if c == '\n':
                in_line = False
                out.append('\n')
            else:
                out.append(' ')
            i += 1
            continue
        if in_block:
            if two == '*/':
                in_block = False
                out.append('  ')
                i += 2
                continue
            out.append('\n' if c == '\n' else ' ')
            i += 1
            continue
        if in_str:
            if c == '\\':
                out.append('  ')
                i += 2
                continue
            if str_delim == '"""' and three == '"""':
                in_str = False
                out.append('   ')
                i += 3
                continue
            if str_delim == '"' and c == '"':
                in_str = False
                out.append(' ')
                i += 1
                continue
            out.append('\n' if c == '\n' else ' ')
            i += 1
            continue
        if three in ('"""',):
            in_str, str_delim = True, '"""'
            out.append('   ')
            i += 3
            continue
        if c == '"':
            in_str, str_delim = True, '"'
            out.append(' ')
            i += 1
            continue
        if two == '//':
            in_line = True
            out.append('  ')
            i += 2
            continue
        if two == '/*':
            in_block = True
            out.append('  ')
            i += 2
            continue
        out.append(c)
        i += 1
    return ''.join(out)


files = {}
for p in sorted(glob.glob(os.path.join(APP, "MonoLedger", "**", "*.swift"), recursive=True)):
    rel = os.path.relpath(p, APP).replace("\\", "/")
    files[rel] = strip_code(open(p, encoding="utf-8").read())

test_files = {}
for p in glob.glob(os.path.join(APP, "MonoLedgerTests", "**", "*.swift"), recursive=True):
    rel = os.path.relpath(p, APP).replace("\\", "/")
    test_files[rel] = strip_code(open(p, encoding="utf-8").read())


def line_of(text, idx):
    return text.count("\n", 0, idx) + 1


def find_block_end(text, start):
    """从 start 处的 { 开始配平"""
    depth = 0
    for i in range(start, len(text)):
        if text[i] == '{':
            depth += 1
        elif text[i] == '}':
            depth -= 1
            if depth == 0:
                return i
    return len(text)


# ---------- 2. 建符号表 ----------
TYPE_RE = re.compile(r'\b(struct|class|enum|actor|protocol)\s+([A-Z]\w*)')
EXT_RE = re.compile(r'\bextension\s+([A-Z]\w*)')
MEMBER_RES = [
    re.compile(r'\bfunc\s+([a-zA-Z_]\w*)'),
    re.compile(r'\b(?:var|let)\s+([a-zA-Z_]\w*)'),
    re.compile(r'\bcase\s+([^\n]+)', re.M),
    re.compile(r'\btypealias\s+([a-zA-Z_]\w*)'),
]

types = {}          # name -> {kind, file, line, members:set, parents:set, protocol:bool}
extensions = {}     # typename -> [(file, line, members)]
top_funcs = {}      # name -> (file, line)
globals_decl = {}   # name -> (file, line)

for rel, src in files.items():
    for m in TYPE_RE.finditer(src):
        kind, name = m.group(1), m.group(2)
        brace = src.find('{', m.end())
        body = src[m.end():brace]
        end = find_block_end(src, brace) if brace != -1 else m.end()
        block = src[brace:end]
        members = set()
        for rx in MEMBER_RES:
            for mm in rx.finditer(block):
                if rx.pattern.startswith(r'\bcase'):
                    for c in mm.group(1).split(','):
                        cm = re.match(r'\s*([a-zA-Z_]\w*)', c)
                        if cm:
                            members.add(cm.group(1))
                else:
                    members.add(mm.group(1))
        # 继承/协议
        parents = set(re.findall(r'[A-Z]\w*', body.replace(kind, '')))
        if name in types:
            add("FATAL", rel, line_of(src, m.start()),
                f"类型 {name} 重复定义（另一处在 {types[name]['file']}:{types[name]['line']}）→ invalid redeclaration")
        else:
            types[name] = {"kind": kind, "file": rel, "line": line_of(src, m.start()),
                           "members": members, "parents": parents}
        # 嵌套类型登记为限定名，不参与重名判定
        for nm in TYPE_RE.finditer(block):
            nested = nm.group(2)
            key = f"{name}.{nested}"
            if nested != name and key not in types:
                types[key] = {"kind": nm.group(1), "file": rel, "line": 0,
                              "members": set(), "parents": set()}

    for m in EXT_RE.finditer(src):
        name = m.group(1)
        brace = src.find('{', m.end())
        end = find_block_end(src, brace) if brace != -1 else m.end()
        block = src[brace:end]
        members = set()
        for rx in MEMBER_RES:
            for mm in rx.finditer(block):
                if rx.pattern.startswith(r'\bcase'):
                    for c in mm.group(1).split(','):
                        cm = re.match(r'\s*([a-zA-Z_]\w*)', c)
                        if cm:
                            members.add(cm.group(1))
                else:
                    members.add(mm.group(1))
        extensions.setdefault(name, []).append({"file": rel, "line": line_of(src, m.start()),
                                                "members": members})

# 合并 extension 成员到类型
for name, exts in extensions.items():
    if name in types:
        for e in exts:
            types[name]["members"] |= e["members"]

# 顶层函数 & 全局变量（含 static 单例）
for rel, src in files.items():
    depth = 0
    i = 0
    # 简单法：顶层 = 花括号深度 0 的行
    for lineno, line in enumerate(src.split("\n"), 1):
        stripped = line.strip()
        if re.match(r'^(?:@\w+(?:\([^)]*\))?\s+)*(?:public |internal |private |fileprivate )?(func|let|var)\s+([a-zA-Z_]\w*)', stripped) and depth == 0:
            m = re.match(r'^(?:@\w+(?:\([^)]*\))?\s+)*(?:public |internal |private |fileprivate )?(func|let|var)\s+([a-zA-Z_]\w*)', stripped)
            if m.group(1) == 'func':
                top_funcs[m.group(2)] = (rel, lineno)
            else:
                globals_decl[m.group(2)] = (rel, lineno)
        depth += line.count("{") - line.count("}")

# ---------- 3. 系统类型白名单 ----------
SYSTEM = set("""
Int Int8 Int16 Int32 Int64 UInt UInt8 UInt16 UInt32 UInt64 Double Float Bool String Character
Array Dictionary Set Optional Result Void Never Any AnyObject AnyHashable Error
Range ClosedRange Comparable Equatable Hashable Codable Encodable Decodable Identifiable
CaseIterable RawRepresentable CustomStringConvertible Sequence Collection IteratorProtocol
Equatable Sequence AsyncSequence Task TaskGroup MainActor Actor Sendable UnsafePointer
StringProtocol Substring Date DateFormatter DateInterval Calendar TimeZone Locale
Decimal NumberFormatter UUID URL URLComponents URLRequest Data JSONEncoder JSONDecoder
Notification NotificationCenter UserDefaults Bundle FileManager ProcessInfo
Locale NumberFormatter CharacterSet NSPredicate NSSortDescriptor NSError NSObject
CGFloat CGRect CGSize CGPoint CGAffineTransform CGImage UIImage UIImageView UIColor UIFont
UIApplication UIDevice UIScreen UIImpactFeedbackGenerator UINotificationFeedbackGenerator
UIPasteboard UIWindowScene UIInterfaceOrientation UIUserInterfaceIdiom
View Text Image Button Label List Form Section Group VStack HStack ZStack LazyVStack
LazyVGrid LazyHGrid Grid GridRow ScrollView ScrollViewReader NavigationStack NavigationLink
NavigationView NavigationSplitView NavigationPath TabView Tab TabSection
Color Font FontWeight FontDesign Material LinearGradient RadialGradient AngularGradient
Gradient Ellipse Circle Rectangle RoundedRectangle Capsule Path Shape ShapeStyle
Spacer Divider Toggle Picker DatePicker Stepper Slider TextField SecureField TextEditor
Alert ActionSheet Sheet ConfirmationDialog Menu MenuStyle ContextMenu
GeometryReader GeometryProxy Binding State StateObject ObservedObject EnvironmentObject
Environment EnvironmentValues Scene App WindowGroup DocumentGroup
Animation AnimationCurve Transition AnyTransition TimelineView
AppStorage SceneStorage ToolbarItem ToolbarItemGroup ToolbarContent ToolbarPlacement
NavigationTitleDisplayMode ListStyle InsetGroupedListStyle SidebarListStyle
ButtonStyle PlainButtonStyle BorderlessButtonStyle DefaultButtonStyle
LabelStyle IconOnlyLabelStyle TitleAndIconLabelStyle
TextAlignment TextCase LineLimit TruncationMode DynamicTypeSize ColorScheme
ImagePaint ScaleEffect OffsetEffect RotateEffect SafeAreaInsets EdgeInsets
Alignment HorizontalAlignment VerticalAlignment UnitPoint Angle Axis Set
ShareLink Transferable PhotosPicker PhotosPickerItem PhotosUI PHPickerViewController
PHPickerConfiguration PHPhotoLibrary PHAsset PHFetchOptions PHFetchResult PHAssetCollection
PHImageManager PHImageRequestOptions UIImagePickerController ImageRenderer
ModelContainer ModelContext ModelConfiguration PersistentModel Query Model ModelActor
FetchDescriptor Predicate SortDescriptor Schema ModelConfiguration
Vision VNRecognizeTextRequest VNImageRequestHandler VNRecognizedTextObservation
VNRecognizedText VNRequestTextRecognitionLevel
AppIntent AppShortcut AppShortcutsProvider IntentParameter IntentResult
ProvidesDialog ReturnsValue ParameterSummary IntentDescription
URLSession HTTPURLResponse
NSLock DispatchQueue DispatchTime DispatchGroup
AsyncImage FetchRequest
CustomPresentationDetent PresentationDetent
ContentUnavailableView ContentSizeCategory
Chip SegmentedPickerStyle
Chart BarMark LineMark SectorMark
Regex NSRegularExpression NSTextCheckingResult
NSRange NSRangePointer
Combine AnyPublisher PassthroughSubject ObservableObject Published Cancellable
NSCache NSItemProvider UIActivityViewController
LocalizedStringKey TextFieldStyle
LabeledContent AsyncImage
RefundError NSError
ForEach GridItem ProgressView StrokeStyle Gesture MagnifyGesture DragGesture Scanner
Content ViewBuilder ViewModifier FocusState LocalizedError LocalizedStringResource
IntentFile Summary Parameter IntentConfiguration DateComponents TimeInterval
NSNumber NSString NSDictionary NSNotFound CFData CFString CFDictionary
CFNumber UIGraphicsImageRenderer UIGraphicsImageRendererFormat
CGImagePropertyOrientation CGImageSource CGImageSourceCreateWithData
CGImageSourceCreateThumbnailAtIndex CGImageSourceCopyPropertiesAtIndex CIImage CIContext
PHImageResultIsDegradedKey PHImageCancelledKey PHImageErrorKey PHImageRequestID
UIImagePickerControllerDelegate UINavigationControllerDelegate
Value Context Configuration Attribute CodingKey Decoder Encoder Container
""".split())

# ---------- 4. 未解析类型检查 ----------
# 系统符号按前缀整类放过：UIKit / Foundation / CoreGraphics / Photos / Vision 的类型
# 全是 UI NS CG CF PH VN 开头，逐个列白名单永远列不全，噪音会淹掉真正的漏声明
SYSTEM_PREFIXES = ("UI", "NS", "CG", "CF", "PH", "VN", "AV", "UT", "MTL", "CI", "CL", "SK", "WK")
SYSTEM_MODULES = {"SwiftUI", "SwiftData", "UIKit", "Foundation", "Photos", "PhotosUI", "Vision",
                  "ImageIO", "AppIntents", "UniformTypeIdentifiers", "Combine", "Observation",
                  "CoreGraphics", "CoreImage", "AVFoundation", "CryptoKit", "XCTest", "MapKit"}

KW = set("""if else for while switch case default return try throws throw await async let var func
struct class enum actor protocol extension import init deinit self Self super nil true false
some any where in as is guard break continue defer do catch repeat typealias associatedtype
operator static private public internal fileprivate open final lazy weak unowned mutating
nonmutating override required convenience subscript get set willSet didSet inout escaping
autoclosure @objc dynamic indirect convenience""".split())

declared_globals = set(globals_decl) | set(top_funcs)
unresolved = {}
for rel, src in files.items():
    for m in re.finditer(r'(?<![\w.])([A-Z][A-Za-z0-9_]{2,})(?![\w])', src):
        name = m.group(1)
        if name in types or name in SYSTEM or name in KW:
            continue
        if name in SYSTEM_MODULES or name.startswith(SYSTEM_PREFIXES):
            continue
        unresolved.setdefault(name, []).append((rel, line_of(src, m.start())))

# 解析不到的类型 = 编译一定失败的 error: cannot find type。
# 系统符号已经按前缀放过，剩下的就是漏声明或拼错，直接记为 FATAL 让 CI 拦住
for name, locs in unresolved.items():
    f0, l0 = locs[0]
    add("FATAL", f0, l0, f"类型 {name} 找不到声明（共 {len(locs)} 处引用，可能是拼写错误或漏建文件）")

# ---------- 5. Type.member 静态访问校验 ----------
PROTO_MEMBERS = {"allCases", "id", "hashValue", "rawValue", "description", "debugDescription",
                 "errorDescription", "failureReason", "recoverySuggestion", "helpAnchor",
                 "localizedDescription", "init", "self", "Type", "none", "startIndex", "endIndex",
                 "encode", "decode", "count", "isEmpty"}
for rel, src in files.items():
    for m in re.finditer(r'(?<![\w.])([A-Z]\w*)\.([a-zA-Z_]\w*)', src):
        tname, member = m.group(1), m.group(2)
        if tname not in types:
            continue
        info = types[tname]
        if member in ('init', 'self', 'Type', 'none'):
            continue
        if member in info["members"]:
            continue
        if member in PROTO_MEMBERS and info["parents"]:
            continue
        # 继承来的成员（父类型在项目内）
        hit = False
        stack = list(info["parents"])
        seen = set()
        while stack:
            p = stack.pop()
            if p in seen:
                continue
            seen.add(p)
            if p in types and member in types[p]["members"]:
                hit = True
                break
            if p in types:
                stack.extend(types[p]["parents"])
        if not hit:
            add("WARN", rel, line_of(src, m.start()),
                f"{tname}.{member} —— 类型 {tname} 及其继承链上没有成员 {member}")

# ---------- 6. SwiftData 模型合规 ----------
for rel, src in files.items():
    for m in re.finditer(r'@Model\b', src):
        # 找到该行后紧跟的 class
        tail = src[m.end():]
        cm = re.search(r'\b(?:final\s+)?class\s+([A-Z]\w*)', tail)
        if not cm:
            add("FATAL", rel, line_of(src, m.start()), "@Model 后面没有 class 声明")
            continue
        cname = cm.group(1)
        brace = src.find('{', m.end() + cm.end())
        end = find_block_end(src, brace)
        block = src[m.end() + cm.end():end]
        # 非 optional、无默认值的存储属性（SwiftData 允许，但关系型必须有默认/optional）
        for pm in re.finditer(r'\b(?:@Attribute[^\n]*\n\s*)?(?:var|let)\s+([a-zA-Z_]\w*)\s*:\s*([^=\n{]+)(=?)([^\n]*)', block):
            pname, ptype, eq, rest = pm.group(1), pm.group(2).strip(), pm.group(3), pm.group(4).strip()
            if ptype.startswith('[') and ']' in ptype and not rest:
                add("WARN", rel, 0, f"@Model {cname}.{pname}: 数组属性无默认值 — 老数据迁移时可能解不出来")
            if ('[' in ptype and 'to:' in ptype) or '@Relationship' in block[max(0, pm.start()-80):pm.start()]:
                pass
        # relationship 检查
        for rm in re.finditer(r'@Relationship([^\n]*)\n\s*(?:var|let)\s+([a-zA-Z_]\w*)', block):
            args, rname = rm.group(1), rm.group(2)
            if 'inverse' not in args:
                add("INFO", rel, 0, f"@Relationship {cname}.{rname} 未指定 inverse（一对多反向关系缺失易致删除不同步）")

# ---------- 7. iOS 18/26 专属 API 扫描（部署目标 17.0） ----------
IOS18 = {
    ".scrollTargetBehavior": "iOS 17 可用",
    "MeshGradient": ("iOS 18", "需要 @available(iOS 18.0, *)"),
    "Tab(\"": ("iOS 18 新 TabView API", "旧 TabView+.tabItem 才是 17 可用"),
    ".symbolEffect(.wiggle": ("iOS 18", ""),
    ".scrollEdgeEffect": ("iOS 26", ""),
    "GlassEffect": ("iOS 26", ""),
    ".glassEffect": ("iOS 26", ""),
    "@Entry": ("iOS 17 可用(Xcode 16 宏)", ""),
    ".onScrollGeometryChange": ("iOS 18", ""),
    "TabView(": ("iOS 13 起可用", ""),
    ".tabViewStyle(.sidebarAdaptable)": ("iOS 18", ""),
    ".containerRelativeFrame": ("iOS 17 可用", ""),
    "NSUbiquitousKeyValueStore": ("iOS 5", ""),
    "SwiftData.Schema": ("iOS 17", ""),
    ".contentMargins": ("iOS 17", ""),
}
for rel, src in files.items():
    for api, meta in IOS18.items():
        ver, note = meta if isinstance(meta, tuple) else (meta, "")
        if api in src:
            for i, line in enumerate(src.split("\n"), 1):
                if api in line:
                    add("INFO", rel, i, f"API {api} 标注 {ver} {note}".strip())

# ---------- 8. import 覆盖 ----------
NEED = {
    "Vision": ["VNRecognizeTextRequest", "VNImageRequestHandler", "VNRecognizedTextObservation", "VNRecognizedText"],
    "PhotosUI": ["PhotosPicker", "PhotosPickerItem"],
    "Photos": ["PHPhotoLibrary", "PHAsset", "PHFetchOptions", "PHImageManager", "PHAssetCollection"],
    "UIKit": ["UIImage", "UIApplication", "UIPasteboard", "UIImpactFeedbackGenerator", "UIDevice", "UIScreen"],
    "AppIntents": ["AppIntent", "AppShortcut", "AppShortcutsProvider", "IntentParameter"],
    "UniformTypeIdentifiers": ["UTType"],
    "CryptoKit": ["SHA256", "SHA512"],
    "AVFoundation": ["AVCaptureSession", "AVCaptureVideoPreviewLayer"],
}
for rel, src in files.items():
    imports = set(re.findall(r'^\s*import\s+(\w+)', src, re.M))
    for mod, syms in NEED.items():
        if mod in imports:
            continue
        used = [s for s in syms if re.search(r'(?<![\w.])' + s + r'(?![\w])', src)]
        if used:
            add("FATAL", rel, 0, f"用到 {', '.join(used[:3])} 但没有 import {mod}")

# ---------- 9. 输出 ----------
print(f"扫描 {len(files)} 个 App 源文件 / {sum(len(s.split(chr(10))) for s in files.values())} 行\n")

print("=== 未解析的大写标识符（可能是拼写错误或漏声明）===")
if not unresolved:
    print("  无")
else:
    for name, locs in sorted(unresolved.items(), key=lambda x: -len(x[1])):
        f0, l0 = locs[0]
        print(f"  {name:28s} x{len(locs):<3d} 首现 {f0}:{l0}")

print("\n=== 问题清单 ===")
order = {"FATAL": 0, "WARN": 1, "INFO": 2}
for lvl, f, ln, msg in sorted(problems, key=lambda x: (order[x[0]], x[1])):
    loc = f"{f}:{ln}" if ln else f
    print(f"[{lvl}] {loc} {msg}")
if not problems:
    print("  无")

print(f"\n统计：FATAL {sum(1 for p in problems if p[0]=='FATAL')} / "
      f"WARN {sum(1 for p in problems if p[0]=='WARN')} / "
      f"INFO {sum(1 for p in problems if p[0]=='INFO')}")

# ---------- 10. 实例成员访问校验（同文件内变量，避免跨文件同名误报） ----------
SYSTEM_MODEL_MEMBERS = {"persistentModelID", "modelContext", "hasChanges", "isDeleted", "hash",
                        "observationRegistrar", "schemaMetadata"}
ARRAY_RE = re.compile(r':\s*\[\s*([A-Z][\w.]*)\s*\]')
SCALAR_RES = [
    re.compile(r'@(?:State|StateObject|ObservedObject|EnvironmentObject|FocusState)\s+(?:private\s+|public\s+)?var\s+([a-zA-Z_]\w*)\s*:\s*([A-Z][\w.]*)'),
    re.compile(r'@Query\s*(?:\([^)]*\))?\s*(?:private\s+)?var\s+([a-zA-Z_]\w*)\s*:\s*([A-Z][\w.]*)'),
    re.compile(r'\b(?:let|var)\s+([a-zA-Z_]\w*)\s*:\s*([A-Z][\w.]*)'),
    re.compile(r'\bfor\s+([a-zA-Z_]\w*)\s+in\s+[a-zA-Z_][\w.]*'),
]

bad = []
for rel, src in files.items():
    varmap = {}
    for m in ARRAY_RE.finditer(src):
        pass
    for rx in SCALAR_RES:
        for m in rx.finditer(src):
            if m.groups() and len(m.groups()) == 2 and m.group(2):
                t = m.group(2)
                if t in types:
                    varmap.setdefault(m.group(1), set()).add(t)
    arrays = {m.start() for m in ARRAY_RE.finditer(src)}
    for vname, tset in varmap.items():
        for m in re.finditer(r'(?<![\w.])' + re.escape(vname) + r'\.([a-zA-Z_]\w*)', src):
            member = m.group(1)
            if member in SYSTEM_MODEL_MEMBERS:
                continue
            ok = False
            for t in tset:
                info = types[t]
                if member in info["members"] or member in PROTO_MEMBERS:
                    ok = True
                    break
                stack, seen = list(info["parents"]), set()
                while stack:
                    p2 = stack.pop()
                    if p2 in seen:
                        continue
                    seen.add(p2)
                    if p2 in types and member in types[p2]["members"]:
                        ok = True
                        break
                    if p2 in types:
                        stack.extend(types[p2]["parents"])
            if not ok:
                bad.append((rel, line_of(src, m.start()), f"{vname}:{','.join(sorted(tset))}.{member}"))

print("\n=== 实例成员未解析 ===")
if not bad:
    print("  无")
for rel, ln, msg in bad:
    print(f"  {rel}:{ln} {msg}")

# ---------- 11. 语法结构完整性 ----------
print("\n=== 结构完整性（括号 / 预处理 / BOM）===")
struct_bad = []
for rel, src in files.items():
    raw = open(os.path.join(APP, rel), "rb").read()
    if raw.startswith(b"\xef\xbb\xbf"):
        struct_bad.append(f"{rel}: 含 UTF-8 BOM，Swift 编译可能报 invalid character")
    for open_c, close_c in (("{", "}"), ("(", ")"), ("[", "]")):
        if src.count(open_c) != src.count(close_c):
            struct_bad.append(f"{rel}: {open_c}{close_c} 不平衡（{src.count(open_c)} vs {src.count(close_c)}）")
    ifs = len(re.findall(r'^\s*#if\b', src, re.M))
    ends = len(re.findall(r'^\s*#endif\b', src, re.M))
    if ifs != ends:
        struct_bad.append(f"{rel}: #if {ifs} / #endif {ends} 不匹配")
    pres = len(re.findall(r'^\s*#Preview', src, re.M))
    if pres:
        for m in re.finditer(r'#Preview[^\n]*\{', src):
            pass
if struct_bad:
    for b in struct_bad:
        print("  ✗ " + b)
else:
    print("  无异常（27 个文件括号、预处理器指令均配平）")

# ---------- 12. 符号重复与命名冲突 ----------
print("\n=== 跨文件同名扩展冲突（同一类型多个 extension 定义同名成员）===")
clash = []
for name, exts in extensions.items():
    if name not in types:
        continue
    seen = {}
    for e in exts:
        for mem in e["members"]:
            if mem in seen and seen[mem] != e["file"]:
                clash.append(f"{name}.{mem} 在 {seen[mem]} 与 {e['file']} 重复定义")
            seen[mem] = e["file"]
if clash:
    for c in clash:
        print("  ✗ " + c)
else:
    print("  无")
