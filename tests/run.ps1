#requires -Version 5.1
[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0
$root = Split-Path $PSScriptRoot -Parent
$scratchRoot = Join-Path ([IO.Path]::GetTempPath()) 'oes-babl-win-tests'
$scratch = Join-Path $scratchRoot ([Guid]::NewGuid().ToString('D'))
$job = $null

function Assert([bool]$Condition, [string]$Message) { if (-not $Condition) { throw $Message } }
function Assert-Throws([scriptblock]$Action, [string]$Pattern) {
    $caught = $null
    try { & $Action | Out-Null } catch { $caught = $_.Exception.Message }
    Assert ($null -ne $caught -and $caught -match $Pattern) "Expected error '$Pattern', got '$caught'."
}
function Invoke-Child([string]$Arguments) {
    $start = New-Object Diagnostics.ProcessStartInfo
    $start.FileName = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $start.Arguments = '-NoProfile -NonInteractive -ExecutionPolicy Bypass ' + $Arguments
    $start.UseShellExecute = $false; $start.CreateNoWindow = $true
    $start.RedirectStandardOutput = $true; $start.RedirectStandardError = $true
    $process = [Diagnostics.Process]::Start($start)
    try {
        $stdout = $process.StandardOutput.ReadToEndAsync()
        $stderr = $process.StandardError.ReadToEndAsync()
        if (-not $process.WaitForExit(30000)) { $process.Kill(); throw 'Test child timed out.' }
        [pscustomobject]@{ Code = $process.ExitCode; Text = $stdout.Result + $stderr.Result }
    } finally { $process.Dispose() }
}
try {
    foreach ($script in @(Get-ChildItem -LiteralPath $root -Filter '*.ps1' -Recurse)) {
        $tokens = $null; $errors = $null
        [void][Management.Automation.Language.Parser]::ParseFile($script.FullName, [ref]$tokens, [ref]$errors)
        Assert ($errors.Count -eq 0) ("Parse errors in " + $script.Name + ': ' + ($errors -join '; '))
        $bytes = [IO.File]::ReadAllBytes($script.FullName)
        Assert ($bytes.Length -ge 3 -and $bytes[0] -eq 239 -and $bytes[1] -eq 187 -and $bytes[2] -eq 191) "Missing UTF-8 BOM: $script"
    }
    . (Join-Path $root 'oes-babl-win.ps1')
    foreach ($file in @('lib\OesNative.cs','README-Windows.md','.gitignore')) {
        $bytes = [IO.File]::ReadAllBytes((Join-Path $root $file))
        Assert ($bytes.Length -ge 3 -and $bytes[0] -eq 239 -and $bytes[1] -eq 187 -and $bytes[2] -eq 191) "Missing UTF-8 BOM: $file"
    }
    [void][IO.Directory]::CreateDirectory($scratch)
    $helpResult = Invoke-Child ('-File ' + (ConvertTo-OesArgument (Join-Path $root 'oes-babl-win.ps1')) + ' -Help')
    Assert ($helpResult.Code -eq 0 -and $helpResult.Text -match 'Usage:' -and $helpResult.Text -match 'OES_BABL_SIZE') 'Help failed.'
    $saved = Join-Path $scratch 'screen-size'
    Assert ((Resolve-OesSize '' '' $saved).Width -eq 1920) 'Default size failed.'
    Set-Content -LiteralPath $saved -Value '1600x900' -Encoding UTF8
    Assert ((Resolve-OesSize '' '' $saved).Width -eq 1600) 'Saved size failed.'
    Assert ((Resolve-OesSize '' '1280x720' $saved).Width -eq 1280) 'Environment priority failed.'
    Assert ((Resolve-OesSize '1024x768' '1280x720' $saved).Width -eq 1024) 'Explicit size priority failed.'
    Assert-Throws { Resolve-OesSize '0x1080' '' $saved } 'Invalid size'
    Assert-Throws { Resolve-OesSize '-1x5' '' $saved } 'Invalid size'
    Assert-Throws { Resolve-OesSize '99999x1080' '' $saved } '16384'
    Set-Content -LiteralPath $saved -Value 'broken' -Encoding UTF8
    Assert ((Resolve-OesSize '' '' $saved -WarningAction SilentlyContinue).Width -eq 1920) 'Corrupt saved size fallback failed.'
    Assert ((Resolve-OesProfile 'Default' $false 'Profile 1') -eq 'Profile 1') 'Profile environment failed.'
    Assert ((Resolve-OesProfile 'Default' $true 'Profile 1') -eq 'Default') 'Explicit profile failed.'
    Assert-Throws { Resolve-OesProfile '..\secret' $true '' } 'directory name'
    Assert ((Get-OesVdaRelease ([pscustomobject]@{Build=17763;UBR=0})) -eq '2019-windows10') 'Win10 selection failed.'
    Assert (-not (Get-OesVdaRelease ([pscustomobject]@{Build=26100;UBR=100}))) 'Unsafe early 24H2 ABI accepted.'
    Assert ((Get-OesVdaRelease ([pscustomobject]@{Build=26100;UBR=2605})) -eq '2024-12-16-windows11') '24H2 selection failed.'
    Assert (-not (Get-OesVdaRelease ([pscustomobject]@{Build=99999;UBR=0}))) 'Unknown future ABI accepted.'
    $physical = [pscustomobject]@{Name='physical';IsVdd=$false;Primary=$false}
    $vdd = [pscustomobject]@{Name='vdd';IsVdd=$true;Primary=$false}
    Assert-Throws { Select-OesDisplay @($physical) '' } 'No verified VDD'
    Assert ((Select-OesDisplay @($physical,$vdd) '').Name -eq 'vdd') 'VDD adapter selection failed.'
    Assert-Throws { Select-OesDisplay @($vdd,$vdd) '' } 'Several VDD'
    $vdd.Primary = $true
    Assert-Throws { Select-OesDisplay @($vdd) '' } 'primary'
    $target = [pscustomobject]@{Name='vdd';Primary=$false;Active=$true;Mode=[pscustomobject]@{X=-1920;Y=0;Width=1920;Height=1080}}
    $other = [pscustomobject]@{Name='physical';Primary=$true;Active=$true;Mode=[pscustomobject]@{X=0;Y=0;Width=1920;Height=1080}}
    Assert-OesDisplayLayout $target @($target,$other)
    $other.Mode.X = -500
    Assert-Throws { Assert-OesDisplayLayout $target @($target,$other) } 'overlaps/mirrors'

    # Ошибка отсутствующего VDD в отдельном процессе / deterministic without uninstalling a driver.
    $harness = Join-Path $scratch 'no-vdd.ps1'
    $source = (Join-Path $root 'oes-babl-win.ps1').Replace("'", "''")
    @"
. '$source'
function Get-OesWindowsVersion { [pscustomobject]@{ Build=26100; UBR=2605 } }
function Get-OesVddDevice { @() }
try { Invoke-OesRun -TargetUrl https://example.com -TargetProfile Default -TargetSize 1920x1080 -Mode Required }
catch { [Console]::Error.WriteLine(('oes-babl-win: ' + `$_.Exception.Message)); exit 1 }
exit 0
"@ | Set-Content -LiteralPath $harness -Encoding UTF8
    $missing = Invoke-Child ('-File ' + (ConvertTo-OesArgument $harness))
    Assert ($missing.Code -eq 1 -and $missing.Text -match 'VDD is not installed' -and
        $missing.Text -match 'winget install --id=VirtualDrivers.Virtual-Display-Driver') 'Missing VDD did not produce an actionable error.'

    # Проверяем реальный ABI Win32 и владение процессами, без Chrome/смены дисплеев.
    Initialize-OesNative
    Assert ([Runtime.InteropServices.Marshal]::SizeOf([type][Oes.Mode]) -eq 220) 'DEVMODE layout is incorrect.'
    Assert ([Runtime.InteropServices.Marshal]::SizeOf([type][Oes.DisplayDevice]) -eq 840) 'DISPLAY_DEVICE layout is incorrect.'
    Assert (@([Oes.Native]::Displays()).Count -gt 0) 'Native display enumeration failed.'
    $center = Get-OesPreviewPoint 1000 800 1920 1080 500 400
    Assert ($center.X -eq 960 -and $center.Y -eq 540) 'Preview scaling is incorrect.'
    Assert ($null -eq (Get-OesPreviewPoint 1000 800 1920 1080 500 0)) 'Letterbox click must be ignored.'
    $preview = New-OesPreview ([pscustomobject]@{Mode=[pscustomobject]@{Width=320;Height=240;X=0;Y=0}}) -Hidden
    try {
        Assert ($preview.Bitmap.Width -eq 320 -and -not $preview.Form.Visible) 'Preview resource initialization failed.'
    } finally { $preview.Form.Dispose(); $preview.Bitmap.Dispose() }
    $helper = Join-Path $scratch 'job-helper.ps1'
    $childPidFile = Join-Path $scratch 'child.txt'
    @'
$child = Start-Process powershell.exe -WindowStyle Hidden -PassThru -ArgumentList '-NoProfile -NonInteractive -Command Start-Sleep -Seconds 60'
$child.Id | Set-Content -LiteralPath $args[0]
Start-Sleep -Seconds 60
'@ | Set-Content -LiteralPath $helper -Encoding UTF8
    $argsLine = '-NoProfile -NonInteractive -ExecutionPolicy Bypass -File ' + (ConvertTo-OesArgument $helper) + ' ' + (ConvertTo-OesArgument $childPidFile)
    $job = New-Object Oes.ChromeJob -ArgumentList (Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'),$argsLine
    $deadline = [DateTime]::UtcNow.AddSeconds(15)
    while (-not (Test-Path -LiteralPath $childPidFile) -and [DateTime]::UtcNow -lt $deadline) { Start-Sleep -Milliseconds 100 }
    Assert (Test-Path -LiteralPath $childPidFile) 'Job helper did not start.'
    $childId = [int](Get-Content -LiteralPath $childPidFile -Raw)
    Assert ($job.ActiveCount -ge 2) 'Child process escaped the job.'
    $parentId = $job.ProcessId
    $job.Dispose(); $job = $null
    $deadline = [DateTime]::UtcNow.AddSeconds(5)
    while ((Get-Process -Id $parentId,$childId -ErrorAction SilentlyContinue) -and [DateTime]::UtcNow -lt $deadline) { Start-Sleep -Milliseconds 100 }
    Assert (-not (Get-Process -Id $parentId,$childId -ErrorAction SilentlyContinue)) 'Kill-on-close left owned processes alive.'
    $outside = Join-Path $scratch 'outside'
    [void][IO.Directory]::CreateDirectory($outside)
    Assert-Throws { Remove-OesTemporaryProfile $outside $scratch } 'Refusing'
    Assert (Test-Path -LiteralPath $outside) 'Unsafe deletion occurred.'
    $owned = Join-Path $scratch ([Guid]::NewGuid().ToString('D'))
    [void][IO.Directory]::CreateDirectory($owned)
    Set-Content -LiteralPath (Join-Path $owned 'private-data') -Value 'test only'
    Remove-OesTemporaryProfile $owned $scratch
    Assert (-not (Test-Path -LiteralPath $owned)) 'Owned temporary profile was not deleted.'
    Write-Output 'Test passed.'
    exit 0
} catch {
    [Console]::Error.WriteLine(('Test failed: ' + $_.Exception.Message))
    exit 1
} finally {
    if ($job) { $job.Dispose() }
    if ((Get-Command Remove-OesTemporaryProfile -ErrorAction SilentlyContinue) -and (Test-Path -LiteralPath $scratch)) {
        Remove-OesTemporaryProfile $scratch $scratchRoot
    }
}
