# Edgeflow installer for Windows 10/11. Started by the one-line command Edgeflow shows on the
# Mac: it checked this file's SHA-256 before running it and passes the pairing secret.
# No admin rights needed: everything goes under %LOCALAPPDATA%\Edgeflow. Windows only
# connects out to the Mac, so no firewall prompt.
param([string]$Secret = '')
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
try { [Console]::OutputEncoding = [Text.Encoding]::UTF8 } catch {}
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$URL = '@@URL@@'
$TOKEN = '@@TOKEN@@'
$VERSION = '@@VERSION@@'
$DESKFLOW = '1.27.0'
$Dir = Join-Path $env:LOCALAPPDATA 'Edgeflow'
$Utf8 = New-Object Text.UTF8Encoding $false

function Report($step, $state, $msg = '') {
    try { Invoke-WebRequest -UseBasicParsing -Method Post -Uri "$URL/s/$TOKEN" -TimeoutSec 5 `
            -Body @{ step = $step; state = $state; msg = $msg; log = $msg } | Out-Null } catch {}
}
function Ok($t) { Write-Host "  [ok] $t" -ForegroundColor Green }
function Fail($step, $msg) {
    Write-Host "  [x] $msg" -ForegroundColor Red
    Report $step 'fail' $msg
    Write-Host "`nEdgeflow: $msg"
    exit 1
}
function Sha256Bytes([string]$s) { [Security.Cryptography.SHA256]::Create().ComputeHash([Text.Encoding]::UTF8.GetBytes($s)) }
function HexOf([byte[]]$b) { ($b | ForEach-Object { $_.ToString('x2') }) -join '' }
function BytesOf([string]$h) { [byte[]]($h -split '(..)' | Where-Object { $_ } | ForEach-Object { [Convert]::ToByte($_, 16) }) }
function WriteText($path, $text) { [IO.File]::WriteAllText($path, $text, $Utf8) }

Write-Host "Edgeflow $VERSION" -ForegroundColor White
if (-not $Secret) { Fail 1 'missing pairing secret' }

# 1. connect to the Mac and open the sealed pairing bundle
try {
    $osv = ((Get-CimInstance Win32_OperatingSystem).Caption -replace '^Microsoft ', '').Trim()
    $resp = (Invoke-WebRequest -UseBasicParsing -Method Post -Uri "$URL/p/$TOKEN" -TimeoutSec 60 `
            -Body @{ hostname = $env:COMPUTERNAME; os = 'windows'; osv = $osv; arch = $env:PROCESSOR_ARCHITECTURE }).Content
} catch { Fail 1 "連不到 Mac / can't reach the Mac" }
if ($resp -is [byte[]]) { $resp = [Text.Encoding]::UTF8.GetString($resp) }
$lines = $resp -split "`n"
$iv = $lines[0].Trim(); $ct = $lines[1].Trim(); $sig = $lines[2].Trim()
$hmac = New-Object Security.Cryptography.HMACSHA256 (, (Sha256Bytes "mac:$Secret"))
if ((HexOf $hmac.ComputeHash([Text.Encoding]::ASCII.GetBytes($ct))) -ne $sig) { Fail 1 '配對資料驗證失敗 / pairing data failed its check' }
$aes = [Security.Cryptography.Aes]::Create()
$aes.Mode = 'CBC'; $aes.Padding = 'PKCS7'; $aes.Key = Sha256Bytes "enc:$Secret"; $aes.IV = BytesOf $iv
$cipher = [Convert]::FromBase64String($ct)
$json = [Text.Encoding]::UTF8.GetString($aes.CreateDecryptor().TransformFinalBlock($cipher, 0, $cipher.Length))
$B = $json | ConvertFrom-Json
Ok 'Mac'; Report 1 ok

# 2. Deskflow (portable, same version as the Mac)
try {
    Get-Process deskflow-core, deskflow -ErrorAction SilentlyContinue | Stop-Process -Force
    $arch = if ($env:PROCESSOR_ARCHITECTURE -eq 'ARM64') { 'arm64' } else { 'x64' }
    $zip = Join-Path $env:TEMP "deskflow-$DESKFLOW-win-$arch-portable.zip"
    Invoke-WebRequest -UseBasicParsing -TimeoutSec 300 -OutFile $zip `
        -Uri "https://github.com/deskflow/deskflow/releases/download/v$DESKFLOW/deskflow-$DESKFLOW-win-$arch-portable.zip"
    $tmp = Join-Path $env:TEMP 'edgeflow-deskflow'
    if (Test-Path $tmp) { Remove-Item $tmp -Recurse -Force }
    Expand-Archive -Path $zip -DestinationPath $tmp -Force
    New-Item -ItemType Directory -Force -Path $Dir | Out-Null
    $dst = Join-Path $Dir 'deskflow'
    if (Test-Path $dst) { Remove-Item $dst -Recurse -Force }
    Move-Item (Get-ChildItem $tmp -Directory | Select-Object -First 1).FullName $dst
    Get-ChildItem $dst -Recurse | Unblock-File
    Remove-Item $zip -Force
} catch { Fail 2 "下載逾時，請確認這台電腦能上網 / download timed out, check this computer is online" }
Ok 'Deskflow'; Report 2 ok

# 3. Edgeflow helper
try {
    $f = 'edgeflow-helper.ps1'
    $data = (Invoke-WebRequest -UseBasicParsing -Uri "$URL/f/$f" -TimeoutSec 60).Content
    if ($data -is [string]) { $data = $Utf8.GetBytes($data) }
    if ((HexOf ([Security.Cryptography.SHA256]::Create().ComputeHash($data))) -ne $B.files.$f) { Fail 3 "$f failed its check" }
    [IO.File]::WriteAllBytes((Join-Path $Dir $f), $data)
    $device = [ordered]@{ deviceId = $B.deviceId; deviceKey = $B.deviceKey; screen = $B.screen; name = $B.name
        server = $B.server; serverHost = $B.serverHost; pairUrl = $B.pairUrl; serverFingerprint = $B.serverFingerprint; version = $B.version }
    WriteText (Join-Path $Dir 'device.json') ($device | ConvertTo-Json)
    WriteText (Join-Path $Dir 'config.json') ($B.config | ConvertTo-Json -Depth 6)
    # start at login without a console window
    $vbs = Join-Path $Dir 'edgeflow.vbs'
    WriteText $vbs ("CreateObject(""WScript.Shell"").Run ""powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File """"" + (Join-Path $Dir $f) + """"""", 0, False")
    Set-ItemProperty -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run' -Name 'Edgeflow' -Value "wscript.exe `"$vbs`""
} catch { Fail 3 "helper install failed: $($_.Exception.Message)" }
Ok 'Edgeflow helper'; Report 3 ok

# 4. certificates (this computer's, made by the Mac, and the Mac's, trusted up front) + client config
$settings = Join-Path $Dir 'deskflow\settings'
New-Item -ItemType Directory -Force -Path (Join-Path $settings 'tls') | Out-Null
WriteText (Join-Path $settings 'tls\deskflow.pem') $B.pem
WriteText (Join-Path $settings 'tls\trusted-servers') ("v2:sha256:" + $B.serverFingerprint + "`n")
$log = (Join-Path $Dir 'deskflow\deskflow.log') -replace '\\', '/'
WriteText (Join-Path $settings 'Deskflow.conf') @"
[client]
remoteHost=$($B.server)

[core]
coreMode=1
computerName=$($B.screen)

[security]
tlsEnabled=true
checkPeerFingerprints=true

[log]
toFile=true
level=Info
file=$log

[gui]
enableUpdateCheck=false
"@
Ok 'TLS'; Report 4 ok

# 5. key mapping: Ctrl/Win swap happens on the Mac; screenshots + Caps Lock are the helper's
Ok 'keys'; Report 5 ok

# 6. start the helper (it runs Deskflow) and wait for the Mac to see us
Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" | Where-Object { $_.CommandLine -like '*edgeflow-helper.ps1*' } |
    ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
$logWin = Join-Path $Dir 'deskflow\deskflow.log'
if (Test-Path $logWin) { Clear-Content $logWin }
# Start it through Task Scheduler: anything started from this window belongs to the
# terminal's job and dies when the window closes (Windows Terminal and others), and over
# SSH it would land outside the desktop. A one-time task runs it in the signed-in
# desktop session, on its own. (The Run key starts it at later logins.)
$started = $false
try {
    $tr = 'wscript.exe "' + $vbs + '"'
    schtasks /Create /TN 'Edgeflow Start' /TR $tr /SC ONCE /ST 00:00 /SD 2000/01/01 /IT /F 2>$null | Out-Null
    if ($LASTEXITCODE -eq 0) {
        schtasks /Run /TN 'Edgeflow Start' 2>$null | Out-Null
        $started = ($LASTEXITCODE -eq 0)
        Start-Sleep -Seconds 2
        schtasks /Delete /TN 'Edgeflow Start' /F 2>$null | Out-Null
    }
} catch { }
if (-not $started) { Start-Process wscript.exe -ArgumentList "`"$vbs`"" }
for ($i = 0; $i -lt 90; $i++) {
    # Deskflow writes "connected to server" only at debug level; at info it's the TLS line
    if ((Test-Path $logWin) -and (Select-String -Path $logWin -Pattern 'connected to (server|secure socket)' -Quiet)) {
        Ok "$($B.screen) <-> Mac"; Report 6 ok
        Write-Host "`n完成，可以關掉這個視窗。 / Done - you can close this window."
        exit 0
    }
    Start-Sleep -Seconds 1
}
Fail 6 "Deskflow 沒有連上 Mac / Deskflow didn't connect to the Mac"
