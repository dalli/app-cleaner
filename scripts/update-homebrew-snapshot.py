#!/usr/bin/env python3
"""Homebrew Cask zap 스냅샷 갱신 (plan.md 4.2 #2, 4.6).

https://formulae.brew.sh/api/cask.json 을 내려받아 **데이터로만** 해석하고(코드 실행 없음),
CleanerCore가 쓰는 축약 JSON(`[HomebrewCask]`)으로 저장한다.

    python3 -I scripts/update-homebrew-snapshot.py
    python3 -I scripts/update-homebrew-snapshot.py --input /path/to/cask.json   # 이미 받은 파일 사용

출력 스키마 (Sources/CleanerCore/Contracts/RuleData.swift `HomebrewCask`):
    {"token": str, "names": [str], "apps": [str], "bundleIDs": [str], "zap": [str]}

- bundleIDs: uninstall/zap 의 launchctl·quit·signal·pkgutil·login_item 값 중 BID 형태인 것
- zap: zap 의 trash·delete·rmdir 경로 (`~/` 또는 `/` 로 시작하는 것만)
- zap 경로나 BID가 하나도 없는 cask는 제외

데이터 라이선스: Homebrew Cask (BSD-2-Clause) — Resources/RuleData/NOTICE-homebrew-cask.txt 참조.
표준 라이브러리만 사용한다.
"""

import argparse
import json
import os
import re
import sys
import tempfile
import urllib.request

API_URL = "https://formulae.brew.sh/api/cask.json"
MAX_BYTES = 256 * 1024 * 1024
BID_RE = re.compile(r"^[A-Za-z0-9_-]+(\.[A-Za-z0-9_-]+)+$")
DEFAULT_OUTPUT = os.path.join(
    os.path.dirname(os.path.abspath(__file__)), "..", "Sources", "CleanerCore", "Resources", "RuleData", "homebrew-casks.json"
)


def download(url, directory):
    """HTTPS로 내려받아 directory 안에 저장한다 (기본 인증서 검증 사용)."""
    path = os.path.join(directory, "cask.json")
    req = urllib.request.Request(url, headers={"User-Agent": "app-cleaner-snapshot/1.0"})
    with urllib.request.urlopen(req, timeout=120) as resp, open(path, "wb") as out:
        total = 0
        while True:
            chunk = resp.read(1 << 20)
            if not chunk:
                break
            total += len(chunk)
            if total > MAX_BYTES:
                raise RuntimeError("응답이 너무 큽니다")
            out.write(chunk)
    return path


def flatten(value):
    """문자열·리스트·중첩 리스트에서 문자열만 꺼낸다."""
    if isinstance(value, str):
        yield value
    elif isinstance(value, list):
        for v in value:
            yield from flatten(v)


def stanza_entries(artifacts, key):
    """artifacts 안의 {key: [...]} 항목들 (각 항목은 dict 목록)"""
    for art in artifacts or []:
        if isinstance(art, dict) and key in art:
            for entry in art[key] if isinstance(art[key], list) else [art[key]]:
                if isinstance(entry, dict):
                    yield entry


def bundle_ids(artifacts):
    found = []
    for key in ("uninstall", "zap"):
        for entry in stanza_entries(artifacts, key):
            for field in ("launchctl", "quit", "pkgutil", "login_item"):
                for s in flatten(entry.get(field)):
                    found.append(s)
            # signal: [["TERM", "com.foo.bar"], ...]
            for s in flatten(entry.get("signal")):
                found.append(s)
    out = []
    for s in found:
        s = s.strip()
        if BID_RE.match(s) and not s.isupper() and s not in out:
            out.append(s)
    return out


def zap_paths(artifacts):
    out = []
    for entry in stanza_entries(artifacts, "zap"):
        for field in ("trash", "delete", "rmdir"):
            for s in flatten(entry.get(field)):
                s = s.strip()
                if (s.startswith("~/") or s.startswith("/")) and ".." not in s.split("/") and s not in out:
                    out.append(s)
    return out


def app_names(artifacts):
    out = []
    for art in artifacts or []:
        if not isinstance(art, dict) or "app" not in art:
            continue
        for item in art["app"] if isinstance(art["app"], list) else [art["app"]]:
            names = []
            if isinstance(item, str):
                names.append(os.path.basename(item))
            elif isinstance(item, dict) and isinstance(item.get("target"), str):
                names.append(os.path.basename(item["target"]))
            for n in names:
                if n.endswith(".app") and n not in out:
                    out.append(n)
    return out


def convert(casks):
    result = []
    for c in casks:
        if not isinstance(c, dict) or not isinstance(c.get("token"), str):
            continue
        artifacts = c.get("artifacts") or []
        entry = {
            "token": c["token"],
            "names": [n for n in flatten(c.get("name")) if n],
            "apps": app_names(artifacts),
            "bundleIDs": bundle_ids(artifacts),
            "zap": zap_paths(artifacts),
        }
        if entry["zap"] or entry["bundleIDs"]:
            result.append(entry)
    result.sort(key=lambda e: e["token"])
    return result


def write(entries, path):
    lines = [json.dumps(e, ensure_ascii=False, separators=(",", ":")) for e in entries]
    tmp = path + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        f.write("[\n" + ",\n".join(lines) + "\n]\n")
    os.replace(tmp, path)


def main():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--input", help="이미 내려받은 cask.json 경로")
    ap.add_argument("--download-dir", help="내려받을 임시 폴더 (기본: 새 임시 폴더)")
    ap.add_argument("--output", default=os.path.normpath(DEFAULT_OUTPUT))
    args = ap.parse_args()

    source = args.input
    if not source:
        directory = args.download_dir or tempfile.mkdtemp(prefix="homebrew-cask-")
        os.makedirs(directory, exist_ok=True)
        source = download(API_URL, directory)
        print(f"downloaded: {source}", file=sys.stderr)

    with open(source, "r", encoding="utf-8") as f:
        data = json.load(f)
    if not isinstance(data, list):
        sys.exit("unexpected cask.json format (expected a list)")
    entries = convert(data)
    if len(entries) < 100:
        sys.exit(f"too few casks ({len(entries)}); keeping the existing snapshot")
    write(entries, args.output)
    print(f"wrote {len(entries)} casks to {args.output} ({os.path.getsize(args.output)} bytes)", file=sys.stderr)


if __name__ == "__main__":
    main()
