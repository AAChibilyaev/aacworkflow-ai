# AACWorkflow installer for Windows — one command to get started.
#
# Install CLI (default): connects to aacworkflow.com
#   irm https://raw.githubusercontent.com/AAChibilyaev/aacworkflow-ai/main/scripts/install.ps1 | iex
#
# Self-host: starts a local AACWorkflow server + installs CLI + configures
#   $env:AACWORKFLOW_MODE="local"; irm https://raw.githubusercontent.com/AAChibilyaev/aacworkflow-ai/main/scripts/install.ps1 | iex
#

$ErrorActionPreference = "Stop"

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------
$RepoUrl       = "https://github.com/AAChibilyaev/aacworkflow.git"
$RepoWebUrl    = "https://github.com/AAChibilyaev/aacworkflow"
$DefaultInstallDir = Join-Path $env:USERPROFILE ".aacworkflow\server"
$InstallDir    = if ($env:AACWORKFLOW_INSTALL_DIR) { $env:AACWORKFLOW_INSTALL_DIR } else { $DefaultInstallDir }

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
function Write-Info  { param([string]$Msg) Write-Host "==> $Msg" -ForegroundColor Cyan }
function Write-Ok    { param([string]$Msg) Write-Host "[OK] $Msg" -ForegroundColor Green }
function Write-Warn  { param([string]$Msg) Write-Warning $Msg }
function Write-Fail  { param([string]$Msg) Write-Host "[ERROR] $Msg" -ForegroundColor Red; exit 1 }

function Test-CommandExists {
    param([string]$Name)
    $null -ne (Get-Command $Name -ErrorAction SilentlyContinue)
}

function Get-EnvFileValue {
    param(
        [string]$Path,
        [string]$Name,
        [string]$Default
    )

    if (-not (Test-Path $Path)) {
        return $Default
    }

    $prefix = "$Name="
    $line = Get-Content $Path |
        Where-Object { $_.StartsWith($prefix) } |
        Select-Object -Last 1
    if (-not $line) {
        return $Default
    }

    $value = $line.Substring($prefix.Length).Trim().Trim('"').Trim("'")
    if ([string]::IsNullOrWhiteSpace($value)) {
        return $Default
    }
    return $value
}

function Get-SelfHostBackendPort {
    foreach ($name in @("BACKEND_PORT", "API_PORT", "SERVER_PORT", "PORT")) {
        $value = Get-EnvFileValue -Path (Join-Path $InstallDir ".env") -Name $name -Default ""
        if (-not [string]::IsNullOrWhiteSpace($value)) {
            return $value
        }
    }
    return "8080"
}

function Get-SelfHostFrontendPort {
    return Get-EnvFileValue -Path (Join-Path $InstallDir ".env") -Name "FRONTEND_PORT" -Default "3000"
}

function Get-LatestVersion {
    try {
        $release = Invoke-RestMethod -Uri "https://api.github.com/repos/AAChibilyaev/aacworkflow-ai/releases/latest" -ErrorAction Stop
        return $release.tag_name
    } catch {
        return $null
    }
}

function Get-SelfHostRef {
    if ($env:AACWORKFLOW_SELFHOST_REF) {
        return $env:AACWORKFLOW_SELFHOST_REF
    }

    $latest = Get-LatestVersion
    if ($latest) {
        return $latest
    }

    return "main"
}

function Checkout-ServerRef {
    param([string]$Ref)

    if ($Ref -eq "main") {
        git fetch origin main --depth 1 2>$null
        git checkout --force main 2>$null
        git reset --hard origin/main 2>$null
        return
    }

    git fetch origin --tags --force 2>$null
    $tagRef = "refs/tags/$Ref"
    git show-ref --verify --quiet $tagRef 2>$null
    if ($LASTEXITCODE -eq 0) {
        git checkout --force $Ref 2>$null
        return
    }

    git fetch origin $Ref --depth 1 2>$null
    git checkout --force $Ref 2>$null
}

function Pull-OfficialSelfHostImages {
    docker compose -f docker-compose.selfhost.yml pull
    if ($LASTEXITCODE -eq 0) {
        return
    }

    Write-Host ""
    Write-Warn "Official images for the selected self-host channel are not published yet."
    Write-Host "This can happen before the first GHCR release is available."
    Write-Host "From $InstallDir, build from source instead:"
    Write-Host "  docker compose -f docker-compose.selfhost.yml -f docker-compose.selfhost.build.yml up -d --build"
    exit 1
}

