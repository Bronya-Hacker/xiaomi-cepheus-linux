#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# 11-release.sh —— 一条命令出线刷包并发布
#
#   GH_TOKEN=... bash scripts/11-release.sh              # 出包 + 上传 + 回写文档
#   GH_TOKEN=... bash scripts/11-release.sh --no-upload  # 只出包，不动 GitHub
#   GH_TOKEN=... bash scripts/11-release.sh --rootfs /path/rootfs.img.tar.zst
#
# 顺序（任何一步失败就停，不带着半成品往下走）：
#   0) 读 payload 版本号 → 推导两个 tag
#   1) 检查 out/ 里的 boot-cepheus.img / kernelfat.img 存在
#   2) 用 flash-templates/ 组包（小包 + 整机包），写 MANIFEST
#   3) 打 zip、算 sha256、验 zip 完整性
#   4) 删旧 zip 资产 → 传新的 → **用 API 返回的 digest 反证**
#   5) 用 docs/release-notes/*.md.in 渲染说明并 PATCH 到两个 Release
#   6) 回写 docs/restore.md 的 RELEASE-TABLE 区块 + docs/release-manifest.json
#
# 为什么第 4 步要"反证"：2026-10-20 踩过 uploads.github.com 被指错 IP、
# 返回 301 而 body 为空的事故 —— curl -X POST 不跟 301，本地看着"成功"，
# 线上其实什么都没有。只有服务端算出来的 digest 才算证据。
#
# 需要的环境变量：
#   GH_TOKEN    有 repo 权限的 token（只在 --no-upload 时可省略）
#   REPO        默认 Bronya-Hacker/xiaomi-cepheus-linux
# ---------------------------------------------------------------------------
set -uo pipefail

HERE=$(cd "$(dirname "$0")/.." && pwd)
OUT="$HERE/out"
TPL="$HERE/flash-templates"
NOTES="$HERE/docs/release-notes"
FLASH="$HERE/flash"
REPO="${REPO:-Bronya-Hacker/xiaomi-cepheus-linux}"
API="https://api.github.com/repos/$REPO"
TOKEN="${GH_TOKEN:-${GITHUB_TOKEN:-}}"
UPLOAD=1
ROOTFS=""

while [ $# -gt 0 ]; do
	case "$1" in
	--no-upload) UPLOAD=0 ;;
	--rootfs) ROOTFS="$2"; shift ;;
	-h | --help) sed -n '2,26p' "$0"; exit 0 ;;
	*) echo "未知参数: $1" >&2; exit 1 ;;
	esac
	shift
done

die() { echo "✗ $*" >&2; exit 1; }
step() { echo; echo "===== $* ====="; }
py() { python3 -c "$@"; }

[ -d "$OUT" ] || die "没有 $OUT —— 先跑 scripts/07-rebuild-all-wsl.sh"
[ -f "$OUT/boot-cepheus.img" ] || die "缺 out/boot-cepheus.img"
[ -f "$OUT/kernelfat.img" ] || die "缺 out/kernelfat.img"
[ "$UPLOAD" = 1 ] && [ -z "$TOKEN" ] && die "需要 GH_TOKEN（或用 --no-upload）"

VER=$(head -1 "$HERE/payload/etc/wifi-cfg.ver")
[ -n "$VER" ] || die "payload/etc/wifi-cfg.ver 是空的"

# 2026-10-19-wifi-3c3445-r3.5  ->  flash-2026-10-19-wifi-3c3445-r3 / full-2026-10-19-r3
DATE=${VER%%-wifi-*}
REST=${VER#*-wifi-}
SSIDHASH=${REST%%-*}
RSUF=${REST##*-}
REL=${RSUF%%.*}
TAG_FLASH="flash-$DATE-wifi-$SSIDHASH-$REL"
TAG_FULL="full-$DATE-$REL"

BUILT=$(date -u '+%Y-%m-%d %H:%M:%S UTC')
# 资产名按 **Release tag** 命名（…-r3.zip），不带 payload 的 .5 小版本 ——
# 这样同一个 Release 反复替换资产时，下载链接和文档都稳定。
SMALL_DIR="$FLASH/cepheus-$DATE-wifi-$SSIDHASH-$REL"
FULL_DIR="$FLASH/cepheus-full-$DATE-$REL"
SMALL_ZIP="cepheus-$DATE-wifi-$SSIDHASH-$REL.zip"
FULL_ZIP="cepheus-full-$DATE-$REL.zip"

echo "payload : $VER"
echo "tags    : $TAG_FLASH / $TAG_FULL"

# rootfs 不重新上传（1 GB，且几乎不变），哈希优先取 --rootfs，其次取上次的清单
ROOTFS_SHA=""
if [ -n "$ROOTFS" ]; then
	[ -f "$ROOTFS" ] || die "rootfs 不存在: $ROOTFS"
	ROOTFS_SHA=$(sha256sum "$ROOTFS" | cut -d' ' -f1)
	ROOTFS_SIZE=$(stat -c%s "$ROOTFS")
elif [ -f "$HERE/docs/release-manifest.json" ]; then
	ROOTFS_SHA=$(py 'import json,sys; d=json.load(open(sys.argv[1])); print(d.get("rootfs",{}).get("sha256",""))' "$HERE/docs/release-manifest.json" 2>/dev/null)
	ROOTFS_SIZE=$(py 'import json,sys; d=json.load(open(sys.argv[1])); print(d.get("rootfs",{}).get("size",0))' "$HERE/docs/release-manifest.json" 2>/dev/null)
fi
[ -n "$ROOTFS_SHA" ] || die "不知道 rootfs 的 sha256 —— 用 --rootfs 指一个文件，或先提交一份 release-manifest.json"

# ---------------------------------------------------------------- 2) 组包
step "1/6 组包"
build_dir() { # <kind> <dir>
	local kind=$1 dir=$2
	rm -rf "$dir"
	mkdir -p "$dir"
	cp -f "$OUT/boot-cepheus.img" "$dir/boot.img"
	cp -f "$OUT/kernelfat.img" "$dir/recovery.img"
	cp -f "$TPL/verify-images.ps1" "$dir/verify-images.ps1"
	if [ "$kind" = full ]; then
		cp -f "$TPL/flash-all-full.bat" "$dir/flash-all.bat"
		sed -e "s|@VERSION@|$VER|g" -e "s|@BUILT@|$BUILT|g" "$TPL/README-full.txt" >"$dir/README.txt"
	else
		cp -f "$TPL/flash-all-small.bat" "$dir/flash-all.bat"
		sed -e "s|@VERSION@|$VER|g" -e "s|@BUILT@|$BUILT|g" "$TPL/README-small.txt" >"$dir/README.txt"
	fi
	# MANIFEST：verify-images.ps1 只认 "<64hex>  <name>" 行
	{
		if [ "$kind" = full ]; then
			echo "# Mi9 (cepheus) full system package"
		else
			echo "# Mi9 (cepheus) fastboot package"
		fi
		echo "version : $VER"
		echo "built   : $BUILT"
		echo
		echo "# sha256 (sha256sum -c compatible):"
		echo "$(sha256sum "$dir/boot.img" | cut -d' ' -f1)  boot.img"
		echo "$(sha256sum "$dir/recovery.img" | cut -d' ' -f1)  recovery.img"
		if [ "$kind" = full ]; then
			echo "$ROOTFS_SHA  rootfs.img.tar.zst"
			echo
			echo "# sizes:"
			echo "#   boot.img            $(stat -c%s "$dir/boot.img")"
			echo "#   recovery.img        $(stat -c%s "$dir/recovery.img")"
			echo "#   rootfs.img.tar.zst  $ROOTFS_SIZE  (ext4 rootfs 4294967296 bytes)"
		fi
	} >"$dir/MANIFEST.txt"
	echo "  $kind -> $dir"
}

build_dir small "$SMALL_DIR"
build_dir full "$FULL_DIR"

BOOT_SHA=$(sha256sum "$SMALL_DIR/boot.img" | cut -d' ' -f1)
REC_SHA=$(sha256sum "$SMALL_DIR/recovery.img" | cut -d' ' -f1)

# ---------------------------------------------------------------- 3) 打包
step "2/6 打 zip"
mzip() { # <dir> <zip>
	python3 - "$1" "$2" <<'PY'
import os, sys, zipfile
d, out = sys.argv[1], sys.argv[2]
names = ["boot.img", "recovery.img", "flash-all.bat", "README.txt", "MANIFEST.txt", "verify-images.ps1"]
if os.path.exists(out):
    os.unlink(out)
with zipfile.ZipFile(out, "w", zipfile.ZIP_DEFLATED) as z:
    for n in names:
        z.write(os.path.join(d, n), n)
print("  %s  %d bytes" % (out, os.path.getsize(out)))
PY
}
mzip "$SMALL_DIR" "$SMALL_DIR/$SMALL_ZIP"
mzip "$FULL_DIR" "$FULL_DIR/$FULL_ZIP"

for z in "$SMALL_DIR/$SMALL_ZIP" "$FULL_DIR/$FULL_ZIP"; do
	python3 -c "import sys,zipfile; z=zipfile.ZipFile(sys.argv[1]); bad=z.testzip(); sys.exit(1 if bad else 0)" "$z" ||
		die "zip 完整性检查失败: $z"
done

SMALL_SHA=$(sha256sum "$SMALL_DIR/$SMALL_ZIP" | cut -d' ' -f1)
FULL_SHA=$(sha256sum "$FULL_DIR/$FULL_ZIP" | cut -d' ' -f1)
SMALL_SIZE=$(stat -c%s "$SMALL_DIR/$SMALL_ZIP")
FULL_SIZE=$(stat -c%s "$FULL_DIR/$FULL_ZIP")
echo "  small  $SMALL_SHA  $SMALL_SIZE"
echo "  full   $FULL_SHA  $FULL_SIZE"
echo "  boot   $BOOT_SHA"
echo "  recov  $REC_SHA"
echo "  rootfs $ROOTFS_SHA"

[ "$UPLOAD" = 1 ] || {
	echo
	echo "（--no-upload：到此为止，包在 $SMALL_DIR / $FULL_DIR）"
	exit 0
}

# ---------------------------------------------------------------- 4) 上传
step "3/6 上传（删旧 → 传新 → 服务端 digest 反证）"

api_get() { curl -sS -m 60 -H "Authorization: Bearer $TOKEN" -H "Accept: application/vnd.github+json" "$@"; }

release_id() { # <tag> -> id（不存在就建）
	local tag=$1 id
	id=$(api_get "$API/releases/tags/$tag" | py 'import json,sys
try: print(json.load(sys.stdin)["id"])
except Exception: print("")')
	if [ -z "$id" ]; then
		id=$(api_get -X POST -d "{\"tag_name\":\"$tag\",\"name\":\"$tag\",\"draft\":false,\"prerelease\":false}" \
			"$API/releases" | py 'import json,sys; print(json.load(sys.stdin)["id"])')
		echo "  新建 release $tag (id $id)" >&2
	fi
	echo "$id"
}

delete_zip_assets() { # <release-id>
	local rid=$1 ids
	ids=$(api_get "$API/releases/$rid" | py 'import json,sys
for a in json.load(sys.stdin).get("assets", []):
    if a["name"].endswith(".zip"): print(a["id"])')
	for a in $ids; do
		code=$(curl -sS -m 60 -o /dev/null -w '%{http_code}' -X DELETE \
			-H "Authorization: Bearer $TOKEN" -H "Accept: application/vnd.github+json" \
			"$API/releases/assets/$a")
		echo "  删旧资产 $a -> $code"
	done
}

upload_asset() { # <release-id> <file> -> 校验服务端 digest
	local rid=$1 f=$2 name sha got code hdrs
	name=$(basename "$f")
	sha=$(sha256sum "$f" | cut -d' ' -f1)
	hdrs=$(mktemp)
	code=$(curl -sS -m 3600 -X POST \
		-H "Authorization: Bearer $TOKEN" -H "Content-Type: application/zip" \
		--data-binary @"$f" -o /tmp/rel-up.json -D "$hdrs" -w '%{http_code}' \
		"https://uploads.github.com/repos/$REPO/releases/$rid/assets?name=$name")
	if [ "$code" != 201 ]; then
		grep -i '^location:' "$hdrs" | sed 's/^/  /' >&2
		rm -f "$hdrs"
		die "上传 $name 失败 HTTP $code（301 说明 uploads.github.com 指到了主站，检查 /etc/hosts）"
	fi
	rm -f "$hdrs"
	got=$(py 'import json; d=json.load(open("/tmp/rel-up.json")); print((d.get("digest") or "").replace("sha256:",""), d.get("size"))')
	echo "  $name -> $got"
	case "$got" in
	"$sha "*) ;;
	*) die "服务端 digest/大小与本地不一致：本地 $sha / $name，服务端 $got" ;;
	esac
}

RID_FLASH=$(release_id "$TAG_FLASH")
RID_FULL=$(release_id "$TAG_FULL")
delete_zip_assets "$RID_FLASH"
delete_zip_assets "$RID_FULL"
upload_asset "$RID_FLASH" "$SMALL_DIR/$SMALL_ZIP"
upload_asset "$RID_FULL" "$FULL_DIR/$FULL_ZIP"

# ---------------------------------------------------------------- 5) 说明
step "4/6 渲染并更新 Release 说明"
render() { # <template> <out>
	sed -e "s|@VERSION@|$VER|g" \
		-e "s|@DATE@|$DATE|g" \
		-e "s|@BOOT_SHA@|$BOOT_SHA|g" \
		-e "s|@RECOVERY_SHA@|$REC_SHA|g" \
		-e "s|@ROOTFS_SHA@|$ROOTFS_SHA|g" \
		"$1" >"$2"
}

render "$NOTES/flash.md.in" /tmp/body-flash.md
ZIP_FILENAME=$SMALL_ZIP
sed -i "s|@ZIP_SHA@|$SMALL_SHA|g; s|@ZIP_SIZE@|$SMALL_SIZE|g; s|@ZIP_FILENAME@|$ZIP_FILENAME|g" /tmp/body-flash.md
render "$NOTES/full.md.in" /tmp/body-full.md
ZIP_FILENAME=$FULL_ZIP
sed -i "s|@ZIP_SHA@|$FULL_SHA|g; s|@ZIP_SIZE@|$FULL_SIZE|g; s|@ZIP_FILENAME@|$ZIP_FILENAME|g" /tmp/body-full.md

patch_body() { # <release-id> <body-file>
	python3 - "$TOKEN" "$API" "$1" "$2" <<'PY'
import json, sys, urllib.request
tok, api, rid, bf = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
body = open(bf, encoding="utf-8").read()
req = urllib.request.Request("%s/releases/%s" % (api, rid), method="PATCH",
    data=json.dumps({"body": body}).encode(),
    headers={"Authorization": "Bearer " + tok, "Content-Type": "application/json",
             "Accept": "application/vnd.github+json"})
with urllib.request.urlopen(req, timeout=60) as r:
    print("  patched", json.load(r)["tag_name"])
PY
}
patch_body "$RID_FLASH" /tmp/body-flash.md
patch_body "$RID_FULL" /tmp/body-full.md

# ---------------------------------------------------------------- 6) 文档
step "5/6 回写 docs/restore.md + release-manifest.json"
python3 - "$HERE/docs/restore.md" "$VER" "$TAG_FULL" "$FULL_ZIP" "$FULL_SIZE" "$FULL_SHA" \
	"$TAG_FLASH" "$SMALL_ZIP" "$SMALL_SIZE" "$SMALL_SHA" \
	"$ROOTFS_SHA" "$REC_SHA" "$BOOT_SHA" <<'PY'
import sys
(path, ver, tfull, fzip, fsize, fsha, tflash, szip, ssize, ssha, rsha, recsha, bootsha) = sys.argv[1:]
table = """<!-- BEGIN RELEASE-TABLE -->
| 文件 | 内容 | 大小 | sha256 |
|---|---|---|---|
| `{fzip}` | `boot.img` + `recovery.img` + `flash-all.bat` + `README` | {fsz} | `{fsha}` |
| `{szip}` | 小包（同 boot + recovery） | {ssz} | `{ssha}` |
| `rootfs.img.tar.zst` | ext4 rootfs，4 GB（tar+zstd） | 1.01 GiB | `{rsha}` |
| ↳ `recovery.img` | payload `{ver}`（不注入公钥、升级不覆盖本机配置） | 64 MiB | `{recsha}` |
| ↳ `boot.img` | UEFI + DTB | 6.5 MiB | `{bootsha}` |

Release：`{tfull}` / `{tflash}`
<!-- END RELEASE-TABLE -->""".format(
    fzip=fzip, fsz="%.1f MB" % (int(fsize) / 1e6), fsha=fsha,
    szip=szip, ssz="%.1f MB" % (int(ssize) / 1e6), ssha=ssha,
    rsha=rsha, ver=ver, recsha=recsha, bootsha=bootsha,
    tfull=tfull, tflash=tflash)

src = open(path, encoding="utf-8").read()
b = "<!-- BEGIN RELEASE-TABLE -->"
e = "<!-- END RELEASE-TABLE -->"
if b in src and e in src:
    head = src[: src.index(b)]
    tail = src[src.index(e) + len(e):]
    open(path, "w", encoding="utf-8").write(head + table + tail)
    print("  restore.md 表格已更新")
else:
    print("  ! restore.md 里没有 RELEASE-TABLE 标记，跳过（先加标记）")
PY

python3 - "$HERE/docs/release-manifest.json" "$VER" "$TAG_FLASH" "$SMALL_ZIP" "$SMALL_SIZE" "$SMALL_SHA" \
	"$TAG_FULL" "$FULL_ZIP" "$FULL_SIZE" "$FULL_SHA" "$ROOTFS_SHA" "$ROOTFS_SIZE" "$BOOT_SHA" "$REC_SHA" <<'PY'
import json, sys, datetime
(path, ver, tflash, szip, ssize, ssha, tfull, fzip, fsize, fsha, rsha, rsize, bootsha, recsha) = sys.argv[1:]
data = {
    "payload": ver,
    "generated": datetime.datetime.utcnow().strftime("%Y-%m-%dT%H:%M:%SZ"),
    "releases": [
        {"tag": tflash, "assets": [{"name": szip, "size": int(ssize), "sha256": ssha}]},
        {"tag": tfull, "assets": [
            {"name": fzip, "size": int(fsize), "sha256": fsha},
            {"name": "rootfs.img.tar.zst", "size": int(rsize or 0), "sha256": rsha},
        ]},
    ],
    "images": {"boot.img": bootsha, "recovery.img": recsha},
}
json.dump(data, open(path, "w", encoding="utf-8"), indent=2, ensure_ascii=False)
print("  release-manifest.json 已写")
PY

step "6/6 完成"
echo "小包   : $SMALL_DIR/$SMALL_ZIP"
echo "整机包 : $FULL_DIR/$FULL_ZIP"
echo "记得提交：docs/restore.md  docs/release-manifest.json"
echo "自检   : bash scripts/12-release-verify.sh   （CI 也在跑同一件事）"
