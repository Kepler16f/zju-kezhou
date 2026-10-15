<#
  课舟 Compass —— Windows 一键「构建 + 本地安装」脚本
  ------------------------------------------------------------------
  在装有 Flutter SDK 与 Visual Studio C++ 工具链的 Windows 上，一条命令完成：
      Release 构建 → 组装发布目录（含 VC++ 运行库）→ 生成安装包 → 安装到本机

  用法（可在任意目录执行）：
      pwsh -File packaging\build_and_install_windows_x64.ps1
      pwsh -File packaging\build_and_install_windows_x64.ps1 -DryRun
      pwsh -File packaging\build_and_install_windows_x64.ps1 -Launch
      pwsh -File packaging\build_and_install_windows_x64.ps1 -Version 0.10.6 -SkipInstall
      powershell -ExecutionPolicy Bypass -File packaging\build_and_install_windows_x64.ps1 -Portable

  参数：
      -Arch         x64（默认）| arm64
      -Version      覆盖版本号；默认读取 compass_app\pubspec.yaml 的 version
      -DryRun       只做体检（路径 / 版本 / 工具链 / 产物），不构建、不安装
      -SkipInstall  只构建并产出安装包，不安装到本机
      -Portable     强制走「用户级便携安装」，不使用 Inno Setup
      -Launch       安装完成后启动应用
      -SkipPubGet   跳过 flutter pub get

  重要说明：
    * windows\CMakeLists.txt 里 set(BINARY_NAME "kezhou")，因此 flutter build windows
      实际产出的是 kezhou.exe。本脚本依然不硬编码 exe 名（优先 kezhou.exe，否则取
      Release 目录里体积最大的 .exe），这样即便将来改名、或 windows\ 脚手架被重新生成，
      也不会因名字对不上而失败。
    * Release 目录兼容三种布局：
        build\windows\<arch>\runner\Release
        build\windows\x64\runner\Release
        build\windows\runner\Release
    * 优先调用 Inno Setup 生成标准安装包（带卸载项）；未找到 ISCC 或指定
      -Portable 时，退化为用户级便携安装到 %LOCALAPPDATA%\Programs\KeZhou。
#>
[CmdletBinding()]
param(
    [ValidateSet('x64', 'arm64')]
    [string]$Arch = 'x64',

    [string]$Version,

    [switch]$DryRun,

    [switch]$SkipInstall,

    [switch]$Portable,

    [switch]$Launch,

    [switch]$SkipPubGet
)

$ErrorActionPreference = 'Stop'

# AppId 与既有本地安装包保持一致（dist\kezhou_x64.iss 与 packaging\build_windows_installer.sh
# 用的都是 ...00001），这样新版会覆盖升级已有安装，而不会并排装出第二份。
# 注意：CI 的 windows-x64 作业用的是 ...00002，两者会被系统视为两个不同产品。
$AppId           = '8F4B1D5E-92A6-4C7B-B3E0-KEZHOU00001'
$AppDisplayName  = '课舟'
$AppPublisher    = 'KeZhou Team'
$PortableDirName = 'KeZhou'
$UninstallKey    = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\KeZhou'

function Write-Step   { param([string]$m) Write-Host ''; Write-Host "==> $m" -ForegroundColor Cyan }
function Write-Ok     { param([string]$m) Write-Host "    $m" -ForegroundColor Green }
function Write-Note   { param([string]$m) Write-Host "    $m" -ForegroundColor Gray }
function Write-WarnMsg{ param([string]$m) Write-Host "    [!] $m" -ForegroundColor Yellow }
function Fail         { param([string]$m) Write-Host ''; Write-Host "错误：$m" -ForegroundColor Red; exit 1 }

function Resolve-Flutter {
    $c = Get-Command flutter -ErrorAction SilentlyContinue
    if ($c) { return $c.Source }
    $cands = New-Object System.Collections.ArrayList
    if ($env:FLUTTER_ROOT) { [void]$cands.Add((Join-Path $env:FLUTTER_ROOT 'bin\flutter.bat')) }
    [void]$cands.Add('C:\flutter\bin\flutter.bat')
    [void]$cands.Add((Join-Path $env:USERPROFILE 'flutter\bin\flutter.bat'))
    [void]$cands.Add((Join-Path $env:LOCALAPPDATA 'flutter\bin\flutter.bat'))
    [void]$cands.Add((Join-Path $env:USERPROFILE 'fvm\default\bin\flutter.bat'))
    foreach ($p in $cands) { if ($p -and (Test-Path -LiteralPath $p)) { return $p } }
    return $null
}