function Convert-ToCliArch {
    param([object]$Value)

    if ($null -eq $Value) {
        return $null
    }

    $normalized = "$Value".Trim().ToUpperInvariant()
    switch ($normalized) {
        "9"      { return "amd64" }
        "AMD64"  { return "amd64" }
        "X64"    { return "amd64" }
        "X86_64" { return "amd64" }
        "12"     { return "arm64" }
        "ARM64"  { return "arm64" }
        "AARCH64" { return "arm64" }
        default  { return $null }
    }
}

function Get-WindowsCliArch {
    $signals = @()
    $nativeArchSignalFound = $false

    # Prefer the native processor architecture over the current PowerShell
    # process architecture. This keeps Windows on ARM from being misdetected
    # when PowerShell is running through x64/x86 emulation.
    try {
        if (Get-Command Get-CimInstance -ErrorAction SilentlyContinue) {
            $processorArch = Get-CimInstance -ClassName Win32_Processor -ErrorAction Stop |
                Select-Object -First 1 -ExpandProperty Architecture
            $signals += [pscustomobject]@{ Source = "Win32_Processor.Architecture"; Value = $processorArch }
            $nativeArchSignalFound = $true
        }
    } catch {}

    try {
        if (-not $nativeArchSignalFound -and (Get-Command Get-WmiObject -ErrorAction SilentlyContinue)) {
            $processorArch = Get-WmiObject -Class Win32_Processor -ErrorAction Stop |
                Select-Object -First 1 -ExpandProperty Architecture
            $signals += [pscustomobject]@{ Source = "Win32_Processor.Architecture"; Value = $processorArch }
            $nativeArchSignalFound = $true
        }
    } catch {}

    try {
        $signals += [pscustomobject]@{
            Source = "RuntimeInformation.OSArchitecture"
            Value = [System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture
        }
    } catch {}

    $signals += [pscustomobject]@{ Source = "PROCESSOR_ARCHITEW6432"; Value = $env:PROCESSOR_ARCHITEW6432 }
    $signals += [pscustomobject]@{ Source = "PROCESSOR_ARCHITECTURE"; Value = $env:PROCESSOR_ARCHITECTURE }

    foreach ($signal in $signals) {
        $arch = Convert-ToCliArch $signal.Value
        if ($arch) {
            return $arch
        }
    }

    $details = ($signals |
        Where-Object { $null -ne $_.Value -and "$($_.Value)".Trim() -ne "" } |
        ForEach-Object { "$($_.Source)=$($_.Value)" }) -join ", "
    if (-not $details) {
        $details = "no architecture signals available"
    }

    Write-Fail "Unsupported Windows architecture ($details). Only x64 and ARM64 are supported."
}

function Get-InstalledCliVersion {
    try {
        $firstLine = aacworkflow version 2>$null | Select-Object -First 1
        if ("$firstLine" -match '\b(v?\d+(?:\.\d+)+)\b') {
            $version = $Matches[1]
            if ($version -notlike 'v*') {
                $version = "v$version"
            }
            return $version
        }
    } catch {}

    return $null
}

# ---------------------------------------------------------------------------
# CLI Installation
# ---------------------------------------------------------------------------
function Install-CliBinary {
    Write-Info "Installing AACWorkflow CLI from GitHub Releases..."

    if (-not [Environment]::Is64BitOperatingSystem) {
        Write-Fail "AACWorkflow requires a 64-bit Windows installation."
    }

    $arch = Get-WindowsCliArch

    $latest = Get-LatestVersion
    if (-not $latest) {
        Write-Fail "Could not determine latest release. Check your network connection."
    }

    $version = $latest.TrimStart('v')
    $url = "https://github.com/AAChibilyaev/aacworkflow-ai/releases/download/$latest/aacworkflow-cli-$version-windows-$arch.zip"
    $tmpDir = Join-Path ([System.IO.Path]::GetTempPath()) "aacworkflow-install"

    if (Test-Path $tmpDir) { Remove-Item $tmpDir -Recurse -Force }
    New-Item -ItemType Directory -Path $tmpDir | Out-Null

    Write-Info "Downloading $url ..."
    try {
        Invoke-WebRequest -Uri $url -OutFile (Join-Path $tmpDir "aacworkflow.zip") -UseBasicParsing
    } catch {
        Remove-Item $tmpDir -Recurse -Force
        Write-Fail "Failed to download CLI binary: $_"
    }

    # Verify SHA256 checksum
    $checksumUrl = "https://github.com/AAChibilyaev/aacworkflow-ai/releases/download/$latest/checksums.txt"
    try {
        $checksums = Invoke-WebRequest -Uri $checksumUrl -UseBasicParsing -ErrorAction Stop
        $checksumContent = if ($checksums.Content -is [byte[]]) {
            [System.Text.Encoding]::UTF8.GetString($checksums.Content)
        } else {
            [string]$checksums.Content
        }
        $zipFile = Join-Path $tmpDir "aacworkflow.zip"
        $actualHash = (Get-FileHash -Path $zipFile -Algorithm SHA256).Hash.ToLower()
        $releaseAsset = "aacworkflow-cli-$version-windows-$arch.zip"
        $legacyAsset = "aacworkflow_windows_$arch.zip"
        $expectedLine = ($checksumContent -split "`r?`n") |
            Where-Object {
                $_ -match [regex]::Escape($releaseAsset) -or
                $_ -match [regex]::Escape($legacyAsset)
            } |
            Select-Object -First 1
        if ($expectedLine) {
            $expectedHash = ($expectedLine -split "\s+")[0].ToLower()
            if ($actualHash -ne $expectedHash) {
                Remove-Item $tmpDir -Recurse -Force
                Write-Fail "Checksum verification failed. Expected: $expectedHash, Got: $actualHash"
            }
            Write-Ok "Checksum verified"
        } else {
            Write-Warn "Could not find checksum entry for $releaseAsset — skipping verification."
        }
    } catch {
        Write-Warn "Could not download checksums.txt — skipping verification."
    }

    Expand-Archive -Path (Join-Path $tmpDir "aacworkflow.zip") -DestinationPath $tmpDir -Force

    $binDir = Join-Path $env:USERPROFILE ".aacworkflow\bin"
    if (-not (Test-Path $binDir)) {
        New-Item -ItemType Directory -Path $binDir -Force | Out-Null
    }

    $exeSrc = Join-Path $tmpDir "aacworkflow.exe"
    if (-not (Test-Path $exeSrc)) {
        $exeSrc = Get-ChildItem -Path $tmpDir -Filter "aacworkflow.exe" -Recurse | Select-Object -First 1 -ExpandProperty FullName
    }
    if (-not $exeSrc -or -not (Test-Path $exeSrc)) {
        Remove-Item $tmpDir -Recurse -Force
        Write-Fail "aacworkflow.exe not found in downloaded archive."
    }

    Copy-Item $exeSrc (Join-Path $binDir "aacworkflow.exe") -Force
    Remove-Item $tmpDir -Recurse -Force

    Add-ToUserPath $binDir
    Write-Ok "AACWorkflow CLI installed to $binDir\aacworkflow.exe"
}

function Add-ToUserPath {
    param([string]$Dir)
    $currentPath = [Environment]::GetEnvironmentVariable("Path", "User")
    if ($currentPath -and $currentPath.Split(";") -contains $Dir) {
        return
    }
    $newPath = if ($currentPath) { "$currentPath;$Dir" } else { $Dir }
    [Environment]::SetEnvironmentVariable("Path", $newPath, "User")
    # Also update current session
    if ($env:Path -notlike "*$Dir*") {
        $env:Path = "$Dir;$env:Path"
    }
    Write-Info "Added $Dir to user PATH (restart your terminal for other sessions to pick it up)."
}

function Install-Cli {
    if (Test-CommandExists "aacworkflow") {
        $currentVer = Get-InstalledCliVersion
        $latestVer = Get-LatestVersion

        $currentCmp = if ($currentVer) { $currentVer -replace '^v','' } else { $null }
        $latestCmp = if ($latestVer) { $latestVer -replace '^v','' } else { $null }

        $isUpToDate = $currentCmp -and -not $latestCmp
        if (-not $isUpToDate) {
            try {
                $isUpToDate = $currentCmp -and $latestCmp -and ([System.Version]$currentCmp -ge [System.Version]$latestCmp)
            } catch {
                $isUpToDate = $currentCmp -and $latestCmp -and ($currentCmp -eq $latestCmp)
            }
        }

        if ($isUpToDate) {
            Write-Ok "AACWorkflow CLI is up to date ($currentVer)"
            return
        }

        Write-Info "AACWorkflow CLI $currentVer installed, latest is $latestVer - upgrading..."
        Install-CliBinary

        $newVer = Get-InstalledCliVersion
        Write-Ok "AACWorkflow CLI upgraded ($currentVer -> $newVer)"
        return
    }

    Install-CliBinary

    if (-not (Test-CommandExists "aacworkflow")) {
        Write-Fail "CLI installed but 'aacworkflow' not found on PATH. Restart your terminal and try again."
    }
}

# ---------------------------------------------------------------------------
# Docker check
# ---------------------------------------------------------------------------
function Test-Docker {
    if (-not (Test-CommandExists "docker")) {
        Write-Fail @"
Docker is not installed. AACWorkflow self-hosting requires Docker and Docker Compose.

Install Docker Desktop for Windows:
  https://docs.docker.com/desktop/install/windows-install/

After installing Docker, re-run this script with `$env:AACWORKFLOW_MODE="local"`.
"@
    }

    try {
        docker info 2>$null | Out-Null
    } catch {
        Write-Fail "Docker is installed but not running. Please start Docker Desktop and re-run this script."
    }

    Write-Ok "Docker is available"
}

# ---------------------------------------------------------------------------
# Server setup (self-host / local)
# ---------------------------------------------------------------------------
function Install-Server {
    Write-Info "Setting up AACWorkflow server..."
    $serverRef = Get-SelfHostRef
    Write-Info "Using self-host assets from $serverRef..."

    if (Test-Path (Join-Path $InstallDir ".git")) {
        Write-Info "Updating existing installation at $InstallDir..."
        Write-Warn "Any local changes in $InstallDir will be overwritten."
    } else {
        Write-Info "Cloning AACWorkflow repository..."
        if (-not (Test-CommandExists "git")) {
            Write-Fail "Git is not installed. Please install git and re-run."
        }
        if (Test-Path $InstallDir) {
            Write-Warn "Removing incomplete installation at $InstallDir..."
            Remove-Item $InstallDir -Recurse -Force
        }
        $parentDir = Split-Path $InstallDir -Parent
        if (-not (Test-Path $parentDir)) {
            New-Item -ItemType Directory -Path $parentDir -Force | Out-Null
        }
        git clone --depth 1 $RepoUrl $InstallDir
    }

    Push-Location $InstallDir
    Checkout-ServerRef $serverRef
    Write-Ok "Repository ready at $InstallDir ($serverRef)"

    if (-not (Test-Path ".env")) {
        Write-Info "Creating .env with random JWT_SECRET..."
        Copy-Item ".env.example" ".env"
        $jwt = -join ((1..32) | ForEach-Object { "{0:x2}" -f (Get-Random -Maximum 256) })
        (Get-Content ".env") -replace '^JWT_SECRET=.*', "JWT_SECRET=$jwt" | Set-Content ".env"
        Write-Ok "Generated .env with random JWT_SECRET"
    } else {
        Write-Ok "Using existing .env"
    }

    Write-Info "Pulling official AACWorkflow images..."
    Pull-OfficialSelfHostImages
    Write-Info "Starting AACWorkflow services (this may take a few minutes on first run)..."
    docker compose -f docker-compose.selfhost.yml up -d

    Write-Info "Waiting for backend to be ready..."
    $backendPort = Get-SelfHostBackendPort
    $ready = $false
    for ($i = 1; $i -le 45; $i++) {
        try {
            $null = Invoke-WebRequest -Uri "http://localhost:$backendPort/health" -UseBasicParsing -TimeoutSec 2
            $ready = $true
            break
        } catch {
            Start-Sleep -Seconds 2
        }
    }

    if ($ready) {
        Write-Ok "AACWorkflow server is running"
    } else {
        Write-Warn "Server is still starting. Check logs with:"
        Write-Host "  cd $InstallDir; docker compose -f docker-compose.selfhost.yml logs"
    }

    Pop-Location
}


# ---------------------------------------------------------------------------
# Main: Default mode (cloud)
# ---------------------------------------------------------------------------
function Start-DefaultInstall {
    Write-Host ""
    Write-Host "  AACWorkflow - Installer" -ForegroundColor White
    Write-Host ""

    Install-Cli

    Write-Host ""
    Write-Host "  ============================================" -ForegroundColor Green
    Write-Host "  [OK] AACWorkflow CLI is ready!" -ForegroundColor Green
    Write-Host "  ============================================" -ForegroundColor Green
    Write-Host ""
    Write-Host "  Next: configure your environment"
    Write-Host ""
    Write-Host "     aacworkflow setup               " -NoNewline; Write-Host "# Connect to AACWorkflow Cloud (aacworkflow.com)" -ForegroundColor DarkGray
    Write-Host "     aacworkflow setup self-host      " -NoNewline; Write-Host "# Connect to a self-hosted server" -ForegroundColor DarkGray
    Write-Host ""
    Write-Host "  Self-hosting? Install the server first:"
    Write-Host '     $env:AACWORKFLOW_MODE="with-server"; irm https://raw.githubusercontent.com/AAChibilyaev/aacworkflow-ai/main/scripts/install.ps1 | iex'
    Write-Host ""
}

# ---------------------------------------------------------------------------
# Main: Local mode (self-host)
# ---------------------------------------------------------------------------
function Start-LocalInstall {
    Write-Host ""
    Write-Host "  AACWorkflow - Self-Host Installer" -ForegroundColor White
    Write-Host "  Provisioning server infrastructure + installing CLI"
    Write-Host ""

    Test-Docker
    Install-Server
    Install-Cli

    Write-Host ""
    Write-Host "  ============================================" -ForegroundColor Green
    Write-Host "  [OK] AACWorkflow server is running and CLI is ready!" -ForegroundColor Green
    Write-Host "  ============================================" -ForegroundColor Green
    Write-Host ""
    $frontendPort = Get-SelfHostFrontendPort
    $backendPort = Get-SelfHostBackendPort
    Write-Host "  Frontend:  http://localhost:$frontendPort"
    Write-Host "  Backend:   http://localhost:$backendPort"
    Write-Host "  Server at: $InstallDir"
    Write-Host ""
    Write-Host "  Next: configure your CLI to connect"
    Write-Host ""
    Write-Host "     aacworkflow setup self-host  " -NoNewline; Write-Host "# Configure + authenticate + start daemon" -ForegroundColor DarkGray
    Write-Host ""
    Write-Host "  Login: configure RESEND_API_KEY in .env for email codes,"
    Write-Host "  or read the generated code from backend logs when Resend is unset."
    Write-Host ""
    Write-Host "  To stop all services:"
    Write-Host '     $env:AACWORKFLOW_MODE="stop"; irm https://raw.githubusercontent.com/AAChibilyaev/aacworkflow-ai/main/scripts/install.ps1 | iex'
    Write-Host ""
}

# ---------------------------------------------------------------------------
# Stop: shut down a self-hosted installation
# ---------------------------------------------------------------------------
function Start-Stop {
    Write-Host ""
    Write-Info "Stopping AACWorkflow services..."

    if (Test-Path $InstallDir) {
        Push-Location $InstallDir
        if (Test-Path "docker-compose.selfhost.yml") {
            docker compose -f docker-compose.selfhost.yml down
            Write-Ok "Docker services stopped"
        } else {
            Write-Warn "No docker-compose.selfhost.yml found at $InstallDir"
        }
        Pop-Location
    } else {
        Write-Warn "No AACWorkflow installation found at $InstallDir"
    }

    if (Test-CommandExists "aacworkflow") {
        try {
            aacworkflow daemon stop 2>$null
            Write-Ok "Daemon stopped"
        } catch {}
    }

    Write-Host ""
}

# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------
$mode = if ($env:AACWORKFLOW_MODE) { $env:AACWORKFLOW_MODE.ToLower() } else { "default" }

switch ($mode) {
    "with-server" { Start-LocalInstall }
    "local"       { Start-LocalInstall }  # backwards compat alias
    "stop"        { Start-Stop }
    default       { Start-DefaultInstall }
}
