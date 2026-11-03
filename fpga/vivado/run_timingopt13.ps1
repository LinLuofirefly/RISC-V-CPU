param(
    [ValidateRange(6,9)][int]$CacheBits = 8,
    [ValidatePattern('^[A-Za-z0-9_]+$')][string]$BuildTag = 'coremark_dual_180MHz_timingopt13',
    [ValidatePattern('^[D-Z]:$')][string]$Drive = 'V:',
    [ValidatePattern('^timingopt[0-9]+$')][string]$OverlayName = 'timingopt13'
)
$ErrorActionPreference = 'Stop'
# WSL does not supply a Windows-style system PATH to child jobs. Vivado's
# generated runme.bat needs cscript.exe from System32 to launch synthesis.
$env:SystemRoot = 'C:\windows'
$env:WINDIR = $env:SystemRoot
$env:COMSPEC = 'C:\windows\system32\cmd.exe'
$env:PATHEXT = '.COM;.EXE;.BAT;.CMD;.VBS;.VBE;.JS;.JSE;.WSF;.WSH;.MSC'
$env:PATH = "C:\windows\system32;C:\windows;C:\windows\system32\Wbem;E:\Vivado\Vivado\2023.2\bin;$env:PATH"
if (!$env:USERPROFILE) { $env:USERPROFILE = [Environment]::GetFolderPath('UserProfile') }
$workspace = (Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
$marker = (Get-Content (Join-Path $PSScriptRoot 'workspace_id.txt') -Raw).Trim()
if (Test-Path "$Drive\") {
    $mappedMarker = "$Drive\fpga\vivado\workspace_id.txt"
    if (!(Test-Path $mappedMarker) -or (Get-Content $mappedMarker -Raw).Trim() -ne $marker) {
        throw "$Drive is already in use by another directory; choose a free drive letter."
    }
} else {
    $mapping = Start-Process -FilePath 'C:\windows\system32\subst.exe' `
        -ArgumentList "$Drive `"$workspace`"" -Wait -PassThru -NoNewWindow
    if ($mapping.ExitCode -ne 0) { throw "subst failed with exit code $($mapping.ExitCode)" }
}
if (!(Test-Path "$Drive\fpga\vivado\workspace_id.txt")) { throw 'Failed to create short workspace drive mapping.' }
try {
    $outputDir = "$Drive\vivado_runs\$BuildTag"
    if (Test-Path "$Drive\vivado_projects\$BuildTag") { throw 'BuildTag already exists; choose a fresh tag to preserve results.' }
    New-Item -ItemType Directory -Path $outputDir -Force | Out-Null
    $env:TEMP = "$outputDir\tmp"
    $env:TMP = $env:TEMP
    New-Item -ItemType Directory -Path $env:TEMP -Force | Out-Null
    $preflight = Start-Process -FilePath 'C:\windows\system32\where.exe' `
        -ArgumentList 'cscript.exe' -Wait -PassThru -NoNewWindow `
        -RedirectStandardOutput "$outputDir\windows_preflight.log"
    if ($preflight.ExitCode -ne 0) { throw 'Windows cscript.exe is missing from the child process PATH.' }
    Push-Location "$Drive\"
    try {
        $command = '/d /s /c ""E:\Vivado\Vivado\2023.2\bin\vivado.bat" -mode batch -source "{0}/fpga/vivado/build_180_timingopt13_full.tcl" -log "{1}\vivado.log" -journal "{1}\vivado.jou" -tclargs {0}/ {2} {3} {4}"' -f $Drive, $outputDir, $CacheBits, $BuildTag, $OverlayName
        $process = Start-Process -FilePath 'C:\windows\system32\cmd.exe' `
            -ArgumentList $command -WorkingDirectory "$Drive\" `
            -RedirectStandardOutput "$outputDir\stdout.log" `
            -RedirectStandardError "$outputDir\stderr.log" `
            -PassThru -NoNewWindow
        Set-Content -Path "$outputDir\windows_process.pid" -Value $process.Id
        $null = $process.Handle
        $process.WaitForExit()
        if ($process.ExitCode -ne 0) { throw "Vivado failed with exit code $($process.ExitCode); see $outputDir\stdout.log" }
        if (!(Test-Path "$outputDir\build_summary.txt")) { throw 'Vivado did not produce the final build summary.' }
    } finally { Pop-Location }
} finally {
    Start-Process -FilePath 'C:\windows\system32\subst.exe' `
        -ArgumentList "$Drive /D" -Wait -NoNewWindow
}
