# Windows entry point. The prompts and progress bar live in gallium_recover.py.
$ErrorActionPreference = "Stop"
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$target = Join-Path $here "gallium_recover.py"
$release = Join-Path $here "python-release.txt"
if (-not (Test-Path $target)) {
  Write-Error "gallium_recover.py was not found next to this script."
  exit 1
}

function Test-Python3([string]$exe) {
  if (-not (Test-Path $exe) -and -not (Get-Command $exe -ErrorAction SilentlyContinue)) {
    return $false
  }
  try {
    & $exe -c "import sys; raise SystemExit(0 if sys.version_info[0] >= 3 else 1)"
    if ($LASTEXITCODE -eq 0) {
      return $true
    }
  } catch {
    return $false
  }
  return $false
}

function Read-PythonRelease([string]$system, [string]$machine) {
  $script:PythonVersion = ""
  $script:PythonBase = ""
  $script:PythonFile = ""
  $script:PythonSha = ""
  if (-not (Test-Path $release)) {
    Write-Error "python-release.txt was not found next to this script."
    exit 1
  }
  $lines = Get-Content $release
  for ($i = 0; $i -lt $lines.Count; $i++) {
    $line = $lines[$i]
    if ($line.StartsWith("version ")) {
      $script:PythonVersion = $line.Substring(8)
    } elseif ($line.StartsWith("base ")) {
      $script:PythonBase = $line.Substring(5)
    } else {
      $parts = $line.Split(" ")
      if ($parts.Length -eq 4 -and $parts[0] -eq $system -and $parts[1] -eq $machine) {
        $script:PythonFile = $parts[2]
        $script:PythonSha = $parts[3]
      }
    }
  }
}

function Install-Python() {
  $machine = $env:PROCESSOR_ARCHITEW6432
  if (-not $machine) {
    $machine = $env:PROCESSOR_ARCHITECTURE
  }
  Read-PythonRelease "Windows" $machine
  if (-not $script:PythonFile -or -not $script:PythonSha -or -not $script:PythonVersion -or -not $script:PythonBase) {
    Write-Error "Automatic Python install is not available for Windows $machine.`nInstall Python 3, then run this script again."
    exit 1
  }
  $curl = Get-Command curl.exe -ErrorAction SilentlyContinue
  if (-not $curl) {
    Write-Error "curl is required to download Python."
    exit 1
  }
  Write-Output "Python 3 was not found."
  Write-Output "The script will download Python $($script:PythonVersion) into your home folder at .gallium-recovery/python."
  $answer = Read-Host "Install Python $($script:PythonVersion)? [y/N]"
  if ($answer -ne "y" -and $answer -ne "Y") {
    Write-Error "Stopped. Python was not installed."
    exit 1
  }
  $dest = Join-Path $env:USERPROFILE ".gallium-recovery\python"
  $parent = Split-Path -Parent $dest
  New-Item -ItemType Directory -Force -Path $parent | Out-Null
  $work = Join-Path ([System.IO.Path]::GetTempPath()) ("gallium-python-" + [System.Guid]::NewGuid().ToString("N"))
  New-Item -ItemType Directory -Force -Path $work | Out-Null
  $archive = Join-Path $work "python.tar.gz"
  $encoded = $script:PythonFile.Replace("+", "%2B")
  $url = "$($script:PythonBase)/$encoded"
  Write-Output "Downloading Python $($script:PythonVersion)..."
  & curl.exe -fL --progress-bar -o $archive $url
  if ($LASTEXITCODE -ne 0) {
    Remove-Item -Recurse -Force $work
    Write-Error "Could not download Python."
    exit 1
  }
  $got = (Get-FileHash -Algorithm SHA256 -Path $archive).Hash.ToLower()
  if ($got -ne $script:PythonSha) {
    Remove-Item -Recurse -Force $work
    Write-Error "Python download did not match the published checksum."
    exit 1
  }
  & tar.exe -xzf $archive -C $work
  if ($LASTEXITCODE -ne 0) {
    Remove-Item -Recurse -Force $work
    Write-Error "Could not unpack Python."
    exit 1
  }
  if (Test-Path $dest) {
    Remove-Item -Recurse -Force $dest
  }
  Copy-Item -Path (Join-Path $work "python") -Destination $dest -Recurse
  Remove-Item -Recurse -Force $work
  Write-Output "Installed Python $($script:PythonVersion)."
}

$python = $null
$names = @("python3", "python", "py")
for ($i = 0; $i -lt $names.Count; $i++) {
  $cmd = Get-Command $names[$i] -ErrorAction SilentlyContinue
  if ($cmd -and (Test-Python3 $cmd.Source)) {
    $python = $cmd.Source
    break
  }
}
$bundledCandidates = @(
  (Join-Path $env:USERPROFILE ".gallium-recovery\python\python.exe"),
  (Join-Path $env:USERPROFILE ".gallium-recovery\python\bin\python.exe")
)
if (-not $python) {
  for ($i = 0; $i -lt $bundledCandidates.Count; $i++) {
    if (Test-Python3 $bundledCandidates[$i]) {
      $python = $bundledCandidates[$i]
      break
    }
  }
}
if (-not $python) {
  Install-Python
  $python = Join-Path $env:USERPROFILE ".gallium-recovery\python\python.exe"
  if (-not (Test-Path $python)) {
    $python = Join-Path $env:USERPROFILE ".gallium-recovery\python\bin\python.exe"
  }
}
if (-not (Test-Python3 $python)) {
  Write-Error "Python 3 is still not available."
  exit 1
}

& $python $target @args
exit $LASTEXITCODE
