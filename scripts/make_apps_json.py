#!/usr/bin/env python3
"""AltStoreのソースJSON(apps.json)を生成・更新する。

使い方: make_apps_json.py <apps.json> <version> <ipaのパス> <owner/repo>
既存のapps.jsonがあれば過去のバージョン履歴を引き継ぐ。
"""
import json
import os
import sys
from datetime import datetime, timezone

BUNDLE_ID = "com.nsan.smartdashboard"
APP_NAME = "スマートダッシュボード"
IPA_NAME = "SmartDashboard.ipa"
MIN_OS = "17.0"


def main() -> None:
    path, version, ipa, repo = sys.argv[1:5]
    size = os.path.getsize(ipa)
    date = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    url = f"https://github.com/{repo}/releases/download/v{version}/{IPA_NAME}"
    description = "天気、為替、電車、センサー、タイマーをまとめた個人用ダッシュボード。通信量を最小にする設計。"

    versions = []
    if os.path.exists(path):
        try:
            with open(path, encoding="utf-8") as f:
                old = json.load(f)
            versions = old["apps"][0].get("versions", [])
        except (ValueError, KeyError, IndexError):
            versions = []
    versions = [v for v in versions if v.get("version") != version]
    versions.insert(0, {
        "version": version,
        "date": date,
        "localizedDescription": f"v{version}",
        "downloadURL": url,
        "size": size,
        "minOSVersion": MIN_OS,
    })

    owner = repo.split("/")[0]
    source = {
        "name": f"{APP_NAME} (Nsan736)",
        "identifier": f"{BUNDLE_ID}.source",
        "sourceURL": f"https://raw.githubusercontent.com/{repo}/main/apps.json",
        "apps": [{
            "name": APP_NAME,
            "bundleIdentifier": BUNDLE_ID,
            "developerName": owner,
            "subtitle": "手元ダッシュボード",
            "localizedDescription": description,
            "iconURL": f"https://raw.githubusercontent.com/{repo}/main/icon.png",
            "tintColor": "2F7DE1",
            "screenshotURLs": [],
            "versions": versions,
            "version": version,
            "versionDate": date,
            "versionDescription": f"v{version}",
            "downloadURL": url,
            "size": size,
            "minOSVersion": MIN_OS,
        }],
        "news": [],
    }
    with open(path, "w", encoding="utf-8") as f:
        json.dump(source, f, ensure_ascii=False, indent=2)
        f.write("\n")


if __name__ == "__main__":
    main()
