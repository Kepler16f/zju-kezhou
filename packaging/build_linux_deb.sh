#!/usr/bin/env bash
# packaging/build_linux_deb.sh — 把 Flutter Linux bundle 目录打成 .deb 直装包
# 用法：bash packaging/build_linux_deb.sh <bundle_dir> <deb_arch> <version> <out_deb> [icon_png]
#   bundle_dir  = flutter build linux 产物 .../release/bundle（含可执行 compass_app、lib/、data/）
#   deb_arch    = amd64 | arm64   （dpkg Architecture）
#   version     = 如 0.13.4（可含 +build，脚本会清洗成 dpkg 合法的 0.13.4-18）
#   out_deb     = 目标 .deb 路径
#   icon_png    = 可选，桌面图标源（存在才嵌 hicolor/256x256）
# 说明：bundle 装到 /opt/kezhou（整目录），/usr/bin/kezhou 软链入口，附 .desktop 与图标。
#   dpkg-deb 成员用相对路径（root 下 opt/ usr/ DEBIAN/），不接受绝对路径成员。
set -euo pipefail

BUNDLE="${1:?需要 bundle 目录}"
DEB_ARCH="${2:?需要 deb 架构（amd64|arm64）}"
VERSION="${3:?需要版本号}"
OUT="${4:?需要输出 .deb 路径}"
ICON="${5:-}"

case "$DEB_ARCH" in amd64|arm64) : ;; *) echo "deb_arch 必须 amd64|arm64，收到 $DEB_ARCH" >&2; exit 2;; esac
[ -d "$BUNDLE" ] || { echo "bundle 目录不存在：$BUNDLE" >&2; exit 1; }
[ -x "$BUNDLE/compass_app" ] || { echo "bundle 缺可执行 compass_app：$BUNDLE" >&2; exit 1; }

# dpkg Version 不允许 '+'：0.13.4+18 → 0.13.4-18；仅保留 [A-Za-z0-9.+~:-]
DEB_VERSION="$(printf '%s' "$VERSION" | tr '+' '-')"
DEB_VERSION="$(printf '%s' "$DEB_VERSION" | sed 's/[^A-Za-z0-9.+-]//g')"
[ -n "$DEB_VERSION" ] || { echo "版本清洗后为空：$VERSION" >&2; exit 1; }

ROOT="$(mktemp -d)"
trap 'rm -rf "$ROOT"' EXIT

install -d "$ROOT/DEBIAN" "$ROOT/opt/kezhou" "$ROOT/usr/bin" "$ROOT/usr/share/applications"
cp -R "$BUNDLE/." "$ROOT/opt/kezhou/"
chmod 0755 "$ROOT/opt/kezhou/compass_app"
ln -s /opt/kezhou/compass_app "$ROOT/usr/bin/kezhou"

cat > "$ROOT/usr/share/applications/kezhou.desktop" <<'DESK'
[Desktop Entry]
Type=Application
Version=1.0
Name=课舟
GenericName=ClassArk
Comment=培养方案结构化与选课风险审计
Exec=kezhou
Icon=kezhou
Terminal=false
Categories=Education;
StartupWMClass=compass_app
DESK

if [ -n "$ICON" ] && [ -f "$ICON" ]; then
  install -d "$ROOT/usr/share/icons/hicolor/256x256/apps"
  install -m 0644 "$ICON" "$ROOT/usr/share/icons/hicolor/256x256/apps/kezhou.png"
fi

cat > "$ROOT/DEBIAN/control" <<CTL
Package: kezhou
Version: $DEB_VERSION
Architecture: $DEB_ARCH
Maintainer: KeZhou Team <kezhou-team@users.noreply.github.com>
Homepage: https://github.com/Kepler16f/zju-kezhou
Depends: libgtk-3-0, libsecret-1-0
Section: utils
Priority: optional
Installed-Size: $(du -sk "$ROOT/opt/kezhou" | cut -f1)
Description: 课舟 ClassArk - 培养方案结构化与选课风险审计
 面向浙江大学本科生的学业规划助手：只读对接教务系统，结构化培养方案、
 审计学分缺口/先修冲突/选课风险，内置 GPA 看板与 AI 解读（可选）。
CTL

chmod 0644 "$ROOT/DEBIAN/control"
dpkg-deb --build --root-owner-group "$ROOT" "$OUT"
ls -lh "$OUT"
