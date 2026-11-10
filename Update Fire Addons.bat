<# :
@echo off
rem Updates the Fire addons you have installed to the latest version on GitHub.
rem Double-click to run. Only addons already in your AddOns folder are updated.
setlocal
set "FIRE_UPDATER=%~f0"
powershell -NoProfile -ExecutionPolicy Bypass -Command "Invoke-Expression ([IO.File]::ReadAllText($env:FIRE_UPDATER))"
echo.
pause
exit /b
#>

# ---------------------------------------------------------------------------
# Everything below is PowerShell (the lines above start it from a .bat file).
# ---------------------------------------------------------------------------
$ErrorActionPreference = 'Stop'
$Repo     = 'firebelley/WoWAddons'
$Branch   = 'master'
$ZipUrl   = "https://github.com/$Repo/archive/refs/heads/$Branch.zip"
$Self     = $env:FIRE_UPDATER
$SelfDir  = Split-Path -Parent $Self
$Config   = Join-Path $SelfDir 'Update Fire Addons.path.txt'

function Say($text, $color = 'Gray') { Write-Host $text -ForegroundColor $color }

Say ''
Say '  Fire addons updater' 'Yellow'
Say "  (https://github.com/$Repo)" 'DarkGray'
Say ''

# ---------------------------------------------------------------------------
# Find the AddOns folder
# ---------------------------------------------------------------------------
function Test-AddOnsFolder($path) {
    return $path -and (Test-Path -LiteralPath $path -PathType Container) -and ((Split-Path -Leaf $path) -eq 'AddOns')
}

$candidates = @()
if (Test-Path -LiteralPath $Config) { $candidates += (Get-Content -LiteralPath $Config -TotalCount 1).Trim() }
$candidates += $SelfDir # the updater can live in the AddOns folder itself
foreach ($key in 'HKLM:\SOFTWARE\WOW6432Node\Blizzard Entertainment\World of Warcraft',
                 'HKLM:\SOFTWARE\Blizzard Entertainment\World of Warcraft') {
    try {
        $install = (Get-ItemProperty -LiteralPath $key -ErrorAction Stop).InstallPath
        if ($install) {
            $root = $install.TrimEnd('\')
            if ((Split-Path -Leaf $root) -like '_*_') { $root = Split-Path -Parent $root } # e.g. ...\_retail_
            $candidates += (Join-Path $root '_forever_\Interface\AddOns')
        }
    } catch { }
}
$candidates += "${env:ProgramFiles(x86)}\World of Warcraft\_forever_\Interface\AddOns"
$candidates += "$env:ProgramFiles\World of Warcraft\_forever_\Interface\AddOns"
foreach ($drive in (Get-PSDrive -PSProvider FileSystem -ErrorAction SilentlyContinue)) {
    $candidates += (Join-Path $drive.Root 'World of Warcraft\_forever_\Interface\AddOns')
    $candidates += (Join-Path $drive.Root 'Games\World of Warcraft\_forever_\Interface\AddOns')
}

$AddOns = $candidates | Where-Object { Test-AddOnsFolder $_ } | Select-Object -First 1
while (-not $AddOns) {
    Say "Couldn't find your WoW Forever AddOns folder." 'Red'
    Say 'Paste its full path (for example C:\Games\World of Warcraft\_forever_\Interface\AddOns):'
    $answer = (Read-Host '>').Trim('" ')
    if (Test-AddOnsFolder $answer) {
        $AddOns = $answer
        Set-Content -LiteralPath $Config -Value $AddOns
    } else {
        Say "That isn't an AddOns folder." 'Red'
    }
}
Say "AddOns folder: $AddOns" 'DarkGray'

# ---------------------------------------------------------------------------
# Program Files may need admin rights to write to: ask for them if so.
# ---------------------------------------------------------------------------
$probe = Join-Path $AddOns ('.fire-updater-' + [guid]::NewGuid().ToString('N'))
try {
    [IO.File]::WriteAllText($probe, 'x')
    Remove-Item -LiteralPath $probe -Force
} catch {
    $admin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)
    if ($admin) { throw "Can't write to $AddOns even as administrator: $($_.Exception.Message)" }
    Say "Windows won't let the updater write to that folder; asking for administrator rights..." 'Yellow'
    Start-Process -FilePath 'cmd.exe' -ArgumentList '/c', "`"`"$Self`"`"" -Verb RunAs
    return
}

