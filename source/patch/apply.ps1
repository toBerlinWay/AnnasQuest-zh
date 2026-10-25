# Anna's Quest 中文化補丁 — 套用 / 還原（純 PowerShell，不需要其他工具）
# 用法: apply.ps1 -Variant tw | cn | original   [-Game "遊戲資料夾"]
param([ValidateSet('tw','cn','original')][string]$Variant = 'tw', [string]$Game = '')
$ErrorActionPreference = 'Stop'
$Here = Split-Path -Parent $MyInvocation.MyCommand.Path
$Manifest = Get-Content "$Here\manifest.json" -Raw -Encoding UTF8 | ConvertFrom-Json
$Label = @{ tw = '繁體中文'; cn = '簡體中文'; original = '英文原版' }[$Variant]

function Hash($p) { (Get-FileHash -LiteralPath $p -Algorithm SHA256).Hash.ToLower() }
function Find-Game {
  if ($Game -and (Test-Path (Join-Path $Game 'data.vis'))) { return $Game }
  $c = @()
  $reg = Get-ItemProperty 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\Steam App 327220' -ErrorAction SilentlyContinue
  if ($reg -and $reg.InstallLocation) { $c += $reg.InstallLocation }
  $steam = (Get-ItemProperty 'HKCU:\Software\Valve\Steam' -ErrorAction SilentlyContinue).SteamPath
  if ($steam) {
    $c += (Join-Path $steam "steamapps\common\Anna's Quest")
    $vdf = Join-Path $steam 'steamapps\libraryfolders.vdf'
    if (Test-Path $vdf) { Select-String -Path $vdf -Pattern '"path"\s+"([^"]+)"' -AllMatches | ForEach-Object { $_.Matches } | ForEach-Object { $c += (Join-Path ($_.Groups[1].Value -replace '\\\\','\') "steamapps\common\Anna's Quest") } }
  }
  $pkgRoot = Split-Path -Parent $Here
  $c += $pkgRoot                          # 補丁包的檔案直接解壓在遊戲資料夾裡
  $c += (Split-Path -Parent $pkgRoot)     # 整個補丁包資料夾放進遊戲資料夾裡
  foreach ($d in $c) { if ($d -and (Test-Path (Join-Path $d 'data.vis'))) { return $d } }
  return $null
}
function Apply-Patch($origPath, $patchPath, $outPath) {
  $o = [IO.File]::ReadAllBytes($origPath); $p = [IO.File]::ReadAllBytes($patchPath)
  if ([Text.Encoding]::ASCII.GetString($p, 0, 5) -ne 'AQZP1') { throw "補丁格式錯誤：$patchPath" }
  $sha = [Security.Cryptography.SHA256]::Create()
  $oh = [BitConverter]::ToString($sha.ComputeHash($o)).Replace('-','').ToLower()
  $want = [BitConverter]::ToString($p, 5, 32).Replace('-','').ToLower()
  if ($oh -ne $want) { throw "來源檔不是預期的原版：$origPath" }
  $size = [BitConverter]::ToInt64($p, 69); $cnt = [BitConverter]::ToInt32($p, 77); $pos = 81
  $out = New-Object byte[] $size; $w = 0
  for ($i = 0; $i -lt $cnt; $i++) {
    $t = $p[$pos]; $pos++
    if ($t -eq 0) { $off = [BitConverter]::ToInt64($p, $pos); $ln = [BitConverter]::ToInt32($p, $pos + 8); $pos += 12; [Buffer]::BlockCopy($o, $off, $out, $w, $ln); $w += $ln }
    else { $ln = [BitConverter]::ToInt32($p, $pos); $pos += 4; [Buffer]::BlockCopy($p, $pos, $out, $w, $ln); $pos += $ln; $w += $ln }
  }
  $nh = [BitConverter]::ToString($sha.ComputeHash($out)).Replace('-','').ToLower()
  $wantNew = [BitConverter]::ToString($p, 37, 32).Replace('-','').ToLower()
  if ($w -ne $size -or $nh -ne $wantNew) { throw "套用結果校驗失敗：$patchPath" }
  [IO.File]::WriteAllBytes($outPath, $out)
}

$G = Find-Game
if (-not $G) { Write-Host "找不到 Anna's Quest 的遊戲資料夾。請把整個補丁包資料夾放進遊戲目錄（和 data.vis 同一層）再執行。" -ForegroundColor Red; exit 1 }
if (Get-Process anna* -ErrorAction SilentlyContinue) { Write-Host "遊戲正在執行中，請先關閉遊戲。" -ForegroundColor Yellow; exit 2 }
Write-Host "遊戲資料夾：$G"
$Bak = Join-Path $G '_zh_backup'
New-Item -ItemType Directory -Force $Bak | Out-Null
$files = $Manifest.files      # 每個項目: rel, orig(sha), tw(sha), cn(sha)
$changed = 0
foreach ($f in $files) {
  $target = Join-Path $G $f.rel
  $bakFile = Join-Path $Bak ($f.rel -replace '[\\/]', '_')
  $cur = Hash $target
  # 第一次碰到原版檔就備份
  if ($cur -eq $f.orig -and -not (Test-Path $bakFile)) { Copy-Item -LiteralPath $target -Destination $bakFile }
  if ($Variant -eq 'original') {
    if ($cur -eq $f.orig) { continue }
    if (-not (Test-Path $bakFile)) { Write-Host "沒有 $($f.rel) 的原版備份，請在 Steam 用「驗證遊戲檔案完整性」還原。" -ForegroundColor Yellow; continue }
    if ((Hash $bakFile) -ne $f.orig) { Write-Host "備份檔 $($f.rel) 校驗不符，請用 Steam 驗證檔案還原。" -ForegroundColor Yellow; continue }
    Copy-Item -LiteralPath $bakFile -Destination $target -Force; $changed++; continue
  }
  $wantHash = $f.$Variant
  if ($cur -eq $wantHash) { continue }
  # 來源：目前就是原版就直接用；否則用備份
  $src = $null
  if ($cur -eq $f.orig) { $src = $target } elseif ((Test-Path $bakFile) -and (Hash $bakFile) -eq $f.orig) { $src = $bakFile }
  if (-not $src) { Write-Host "$($f.rel) 不是已知的原版（1.3.4792）也沒有備份，略過。請先在 Steam 驗證遊戲檔案完整性再執行。" -ForegroundColor Yellow; continue }
  $patch = Join-Path $Here "$Variant\$($f.rel -replace '[\\/]', '_').patch"
  if (-not (Test-Path $patch)) { Write-Host "找不到補丁：$patch" -ForegroundColor Red; exit 4 }
  $tmp = "$target.zhtmp"
  Apply-Patch $src $patch $tmp
  Move-Item -LiteralPath $tmp -Destination $target -Force
  $changed++
  Write-Host "  已更新 $($f.rel)"
}
if ($changed -eq 0) { Write-Host "遊戲目前已經是「$Label」，不需變更。" -ForegroundColor Green }
else { Write-Host "完成：已套用「$Label」（更新了 $changed 個檔案）。" -ForegroundColor Green }
Write-Host "提醒：Steam 執行「驗證遊戲檔案完整性」或遊戲更新後會變回英文，再執行一次安裝即可。"
