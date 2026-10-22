#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
在 macOS / Linux 上把 arch=all 的纯脚本 LuCI 包打成 OpenWrt .ipk（opkg）。

适用：包目录里有 Makefile + root/ + htdocs/，没有任何需要交叉编译的源码。

安装路径规则（对齐 feeds/luci/luci.mk 的 Package/install）：
    root/*    -> /
    htdocs/*  -> /www/
    luasrc/*  -> /usr/lib/lua/luci/     （本包未使用）

用法：
    python3 tools/build_ipk.py            # 产出 dist/luci-app-neokuainiao_<ver>-<rel>_all.ipk
    python3 tools/build_ipk.py --out /tmp/out
"""

import argparse
import gzip
import io
import os
import re
import shutil
import stat
import subprocess
import sys
import tarfile
import time

HERE = os.path.dirname(os.path.abspath(__file__))
PKG_DIR = os.path.dirname(HERE)
PKG_NAME = "luci-app-neokuainiao"
DEFAULT_SRC = PKG_DIR

EXEC_PATTERNS = [
    r"^etc/init\.d/",
    r"^etc/uci-defaults/",
    r"^usr/libexec/.*\.sh$",
    r"^usr/sbin/",
    r"^usr/bin/",
]

CONFFILES = ["/etc/config/neokuainiao"]

CONTROL_TEMPLATE = """Package: {pkg}
Version: {ver}-{rel}
Depends: {deps}
Source: package/{pkg}
SourceName: {pkg}
License: MIT
Section: luci
SourceDateEpoch: {epoch}
URL: {url}
Maintainer: {maintainer}
Architecture: all
Installed-Size: {size}
Description: {title}
 {desc}
"""

POSTINST_TMPL = """#!/bin/sh
[ -n "$IPKG_INSTROOT" ] || {
	rm -f  /tmp/luci-indexcache*
	rm -rf /tmp/luci-modulecache
	/etc/init.d/neokuainiao enable 2>/dev/null
	/etc/init.d/neokuainiao restart 2>/dev/null
	killall -HUP rpcd 2>/dev/null
}
exit 0
"""

PRERM_TMPL = """#!/bin/sh
[ -n "$IPKG_INSTROOT" ] || {
	/etc/init.d/neokuainiao stop 2>/dev/null
	/etc/init.d/neokuainiao disable 2>/dev/null
}
exit 0
"""


def read_makefile_var(text, name, default=""):
    m = re.search(r"^%s\s*:?=\s*(.+)$" % re.escape(name), text, re.M)
    if not m:
        return default
    return m.group(1).strip()


def norm_exec(relpath):
    for pat in EXEC_PATTERNS:
        if re.search(pat, relpath):
            return 0o755
    return 0o644


def stage_tree(src, stage):
    """把包内容铺进 stage 目录，返回 [(安装内相对路径, mode)]"""
    entries = []

    def walk(src_root, dst_root, prefix):
        for root, dirs, files in os.walk(src_root):
            dirs.sort()
            for f in sorted(files):
                s = os.path.join(root, f)
                rel = os.path.relpath(s, src_root).replace(os.sep, "/")
                d = os.path.join(dst_root, rel)
                os.makedirs(os.path.dirname(d), exist_ok=True)
                shutil.copyfile(s, d)
                mode = norm_exec(rel)
                os.chmod(d, mode)
                entries.append((prefix + rel, mode))

    rootdir = os.path.join(src, "root")
    if os.path.isdir(rootdir):
        walk(rootdir, stage, "")
    htdocs = os.path.join(src, "htdocs")
    if os.path.isdir(htdocs):
        walk(htdocs, os.path.join(stage, "www"), "www/")

    return entries


def build_epoch():
    """打包用的时间戳。

    默认取**构建时的当前时间**，不能固定死：LuCI 给 luci-static 资源 URL 生成
    `?v=<mtime>` 版本参数，mtime 不变浏览器就永远用缓存——曾因固定成 2023-11-15
    导致升级插件后页面仍是旧 JS（改了 overview.js 用户看不到）。
    需要可复现构建时设 SOURCE_DATE_EPOCH 即可固定。
    """
    v = os.environ.get("SOURCE_DATE_EPOCH", "")
    try:
        return int(v) if v else int(time.time())
    except ValueError:
        return int(time.time())


def make_tar_gz(path, entries, stage, prefix=""):
    """构造 tar.gz：目录在前、文件按名排序，uid/gid=0，mtime 取 build_epoch()"""
    epoch = build_epoch()
    with open(path, "wb") as raw:
        gz = gzip.GzipFile(fileobj=raw, mode="wb", mtime=0)
        tf = tarfile.open(fileobj=gz, mode="w", format=tarfile.GNU_FORMAT)

        def add_dir(rel):
            ti = tarfile.TarInfo("./" + rel if rel else "./")
            ti.type = tarfile.DIRTYPE
            ti.mode = 0o755
            ti.uid = ti.gid = 0
            ti.uname = ti.gname = "root"
            ti.mtime = epoch
            tf.addfile(ti)

        add_dir("")
        dirs = set()
        for rel, _ in entries:
            parts = rel.split("/")[:-1]
            for i in range(1, len(parts) + 1):
                dirs.add("/".join(parts[:i]))
        for d in sorted(dirs):
            add_dir(d)

        for rel, mode in sorted(entries):
            p = os.path.join(stage, rel)
            data = open(p, "rb").read()
            ti = tarfile.TarInfo("./" + rel)
            ti.size = len(data)
            ti.mode = mode
            ti.uid = ti.gid = 0
            ti.uname = ti.gname = "root"
            ti.mtime = epoch
            tf.addfile(ti, io.BytesIO(data))
        tf.close()
        gz.close()


def make_control_tar(path, files, epoch):
    with open(path, "wb") as raw:
        gz = gzip.GzipFile(fileobj=raw, mode="wb", mtime=0)
        tf = tarfile.open(fileobj=gz, mode="w", format=tarfile.GNU_FORMAT)
        for name, (data, mode) in files.items():
            b = data.encode() if isinstance(data, str) else data
            ti = tarfile.TarInfo("./" + name)
            ti.size = len(b)
            ti.mode = mode
            ti.uid = ti.gid = 0
            ti.uname = ti.gname = "root"
            ti.mtime = epoch
            tf.addfile(ti, io.BytesIO(b))
        tf.close()
        gz.close()


def ipk_write(out, members, epoch=None):
    """写 OpenWrt/QWRT 的 .ipk。

    坑（2026-10-22 实测踩到）：OpenWrt 的 ipk **不是** Debian 的 ar 容器
    （`!<arch>` + 三个成员），而是**一个 gzip 压缩的 tar**，tar 里再放三个文件：

        ./debian-binary    内容就是 "2.0\\n"
        ./data.tar.gz
        ./control.tar.gz

    注意顺序是 data 在 control **之前**，和 .deb 的 ar 顺序相反。
    按 deb 的 ar 格式打，opkg 会报
    `pkg_init_from_file: Malformed package file`。
    参照物：OpenWrt SDK 产出的 luci-app-homeproxy ipk（`file` 显示 gzip compressed data）。

    另：mtime 不能固定死，否则 LuCI 的 `?v=<mtime>` 资源版本号不变，
    浏览器会一直用缓存里的旧 JS（改 overview.js 用户看不到）。
    """
    if epoch is None:
        epoch = build_epoch()
    with open(out, "wb") as raw:
        gz = gzip.GzipFile(fileobj=raw, mode="wb", mtime=epoch)
        tf = tarfile.open(fileobj=gz, mode="w", format=tarfile.GNU_FORMAT)
        for name, path in members:
            data = open(path, "rb").read()
            ti = tarfile.TarInfo("./" + name)
            ti.size = len(data)
            ti.mode = 0o644
            ti.uid = ti.gid = 0
            ti.uname = ti.gname = "root"
            ti.mtime = epoch
            tf.addfile(ti, io.BytesIO(data))
        tf.close()
        gz.close()


def ipk_verify(path, expect_names):
    """打包后自检：重新解析外层 gzip tar，确认成员名/顺序/大小"""
    if path.endswith(".ipk") and not path.startswith("./"):
        blob_head = open(path, "rb").read(2)
        if blob_head != b"\x1f\x8b":
            raise SystemExit("[verify] ipk 不是 gzip 开头（应是 1f 8b），实际 %r" % blob_head)
    with tarfile.open(path, "r:gz") as tf:
        got = []
        for ti in tf.getmembers():
            got.append((ti.name, ti.size))
            if ti.size <= 0:
                raise SystemExit("[verify] 成员 %s 大小为 0" % ti.name)
    names = [n for n, _ in got]
    if names != list(expect_names):
        raise SystemExit("[verify] 成员顺序/名字不匹配: %r != %r" % (names, list(expect_names)))
    print("[verify] ipk(gzip tar) 结构 OK: " + ", ".join("%s(%dB)" % (n, s) for n, s in got))
    # 额外确认 debian-binary 内容
    with tarfile.open(path, "r:gz") as tf:
        db = tf.extractfile("./debian-binary").read()
    if db != b"2.0\n":
        raise SystemExit("[verify] debian-binary 内容应为 '2.0\\n'，实际 %r" % db)
    # mtime 不能是固定的老值：LuCI 用 mtime 生成 luci-static 的 ?v= 版本参数，
    # mtime 不变化浏览器会一直用缓存里的旧 JS（曾导致改 overview.js 用户看不到）。
    now = int(time.time())
    with tarfile.open(path, "r:gz") as tf:
        for ti in tf.getmembers():
            if ti.name.startswith("./www/") and ti.mtime < now - 30 * 86400:
                raise SystemExit(
                    "[verify] %s 的 mtime=%d 太旧（超过 30 天），浏览器会一直用缓存；"
                    "请勿固定 SOURCE_DATE_EPOCH" % (ti.name, ti.mtime))
    # 额外确认 maintainer script 的 shell 语法（曾因 {{ }} 未还原导致 postinst bad substitution）
    with tarfile.open(path, "r:gz") as tf:
        ctrl = tf.extractfile("./control.tar.gz").read()
    import subprocess
    import tempfile
    with tarfile.open(fileobj=io.BytesIO(ctrl), mode="r:gz") as tf:
        for script in ("postinst", "prerm"):
            try:
                body = tf.extractfile("./" + script).read()
            except KeyError:
                continue
            with tempfile.NamedTemporaryFile("wb", suffix=".sh", delete=False) as sf:
                sf.write(body)
                sp = sf.name
            try:
                r = subprocess.run(["sh", "-n", sp], capture_output=True)
                if r.returncode != 0:
                    raise SystemExit("[verify] %s 语法错误: %s"
                                     % (script, r.stderr.decode("utf-8", "replace").strip()))
            finally:
                os.unlink(sp)
    print("[verify] maintainer script 语法 OK (postinst/prerm)")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--src", default=DEFAULT_SRC)
    ap.add_argument("--out", default=os.path.join(PKG_DIR, "dist"))
    args = ap.parse_args()

    mk = open(os.path.join(args.src, "Makefile"), encoding="utf-8").read()
    ver = read_makefile_var(mk, "PKG_VERSION", "1.0.0")
    rel = read_makefile_var(mk, "PKG_RELEASE", "1")
    deps_raw = read_makefile_var(mk, "LUCI_DEPENDS", "+luci-base")
    dep_list = [d.lstrip("+") for d in re.split(r"[,\s]+", deps_raw) if d.strip()]
    dep_list = [d for d in dep_list if d and d != "libc"]
    deps = ", ".join(["libc"] + dep_list)
    title = read_makefile_var(mk, "LUCI_TITLE", PKG_NAME)
    desc = read_makefile_var(mk, "LUCI_DESCRIPTION", title)
    maintainer = read_makefile_var(mk, "PKG_MAINTAINER", "unknown")
    epoch = build_epoch()

    tmp = os.path.join(args.out, ".stage")
    if os.path.isdir(tmp):
        shutil.rmtree(tmp)
    stage = os.path.join(tmp, "data")
    os.makedirs(stage, exist_ok=True)

    entries = stage_tree(args.src, stage)

    # Installed-Size（KB，向上取整）
    total = 0
    for rel_, _ in entries:
        total += os.path.getsize(os.path.join(stage, rel_))
    size_kb = (total + 1023) // 1024

    os.makedirs(args.out, exist_ok=True)

    data_tgz = os.path.join(tmp, "data.tar.gz")
    make_tar_gz(data_tgz, entries, stage)

    control = CONTROL_TEMPLATE.format(
        pkg=PKG_NAME, ver=ver, rel=rel, deps=deps, epoch=epoch,
        url="https://github.com/xiaodandaodao/luci-app-NeoKuaiNiao",
        maintainer=maintainer, size=size_kb, title=title, desc=desc,
    )
    ctrl_files = {
        "control": (control, 0o644),
        "conffiles": ("\n".join(CONFFILES) + "\n", 0o644),
        "postinst": (POSTINST_TMPL, 0o755),
        "prerm": (PRERM_TMPL, 0o755),
    }
    ctrl_tgz = os.path.join(tmp, "control.tar.gz")
    make_control_tar(ctrl_tgz, ctrl_files, epoch)

    debian = os.path.join(tmp, "debian-binary")
    with open(debian, "w") as f:
        f.write("2.0\n")

    outfile = os.path.join(args.out, "%s_%s-%s_all.ipk" % (PKG_NAME, ver, rel))
    ipk_write(outfile, [
        ("debian-binary", debian),
        ("data.tar.gz", data_tgz),
        ("control.tar.gz", ctrl_tgz),
    ], epoch=epoch)
    ipk_verify(outfile, ["./debian-binary", "./data.tar.gz", "./control.tar.gz"])

    # 兜底：单独的 rootfs 负载包。opkg 万一还是挑刺，可在设备上直接
    # tar xzf 到 / 完成安装（不写 opkg 数据库，卸载需手工删文件）。
    payload = os.path.join(args.out, "%s-payload_%s-%s.tar.gz" % (PKG_NAME, ver, rel))
    shutil.copyfile(data_tgz, payload)

    print("[build] %s" % outfile)
    print("[build] %s（兜底负载包）" % payload)
    print("[build] version %s-%s, %d 个文件, %d KB" % (ver, rel, len(entries), size_kb))
    for rel_, mode in sorted(entries):
        print("        %04o %s" % (mode, rel_))
    shutil.rmtree(tmp, ignore_errors=True)
    return 0


if __name__ == "__main__":
    sys.exit(main())
