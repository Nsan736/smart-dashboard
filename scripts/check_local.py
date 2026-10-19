#!/usr/bin/env python3
"""macOSが不要な確認を手元で行う。Actionsを回す前に必ず実行する。

  python scripts/check_local.py

確認する内容:
- フィクスチャのJSONが妥当か、秘密情報(acl:consumerKey、トークンらしき長い文字列)を含まないか
- Git の管理下のファイルに、ODPT のトークンの値が書かれていないか。private/ が管理外か
- project.yml と GitHub Actions のYAMLが読めるか、Info.plistの必須キーがあるか
- ワークフローのトリガーが方針どおりか(mainへのpushで動かない)
- make_apps_json.py が動き、履歴を引き継ぐか
- Swiftのソースの括弧の対応(簡易チェック)
- @MainActor な型(View に準拠した型を含む)の静的メンバーを、@MainActor でないテストから呼んでいないか
- Swift の文字列が行の途中で切れていないか(パッチの文字列の改行の記号が、本物の改行になる誤り。v0.9.17 の ci で起きた)
- アプリに同梱した小ツールの形式の説明が、docs/tools-format.md と同じか
- Claude の APIキーらしき文字列(sk-ant-)が、Git の管理下のファイルに書かれていないか
- スクリプト型のサンプル(examples/tools と、テストのフィクスチャ)が、examples/tools/src の JavaScript から作ったものと同じか
"""
import glob
import json
import os
import re
import subprocess
import sys
import tempfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
errors = []


def check(condition, message):
    if not condition:
        errors.append(message)


# トークンらしき文字列: 小文字の16進で40文字以上、または英数字だけで48文字以上(ODPT の ucode の @id は大文字の16進32文字なので当たらない)
TOKEN_LIKE = re.compile(r"(?<![0-9A-Za-z])(?:[0-9a-f]{40,}|[0-9A-Za-z]{48,})(?![0-9A-Za-z])")
ANTHROPIC_KEY = re.compile(r"sk-ant-[A-Za-z0-9_-]{16,}")
TOKEN_KEYS = re.compile(r"consumerKey|acl:|api[_-]?key|access[_-]?token", re.IGNORECASE)


def find_token_like(value, path=""):
    """JSON の値をたどって、トークンらしき文字列と、トークンの名前のキーを探す"""
    found = []
    if isinstance(value, dict):
        for key, item in value.items():
            if TOKEN_KEYS.search(key):
                found.append(f"{path}/{key}: トークンの名前のキー")
            found += find_token_like(item, f"{path}/{key}")
    elif isinstance(value, list):
        for index, item in enumerate(value):
            found += find_token_like(item, f"{path}[{index}]")
    elif isinstance(value, str) and TOKEN_LIKE.search(value):
        found.append(f"{path}: トークンらしき文字列")
    return found


def check_fixtures():
    files = glob.glob(os.path.join(ROOT, "SmartDashboardTests", "Fixtures", "*.json"))
    check(files, "フィクスチャがありません")
    for path in files:
        text = open(path, encoding="utf-8").read()
        name = os.path.basename(path)
        try:
            data = json.loads(text)
        except ValueError as e:
            errors.append(f"{name}: JSONが不正 ({e})")
            continue
        check("consumerKey" not in text, f"{name}: トークンらしき文字列を含む")
        for problem in find_token_like(data)[:3]:
            errors.append(f"{name}{problem}")


def check_committed_secrets():
    """Git の管理下のファイルに、acl:consumerKey の値が書かれていないか。private/ が管理外か。"""
    try:
        listed = subprocess.run(["git", "ls-files"], cwd=ROOT, capture_output=True, text=True, encoding="utf-8", check=True).stdout.split("\n")
    except (OSError, subprocess.CalledProcessError):
        print("注意: git がないため、管理下のファイルの確認を省略")
        return
    check(not any(f.startswith("private/") for f in listed), "private/ のファイルが Git の管理下にあります")
    assigned = re.compile(r"acl:consumerKey=([^&\s\"'<>]+)")
    placeholders = ("[", "{", "<", "(", "$", "YOUR", "xxx", "invalid")
    for name in listed:
        if not name or not name.endswith((".swift", ".py", ".json", ".md", ".yml", ".txt")):
            continue
        try:
            text = open(os.path.join(ROOT, name), encoding="utf-8").read()
        except (OSError, UnicodeDecodeError):
            continue
        for match in assigned.finditer(text):
            check(match.group(1).startswith(placeholders), f"{name}: acl:consumerKey に値が書かれています")
        check(ANTHROPIC_KEY.search(text) is None, f"{name}: Claude の APIキーらしき文字列(sk-ant-)が書かれています")


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


def check_unterminated_strings():
    """1行の中で引用符の数が奇数の行(複数行の文字列 \"\"\" と #"..."# の行は除く)。文字列の途中の改行を見つける。"""
    backslash = chr(92)
    for path in glob.glob(os.path.join(ROOT, "SmartDashboard*", "**", "*.swift"), recursive=True):
        in_multiline = False
        for number, line in enumerate(open(path, encoding="utf-8").read().splitlines(), 1):
            if '"""' in line:
                if line.count('"""') % 2 == 1:
                    in_multiline = not in_multiline
                continue
            if in_multiline or '#"' in line:
                continue
            count, i = 0, 0
            while i < len(line):
                if line[i] == backslash:
                    i += 2
                    continue
                if line[i] == '"':
                    count += 1
                i += 1
            check(count % 2 == 0, f"{os.path.relpath(path, ROOT)}:{number}: 文字列が行の途中で切れている可能性(引用符の数が奇数)")


def check_bundled_docs():
    """Claude に送る形式の説明(アプリに同梱)が、docs/tools-format.md と同じか"""
    source = os.path.join(ROOT, "docs", "tools-format.md")
    bundled = os.path.join(ROOT, "SmartDashboard", "Resources", "tools-format.md")
    same = os.path.exists(bundled) and open(source, "rb").read() == open(bundled, "rb").read()
    check(same, "SmartDashboard/Resources/tools-format.md が docs/tools-format.md と違います(docs のほうを写してください)")


def check_script_examples():
    """スクリプト型のサンプルを、元の JavaScript から作り直したものと比べる(python scripts/build_tool_examples.py で作る)"""
    sys.path.insert(0, os.path.join(ROOT, "scripts"))
    import build_tool_examples
    for name, meta in build_tool_examples.TOOLS.items():
        expected = build_tool_examples.build(name, meta)
        for path in (os.path.join(ROOT, "examples", "tools", name + ".json"),
                     os.path.join(ROOT, "SmartDashboardTests", "Fixtures", "tool_script_" + name.replace("-", "_") + ".json")):
            same = os.path.exists(path) and open(path, encoding="utf-8").read() == expected
            check(same, f"{os.path.relpath(path, ROOT)} が examples/tools/src/{name}.js と合いません(python scripts/build_tool_examples.py を実行)")
    bundle = build_tool_examples.BUNDLE
    same = os.path.exists(bundle) and open(bundle, encoding="utf-8").read() == build_tool_examples.bundle_text()
    check(same, "SmartDashboard/Resources/tool_samples.json が examples/tools と合いません(python scripts/build_tool_examples.py を実行)")
    # 組み込みのツールの JavaScript 版(v0.9.32)
    for name, meta in build_tool_examples.BUILTIN.items():
        path = os.path.join(ROOT, "examples", "tools", "builtin", name + ".json")
        same = os.path.exists(path) and open(path, encoding="utf-8").read() == build_tool_examples.build_builtin(name, meta)
        check(same, f"examples/tools/builtin/{name}.json が examples/tools/src/builtin/{name}.js と合いません(python scripts/build_tool_examples.py を実行)")
    bundle = build_tool_examples.BUILTIN_BUNDLE
    same = os.path.exists(bundle) and open(bundle, encoding="utf-8").read() == build_tool_examples.builtin_bundle_text()
    check(same, "SmartDashboard/Resources/builtin_script_tools.json が examples/tools/src/builtin と合いません(python scripts/build_tool_examples.py を実行)")


for step in (check_fixtures, check_committed_secrets, check_yaml, check_apps_json, check_swift_brackets, check_double_backslash,
             check_main_actor_statics, check_unterminated_strings, check_bundled_docs, check_script_examples):
    step()

if errors:
    print("NG")
    for e in errors:
        print(" -", e)
    sys.exit(1)
print("OK: 手元の確認はすべて通りました")
