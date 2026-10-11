# Mythic Boss Records - tools (run by "MBR Tools.cmd" or the Windows task, every minute)
#   -Action import   read the new part of your WoWCombatLog.txt -> LocalLogData.lua (shared by the addon)
#   -Action update   install the newest addon version (from the GitHub page in update-source.txt)
#   -Action auto     what the scheduled task runs, silently: update check every minute,
#                    combat log import every 15 minutes
#   -FromStart       read the whole combat log again
# Nothing is ever sent anywhere: the log is read on your PC, the addon shares the results in game.
param([string]$Action = 'auto', [switch]$FromStart)
$ErrorActionPreference = 'Stop'

$Tools    = $PSScriptRoot
$AddonDir = Split-Path -Parent $Tools
$WowDir   = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $AddonDir))   # ...\Interface\AddOns\MythicBossRecords
$DataDir  = Join-Path $env:LOCALAPPDATA 'MythicBossRecords'
$LogFile  = Join-Path $DataDir 'tools.log'
if (-not (Test-Path $DataDir)) { New-Item -ItemType Directory -Path $DataDir | Out-Null }

function Log($msg) {
    Write-Host $msg
    try {
        if ((Test-Path $LogFile) -and (Get-Item $LogFile).Length -gt 200KB) { Remove-Item $LogFile -Force }
        Add-Content -Path $LogFile -Value ((Get-Date -Format 'yyyy-MM-dd HH:mm') + '  ' + $msg) -Encoding UTF8
    } catch {}
}

# ---------------------------------------------------------------- combat log
function Find-CombatLog {
    $override = Join-Path $Tools 'combatlog-path.txt'
    if (Test-Path $override) { return (Get-Content $override -TotalCount 1).Trim() }
    return (Join-Path $WowDir 'Logs\WoWCombatLog.txt')
}

# the addon shows this when "Sync logs" finds nothing (ToolsStatus.lua, loaded at login / reload)
function Write-Status($text) {
    try {
        $t = $text.Replace('\', '\\').Replace('"', "'")
        $lua = "local ADDON, ns = ...`r`nns.TOOLS_STATUS = { time = " + [DateTimeOffset]::UtcNow.ToUnixTimeSeconds() + ', text = "' + $t + '" }' + "`r`n"
        [IO.File]::WriteAllText((Join-Path $AddonDir 'ToolsStatus.lua'), $lua, (New-Object Text.UTF8Encoding($false)))
    } catch {}
}

function Import-CombatLog {
    $log = Find-CombatLog
    if (-not (Test-Path $log)) {
        Log "No combat log yet ($log). In game type /combatlog before a key, then run this again."
        Write-Status "No combat log found at $log. Type /combatlog in game before a key. If your WoW writes it somewhere else, put the full path of WoWCombatLog.txt in Tools\combatlog-path.txt."
        return $true
    }
    if (-not ('MBRLogImport' -as [type])) {
        Add-Type -TypeDefinition ([IO.File]::ReadAllText((Join-Path $Tools 'LogImport.cs'))) -Language CSharp
    }
    $out = Join-Path $AddonDir 'LocalLogData.lua'
    $t = [Diagnostics.Stopwatch]::StartNew()
    $summary = [MBRLogImport]::Run($log, $DataDir, $out, [bool]$FromStart)
    Log ("Combat log: {0} ({1:0}s). /reload in WoW to load it." -f $summary, $t.Elapsed.TotalSeconds)
    Write-Status ("Combat log " + $log + ": " + $summary)
    return $true
}

# ---------------------------------------------------------------- addon update
function Get-LocalVersion {
    $core = Join-Path $AddonDir 'Core.lua'
    $m = [regex]::Match([IO.File]::ReadAllText($core), 'ns\.VERSION\s*=\s*"([^"]+)"')
    if ($m.Success) { return $m.Groups[1].Value } else { return '0' }
}
function VersionNum($v) { $p = ($v -replace '[^0-9.]', '').Split('.') + @('0', '0', '0'); return [int]$p[0] * 10000 + [int]$p[1] * 100 + [int]$p[2] }

function Update-Addon {
    $srcFile = Join-Path $Tools 'update-source.txt'
    if (-not (Test-Path $srcFile)) { Log 'Updates are not set up (Tools\update-source.txt is missing).'; return $true }
    $repo = (Get-Content $srcFile -TotalCount 1).Trim()
    if ($repo -eq '' -or $repo -like '*OWNER*') { Log 'Updates are not set up yet (no release page in Tools\update-source.txt).'; return $true }
    $current = Get-LocalVersion
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    $hdr = @{ 'User-Agent' = 'MBR-Tools' }
    $latest = $null; $zipUrl = $null
    # 1) the repository itself: version from Core.lua, MythicBossRecords.zip on the main branch
    if ($repo -notlike 'http*') {
        try {
            $raw = "https://raw.githubusercontent.com/$repo/main"
            $core = (Invoke-WebRequest -Uri "$raw/MythicBossRecords/Core.lua" -Headers $hdr -UseBasicParsing -TimeoutSec 30).Content
            if ($core -is [byte[]]) { $core = [Text.Encoding]::UTF8.GetString($core) }
            $m = [regex]::Match($core, 'ns\.VERSION\s*=\s*"([^"]+)"')
            if ($m.Success) { $latest = $m.Groups[1].Value; $zipUrl = "$raw/MythicBossRecords.zip" }
        } catch {}
    }
    # 2) otherwise the latest GitHub release (tag vX.Y + a zip file)
    if (-not $zipUrl) {
        $api = if ($repo -like 'http*') { $repo } else { "https://api.github.com/repos/$repo/releases/latest" }
        $release = Invoke-RestMethod -Uri $api -Headers $hdr -TimeoutSec 60
        $asset = $release.assets | Where-Object { $_.name -like '*.zip' } | Select-Object -First 1
        if ($asset) { $latest = ($release.tag_name -replace '^[vV]', ''); $zipUrl = $asset.browser_download_url }
    }
    if (-not $zipUrl) { throw 'no release found' }
    if ((VersionNum $latest) -le (VersionNum $current)) {
        if ($Action -ne 'auto') { Log "Addon is up to date (V.$current)." }    # not every minute in the log
        return $true
    }
    $work = Join-Path ([IO.Path]::GetTempPath()) ('mbr-update-' + [guid]::NewGuid())
    try {
        New-Item -ItemType Directory -Path $work | Out-Null
        $zip = Join-Path $work 'addon.zip'
        Invoke-WebRequest -Uri $zipUrl -Headers $hdr -OutFile $zip -UseBasicParsing -TimeoutSec 300
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        [IO.Compression.ZipFile]::ExtractToDirectory($zip, (Join-Path $work 'x'))
        $src = Join-Path $work 'x\MythicBossRecords'
        if (-not (Test-Path (Join-Path $src 'MythicBossRecords.toc'))) { throw 'the download does not contain the MythicBossRecords addon' }
        # copy over this folder; your own combat-log data and settings stay
        Get-ChildItem $src -Recurse -File | ForEach-Object {
            $rel = $_.FullName.Substring($src.Length + 1) -replace '/', '\'
            if ($rel -eq 'LocalLogData.lua' -or $rel -eq 'ToolsStatus.lua' -or $rel -eq 'Tools\update-source.txt' -or $rel -eq 'Tools\combatlog-path.txt') { return }
            $dest = Join-Path $AddonDir $rel
            $dir = Split-Path -Parent $dest
            if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir | Out-Null }
            if ($rel -eq 'MBR Tools.cmd') { $dest = "$dest.new" }      # the running menu is swapped in by itself
            Copy-Item $_.FullName $dest -Force
        }
        Log "Addon updated from V.$current to V.$latest. Restart WoW to load it."
    } finally {
        if (Test-Path $work) { Remove-Item $work -Recurse -Force -ErrorAction SilentlyContinue }
    }
    return $true
}

