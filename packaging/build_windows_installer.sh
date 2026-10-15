#!/usr/bin/env bash
# packaging/build_windows_installer.sh — 课舟 Windows 安装包（Setup.exe）一键构建
# 用法：bash packaging/build_windows_installer.sh [arm64|x64] [版本号]
# 产物：D:\compass\dist\KeZhouSetup-<版本>-win-<arch>.exe（复制到 Downloads；arm64 自动装机）
# 依赖：VS Build Tools（VC 运行库 redist）、Inno Setup 6、flutter（C:\flutter）
set -euo pipefail
ARCH="${1:-arm64}"
VER="${2:-0.10.0}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
REL="$ROOT/compass_app/build/windows/$ARCH/runner/Release"
DIST="$ROOT/dist"
STAGE="$DIST/stage-win-$ARCH"

# 1) 构建 Release（产物不存在或源码更新时）
if [ ! -f "$REL/kezhou.exe" ]; then
  export PATH="/c/flutter/bin:$PATH"
  (cd "$ROOT/compass_app" && flutter build windows --release --no-tree-shake-icons)
fi
[ -f "$REL/kezhou.exe" ] || { echo "未找到 $REL/kezhou.exe（先 flutter build windows）"; exit 1; }

# 2) 定位 Inno Setup
ISCC=""
for p in "/c/Users/$USERNAME/AppData/Local/Programs/Inno Setup 6/ISCC.exe" \
         "/c/Program Files (x86)/Inno Setup 6/ISCC.exe" "/c/Program Files/Inno Setup 6/ISCC.exe"; do
  [ -f "$p" ] && ISCC="$p" && break
done
[ -n "$ISCC" ] || { echo "未找到 Inno Setup（winget install JRSoftware.InnoSetup）"; exit 1; }

# 3) 暂存目录：bundle + VC++ 运行库（flutter_windows.dll 依赖，干净机器必需）
rm -rf "$STAGE"; mkdir -p "$STAGE"
cp -r "$REL/." "$STAGE/"
CRT=$(ls -d "/c/Program Files (x86)/Microsoft Visual Studio/2022/BuildTools/VC/Redist/MSVC/"*/"$ARCH"/Microsoft.VC143.CRT 2>/dev/null | sort -V | tail -1)
if [ -n "$CRT" ]; then
  cp "$CRT"/vcruntime140*.dll "$CRT"/msvcp140*.dll "$STAGE/"
  echo "已内置 VC++ 运行库：$CRT"
else
  echo "⚠️ 未找到 $ARCH 的 VC 运行库 redist，安装包可能无法在干净机器运行"
fi

# 4) 生成 .iss 并编译（Inno 需要 Windows 风格路径，Git Bash 下用 cygpath 转换）
cyw() { cygpath -w "$1" 2>/dev/null || echo "$1" | sed 's#^/\([a-z]\)/#\U\1:\\#; s#/#\\#g'; }
STAGE_W=$(cyw "$STAGE"); DIST_W=$(cyw "$DIST"); ICON_W=$(cyw "$ROOT/compass_app/windows/runner/resources/app_icon.ico")
ISS="$DIST/kezhou_$ARCH.iss"
case "$ARCH" in
  arm64) ARCHKEY="arm64" ;;
  x64)   ARCHKEY="x64"  ;;
  *) echo "未知架构 $ARCH"; exit 1 ;;
esac
cat > "$ISS" <<EOF
; 自动生成：build_windows_installer.sh — 勿手改
[Setup]
AppId={{8F4B1D5E-92A6-4C7B-B3E0-KEZHOU00001}
AppName=课舟
AppVersion=$VER
AppPublisher=KeZhou Team
DefaultDirName={autopf}\\KeZhou
DefaultGroupName=课舟
UninstallDisplayIcon={app}\\kezhou.exe
OutputDir=$DIST_W
OutputBaseFilename=KeZhouSetup-$VER-win-$ARCH
ArchitecturesAllowed=$ARCHKEY
ArchitecturesInstallIn64BitMode=$ARCHKEY
Compression=lzma2/max
SolidCompression=yes
SetupIconFile=$ICON_W
DisableProgramGroupPage=yes
PrivilegesRequired=lowest
PrivilegesRequiredOverridesAllowed=dialog
[Files]
Source: "$STAGE_W\\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs
[Icons]
Name: "{group}\\课舟"; Filename: "{app}\\kezhou.exe"
Name: "{autodesktop}\\课舟"; Filename: "{app}\\kezhou.exe"
[Run]
Filename: "{app}\\kezhou.exe"; Description: "立即运行课舟"; Flags: nowait postinstall skipifsilent
EOF

"$ISCC" "$ISS" | tail -2
OUT="$DIST/KeZhouSetup-$VER-win-$ARCH.exe"
[ -f "$OUT" ] || { echo "安装包未产出，检查 ISCC 输出"; exit 1; }
cp "$OUT" "/c/Users/$USERNAME/Downloads/"
echo "== 交付: $OUT（已复制到 Downloads）=="
ls -la "$OUT" | awk '{print $5" bytes"}'

# 本机自动安装（用户约定：arm64 版改好直接装上；SKIP_INSTALL=1 可跳过）
# 注意：ps1 里不能硬编码中文用户名路径（PowerShell 5.1 按 GBK 读无 BOM 脚本会乱码），
# 一律用 $env:USERPROFILE / $env:ProgramFiles 动态解析。
# 改名迁移：先静默卸载旧"学业罗盘/Compass"（若装过），再装课舟。
if [ "$ARCH" = "arm64" ] && [ "${SKIP_INSTALL:-0}" != "1" ]; then
  OUT_W=$(cygpath -w "$OUT")
  cat > /tmp/kezhou_autoinstall.ps1 <<PSEOF
# 卸载旧 Compass（学业罗盘）
foreach (\$dir in @("\$env:ProgramFiles\Compass", "\$env:LOCALAPPDATA\Programs\Compass")) {
  \$un = Join-Path \$dir 'unins000.exe'
  if (Test-Path \$un) {
    Start-Process -FilePath \$un -ArgumentList '/VERYSILENT','/SUPPRESSMSGBOXES' -Wait -ErrorAction SilentlyContinue
    Write-Output ("旧版已卸载: " + \$dir)
    Start-Sleep -Seconds 2
  }
}
# 安新课舟
\$p = Start-Process -FilePath '$OUT_W' -ArgumentList '/VERYSILENT','/SUPPRESSMSGBOXES','/NORESTART','/FORCECLOSEAPPLICATIONS' -PassThru -Wait
Write-Output ("setup exit=" + \$p.ExitCode)
foreach (\$dir in @("\$env:ProgramFiles\KeZhou", "\$env:LOCALAPPDATA\Programs\KeZhou")) {
  if (Test-Path (Join-Path \$dir 'kezhou.exe')) {
    Write-Output ("INSTALLED AT: " + \$dir)
  }
}
PSEOF
  powershell -NoProfile -ExecutionPolicy Bypass -File "$(cygpath -w /tmp/kezhou_autoinstall.ps1)" 2>&1 | tail -3
  echo "== 已静默安装课舟到本机（开始菜单/桌面快捷方式已建）=="
fi