function Resolve-Iscc {
    $c = Get-Command ISCC.exe -ErrorAction SilentlyContinue
    if ($c) { return $c.Source }
    $cands = @(
        (Join-Path ${env:ProgramFiles(x86)} 'Inno Setup 6\ISCC.exe'),
        (Join-Path $env:ProgramFiles 'Inno Setup 6\ISCC.exe'),
        (Join-Path $env:LOCALAPPDATA 'Programs\Inno Setup 6\ISCC.exe')
    )
    foreach ($p in $cands) { if (Test-Path -LiteralPath $p) { return $p } }
    return $null
}

function Get-VcRuntimeDir {
    param([string]$ArchName)
    $roots = @("${env:ProgramFiles(x86)}\Microsoft Visual Studio", "$env:ProgramFiles\Microsoft Visual Studio")
    foreach ($r in $roots) {
        if (-not (Test-Path -LiteralPath $r)) { continue }
        $hit = Get-ChildItem -LiteralPath $r -Recurse -Directory -Filter 'Microsoft.VC*.CRT' -ErrorAction SilentlyContinue |
               Where-Object { $_.FullName -match ('\\' + [regex]::Escape($ArchName) + '\\Microsoft\.VC') } |
               Sort-Object FullName -Descending | Select-Object -First 1
        if ($hit) { return $hit.FullName }
    }
    return $null
}

function Find-ReleaseDir {
    param([string]$App, [string]$ArchName)
    $cands = @(
        (Join-Path $App "build\windows\$ArchName\runner\Release"),
        (Join-Path $App 'build\windows\runner\Release'),
        (Join-Path $App 'build\windows\x64\runner\Release'),
        (Join-Path $App 'build\windows\arm64\runner\Release')
    )
    foreach ($c in $cands) { if (Test-Path -LiteralPath $c) { return $c } }
    $hit = Get-ChildItem -LiteralPath (Join-Path $App 'build\windows') -Recurse -Directory -Filter 'Release' -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($hit) { return $hit.FullName }
    return $null
}

function Get-AppExeName {
    param([string]$ReleasePath)
    $exes = @(Get-ChildItem -LiteralPath $ReleasePath -Filter '*.exe' -File -ErrorAction SilentlyContinue)
    if ($exes.Count -eq 0) { return $null }
    $pref = $exes | Where-Object { $_.BaseName -eq 'kezhou' } | Select-Object -First 1
    if (-not $pref) { $pref = $exes | Sort-Object Length -Descending | Select-Object -First 1 }
    return $pref.Name
}

# ---------- 0. 定位仓库与 Flutter 工程 ----------
$ScriptPath = $MyInvocation.MyCommand.Path
if ([string]::IsNullOrEmpty($ScriptPath)) { $ScriptPath = $PSCommandPath }
if ([string]::IsNullOrEmpty($ScriptPath)) { Fail '无法确定脚本自身路径，请用 -File 方式运行本脚本。' }
$ScriptDir = Split-Path -Parent $ScriptPath
$RepoRoot  = Split-Path -Parent $ScriptDir
$AppDir    = Join-Path $RepoRoot 'compass_app'
if (-not (Test-Path -LiteralPath (Join-Path $AppDir 'pubspec.yaml'))) {
    if (Test-Path -LiteralPath (Join-Path $RepoRoot 'pubspec.yaml')) { $AppDir = $RepoRoot }
    else { Fail "未找到 Flutter 工程，期望 $AppDir\pubspec.yaml" }
}
$PubspecPath = Join-Path $AppDir 'pubspec.yaml'
$DistDir     = Join-Path $RepoRoot 'dist'

# ---------- 1. 版本号与目标架构 ----------
if (-not $Version) {
    $txt = Get-Content -LiteralPath $PubspecPath -Raw
    $mv  = [regex]::Match($txt, '(?m)^version:\s*([0-9]+(?:\.[0-9]+)*)')
    if ($mv.Success) { $Version = $mv.Groups[1].Value } else { $Version = '0.0.0' }
}
if ($Arch -eq 'x64') { $FlutterPlatform = 'windows-x64' } else { $FlutterPlatform = 'windows-arm64' }

Write-Step "课舟 Compass $Version / Windows $Arch"
Write-Note "工程目录：$AppDir"
Write-Note "仓库根目录：$RepoRoot"