# ---------------------------------------------------------------- schedule
# older versions ran every 15 minutes: switch an existing task to every minute (once)
function Set-Schedule {
    $mark = Join-Path $DataDir 'schedule-1min.txt'
    if (Test-Path $mark) { return }
    $task = 'MythicBossRecords Tools'
    & schtasks.exe /Query /TN $task 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) { return }                     # automatic is off: leave it off
    $vbs = Join-Path $Tools 'run-hidden.vbs'
    & schtasks.exe /Create /F /TN $task /SC MINUTE /MO 1 /TR "wscript.exe \"$vbs\"" 2>&1 | Out-Null
    if ($LASTEXITCODE -eq 0) { Set-Content -Path $mark -Value (Get-Date -Format s); Log 'Automatic: update check every minute now.' }
}

# ---------------------------------------------------------------- main
$ok = $true
try {
    switch ($Action) {
        'import' { $ok = Import-CombatLog }
        'update' { $ok = Update-Addon }
        default  {
            try { Set-Schedule } catch {}
            # the menu could not replace itself while it was open: do it now
            $newCmd = Join-Path $AddonDir 'MBR Tools.cmd.new'
            if (Test-Path $newCmd) { try { Move-Item $newCmd (Join-Path $AddonDir 'MBR Tools.cmd') -Force } catch {} }
            $before = Get-LocalVersion
            try { [void](Update-Addon) } catch { $ok = $false }      # every minute (errors: no internet, etc.)
            if ((Get-LocalVersion) -ne $before) { Remove-Item (Join-Path $DataDir 'lastimport.txt') -ErrorAction SilentlyContinue }
            # combat log: every 15 minutes (it reads only the new part)
            $stamp = Join-Path $DataDir 'lastimport.txt'
            $due = -not (Test-Path $stamp) -or ((Get-Date) - (Get-Item $stamp).LastWriteTime).TotalMinutes -ge 14.5
            if ($due -or $FromStart) {
                Set-Content -Path $stamp -Value (Get-Date -Format s)
                try { [void](Import-CombatLog) } catch { Log ('Combat log import failed: ' + $_.Exception.Message); Write-Status ('Combat log import failed: ' + $_.Exception.Message); $ok = $false }
            }
        }
    }
} catch {
    Log ('Failed: ' + $_.Exception.Message)
    $ok = $false
}
if ($ok) { exit 0 } else { exit 1 }
