#requires -Version 5.1
[CmdletBinding()]
param([switch]$Help)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0
function Get-OesUpdatedPath([string]$Current, [string]$Directory) {
    $target = [IO.Path]::GetFullPath($Directory).TrimEnd('\')
    $entries = New-Object 'System.Collections.Generic.List[string]'
    $found = $false
    foreach ($entry in @($Current -split ';')) {
        if ([string]::IsNullOrWhiteSpace($entry)) { continue }
        $normalized = [Environment]::ExpandEnvironmentVariables($entry.Trim().Trim('"')).TrimEnd('\')
        if ($normalized -ieq $target) {
            if (-not $found) { $entries.Add($Directory); $found = $true }
        } else { $entries.Add($entry) }
    }
    if (-not $found) { $entries.Add($Directory) }
    $entries -join ';'
}

function Install-OesPackage([string]$Winget, [string]$Id) {
    # winget uses HRESULT exit codes; do not treat network/source errors as "not installed".
    $output = & $Winget list --id $Id -e --source winget --accept-source-agreements --disable-interactivity 2>&1
    $code = $LASTEXITCODE
    if ($code -eq 0) { Write-Host "$Id is already installed."; return $false }
    $hex = '{0:X8}' -f ($code -band 0xffffffffL)
    if ($hex -ne '8A150014') { throw "winget list failed for $Id (0x$hex): $output" }
    Write-Host "Installing $Id. Windows may ask for administrator approval."
    & $Winget install --id $Id -e --source winget --accept-source-agreements --accept-package-agreements --disable-interactivity --silent | Out-Host
    $code = $LASTEXITCODE
    $hex = '{0:X8}' -f ($code -band 0xffffffffL)
    if ($code -eq 3010 -or $hex -in @('8A150109','8A15010A','8A15010B')) {
        Write-Warning "$Id requires a restart. Save your work and restart Windows before running oes-babl-win."
        return $true
    }
    if ($code -ne 0) { throw "winget install failed for $Id (0x$hex). Retry the command manually and inspect its output." }
    return $false
}

function Save-OesVda([string]$Tag, [string]$Stage) {
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    $expectedHash = Get-OesVdaHash $Tag
    $expectedUrl = "https://github.com/Ciantic/VirtualDesktopAccessor/releases/download/$Tag/VirtualDesktopAccessor.dll"
    $dll = Join-Path $Stage 'VirtualDesktopAccessor.dll'
    try { Invoke-WebRequest -UseBasicParsing -Uri $expectedUrl -OutFile $dll -TimeoutSec 120 }
    catch { throw "VDA download failed. Check network/proxy access to github.com and retry install.ps1. $($_.Exception.Message)" }
    $bytes = [IO.File]::ReadAllBytes($dll)
    if ($bytes.Length -lt 256 -or $bytes[0] -ne 0x4d -or $bytes[1] -ne 0x5a) {
        throw 'Downloaded VDA file is incomplete or is not a PE binary.'
    }
    $pe = [BitConverter]::ToInt32($bytes, 0x3c)
    if ($pe -lt 64 -or ($pe + 6) -gt $bytes.Length -or [BitConverter]::ToUInt32($bytes, $pe) -ne 0x4550 -or
        [BitConverter]::ToUInt16($bytes, $pe + 4) -ne 0x8664) { throw 'Downloaded VDA is not an x64 Windows DLL.' }
    $hash = (Get-FileHash -LiteralPath $dll -Algorithm SHA256).Hash
    if ($hash -ne $expectedHash) { throw 'VDA SHA256 does not match the pinned official release. Do not use this file; inspect the upstream release before updating the pin.' }
    $metadata = [ordered]@{ Tag = $Tag; Sha256 = $hash; Source = $expectedUrl }
    [IO.File]::WriteAllText((Join-Path $Stage 'vda.json'), ($metadata | ConvertTo-Json), (New-Object Text.UTF8Encoding($true)))
    Unblock-File -LiteralPath $dll
}

function Invoke-OesInstall {
    . (Join-Path $PSScriptRoot 'oes-babl-win.ps1')
    $version = Get-OesWindowsVersion
    $wingetCommand = Get-Command winget.exe -ErrorAction SilentlyContinue
    if (-not $wingetCommand) {
        throw 'winget is missing. Install/update App Installer from Microsoft Store: https://apps.microsoft.com/detail/9NBLGGH4NNS1 . Then open a new PowerShell window.'
    }
    $tag = Get-OesVdaRelease $version
    if (-not $tag) {
        Write-Warning "No approved VDA ABI for build $($version.Build).$($version.UBR). Installing the latest known DLL for storage only; run with -DesktopMode MonitorOnly."
        $tag = '2024-12-16-windows11'
    }
    if ($version.Build -lt 22000) { Write-Warning 'Windows 10 VDA cannot create/remove desktops. Use -DesktopMode MonitorOnly; see README-Windows.md.' }
    $destination = Join-Path $env:LOCALAPPDATA 'oes-babl-win'
    $config = Join-Path $env:APPDATA 'oes-babl-win'
    $mutex = New-Object Threading.Mutex($false, 'Local\oes-babl-win-session')
    $locked = $false; $stage = $null
    try {
        try { $locked = $mutex.WaitOne(0) } catch [Threading.AbandonedMutexException] { $locked = $true }
        if (-not $locked) { throw 'Close oes-babl-win or the other installer before installing.' }
        [void][IO.Directory]::CreateDirectory($destination)
        [void][IO.Directory]::CreateDirectory((Join-Path $destination 'lib'))
        [void][IO.Directory]::CreateDirectory($config)
        $stage = Join-Path $destination ('.install-' + [Guid]::NewGuid().ToString('D'))
        [void][IO.Directory]::CreateDirectory($stage)
        # Validate/download before invoking installers that may require elevation.
        Save-OesVda $tag $stage
        $restart = $false
        $vc = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\VisualStudio\14.0\VC\Runtimes\x64' -ErrorAction SilentlyContinue
        if (-not $vc -or $vc.Installed -ne 1) {
            $restart = (Install-OesPackage $wingetCommand.Source 'Microsoft.VCRedist.2015+.x64') -or $restart
        } else { Write-Host 'Visual C++ x64 Redistributable is already installed.' }
        if (@(Get-OesVddDevice).Count -eq 0) {
            $restart = (Install-OesPackage $wingetCommand.Source 'VirtualDrivers.Virtual-Display-Driver') -or $restart
        } else { Write-Host 'VDD device is already installed.' }
        foreach ($file in @('oes-babl-win.ps1', 'lib\OesNative.cs', 'README-Windows.md')) {
            $source = Join-Path $PSScriptRoot $file
            $target = Join-Path $destination $file
            if (-not (Test-Path -LiteralPath $source -PathType Leaf)) { throw "Source file missing: $source. Extract the complete project." }
            if ([IO.Path]::GetFullPath($source) -ine [IO.Path]::GetFullPath($target)) { Copy-Item -LiteralPath $source -Destination $target -Force }
        }
        foreach ($file in @('VirtualDesktopAccessor.dll', 'vda.json')) {
            Copy-Item -LiteralPath (Join-Path $stage $file) -Destination (Join-Path $destination "lib\$file") -Force
        }
        Initialize-OesNative
        Add-Type -AssemblyName System.Windows.Forms
        $dpi = [Oes.Native]::SetThreadDpiAwarenessContext([IntPtr](-4))
        if ($dpi -eq [IntPtr]::Zero) { throw 'Cannot determine primary screen with physical-pixel DPI awareness.' }
        try {
            $bounds = [Windows.Forms.Screen]::PrimaryScreen.Bounds
            if ($bounds.Width -le 0 -or $bounds.Height -le 0) { throw 'No primary screen. Run from a local interactive Windows session.' }
            [IO.File]::WriteAllText((Join-Path $config 'screen-size'), ('{0}x{1}' -f $bounds.Width,$bounds.Height), (New-Object Text.UTF8Encoding($true)))
        } finally { [void][Oes.Native]::SetThreadDpiAwarenessContext($dpi) }
        $oldPath = [Environment]::GetEnvironmentVariable('Path', 'User')
        $newPath = Get-OesUpdatedPath $oldPath $destination
        if ($oldPath -cne $newPath) { [Environment]::SetEnvironmentVariable('Path', $newPath, 'User') }
        $env:Path = Get-OesUpdatedPath $env:Path $destination
        Write-Host "Installed application files: $destination"
        if ($restart) { Write-Warning 'Installation requested a restart. Restart Windows, then rerun install.ps1 and tests\install.ps1.'; return 3010 }
        if (@(Get-OesVddDevice | Where-Object { $_.ConfigManagerErrorCode -eq 0 }).Count -eq 0) {
            throw 'Application files installed, but no ready VDD device is detected. Open Virtual Driver Control and install/enable its driver, then rerun install.ps1 and tests\install.ps1.'
        }
        Write-Host 'Open a new PowerShell window, then run: oes-babl-win.ps1 -Help'
        return 0
    } finally {
        try { if ($stage -and (Test-Path -LiteralPath $stage)) {
            # Only remove our flat staging files, not an arbitrary recursive tree.
            foreach ($name in @('VirtualDesktopAccessor.dll','vda.json')) {
                $file = Join-Path $stage $name
                if (Test-Path -LiteralPath $file) { Remove-Item -LiteralPath $file -Force }
            }
            [IO.Directory]::Delete($stage, $false)
        } } finally {
            if ($locked) { $mutex.ReleaseMutex() }
            $mutex.Dispose()
        }
    }
}

if ($MyInvocation.InvocationName -ne '.') {
    if ($Help) { Write-Output 'Usage: powershell.exe -NoProfile -File .\install.ps1 [-Verbose]'; exit 0 }
    try { $result = Invoke-OesInstall; exit ([int]$result) }
    catch { [Console]::Error.WriteLine(('install: ' + $_.Exception.Message)); exit 1 }
}
