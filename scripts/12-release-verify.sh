#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# 12-release-verify.sh —— 校验"线上资产"和仓库里记的哈希是否一致
#
#   bash scripts/12-release-verify.sh
#
# 依据 docs/release-manifest.json（11-release.sh 自动维护）；不需要 token，
# 公开仓库的 Release 资产自带 digest 字段（GitHub 服务端算的 sha256）。
# CI 每周跑一次 + 手动可跑（.github/workflows/release-verify.yml）。
#
# 失败条件：资产缺失、大小不符、digest 不符、manifest 里的哈希没出现在
#           docs/restore.md 里（防止文档和清单再次分叉）。
# ---------------------------------------------------------------------------
set -uo pipefail

HERE=$(cd "$(dirname "$0")/.." && pwd)
MAN="$HERE/docs/release-manifest.json"
REPO="${REPO:-Bronya-Hacker/xiaomi-cepheus-linux}"
[ -f "$MAN" ] || { echo "✗ 缺 $MAN"; exit 1; }

tmp=$(mktemp)
if ! curl -sS -m 60 -H 'Accept: application/vnd.github+json' \
	"https://api.github.com/repos/$REPO/releases?per_page=30" -o "$tmp"; then
	echo "✗ 拉取 Release 失败"
	rm -f "$tmp"
	exit 1
fi

python3 - "$MAN" "$tmp" "$HERE/docs/restore.md" <<'PY'
import json, sys

man_path, api_path, doc_path = sys.argv[1:4]
man = json.load(open(man_path, encoding="utf-8"))
releases = {r["tag_name"]: {a["name"]: a for a in r.get("assets", [])}
            for r in json.load(open(api_path, encoding="utf-8"))}
doc = open(doc_path, encoding="utf-8").read()

bad = 0
def fail(msg):
    global bad
    bad += 1
    print("  [FAIL] " + msg)

print("payload: %s   manifest 生成于 %s" % (man.get("payload"), man.get("generated")))
for rel in man.get("releases", []):
    tag = rel["tag"]
    if tag not in releases:
        fail("Release 不存在: " + tag)
        continue
    print("== " + tag)
    for want in rel["assets"]:
        got = releases[tag].get(want["name"])
        if not got:
            fail("缺少资产 %s" % want["name"])
            continue
        digest = (got.get("digest") or "").replace("sha256:", "")
        if got.get("size") != want.get("size"):
            fail("%s 大小 %s != %s" % (want["name"], got.get("size"), want.get("size")))
        elif digest != want["sha256"]:
            fail("%s digest %s != %s" % (want["name"], digest, want["sha256"]))
        else:
            print("  [ok]   %s  %d bytes  %s" % (want["name"], got["size"], digest[:16]))
        if want["sha256"] not in doc:
            fail("%s 的 sha256 不在 docs/restore.md 里（文档与清单分叉）" % want["name"])

for name, sha in (man.get("images") or {}).items():
    if sha not in doc:
        fail("images.%s 的 sha256 不在 docs/restore.md 里" % name)

print()
if bad:
    print("✗ %d 项不一致" % bad)
    sys.exit(1)
print("✓ 线上资产、manifest、docs/restore.md 三者一致")
PY
rc=$?
rm -f "$tmp"
exit $rc
