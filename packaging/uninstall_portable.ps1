<#
  课舟 Compass 卸载脚本（用户级便携安装）
  ------------------------------------------------------------------
  本文件由 packaging\build_and_install_windows_x64.ps1 复制到安装目录
  （%LOCALAPPDATA%\Programs\KeZhou）并在注册表登记为卸载入口。

  安全约束：只允许删除 %LOCALAPPDATA%\Programs 之下的内容；
           解析后的路径一旦越界，立即拒绝执行并退出。
#>
$ErrorActionPreference = 'Stop'

$appName = '课舟 Compass'
$unKey   = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\KeZhou'

$here = [IO.Path]::GetFullPath($PSScriptRoot)
$base = [IO.Path]::GetFullPath((Join-Path $env:LOCALAPPDATA 'Programs')).TrimEnd('\')
if (-not $here.StartsWith($base + '\', [StringComparison]::OrdinalIgnoreCase)) {
    Write-Error "拒绝执行：$here 不在 $base 之下。本脚本仅用于卸载用户级便携安装。"
    exit 1
}

Write-Host "即将卸载 $appName"
Write-Host "安装目录：$here"

# 1) 结束正在运行的进程
foreach ($n in @('kezhou', 'compass_app')) {
    Get-Process -Name $n -ErrorAction SilentlyContinue | ForEach-Object {
        try { $_.Kill(); $_.WaitForExit(5000) } catch { }
    }
}

# 2) 删除开始菜单 / 桌面快捷方式
$links = @(
    (Join-Path $env:APPDATA "Microsoft\Windows\Start Menu\Programs\$appName.lnk"),
    (Join-Path ([Environment]::GetFolderPath('Desktop')) "$appName.lnk")
)
foreach ($l in $links) {
    if (Test-Path -LiteralPath $l) { Remove-Item -LiteralPath $l -Force }
}

# 3) 删除注册表卸载项
if (Test-Path $unKey) { Remove-Item -Path $unKey -Recurse -Force }

# 4) 延迟删除安装目录：本脚本此刻正运行于该目录，必须交给子进程在父进程退出后执行
$inner = "Start-Sleep -Milliseconds 1500; Remove-Item -LiteralPath '" + $here.Replace("'", "''") + "' -Recurse -Force"
Start-Process -FilePath 'powershell.exe' -WindowStyle Hidden -ArgumentList @(
    '-NoProfile', '-ExecutionPolicy', 'Bypass', '-Command', $inner
) | Out-Null

Write-Host '卸载完成。'