#!/usr/bin/env python3
"""macOSが不要な確認を手元で行う。Actionsを回す前に必ず実行する。

  python scripts/check_local.py

確認する内容:
- フィクスチャのJSONが妥当か、秘密情報(acl:consumerKey)を含まないか
- project.yml と GitHub Actions のYAMLが読めるか、Info.plistの必須キーがあるか
- ワークフローのトリガーが方針どおりか(mainへのpushで動かない)
- make_apps_json.py が動き、履歴を引き継ぐか
- Swiftのソースの括弧の対応(簡易チェック)
- @MainActor な型(View に準拠した型を含む)の静的メンバーを、@MainActor でないテストから呼んでいないか
"""
import glob
import json
import os
import subprocess
import sys
import tempfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
errors = []


def check(condition, message):
    if not condition:
        errors.append(message)


def check_fixtures():
    files = glob.glob(os.path.join(ROOT, "SmartDashboardTests", "Fixtures", "*.json"))
    check(files, "フィクスチャがありません")
    for path in files:
        text = open(path, encoding="utf-8").read()
        try:
            json.loads(text)
        except ValueError as e:
            errors.append(f"{os.path.basename(path)}: JSONが不正 ({e})")
        check("consumerKey" not in text, f"{os.path.basename(path)}: トークンらしき文字列を含む")


def check_yaml():
    try:
        import yaml
    except ImportError:
        print("注意: PyYAMLがないためYAMLの確認を省略")
        return
    project = yaml.safe_load(open(os.path.join(ROOT, "project.yml"), encoding="utf-8"))
    props = project["targets"]["SmartDashboard"]["info"]["properties"]
    for key in ("NSLocationWhenInUseUsageDescription", "NSMotionUsageDescription", "NSMicrophoneUsageDescription"):
        check(props.get(key), f"project.yml: {key} がありません")
    for target in project["targets"].values():
        for source in target.get("sources", []):
            check(os.path.isdir(os.path.join(ROOT, source["path"])), f"project.yml: {source['path']} がありません")

    for path in glob.glob(os.path.join(ROOT, ".github", "workflows", "*.yml")):
        name = os.path.basename(path)
        wf = yaml.safe_load(open(path, encoding="utf-8"))
        triggers = wf.get("on", wf.get(True)) or {}
        push = triggers.get("push") if isinstance(triggers, dict) else None
        check(not (push and push.get("branches")), f"{name}: ブランチへのpushで動く設定になっています")
        check(wf.get("concurrency", {}).get("cancel-in-progress") is True, f"{name}: cancel-in-progress がありません")
        for job_name, job in wf["jobs"].items():
            check(job.get("timeout-minutes"), f"{name}: {job_name} に timeout-minutes がありません")


def check_apps_json():
    script = os.path.join(ROOT, "scripts", "make_apps_json.py")
    with tempfile.TemporaryDirectory() as tmp:
        out = os.path.join(tmp, "apps.json")
        ipa = os.path.join(tmp, "a.ipa")
        open(ipa, "wb").write(b"x" * 1234)
        for version in ("1.0.0", "1.0.1", "1.0.1"):
            subprocess.run([sys.executable, script, out, version, ipa, "Nsan736/smart-dashboard"], check=True)
        app = json.load(open(out, encoding="utf-8"))["apps"][0]
        check([v["version"] for v in app["versions"]] == ["1.0.1", "1.0.0"], "apps.json: バージョン履歴が正しくない")
        check(app["size"] == 1234 and app["version"] == "1.0.1", "apps.json: サイズまたはバージョンが正しくない")
        check(app["downloadURL"].endswith("/releases/download/v1.0.1/SmartDashboard.ipa"), "apps.json: URLが正しくない")
    current = os.path.join(ROOT, "apps.json")
    if os.path.exists(current):
        json.load(open(current, encoding="utf-8"))