# ---------------------------------------------------------------------------
# Download the latest version
# ---------------------------------------------------------------------------
$work = Join-Path ([IO.Path]::GetTempPath()) ('FireAddons-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $work | Out-Null
try {
    Say 'Downloading the latest version...'
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    $zip = Join-Path $work 'latest.zip'
    $ProgressPreference = 'SilentlyContinue' # the progress bar makes downloads very slow in Windows PowerShell
    Invoke-WebRequest -Uri $ZipUrl -OutFile $zip -UseBasicParsing
    Expand-Archive -LiteralPath $zip -DestinationPath (Join-Path $work 'x')
    $source = Get-ChildItem -LiteralPath (Join-Path $work 'x') -Directory | Select-Object -First 1

    # An addon is a top-level folder with a .toc file named after it.
    $available = Get-ChildItem -LiteralPath $source.FullName -Directory |
        Where-Object { Test-Path -LiteralPath (Join-Path $_.FullName ($_.Name + '.toc')) }

    function Get-Version($folder, $name) {
        $toc = Join-Path $folder "$name.toc"
        if (Test-Path -LiteralPath $toc) {
            $line = Get-Content -LiteralPath $toc | Where-Object { $_ -match '^##\s*Version:\s*(.+)$' } | Select-Object -First 1
            if ($line -match '^##\s*Version:\s*(.+)$') { return $Matches[1].Trim() }
        }
        return '?'
    }

    # "relative path = hash" for every file, to tell whether anything changed.
    function Get-Fingerprint($folder) {
        $base = (Get-Item -LiteralPath $folder).FullName.TrimEnd('\') + '\' # same path form as the files below
        $lines = Get-ChildItem -LiteralPath $folder -Recurse -File | Sort-Object FullName | ForEach-Object {
            $_.FullName.Substring($base.Length) + '=' + (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash
        }
        return ($lines -join "`n")
    }

    Say ''
    $updated = 0; $current = 0; $installed = 0
    foreach ($addon in $available) {
        $name = $addon.Name
        $target = Join-Path $AddOns $name
        if (-not (Test-Path -LiteralPath $target)) { continue } # not installed: opt-in by installing it once by hand
        $installed++

        $item = Get-Item -LiteralPath $target -Force
        if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) {
            Say ("  {0,-14} skipped (linked to a development copy)" -f $name) 'DarkGray'
            continue
        }

        if ((Get-Fingerprint $target) -eq (Get-Fingerprint $addon.FullName)) {
            Say ("  {0,-14} up to date ({1})" -f $name, (Get-Version $target $name)) 'Gray'
            $current++
            continue
        }

        $old = Get-Version $target $name
        $new = Get-Version $addon.FullName $name
        Remove-Item -LiteralPath $target -Recurse -Force
        Copy-Item -LiteralPath $addon.FullName -Destination $target -Recurse
        $change = if ($old -ne $new) { "$old -> $new" } else { $new }
        Say ("  {0,-14} updated ({1})" -f $name, $change) 'Green'
        $updated++
    }

    Say ''
    if ($installed -eq 0) {
        Say "None of the Fire addons are installed in $AddOns yet." 'Yellow'
        Say "To install one, download it from https://github.com/$Repo (Code > Download ZIP),"
        Say 'and copy the addon folders you want (for example FireBags) into your AddOns folder.'
        Say 'After that, this updater keeps them up to date.'
    } elseif ($updated -gt 0) {
        Say "$updated addon(s) updated." 'Green'
        if (Get-Process -Name 'Wow*' -ErrorAction SilentlyContinue) {
            Say 'WoW is running: type /reload in game to load the new version.' 'Yellow'
        }
    } else {
        Say 'Everything is up to date.' 'Green'
    }

    $notInstalled = $available | Where-Object { -not (Test-Path -LiteralPath (Join-Path $AddOns $_.Name)) } | ForEach-Object Name
    if ($notInstalled -and $installed -gt 0) {
        Say ("Also available (not installed): " + ($notInstalled -join ', ')) 'DarkGray'
    }
    if (Test-Path -LiteralPath (Join-Path $AddOns "WoWAddons-$Branch")) {
        Say ''
        Say "Note: there's a 'WoWAddons-$Branch' folder in AddOns. WoW can't load addons from inside it -" 'Yellow'
        Say 'move the addon folders out of it into AddOns itself.' 'Yellow'
    }
} catch {
    Say ''
    Say "Update failed: $($_.Exception.Message)" 'Red'
} finally {
    Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
}