# ---------- 2. 工具链探测 ----------
$flutter = Resolve-Flutter
$iscc    = Resolve-Iscc

$vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'
$vsPath  = $null
if (Test-Path -LiteralPath $vswhere) {
    $vsPath = & $vswhere -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath 2>$null
}

if ($flutter) { Write-Note "flutter：$flutter" }            else { Write-WarnMsg '未找到 flutter。安装：winget install --id Flutter.Flutter，或设置 FLUTTER_ROOT。' }
if ($vsPath)  { Write-Note "MSVC：$vsPath" }                else { Write-WarnMsg '未找到 VS C++ 生成工具（VC.Tools.x86.x64）。安装：winget install --id Microsoft.VisualStudio.2022.BuildTools --override "--add Microsoft.VisualStudio.Workload.VCTools --includeRecommended"' }
if ($iscc)    { Write-Note "Inno Setup：$iscc" }            else { Write-WarnMsg '未找到 Inno Setup（可 winget install --id JRSoftware.InnoSetup），将退化为便携安装。' }

$crtDir    = Get-VcRuntimeDir $Arch
$ReleaseDir = Find-ReleaseDir -App $AppDir -ArchName $Arch
if ($crtDir)     { Write-Note "VC++ 运行库：$crtDir" }       else { Write-WarnMsg '未找到 VC++ 运行库 redist（干净机器上可能缺 vcruntime140.dll / msvcp140.dll）。' }
if ($ReleaseDir) { Write-Note "已有 Release 产物：$ReleaseDir" }
$stageDir  = Join-Path $DistDir "stage-win-$Arch"

if ($DryRun) {
    Write-Step '体检结束（-DryRun：未构建、未安装）'
    if (-not $flutter) { Write-WarnMsg '缺 flutter，无法构建。' }
    elseif (-not $vsPath) { Write-WarnMsg '缺 VS C++ 生成工具，flutter build windows 大概率失败。' }
    else { Write-Ok '工具链齐备，可直接去掉 -DryRun 正式构建。' }
    exit 0
}

if (-not $flutter) {
    Fail '未找到 flutter。请先安装 Flutter SDK 并把 bin 加入 PATH（winget install --id Flutter.Flutter），或设置 FLUTTER_ROOT 指向 SDK 根目录后重试。'
}

# ---------- 3. 构建 ----------
Push-Location -LiteralPath $AppDir
try {
    if (-not (Test-Path -LiteralPath (Join-Path $AppDir 'windows'))) {
        Write-Step '缺少 windows\ 平台目录，执行 flutter create --platforms windows'
        & $flutter create --platforms windows .
        if ($LASTEXITCODE -ne 0) { Fail 'flutter create --platforms windows 失败' }
    }

    if (-not $SkipPubGet) {
        Write-Step 'flutter pub get'
        & $flutter pub get
        if ($LASTEXITCODE -ne 0) { Fail 'flutter pub get 失败' }
    }

    Write-Step "flutter build windows --release（$Arch）"
    if ($Arch -eq 'x64') {
        & $flutter build windows --release --no-tree-shake-icons
    } else {
        & $flutter build windows --release --no-tree-shake-icons --target-platform $FlutterPlatform
        if ($LASTEXITCODE -ne 0) {
            Write-WarnMsg "--target-platform $FlutterPlatform 未被当前 Flutter 支持，回退为宿主架构构建。arm64 版建议在 Windows-on-ARM 机器上原生构建。"
            & $flutter build windows --release --no-tree-shake-icons
        }
    }
    if ($LASTEXITCODE -ne 0) { Fail 'flutter build windows 失败' }
} finally {
    Pop-Location
}

# ---------- 4. 定位 Release 产物 ----------
Write-Step '定位 Release 产物目录'
$ReleaseDir = Find-ReleaseDir -App $AppDir -ArchName $Arch
if (-not $ReleaseDir) { Fail '未找到 Release 产物目录，构建可能未真正完成。' }
Write-Ok $ReleaseDir

# ---------- 5. 探测可执行文件名（不硬编码 kezhou.exe） ----------
$ExeName = Get-AppExeName -ReleasePath $ReleaseDir
if (-not $ExeName) { Fail "Release 目录中没有 .exe：$ReleaseDir" }
if ($ExeName -ne 'kezhou.exe') {
    Write-WarnMsg "本次产出的是 $ExeName（windows\CMakeLists.txt 的 BINARY_NAME 为 kezhou 时会得到 kezhou.exe），已按实际文件名生成快捷方式与安装包。"
}
Write-Ok "可执行文件：$ExeName"

