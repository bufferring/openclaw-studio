# voice-transcribe/scripts/transcribe.ps1
# PowerShell wrapper for the OpenClaw Studio local Whisper runner.
# Usage: transcribe.ps1 <audio-file> [-Model MODEL] [-Out OUTPUT] [-Language LANG]
param(
    [Parameter(Position=0, Mandatory=$true)]
    [string]$AudioFile,

    [string]$Model    = "",
    [string]$Out      = "",
    [string]$Language = ""
)

Set-StrictMode -Off
$ErrorActionPreference = "Stop"

if (-not (Test-Path $AudioFile)) {
    Write-Error "File not found: $AudioFile"
    exit 1
}

# Resolve runner — prefer env var, fall back to default install path
$defaultRunner = Join-Path $env:USERPROFILE ".openclaw\bin\voice-transcribe.ps1"
$runner = if ($env:WHISPER_RUNNER) { $env:WHISPER_RUNNER } else { $defaultRunner }

if (-not (Test-Path $runner)) {
    Write-Error "voice-transcribe runner not found at: $runner`nRun OpenClaw Studio option 1 (Install/Update) and enable voice transcription."
    exit 1
}

# Resolve model — prefer flag, then env model file, then runner default
if (-not $Model) {
    $modelFile = if ($env:WHISPER_MODEL_FILE) { $env:WHISPER_MODEL_FILE } else {
        Join-Path $env:USERPROFILE ".openclaw\voice\model"
    }
    if (Test-Path $modelFile) {
        $Model = (Get-Content $modelFile -Raw).Trim()
    }
}

# Resolve output path
if (-not $Out) {
    $Out = [System.IO.Path]::ChangeExtension($AudioFile, ".txt")
}

$outDir = Split-Path $Out -Parent
if ($outDir -and -not (Test-Path $outDir)) {
    New-Item -ItemType Directory -Force -Path $outDir | Out-Null
}

# Build runner args and invoke
$runnerArgs = @($AudioFile)
if ($Model)    { $runnerArgs += "--model";    $runnerArgs += $Model }
if ($Language) { $runnerArgs += "--language"; $runnerArgs += $Language }

$psExe = if (Get-Command "pwsh" -ErrorAction SilentlyContinue) { "pwsh" } else { "powershell" }
$transcript = & $psExe -NoProfile -File $runner @runnerArgs

if ($LASTEXITCODE -ne 0) {
    Write-Error "Runner exited with code $LASTEXITCODE"
    exit $LASTEXITCODE
}

$transcript | Set-Content -Path $Out -Encoding UTF8
Write-Host $Out