def check_swift_brackets():
    """文字列とコメントを除いて括弧の対応だけを見る。コンパイルの代わりにはならない。"""
    pairs = {")": "(", "]": "[", "}": "{"}
    for path in glob.glob(os.path.join(ROOT, "SmartDashboard*", "**", "*.swift"), recursive=True):
        text = open(path, encoding="utf-8").read()
        if '"""' in text or '#"' in text:
            continue
        stack = []
        i, n = 0, len(text)
        in_string = False
        ok = True
        while i < n and ok:
            ch = text[i]
            if in_string:
                if ch == "\\":
                    if text[i + 1:i + 2] == "(":
                        depth, i = 1, i + 2
                        while i < n and depth:
                            depth += {"(": 1, ")": -1}.get(text[i], 0)
                            i += 1
                        continue
                    i += 1
                elif ch == '"':
                    in_string = False
            elif text.startswith("//", i):
                i = text.find("\n", i)
                if i < 0:
                    break
            elif ch == '"':
                in_string = True
            elif ch in "([{":
                stack.append(ch)
            elif ch in pairs:
                ok = bool(stack) and stack.pop() == pairs[ch]
            i += 1
        check(ok and not stack, f"{os.path.relpath(path, ROOT)}: 括弧の対応が取れていない可能性")


def check_double_backslash():
    """文字列補間やキーパスのバックスラッシュが二重になっていないか(生成時のエスケープの誤り)。"""
    bad = chr(92) * 2
    for path in glob.glob(os.path.join(ROOT, "SmartDashboard*", "**", "*.swift"), recursive=True):
        for number, line in enumerate(open(path, encoding="utf-8").read().splitlines(), 1):
            if bad + "(" in line or bad + "." in line:
                errors.append(f"{os.path.relpath(path, ROOT)}:{number}: バックスラッシュが二重になっています")


def check_main_actor_statics():
    """ciで実際に起きた失敗の再発防止。nonisolated でない静的メンバーを集め、テスト側の呼び出しを調べる。"""
    import re
    isolated = {}
    for path in glob.glob(os.path.join(ROOT, "SmartDashboard", "**", "*.swift"), recursive=True):
        lines = open(path, encoding="utf-8").read().splitlines()
        current, pending = None, False
        for line in lines:
            stripped = line.strip()
            if stripped.startswith("@MainActor") and "class" not in stripped and "func" not in stripped:
                pending = True
                continue
            m = re.match(r"^(?:final )?(?:class|struct|enum|actor|extension) (\w+)", line)
            if m:
                is_view = re.search(r":\s*(?:[\w.]+,\s*)*View\b", line) is not None
                current = m.group(1) if (pending or "@MainActor" in line or is_view) else None
                pending = False
            elif stripped and not stripped.startswith("@"):
                pending = False
            if current:
                s = re.match(r"^\s+(?:private(?:\(set\))? |fileprivate )?static (?:func|let|var) (\w+)", line)
                if s and "nonisolated" not in line and "private static" not in line:
                    isolated.setdefault(current, set()).add(s.group(1))
    for path in glob.glob(os.path.join(ROOT, "SmartDashboardTests", "*.swift")):
        lines = open(path, encoding="utf-8").read().splitlines()
        for i, line in enumerate(lines):
            for cls, members in isolated.items():
                for member in members:
                    if re.search(rf"{cls}\.{member}", line):
                        context = [l for l in lines[:i] if re.search(r"func test|class \w+: XCTestCase", l) or "@MainActor" in l]
                        recent = context[-3:]
                        func_idx = max((k for k, l in enumerate(recent) if "func test" in l), default=-1)
                        ok = func_idx > 0 and "@MainActor" in recent[func_idx - 1]
                        cls_lines = [k for k, l in enumerate(context) if "XCTestCase" in l]
                        if cls_lines and cls_lines[-1] > 0 and "@MainActor" in context[cls_lines[-1] - 1]:
                            ok = True
                        check(ok, f"{os.path.basename(path)}:{i + 1}: {cls}.{member} は @MainActor。テストを @MainActor にするか nonisolated にする")


for step in (check_fixtures, check_yaml, check_apps_json, check_swift_brackets, check_double_backslash, check_main_actor_statics):
    step()

if errors:
    print("NG")
    for e in errors:
        print(" -", e)
    sys.exit(1)
print("OK: 手元の確認はすべて通りました")