# ---------- 6. 组装发布目录 + VC++ 运行库 ----------
$StageDir = $stageDir
if (Test-Path -LiteralPath $StageDir) { Remove-Item -LiteralPath $StageDir -Recurse -Force }
New-Item -ItemType Directory -Path $StageDir -Force | Out-Null
Copy-Item -Path (Join-Path $ReleaseDir '*') -Destination $StageDir -Recurse -Force

if ($crtDir) {
    foreach ($pat in @('vcruntime140*.dll', 'msvcp140*.dll', 'concrt140.dll')) {
        Get-ChildItem -LiteralPath $crtDir -Filter $pat -File -ErrorAction SilentlyContinue | ForEach-Object {
            Copy-Item -LiteralPath $_.FullName -Destination $StageDir -Force
        }
    }
    Write-Ok "已内置 VC++ 运行库：$crtDir"
}

# ---------- 7. 生成安装包（Inno Setup，可选） ----------
$setupExe = $null
if ((-not $Portable) -and $iscc) {
    Write-Step "生成安装包（Inno Setup：$iscc）"
    $innoArchKey = 'x64'
    if ($Arch -ne 'x64') { $innoArchKey = 'arm64' }
    try {
        $iv  = (Get-Item -LiteralPath $iscc).VersionInfo.ProductVersion
        $ivm = [regex]::Match($iv, '^(\d+)\.(\d+)')
        if ($ivm.Success) {
            $major = [int]$ivm.Groups[1].Value
            $minor = [int]$ivm.Groups[2].Value
            if (($major -gt 6) -or (($major -eq 6) -and ($minor -ge 3))) {
                if ($Arch -eq 'x64') { $innoArchKey = 'x64compatible' }
            }
        }
    } catch { }

    $iconPath = Join-Path $AppDir 'windows\runner\resources\app_icon.ico'
    $iconLine = ''
    if (Test-Path -LiteralPath $iconPath) { $iconLine = "SetupIconFile=$iconPath" }

    $issPath = Join-Path $DistDir "kezhou_win_$Arch.iss"
    $iss = @"
; 自动生成：packaging\build_and_install_windows_x64.ps1 —— 请勿手改
[Setup]
AppId={{$AppId}
AppName=$AppDisplayName
AppVersion=$Version
AppVerName=$AppDisplayName $Version
AppPublisher=$AppPublisher
DefaultDirName={autopf}\$PortableDirName
DisableProgramGroupPage=yes
UninstallDisplayIcon={app}\$ExeName
OutputDir=$DistDir
OutputBaseFilename=KeZhouSetup-$Version-win-$Arch
ArchitecturesAllowed=$innoArchKey
ArchitecturesInstallIn64BitMode=$innoArchKey
Compression=lzma2/max
SolidCompression=yes
PrivilegesRequired=lowest
PrivilegesRequiredOverridesAllowed=dialog
$iconLine

[Files]
Source: "$StageDir\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{autoprograms}\$AppDisplayName"; Filename: "{app}\$ExeName"
Name: "{autodesktop}\$AppDisplayName"; Filename: "{app}\$ExeName"; Tasks: desktopicon

[Tasks]
Name: "desktopicon"; Description: "创建桌面快捷方式"; GroupDescription: "附加任务："

[Run]
Filename: "{app}\$ExeName"; Description: "运行 $AppDisplayName"; Flags: nowait postinstall skipifsilent
"@
    [IO.File]::WriteAllText($issPath, ($iss -replace "`r`n", "`n" -replace "`n", "`r`n"), (New-Object System.Text.UTF8Encoding($true)))
    Write-Note "iss：$issPath"

    & $iscc $issPath
    if ($LASTEXITCODE -ne 0) {
        Write-WarnMsg 'Inno Setup 编译失败，转为便携安装。'
    } else {
        $candidate = Join-Path $DistDir "KeZhouSetup-$Version-win-$Arch.exe"
        if (Test-Path -LiteralPath $candidate) {
            $setupExe = $candidate
            Write-Ok "安装包：$setupExe"
        } else {
            Write-WarnMsg "Inno 未产出预期文件：$candidate"
        }
    }
} elseif (-not $Portable) {
    Write-WarnMsg '未找到 Inno Setup，改用便携安装。'
}

# ---------- 8. 安装 ----------
if ($SkipInstall) {
    Write-Step '已指定 -SkipInstall：跳过安装'
    Write-Note "发布目录：$StageDir"
    if ($setupExe) { Write-Note "安装包：$setupExe" }
    exit 0
}

$launchExe = $null

if ($setupExe) {
    Write-Step '静默安装到本机'
    $p = Start-Process -FilePath $setupExe -ArgumentList '/VERYSILENT', '/SUPPRESSMSGBOXES', '/NORESTART', '/FORCECLOSEAPPLICATIONS' -PassThru -Wait
    Write-Ok "Setup 退出码 = $($p.ExitCode)"
    $installed = @(
        (Join-Path $env:LOCALAPPDATA "Programs\$PortableDirName\$ExeName"),
        (Join-Path $env:ProgramFiles "$PortableDirName\$ExeName")
    ) | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
    if ($installed) {
        Write-Ok "已安装：$installed"
        $launchExe = $installed
    } else {
        Write-WarnMsg "未在常见位置找到安装结果，请检查 %LOCALAPPDATA%\Programs\$PortableDirName"
    }
} else {
    $targetRoot = Join-Path $env:LOCALAPPDATA 'Programs'
    $target     = Join-Path $targetRoot $PortableDirName
    $targetFull = [IO.Path]::GetFullPath($target)
    $rootFull   = [IO.Path]::GetFullPath($targetRoot).TrimEnd('\')
    if (-not $targetFull.StartsWith($rootFull + '\', [StringComparison]::OrdinalIgnoreCase)) {
        Fail "拒绝安装：目标目录 $targetFull 不在 $rootFull 之下。"
    }

    Write-Step "便携安装到 $targetFull"
    if (Test-Path -LiteralPath $targetFull) { Remove-Item -LiteralPath $targetFull -Recurse -Force }
    New-Item -ItemType Directory -Path $targetFull -Force | Out-Null
    Copy-Item -Path (Join-Path $StageDir '*') -Destination $targetFull -Recurse -Force

    $exeFull = Join-Path $targetFull $ExeName

    $ws = New-Object -ComObject WScript.Shell
    $links = @(
        (Join-Path $env:APPDATA "Microsoft\Windows\Start Menu\Programs\$AppDisplayName.lnk"),
        (Join-Path ([Environment]::GetFolderPath('Desktop')) "$AppDisplayName.lnk")
    )
    foreach ($lnk in $links) {
        $sc = $ws.CreateShortcut($lnk)
        $sc.TargetPath       = $exeFull
        $sc.WorkingDirectory = $targetFull
        $sc.IconLocation     = $exeFull
        $sc.Save()
    }
    Write-Ok '已创建开始菜单 / 桌面快捷方式'

    $uninstaller = Join-Path $targetFull 'uninstall.ps1'
    $template    = Join-Path $ScriptDir 'uninstall_portable.ps1'
    if (-not (Test-Path -LiteralPath $template)) { Fail "缺少卸载模板：$template" }
    Copy-Item -LiteralPath $template -Destination $uninstaller -Force

    New-Item -Path $UninstallKey -Force | Out-Null
    Set-ItemProperty -Path $UninstallKey -Name 'DisplayName'     -Value $AppDisplayName
    Set-ItemProperty -Path $UninstallKey -Name 'DisplayVersion'  -Value $Version
    Set-ItemProperty -Path $UninstallKey -Name 'Publisher'       -Value $AppPublisher
    Set-ItemProperty -Path $UninstallKey -Name 'InstallLocation' -Value $targetFull
    Set-ItemProperty -Path $UninstallKey -Name 'DisplayIcon'     -Value $exeFull
    Set-ItemProperty -Path $UninstallKey -Name 'UninstallString' -Value "powershell.exe -NoProfile -ExecutionPolicy Bypass -File `"$uninstaller`""
    Set-ItemProperty -Path $UninstallKey -Name 'NoModify' -Value 1 -Type DWord
    Set-ItemProperty -Path $UninstallKey -Name 'NoRepair' -Value 1 -Type DWord

    Write-Ok "已注册卸载项（设置 → 应用 中可见「$AppDisplayName」）"
    Write-Ok "已安装：$exeFull"
    $launchExe = $exeFull
}

# ---------- 9. 启动 ----------
if ($Launch -and $launchExe -and (Test-Path -LiteralPath $launchExe)) {
    Write-Step '启动应用'
    Start-Process -FilePath $launchExe -WorkingDirectory (Split-Path -Parent $launchExe)
}

Write-Step '完成'
Write-Note "版本 $Version / 架构 $Arch"
