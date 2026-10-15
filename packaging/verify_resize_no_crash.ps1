param(
  [Parameter(Mandatory=$true)][string]$ExePath,
  [string]$Tag = 'stress',
  [string]$ShotPath = ''
)
$ErrorActionPreference = 'Continue'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

Add-Type -Namespace W3 -Name U -MemberDefinition @'
[DllImport("user32.dll", SetLastError=true)]
public static extern bool SetWindowPos(IntPtr hWnd, IntPtr hWndInsertAfter, int X, int Y, int cx, int cy, uint uFlags);
[DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);
[DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr hWnd, out RECT lpRect);
[DllImport("user32.dll")] public static extern bool PrintWindow(IntPtr hWnd, IntPtr hdcBlt, uint nFlags);
[DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr hWnd);
public struct RECT { public int Left, Top, Right, Bottom; }
'@

Get-Process -Name ([IO.Path]::GetFileNameWithoutExtension($ExePath)) -ErrorAction SilentlyContinue |
  Where-Object { $_.MainWindowHandle -ne 0 } | Stop-Process -Force -ErrorAction SilentlyContinue
Start-Sleep -Milliseconds 500

Write-Output ("[$Tag] launching " + $ExePath)
$p = Start-Process -FilePath $ExePath -PassThru
$hwnd = [IntPtr]::Zero
$deadline = (Get-Date).AddSeconds(25)
while ((Get-Date) -lt $deadline) {
  if ($p.HasExited) { break }
  $p.Refresh()
  if ($p.MainWindowHandle -ne [IntPtr]::Zero -and [W3.U]::IsWindowVisible($p.MainWindowHandle)) { $hwnd = $p.MainWindowHandle; break }
  Start-Sleep -Milliseconds 250
}
if ($p.HasExited) { Write-Output ("[$Tag] exited during startup code=" + $p.ExitCode); exit 0 }
Start-Sleep -Seconds 6
if ($p.HasExited) { Write-Output ("[$Tag] exited during warmup code=" + $p.ExitCode); exit 0 }

$SWP_NOZORDER = 0x0004; $SWP_NOACTIVATE = 0x0010
$sizes = @(1150,1010,820,640,470,380,430,560,720,900,1080,1240,1320,690,510,410,600,780,960,1140,300,500,1240,880,700)
$n = 0
foreach ($w in $sizes) {
  if ($p.HasExited) { break }
  $h = [int]($w * 0.62)
  $r = New-Object W3.U+RECT
  [void][W3.U]::GetWindowRect($hwnd, [ref]$r)
  [void][W3.U]::SetWindowPos($hwnd, [IntPtr]::Zero, $r.Left, $r.Top, $w, $h, ($SWP_NOZORDER -bor $SWP_NOACTIVATE))
  $n++
  Start-Sleep -Milliseconds 220
  $p.Refresh()
}
# maximize/restore round trips (ascii only: PS 5.1 reads no-BOM files as GBK)
foreach ($cmd in @(3, 9, 3, 9, 3, 9)) {   # SW_MAXIMIZE=3, SW_RESTORE=9
  if ($p.HasExited) { break }
  [void][W3.U]::ShowWindow($hwnd, $cmd)
  Start-Sleep -Milliseconds 500
  $p.Refresh()
}
if (-not $p.HasExited) {
  Start-Sleep -Milliseconds 500
  $p.Refresh()
}
if ($p.HasExited) {
  $hex = '0x' + ('{0:x8}' -f ($p.ExitCode -band 0xffffffff))
  Write-Output ("[$Tag] RESULT: CRASHED after $n resizes, exit=$($p.ExitCode) ($hex)")
  exit 0
}
Write-Output ("[$Tag] RESULT: SURVIVED $n resizes + 3 maximize/restore cycles")

if ($ShotPath -ne '') {
  $r = New-Object W3.U+RECT
  [void][W3.U]::GetWindowRect($hwnd, [ref]$r)
  $w = $r.Right - $r.Left; $h = $r.Bottom - $r.Top
  Add-Type -AssemblyName System.Drawing
  $bmp = New-Object System.Drawing.Bitmap $w, $h
  $g = [System.Drawing.Graphics]::FromImage($bmp)
  $hdc = $g.GetHdc()
  [void][W3.U]::PrintWindow($hwnd, $hdc, 2)   # PW_RENDERFULLCONTENT
  $g.ReleaseHdc($hdc)
  $g.Dispose()
  $bmp.Save($ShotPath, [System.Drawing.Imaging.ImageFormat]::Png)
  $bmp.Dispose()
  Write-Output ("[$Tag] screenshot saved: " + $ShotPath)
}
Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue
