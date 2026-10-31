#requires -Version 5.1
[CmdletBinding()]
param([switch]$SelfTest)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0
$root = Split-Path $PSScriptRoot -Parent
$scratchRoot = Join-Path ([IO.Path]::GetTempPath()) 'oes-babl-win-install-tests'
$scratch = Join-Path $scratchRoot ([Guid]::NewGuid().ToString('D'))

function Assert([bool]$Condition, [string]$Message) { if (-not $Condition) { throw $Message } }
function Test-OesInstallation([string]$Directory, [string]$Config, [string]$UserPath) {
    foreach ($file in @('oes-babl-win.ps1', 'README-Windows.md', 'lib\OesNative.cs', 'lib\VirtualDesktopAccessor.dll', 'lib\vda.json')) {
        Assert (Test-Path -LiteralPath (Join-Path $Directory $file) -PathType Leaf) "Installed file missing: $file. Run install.ps1."
    }
    $matches = @($UserPath -split ';' | Where-Object {
        [Environment]::ExpandEnvironmentVariables($_.Trim().Trim('"')).TrimEnd('\') -ieq $Directory.TrimEnd('\')
    })
    Assert ($matches.Count -eq 1) 'User PATH must contain the installation directory exactly once.'
    $sizePath = Join-Path $Config 'screen-size'
    Assert (Test-Path -LiteralPath $sizePath) 'Saved screen-size is missing.'
    $size = (Get-Content -LiteralPath $sizePath -Raw).Trim()
    Assert ($size -match '^[1-9]\d{0,4}x[1-9]\d{0,4}$') 'screen-size must contain positive WIDTHxHEIGHT.'
    $metadata = Get-Content -LiteralPath (Join-Path $Directory 'lib\vda.json') -Raw | ConvertFrom-Json
    Assert ((Get-FileHash -LiteralPath (Join-Path $Directory 'lib\VirtualDesktopAccessor.dll') -Algorithm SHA256).Hash -eq $metadata.Sha256) 'Installed VDA hash does not match vda.json.'
}

try {
    . (Join-Path $root 'oes-babl-win.ps1')
    . (Join-Path $root 'install.ps1')
    if ($SelfTest) {
        # Fixtures test the checker and PATH idempotence; this does not install a driver.
        [void][IO.Directory]::CreateDirectory((Join-Path $scratch 'lib'))
        foreach ($file in @('oes-babl-win.ps1', 'README-Windows.md', 'lib\OesNative.cs', 'lib\VirtualDesktopAccessor.dll')) {
            Set-Content -LiteralPath (Join-Path $scratch $file) -Value 'fixture only' -Encoding UTF8
        }
        $hash = (Get-FileHash -LiteralPath (Join-Path $scratch 'lib\VirtualDesktopAccessor.dll') -Algorithm SHA256).Hash
        @{Sha256=$hash} | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $scratch 'lib\vda.json') -Encoding UTF8
        Set-Content -LiteralPath (Join-Path $scratch 'screen-size') -Value '1920x1080' -Encoding UTF8
        $path = Get-OesUpdatedPath "C:\Windows;$scratch;$($scratch.ToUpperInvariant())\" $scratch
        Assert ((Get-OesUpdatedPath $path $scratch) -ceq $path) 'Repeated installation would modify PATH again.'
        Test-OesInstallation $scratch $scratch $path
        Set-Content -LiteralPath (Join-Path $scratch 'screen-size') -Value '0x1080' -Encoding UTF8
        $failed = $false
        try { Test-OesInstallation $scratch $scratch $path } catch { $failed = $_.Exception.Message -match 'positive' }
        Assert $failed 'Checker accepted an invalid saved size.'
        Write-Host 'Fixture checks only; real installation has not been tested by -SelfTest.'
    } else {
        $installDirectory = Join-Path $env:LOCALAPPDATA 'oes-babl-win'
        Test-OesInstallation $installDirectory (Join-Path $env:APPDATA 'oes-babl-win') ([Environment]::GetEnvironmentVariable('Path','User'))
        Assert-OesVddInstalled
        Initialize-OesNative
        Assert (@([Oes.Native]::Displays() | Where-Object { $_.IsVdd }).Count -gt 0) 'VDD has no display endpoint. Add a monitor in Virtual Driver Control.'
        $vc = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\VisualStudio\14.0\VC\Runtimes\x64' -ErrorAction SilentlyContinue
        Assert ($null -ne $vc -and $vc.Installed -eq 1) 'VC++ x64 runtime is missing.'
        $version = Get-OesWindowsVersion
        if ($version.Build -ge 22000 -and (Get-OesVdaRelease $version)) {
            $desktopApi = $null
            try { $desktopApi = Open-OesDesktops $version; [void]$desktopApi.Current() }
            finally { if ($desktopApi) { $desktopApi.Dispose() } }
        } else { Write-Warning 'Only MonitorOnly is supported on this Windows build; no desktop automation smoke test.' }
    }
    Write-Output 'Test passed.'
    exit 0
} catch {
    [Console]::Error.WriteLine(('Test failed: ' + $_.Exception.Message))
    exit 1
} finally {
    if ((Get-Command Remove-OesTemporaryProfile -ErrorAction SilentlyContinue) -and (Test-Path -LiteralPath $scratch)) {
        Remove-OesTemporaryProfile $scratch $scratchRoot
    }
}
