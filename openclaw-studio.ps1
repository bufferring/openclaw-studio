<#
.SYNOPSIS
    OpenClaw Studio - Multi-Agent Orchestration Platform v5.3.1

.DESCRIPTION
    v5.3.1 - Windows parity + group chat docs:
      - Added Set-AgentModel (parity with bash set_agent_model)
      - Edit-Agent: shows current values, available models, calls Set-AgentModel
      - Test-Health: added agents config + Telegram bots checks
      - BotFather Group Privacy reminder in agent wizard
      - README: Group Chat setup section with groupPolicy table

    v5.3.0 - Provider audit, group chat, cleanup:
      - Renamed scripts: openclaw-setup.* -> openclaw-studio.*
      - Fixed ALL provider model IDs (verified against OpenClaw 2026.3.12 catalog)
      - Renamed provider zhipu -> zai; removed deepseek (use openrouter/deepseek/)
      - Group chat enabled by default (groupPolicy + groupAllowFrom set automatically)
      - edit/delete/list agents now use OpenClaw CLI as primary source
      - Removed dead code and stale comments
      - Skills import validates discovery

    v5.2.0 - Cloud-only, thin config layer
    v5.1.0 - Node 24 + npm, IPv6 fix, skills auto-import
    v5.0.0 - Telegram plugin, allowFrom, auth-profiles, gateway persistence

.PARAMETER Action
    install | skills | agents | health | backup | restore | activate | checklist | prereqs

.PARAMETER Debug
    Enable verbose debug output

.PARAMETER Help
    Show this help message
#>
param(
    [string]$Action = "",
    [switch]$Debug,
    [switch]$Help
)

Set-StrictMode -Off
$ErrorActionPreference = "Continue"
if ($Debug) { $DebugPreference = "Continue" }

# =============================================================================
# CONSTANTS & CONFIGURATION
# =============================================================================

$VERSION     = "5.3.4"
$SCRIPT_DIR  = $PSScriptRoot
$CONFIG_DIR  = Join-Path $env:USERPROFILE ".openclaw"
$WORKSPACE_DIR = Join-Path $CONFIG_DIR "workspace"
$AGENTS_DIR  = Join-Path $CONFIG_DIR "agents"
$BACKUP_DIR  = Join-Path $env:USERPROFILE ".openclaw-backups"
$LOG_FILE    = Join-Path $CONFIG_DIR "setup.log"
$AGENTS_CONFIG   = Join-Path $CONFIG_DIR "agents.json"
$VOICE_BIN_DIR   = Join-Path $CONFIG_DIR "bin"
$VOICE_DIR       = Join-Path $CONFIG_DIR "voice"
$VOICE_VENV_DIR  = Join-Path $VOICE_DIR "venv"
$VOICE_SCRIPT    = Join-Path $VOICE_DIR "transcribe.py"
$VOICE_MODEL_FILE = Join-Path $VOICE_DIR "model"
$VOICE_RUNNER    = Join-Path $VOICE_BIN_DIR "voice-transcribe.ps1"
$VOICE_CACHE_DIR = Join-Path $env:USERPROFILE ".cache\whisper"
$VOICE_ENV_FILE  = Join-Path $VOICE_DIR "env.ps1"
$WHISPER_PY_PACKAGE = "openai-whisper"
$WHISPER_MODELS  = @("tiny","base","small","medium","large-v3")

$PROVIDERS = [ordered]@{
    "google"     = "Google Gemini (Free tier)"
    "groq"       = "Groq (Free tier)"
    "zai"        = "ZAI / Zhipu (Free tier)"
    "anthropic"  = "Anthropic Claude (Paid)"
    "openai"     = "OpenAI GPT (Paid)"
    "openrouter" = "OpenRouter (Multi-provider)"
}

$PROVIDER_FREE = @("google","zai","groq")

$PROVIDER_MODELS = @{
    "google"     = @("gemini-2.0-flash","gemini-1.5-pro","gemini-2.5-flash","gemini-1.5-flash")
    "groq"       = @("llama-3.3-70b-versatile","llama-3.1-8b-instant","gemma2-9b-it")
    "zai"        = @("glm-4.7-flash","glm-4.7","glm-5","glm-4.5-flash")
    "anthropic"  = @("claude-sonnet-4-6","claude-opus-4-6","claude-3-5-sonnet-20241022")
    "openai"     = @("gpt-4o","gpt-4.1","gpt-4.1-mini")
    "openrouter" = @("anthropic/claude-sonnet-4","openai/gpt-4o","meta-llama/llama-3.3-70b-instruct")
}

$PROVIDER_AUTH_ID = @{
    "google"="google"; "anthropic"="anthropic"; "openai"="openai"
    "groq"="groq"; "openrouter"="openrouter"; "zai"="zai"
}

# =============================================================================
# UTILITY FUNCTIONS
# =============================================================================

function Write-Log {
    param([string]$Message)
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    try { "[$timestamp] $Message" | Add-Content -Path $LOG_FILE -ErrorAction SilentlyContinue } catch {}
}

function Write-Debug-Info {
    param([string]$Message)
    if ($Debug) { Write-Host "[DEBUG] $Message" -ForegroundColor Yellow }
}

function Show-Banner {
    Clear-Host
    Write-Host ""
    Write-Host (" ██████╗ ██████╗ ███████╗███╗   ██╗ ██████╗██╗      █████╗ ██╗    ██╗") -ForegroundColor Cyan
    Write-Host ("██╔═══██╗██╔══██╗██╔════╝████╗  ██║██╔════╝██║     ██╔══██╗██║    ██║") -ForegroundColor Cyan
    Write-Host ("██║   ██║██████╔╝█████╗  ██╔██╗ ██║██║     ██║     ███████║██║ █╗ ██║") -ForegroundColor Cyan
    Write-Host ("██║   ██║██╔═══╝ ██╔══╝  ██║╚██╗██║██║     ██║     ██╔══██║██║███╗██║") -ForegroundColor Cyan
    Write-Host ("╚██████╔╝██║     ███████╗██║ ╚████║╚██████╗███████╗██║  ██║╚███╔███╔╝") -ForegroundColor Cyan
    Write-Host (" ╚═════╝ ╚═╝     ╚══════╝╚═╝  ╚═══╝ ╚═════╝╚══════╝╚═╝  ╚═╝ ╚══╝╚══╝") -ForegroundColor Cyan
    Write-Host ("         ─────────────  S T U D I O  ─────────────  v$VERSION") -ForegroundColor White
    Write-Host ("            Multi-Agent Orchestration Platform") -ForegroundColor Yellow
    Write-Host ""
}

function Write-Header {
    param([string]$Title)
    Write-Host ""
    Write-Host ("=" * 72) -ForegroundColor Magenta
    Write-Host "  $Title" -ForegroundColor White
    Write-Host ("=" * 72) -ForegroundColor Magenta
    Write-Host ""
}

function Write-Success { param([string]$Msg) Write-Host "✓ $Msg" -ForegroundColor Green;  Write-Log "OK: $Msg" }
function Write-Err     { param([string]$Msg) Write-Host "✗ $Msg" -ForegroundColor Red;    Write-Log "ERROR: $Msg" }
function Write-Warn    { param([string]$Msg) Write-Host "⚠ $Msg" -ForegroundColor Yellow; Write-Log "WARN: $Msg" }
function Write-Info    { param([string]$Msg) Write-Host "ℹ $Msg" -ForegroundColor Blue }
function Write-Step    { param([string]$Msg) Write-Host "→ $Msg" -ForegroundColor Cyan }

function Confirm-Action {
    param([string]$Prompt, [string]$Default = "n")
    $hint = if ($Default -eq "y") { "[Y/n]" } else { "[y/N]" }
    $input = Read-Host "$Prompt $hint"
    if ([string]::IsNullOrWhiteSpace($input)) { return ($Default -eq "y") }
    return ($input -match "^[Yy]")
}

function Press-Enter {
    Write-Host ""
    Read-Host "Press Enter to continue..." | Out-Null
}

function Test-Command {
    param([string]$Cmd)
    return [bool](Get-Command $Cmd -ErrorAction SilentlyContinue)
}

function Require-Jq {
    if (-not (Test-Command "jq")) {
        Write-Err "jq is required. Run option 1 (Install/Update OpenClaw) first."
        return $false
    }
    return $true
}

# Build JSON array from comma-separated IDs (helper used in Telegram setup)
function Build-AllowFromJson {
    param([string]$Ids)
    if ($Ids -eq "*") { return '["*"]' }
    $parts = $Ids -split "," | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne "" }
    $items = $parts | ForEach-Object {
        if ($_ -match "^\d+$") { $_ } else { "`"$_`"" }
    }
    return "[" + ($items -join ",") + "]"
}

# =============================================================================
# DEPENDENCY INSTALLATION
# =============================================================================

function Install-Dependencies {
    Write-Header "Checking Dependencies"

    foreach ($cmd in @("git","curl","jq")) {
        if (Test-Command $cmd) {
            Write-Success "$cmd already available"
        } else {
            Write-Warn "$cmd not found — install via winget/choco/scoop"
            if (Test-Command "winget") {
                $pkgMap = @{"git"="Git.Git";"curl"="curl.curl";"jq"="jqlang.jq"}
                if ($pkgMap.ContainsKey($cmd)) {
                    Write-Info "Trying: winget install $($pkgMap[$cmd])"
                    winget install $pkgMap[$cmd] --silent 2>$null | Out-Null
                }
            }
        }
    }
}

function Install-Node {
    Write-Header "Installing Node.js 24"

    if (Test-Command "node") {
        $curVer = (node --version 2>$null) -replace '^v','' -split '\.' | Select-Object -First 1
        if ([int]$curVer -ge 24) {
            Write-Success "Node.js $(node --version) already installed"
            return
        }
        Write-Info "Current Node.js $(node --version) is below v24. Upgrading..."
    }

    if (Test-Command "winget") {
        Write-Info "Installing Node.js 24 via winget..."
        winget install OpenJS.NodeJS --version "24" --silent 2>$null | Out-Null
        if ($LASTEXITCODE -eq 0) {
            Write-Success "Node.js 24 installed via winget"
            Write-Info "Reload terminal if node is not found"
        } else {
            Write-Warn "winget install returned non-zero; trying manual download..."
        }
    }

    if (-not (Test-Command "node") -or ([int]((node --version 2>$null) -replace '^v','' -split '\.')[0]) -lt 24) {
        Write-Info "Download Node.js 24 from https://nodejs.org/en/download"
        Write-Info "Or use nvm-windows: https://github.com/coreybutler/nvm-windows"
    }
}

# =============================================================================
# OPENCLAW INSTALLATION
# =============================================================================

function Install-OpenClaw {
    Write-Header "Installing OpenClaw"

    if (Test-Command "openclaw") {
        $ver = (openclaw --version 2>$null)
        Write-Success "OpenClaw already installed ($ver)"
        if (-not (Confirm-Action "Reinstall/update OpenClaw?" "n")) { return }
    }

    Write-Info "Installing OpenClaw via npm..."
    npm install -g openclaw 2>&1 | Select-Object -Last 5 | ForEach-Object { Write-Host "  $_" }

    if (Test-Command "openclaw") {
        Write-Success "OpenClaw installed ($(openclaw --version 2>$null))"
        New-Item -ItemType Directory -Force -Path $CONFIG_DIR,$WORKSPACE_DIR,$AGENTS_DIR,$BACKUP_DIR | Out-Null
    } else {
        Write-Err "OpenClaw installation failed — check npm and internet connection"
    }
}

# =============================================================================
# OPENCLAW PREREQUISITES  (required before agents/gateway work)
# =============================================================================

function Ensure-OpenClawPrerequisites {
    Write-Header "Configuring OpenClaw Prerequisites"

    if (-not (Test-Command "openclaw")) {
        Write-Err "OpenClaw not installed. Run option 1 first."
        return
    }

    # Seed openclaw.json if it doesn't exist (fresh install)
    $ocConfig = Join-Path $CONFIG_DIR "openclaw.json"
    if (-not (Test-Path $ocConfig)) {
        Write-Info "Seeding openclaw.json (fresh install)..."
        New-Item -ItemType Directory -Force -Path $CONFIG_DIR | Out-Null
        '{"gateway":{"mode":"local"}}' | Set-Content -Path $ocConfig -Encoding UTF8
        Write-Success "Created openclaw.json with gateway.mode=local"
    }

    # 1. Set gateway.mode = local (REQUIRED — gateway refuses to start without it)
    $curMode = try { (openclaw config get gateway.mode 2>$null).Trim() } catch { "" }
    if ($curMode -ne "local" -and $curMode -ne "remote") {
        Write-Info "Setting gateway.mode = local..."
        $setResult = openclaw config set gateway.mode local 2>$null
        if ($LASTEXITCODE -eq 0) {
            Write-Success "gateway.mode set to local"
        } else {
            # Fallback: write directly to JSON (CLI may fail on fresh config)
            Write-Warn "CLI config set failed; writing gateway.mode directly..."
            try {
                $cfg = if (Test-Path $ocConfig) { Get-Content $ocConfig -Raw | ConvertFrom-Json } else { [PSCustomObject]@{} }
                if (-not $cfg.gateway) { $cfg | Add-Member -NotePropertyName "gateway" -NotePropertyValue ([PSCustomObject]@{}) }
                $cfg.gateway | Add-Member -NotePropertyName "mode" -NotePropertyValue "local" -Force
                $cfg | ConvertTo-Json -Depth 10 | Set-Content -Path $ocConfig -Encoding UTF8
                Write-Success "gateway.mode written via fallback"
            } catch {
                Write-Err "CRITICAL: Could not set gateway.mode — gateway will not start: $_"
            }
        }
    } else {
        Write-Success "gateway.mode already set ($curMode)"
    }

    # 2. Enable Telegram plugin (required before 'openclaw channels add --channel telegram')
    $tgStatus = openclaw plugins list 2>$null | Select-String -Pattern "telegram" -SimpleMatch | Select-String -Pattern "loaded|enabled" -SimpleMatch
    if (-not $tgStatus) {
        Write-Info "Enabling Telegram plugin..."
        $result = openclaw plugins enable telegram 2>$null
        if ($result) { Write-Success "Telegram plugin enabled" }
        else         { Write-Warn "Could not enable Telegram plugin (may already be enabled)" }
    } else {
        Write-Success "Telegram plugin already enabled"
    }

    Write-Success "Prerequisites configured"
}

# =============================================================================
# SKILLS MANAGEMENT
# =============================================================================

function Import-Skills {
    Write-Header "Importing Skills from everything-claude-code"

    $tmpDir = Join-Path $env:TEMP "everything-claude-code"

    if (Test-Path $tmpDir) {
        Write-Info "Updating skills repository..."
        Push-Location $tmpDir
        git pull -q 2>$null | Out-Null
        Pop-Location
    } else {
        Write-Info "Cloning skills repository..."
        git clone --depth 1 "https://github.com/affaan-m/everything-claude-code" $tmpDir -q 2>$null
    }

    if (-not (Test-Path $tmpDir)) {
        Write-Err "Failed to clone skills repo (check internet)"
        return
    }

    # Find openclaw skills directory
    $openclawSkills = $null
    foreach ($candidate in @(
        (Join-Path (Split-Path (Get-Command openclaw -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Source)) "..\lib\node_modules\openclaw\skills"),
        (Join-Path (Split-Path (Get-Command openclaw -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Source)) "..\node_modules\openclaw\skills"),
        "$(npm root -g 2>$null)\openclaw\skills"
    )) {
        if (Test-Path $candidate) { $openclawSkills = $candidate; break }
    }

    if (-not $openclawSkills) {
        Write-Err "Could not locate OpenClaw skills directory — install OpenClaw first"
        return
    }

    $srcSkills = Join-Path $tmpDir "skills"
    $before = (Get-ChildItem $openclawSkills -Directory -ErrorAction SilentlyContinue | Measure-Object).Count
    Copy-Item "$srcSkills\*" $openclawSkills -Recurse -Force 2>$null

    # Also install bundled skills from this repo's skills/ directory
    $localSkillsDir = Join-Path $SCRIPT_DIR "skills"
    if (Test-Path $localSkillsDir) {
        Copy-Item "$localSkillsDir\*" $openclawSkills -Recurse -Force 2>$null
        Write-Info "Bundled skills also installed from $localSkillsDir"
    }

    $after = (Get-ChildItem $openclawSkills -Directory -ErrorAction SilentlyContinue | Measure-Object).Count
    Write-Success "$($after - $before) new skills imported ($after total) -> $openclawSkills"

    # Verify OpenClaw discovers the imported skills
    if (Test-Command "openclaw") {
        $discovered = (openclaw skills list 2>&1 | Select-String -Pattern "ready|missing" | Measure-Object).Count
        Write-Info "OpenClaw sees $discovered skills (use 'openclaw skills list' for details)"
    }
}

function Get-Skills {
    Write-Header "Available Skills"
    if (Test-Command "openclaw") {
        openclaw skills list 2>$null | Select-Object -First 50
    } else {
        Write-Warn "OpenClaw not installed"
    }
}

# =============================================================================
# NATIVE CLI INTEGRATION LAYER
# =============================================================================

function Add-TelegramChannel {
    param([string]$AccountId, [string]$BotToken, [string]$DisplayName = "")
    if ([string]::IsNullOrEmpty($DisplayName)) { $DisplayName = $AccountId }

    Write-Debug-Info "Add-TelegramChannel: account=$AccountId name=$DisplayName"

    $out = openclaw channels add --channel telegram --token $BotToken --account $AccountId --name $DisplayName 2>&1
    if ($LASTEXITCODE -eq 0) {
        Write-Success "Telegram account '$AccountId' added"
        return $true
    } else {
        Write-Err "Failed to add Telegram channel for '$AccountId'"
        Write-Info "Output: $out"
        return $false
    }
}

function Set-TelegramAllowlist {
    param([string]$AccountId, [string]$AllowIds)

    Write-Debug-Info "Set-TelegramAllowlist: account=$AccountId allow=$AllowIds"

    $allowJson = Build-AllowFromJson -Ids $AllowIds
    $dmPolicy  = if ($AllowIds -eq "*") { "open" } else { "allowlist" }

    # Set allowFrom first, then dmPolicy (order matters for validation)
    openclaw config set "channels.telegram.accounts.$AccountId.allowFrom" $allowJson --strict-json 2>$null | Out-Null
    $r = openclaw config set "channels.telegram.accounts.$AccountId.dmPolicy" $dmPolicy 2>$null
    if ($LASTEXITCODE -eq 0) {
        Write-Success "Telegram DM policy: $dmPolicy (allowFrom: $AllowIds)"
    } else {
        Write-Warn "Could not fully set Telegram allowlist for '$AccountId'"
        Write-Debug-Info "Output: $r"
    }

    # Mirror the same policy to group chat so agents work in groups by default
    openclaw config set "channels.telegram.accounts.$AccountId.groupAllowFrom" $allowJson --strict-json 2>$null | Out-Null
    $gr = openclaw config set "channels.telegram.accounts.$AccountId.groupPolicy" $dmPolicy 2>$null
    if ($LASTEXITCODE -eq 0) {
        Write-Success "Telegram group policy: $dmPolicy"
    } else {
        Write-Warn "Could not set groupPolicy for '$AccountId'"
    }
}

function New-AgentNative {
    param([string]$AgentId, [string]$Model, [string]$Workspace, [string]$TgAccount = "")

    Write-Debug-Info "New-AgentNative: id=$AgentId model=$Model workspace=$Workspace tg=$TgAccount"
    New-Item -ItemType Directory -Force -Path $Workspace | Out-Null

    $bindArgs = @()
    if ($TgAccount -ne "") { $bindArgs = @("--bind", "telegram:$TgAccount") }

    $out = openclaw agents add $AgentId --model $Model --workspace $Workspace --non-interactive @bindArgs 2>&1
    if ($LASTEXITCODE -eq 0) {
        Write-Success "Agent '$AgentId' created via OpenClaw CLI"
        return $true
    } else {
        Write-Err "openclaw agents add failed for '$AgentId'"
        Write-Info "Output: $out"
        return $false
    }
}

function Set-AgentIdentity {
    param([string]$AgentId, [string]$Name, [string]$Emoji = "🤖")

    Write-Debug-Info "Set-AgentIdentity: id=$AgentId name=$Name emoji=$Emoji"

    openclaw agents set-identity --agent $AgentId --name $Name --emoji $Emoji 2>$null | Out-Null
    if ($LASTEXITCODE -eq 0) {
        Write-Success "Identity set: $Emoji $Name"
    } else {
        Write-Warn "Could not set identity via CLI — writing manually"
        $agentDir = Join-Path $AGENTS_DIR "$AgentId\agent"
        New-Item -ItemType Directory -Force -Path $agentDir | Out-Null
        @{name=$Name;emoji=$Emoji;theme="default"} | ConvertTo-Json | Set-Content (Join-Path $agentDir "identity.json")
    }
}

function Write-AuthProfiles {
    param([string]$AgentId, [string]$Provider, [string]$ApiKey)

    $agentDir = Join-Path $AGENTS_DIR "$AgentId\agent"
    New-Item -ItemType Directory -Force -Path $agentDir | Out-Null
    $authFile = Join-Path $agentDir "auth-profiles.json"

    # Load existing profiles (merge, don't overwrite)
    $profiles = @{}
    if (Test-Path $authFile) {
        try {
            $existing = Get-Content $authFile -Raw | ConvertFrom-Json
            if ($existing.profiles) {
                foreach ($prop in $existing.profiles.PSObject.Properties) {
                    $profiles[$prop.Name] = $prop.Value
                }
            }
        } catch {}
    }

    # Build new profile entry
    $authProv   = if ($PROVIDER_AUTH_ID.ContainsKey($Provider)) { $PROVIDER_AUTH_ID[$Provider] } else { $Provider }
    $profileId  = "${authProv}:manual"

    Write-Debug-Info "Write-AuthProfiles: agent=$AgentId profile=$profileId file=$authFile"

    # Merge new entry
    $profiles[$profileId] = [ordered]@{
        type     = "api_key"
        provider = $authProv
        key      = $ApiKey
    }

    # Build output object
    $output = [ordered]@{ version = 1; profiles = [ordered]@{} }
    foreach ($k in $profiles.Keys) { $output.profiles[$k] = $profiles[$k] }

    $output | ConvertTo-Json -Depth 5 | Set-Content -Path $authFile -Encoding UTF8
    Write-Success "Auth profile '$profileId' stored for agent '$AgentId'"
}

function Set-AgentModel {
    param([string]$AgentId, [string]$NewModel)

    $cliJson = openclaw agents list --json 2>&1 | Out-String
    $idx = $null
    try {
        $agList = $cliJson | ConvertFrom-Json
        for ($i = 0; $i -lt $agList.Count; $i++) {
            if ($agList[$i].id -eq $AgentId) { $idx = $i; break }
        }
    } catch {}

    if ($null -eq $idx) {
        Write-Err "Agent '$AgentId' not found in OpenClaw (openclaw agents list)"
        return
    }

    $r = openclaw config set "agents.list.$idx.model" $NewModel 2>$null
    if ($LASTEXITCODE -eq 0) {
        Write-Success "Agent '$AgentId' model -> $NewModel"
        openclaw gateway restart 2>$null | Out-Null
        Write-Info "Gateway restarted"
    } else {
        Write-Err "openclaw config set failed for agents.list.$idx.model"
    }
}

# =============================================================================
# INTERACTIVE AGENT WIZARD
# =============================================================================

function New-AgentInteractive {
    param([int]$AgentNum = 1, [int]$TotalAgents = 1)

    Write-Header "Agent $AgentNum of $TotalAgents"

    # --- Agent ID ---
    $agentId = Read-Host "Agent ID (lowercase, no spaces, e.g. 'assistant')"
    if ([string]::IsNullOrWhiteSpace($agentId)) { $agentId = "agent$AgentNum" }
    $agentId = $agentId.ToLower() -replace "\s+",""

    # --- Name ---
    $agentName = Read-Host "Display Name (e.g. 'Personal Assistant')"
    if ([string]::IsNullOrWhiteSpace($agentName)) { $agentName = $agentId }

    # --- Emoji ---
    $emoji = Read-Host "Emoji (default 🤖)"
    if ([string]::IsNullOrWhiteSpace($emoji)) { $emoji = "🤖" }

    # --- Profile ---
    Write-Host ""
    Write-Info "Agent profile describes the persona and specialization."
    $profile = Read-Host "Profile (optional, press Enter to skip)"

    # --- Model Provider ---
    Write-Host ""
    Write-Step "Select model provider:"
    $providerList = @("google","groq","zai","anthropic","openai","openrouter")
    for ($i = 0; $i -lt $providerList.Count; $i++) {
        $p = $providerList[$i]
        $badge = if ($PROVIDER_FREE -contains $p) { "[FREE] " } else { "[PAID] " }
        Write-Host ("  {0}) {1}{2}" -f ($i+1), $badge, $PROVIDERS[$p])
    }
    Write-Host ""
    $providerChoice = Read-Host "Select provider [1-6, default=1 Google]"
    if ([string]::IsNullOrWhiteSpace($providerChoice)) { $providerChoice = "1" }
    $pIdx = [int]$providerChoice - 1
    if ($pIdx -lt 0 -or $pIdx -ge $providerList.Count) { $pIdx = 0 }
    $provider = $providerList[$pIdx]

    # --- Model Selection ---
    $models = $PROVIDER_MODELS[$provider]

    Write-Host ""
    Write-Step "Select model:"
    for ($i = 0; $i -lt $models.Count; $i++) {
        Write-Host ("  {0}) {1}" -f ($i+1), $models[$i])
    }
    Write-Host ("  {0}) Enter custom model ID" -f ($models.Count+1))
    $modelChoice = Read-Host "Select model [default=1]"
    if ([string]::IsNullOrWhiteSpace($modelChoice)) { $modelChoice = "1" }
    $mIdx = [int]$modelChoice - 1

    if ($mIdx -eq $models.Count) {
        $customModel = Read-Host "Custom model ID"
        $model = "$provider/$customModel"
    } elseif ($mIdx -ge 0 -and $mIdx -lt $models.Count) {
        $model = "$provider/$($models[$mIdx])"
    } else {
        $model = "$provider/$($models[0])"
    }

    # --- API Key ---
    $apiKey = ""
    Write-Host ""
    $keyEnvVar = ($provider.ToUpper() + "_API_KEY")
    Write-Step "API Key for $($PROVIDERS[$provider])"
    $apiKey = Read-Host "API Key (or Enter to use `$$keyEnvVar)"
    if ([string]::IsNullOrWhiteSpace($apiKey)) {
        $apiKey = [Environment]::GetEnvironmentVariable($keyEnvVar) ?? ""
        if ($apiKey) { Write-Info "Using `$$keyEnvVar from environment" }
    }

    # --- Skills ---
    Write-Host ""
    Write-Step "Select skills (comma-separated numbers, 'all', or Enter to skip):"
    $skillList = @()

    $ocSkillsDir = $null
    $candidates = @(
        (Join-Path (Split-Path (Get-Command openclaw -EA SilentlyContinue | Select-Object -Exp Source)) "..\lib\node_modules\openclaw\skills"),
        (Join-Path (Split-Path (Get-Command openclaw -EA SilentlyContinue | Select-Object -Exp Source)) "..\node_modules\openclaw\skills"),
        "$(npm root -g 2>$null)\openclaw\skills"
    )
    foreach ($c in $candidates) { if (Test-Path $c) { $ocSkillsDir = $c; break } }

    if ($ocSkillsDir) {
        $skillList = Get-ChildItem $ocSkillsDir -Directory -EA SilentlyContinue | Select-Object -First 30 -Exp Name
    } elseif (Test-Path $AGENTS_DIR) {
        $skillList = Get-ChildItem $AGENTS_DIR -Filter "*.md" -EA SilentlyContinue | Select-Object -First 30 -Exp BaseName
    }

    $selectedSkills = @()
    if ($skillList.Count -gt 0) {
        for ($i = 0; $i -lt $skillList.Count; $i++) {
            Write-Host ("  {0,2}) {1}" -f ($i+1), $skillList[$i])
        }
        $skillChoice = Read-Host "Select skills"
        if ($skillChoice -eq "all") {
            $selectedSkills = $skillList
        } elseif ($skillChoice) {
            foreach ($part in ($skillChoice -split ",")) {
                $idx = [int]$part.Trim() - 1
                if ($idx -ge 0 -and $idx -lt $skillList.Count) { $selectedSkills += $skillList[$idx] }
            }
        }
    } else {
        Write-Info "No skills found — import skills first (option 2)"
    }

    # --- Telegram ---
    Write-Host ""
    Write-Header "Telegram Bot Configuration"
    $botToken = Read-Host "Bot Token (from @BotFather, or Enter to skip)"
    $allowIds = ""
    if ($botToken) {
        Write-Host ""
        Write-Warn "For GROUP CHAT: disable Group Privacy in @BotFather"
        Write-Info "  BotFather -> /mybots -> $agentId -> Bot Settings -> Group Privacy -> Turn off"
        Write-Info "  Without this, the bot only sees @mentions and /commands in groups."
        Write-Host ""
        Write-Step "Restrict bot to specific Telegram user IDs"
        Write-Info "Get your ID: use option 8 in main menu, or message @userinfobot"
        $allowIds = Read-Host "Allowed User IDs (comma-separated, or '*' for all)"
        if ([string]::IsNullOrWhiteSpace($allowIds)) { $allowIds = "*" }
    }

    # =========================================================================
    # EXECUTE
    # =========================================================================
    Write-Host ""
    Write-Header "Creating Agent: $agentName ($agentId)"

    $workspace   = Join-Path $WORKSPACE_DIR $agentId
    $nativeOk    = $true

    # Step 1: Add Telegram channel
    if ($botToken) {
        if (Add-TelegramChannel -AccountId $agentId -BotToken $botToken -DisplayName $agentName) {
            Set-TelegramAllowlist -AccountId $agentId -AllowIds $allowIds
        } else {
            Write-Warn "Telegram setup failed; agent will be created without Telegram"
            $botToken = ""
        }
    }

    # Step 2: Create agent
    $tgBind = if ($botToken) { $agentId } else { "" }
    if (-not (New-AgentNative -AgentId $agentId -Model $model -Workspace $workspace -TgAccount $tgBind)) {
        Write-Warn "Native CLI agent creation failed; saving config manually"
        $nativeOk = $false
    }

    # Step 3: Set identity
    Set-AgentIdentity -AgentId $agentId -Name $agentName -Emoji $emoji

    # Step 4: Store auth in auth-profiles.json
    Write-AuthProfiles -AgentId $agentId -Provider $provider -ApiKey $apiKey

    # Step 5: Write profile
    if ($profile) {
        New-Item -ItemType Directory -Force -Path $workspace | Out-Null
        "# $agentName`n`n$profile" | Set-Content (Join-Path $workspace "IDENTITY.md") -Encoding UTF8
    }

    # Step 6: Track in agents.json
    New-Item -ItemType Directory -Force -Path $CONFIG_DIR | Out-Null
    if (-not (Test-Path $AGENTS_CONFIG)) {
        '{"agents":{},"default_agent":null}' | Set-Content $AGENTS_CONFIG -Encoding UTF8
    }

    $rec = [ordered]@{
        id          = $agentId
        name        = $agentName
        emoji       = $emoji
        profile     = $profile
        model       = $model
        bot_token   = $botToken
        allow_from  = @($allowIds)
        skills      = $selectedSkills
        created_at  = (Get-Date -Format "o")
        native_cli  = $nativeOk
    }

    try {
        $cfg = Get-Content $AGENTS_CONFIG -Raw | ConvertFrom-Json
        $cfg.agents | Add-Member -NotePropertyName $agentId -NotePropertyValue $rec -Force
        $cfg | ConvertTo-Json -Depth 10 | Set-Content $AGENTS_CONFIG -Encoding UTF8
    } catch {
        Write-Warn "Could not update agents.json: $_"
    }

    # Set as default if first agent
    try {
        $curDef = (Get-Content $AGENTS_CONFIG -Raw | ConvertFrom-Json).default_agent
        if (-not $curDef -or $curDef -eq "null") {
            if (Confirm-Action "Set '$agentName' as the default agent?" "y") {
                $cfg2 = Get-Content $AGENTS_CONFIG -Raw | ConvertFrom-Json
                $cfg2 | Add-Member -NotePropertyName "default_agent" -NotePropertyValue $agentId -Force
                $cfg2 | ConvertTo-Json -Depth 10 | Set-Content $AGENTS_CONFIG -Encoding UTF8
                Write-Success "Default agent: $agentId"
            }
        }
    } catch {}

    Write-Host ""
    Write-Success "Agent '$emoji $agentName' ($agentId) configured"
    if ($botToken) {
        $policyLabel = if ($allowIds -eq "*") { "open" } else { "allowlist" }
        Write-Info "Telegram: bot connected, dmPolicy=$policyLabel"
    }
    Write-Info "Model: $model"
    Write-Info "Run option 7 (Activate Agents) to start the gateway"
}

function Setup-MultiAgent {
    Write-Header "Multi-Agent Setup"
    Write-Host ""
    Write-Info "Configure multiple agents, each with their own:"
    Write-Host "  • Telegram bot token + allowed user IDs"
    Write-Host "  • Model, API key, and skills"
    Write-Host "  • Display name and persona profile"
    Write-Host ""

    $numStr = Read-Host "How many agents to configure? [1-10]"
    $num = [int]$numStr
    if ($num -lt 1) { $num = 1 }
    if ($num -gt 10) { $num = 10 }

    for ($i = 1; $i -le $num; $i++) {
        New-AgentInteractive -AgentNum $i -TotalAgents $num
        Write-Host ""
        if ($i -lt $num) { Press-Enter }
    }

    Write-Header "Agents Configured"
    Get-Agents
}

# =============================================================================
# AGENT-POOL.JSON DEPLOYMENT
# =============================================================================

function Deploy-FromAgentPool {
    Write-Header "Deploy from agent-pool.json"

    $poolFile = Join-Path $SCRIPT_DIR "agent-pool.json"

    if (-not (Test-Path $poolFile)) {
        Write-Warn "No agent-pool.json found"
        Write-Info "Creating sample..."
        @'
{
  "agents": {
    "orchestrator": {
      "model": "google/gemini-2.0-flash",
      "skills": ["chief-of-staff"],
      "description": "Routes tasks to specialists",
      "role": "Orchestration"
    },
    "python-dev": {
      "model": "google/gemini-2.0-flash",
      "skills": ["coding-agent"],
      "description": "Python backend specialist",
      "role": "Python development"
    }
  },
  "routing": {
    "python": ["python-dev"],
    "architecture": ["orchestrator"]
  }
}
'@ | Set-Content $poolFile -Encoding UTF8
        Write-Success "Sample agent-pool.json created — edit and re-run"
        return
    }

    if (-not (Require-Jq)) { return }

    $poolJson  = Get-Content $poolFile -Raw | ConvertFrom-Json
    $agentIds  = $poolJson.agents.PSObject.Properties.Name
    $agentCount = $agentIds.Count

    if ($agentCount -eq 0) { Write-Err "No agents in agent-pool.json"; return }

    Write-Info "Found $agentCount agents:"
    foreach ($id in $agentIds) {
        $role = $poolJson.agents.$id.role ?? "Agent"
        $sc   = ($poolJson.agents.$id.skills ?? @()).Count
        Write-Host ("  {0,-20} {1} ({2} skills)" -f $id, $role, $sc)
    }
    Write-Host ""

    if (-not (Confirm-Action "Deploy these $agentCount agents?" "y")) {
        Write-Info "Cancelled"
        return
    }

    $ok = 0; $fail = 0

    # Ensure agents.json exists
    New-Item -ItemType Directory -Force -Path $CONFIG_DIR | Out-Null
    if (-not (Test-Path $AGENTS_CONFIG)) {
        '{"agents":{},"default_agent":null}' | Set-Content $AGENTS_CONFIG -Encoding UTF8
    }

    foreach ($agentId in $agentIds) {
        Write-Host ""
        Write-Step "Deploying: $agentId"
        $model     = if ($poolJson.agents.$agentId.model) { $poolJson.agents.$agentId.model } else { "google/gemini-2.0-flash" }
        $role      = if ($poolJson.agents.$agentId.role)  { $poolJson.agents.$agentId.role  } else { "Agent" }
        $workspace = Join-Path $WORKSPACE_DIR $agentId

        if (New-AgentNative -AgentId $agentId -Model $model -Workspace $workspace) {
            $ok++
            Set-AgentIdentity -AgentId $agentId -Name $role -Emoji "🤖"

            # Write auth-profiles.json
            $poolProvider = ($model -split "/")[0]
            $poolApiKey   = $poolJson.agents.$agentId.api_key
            Write-AuthProfiles -AgentId $agentId -Provider $poolProvider -ApiKey ($poolApiKey ?? "")

            # Track in agents.json
            $rec = [ordered]@{ id=$agentId; name=$role; emoji="🤖"; model=$model; native_cli=$true; source="agent-pool.json" }
            try {
                $cfg = Get-Content $AGENTS_CONFIG -Raw | ConvertFrom-Json
                $cfg.agents | Add-Member -NotePropertyName $agentId -NotePropertyValue $rec -Force
                $cfg | ConvertTo-Json -Depth 10 | Set-Content $AGENTS_CONFIG -Encoding UTF8
            } catch {}
        } else { $fail++ }
    }

    Write-Host ""
    Write-Header "Deployment Summary"
    Write-Success "Deployed: $ok agents"
    if ($fail -gt 0) { Write-Err "Failed: $fail agents" }

    # Show routing rules
    if ($poolJson.routing) {
        Write-Host ""
        Write-Info "Routing rules:"
        foreach ($key in $poolJson.routing.PSObject.Properties.Name) {
            $targets = $poolJson.routing.$key -join ", "
            Write-Host ("  {0,-15} -> {1}" -f $key, $targets) -ForegroundColor Cyan
        }
    }
}

# =============================================================================
# AGENT MANAGEMENT
# =============================================================================

function Get-Agents {
    Write-Header "Configured Agents"

    if (Test-Command "openclaw") {
        Write-Info "From OpenClaw CLI:"
        $cliOut = openclaw agents list --bindings 2>&1 | Out-String
        if ($cliOut) {
            # Strip doctor warning box lines for cleaner output
            $cliOut -split "`n" | Where-Object { $_ -notmatch '^\s*[│├╮╯◇]|Doctor warnings|^\s*$|🦞' } | ForEach-Object { Write-Host $_ }
        } else {
            Write-Warn "Could not query OpenClaw agent list"
        }
        Write-Host ""
    }

    if (-not (Test-Path $AGENTS_CONFIG)) { Write-Info "(No local agents.json)"; return }
    try {
        $cfg   = Get-Content $AGENTS_CONFIG -Raw | ConvertFrom-Json
        $count = ($cfg.agents.PSObject.Properties | Measure-Object).Count
        if ($count -eq 0) { return }
        Write-Info "From local tracking: $count agent(s)"
        foreach ($prop in $cfg.agents.PSObject.Properties) {
            $a = $prop.Value
            $botStatus = if ($a.bot_token) { "configured" } else { "not set" }
            Write-Host ("  {0} {1}: {2} [{3}]" -f ($a.emoji ?? "🤖"), $prop.Name, ($a.name ?? $prop.Name), ($a.model ?? "no model"))
            Write-Host ("    Bot: $botStatus  |  Allowed: $($a.allow_from -join ', ')")
        }
    } catch { Write-Warn "Could not parse agents.json" }
}

function Edit-Agent {
    Write-Header "Edit Agent"

    # Primary: OpenClaw CLI; fallback: local agents.json
    $agList = @()
    $cliJson = ""
    if (Test-Command "openclaw") {
        $cliJson = openclaw agents list --json 2>&1 | Out-String
        try { $agList = $cliJson | ConvertFrom-Json } catch {}
    }
    $agentIds = @($agList | ForEach-Object { $_.id })
    if ($agentIds.Count -eq 0 -and (Test-Path $AGENTS_CONFIG)) {
        try { $agentIds = @((Get-Content $AGENTS_CONFIG -Raw | ConvertFrom-Json).agents.PSObject.Properties.Name) } catch {}
    }
    if ($agentIds.Count -eq 0) { Write-Warn "No agents configured"; return }

    Write-Host ""
    for ($i = 0; $i -lt $agentIds.Count; $i++) {
        $curMdl = ($agList | Where-Object { $_.id -eq $agentIds[$i] } | Select-Object -First 1).model
        if (-not $curMdl) { $curMdl = "(default)" }
        Write-Host ("  {0}) {1,-20}  model: {2}" -f ($i+1), $agentIds[$i], $curMdl)
    }
    Write-Host ""
    $choice = [int](Read-Host "Select agent to edit") - 1
    if ($choice -lt 0 -or $choice -ge $agentIds.Count) { Write-Err "Invalid selection"; return }

    $agentId = $agentIds[$choice]

    # Fetch current values from CLI
    $ag = $agList | Where-Object { $_.id -eq $agentId } | Select-Object -First 1
    $curModel = if ($ag.model) { $ag.model } else { "" }
    $curName  = if ($ag.identityName) { $ag.identityName } elseif ($ag.name) { $ag.name } else { $agentId }
    $curAllow = ""
    try { $curAllow = (openclaw config get "channels.telegram.accounts.$agentId.allowFrom" 2>$null | Where-Object { $_ -notmatch "^\s*$|lobster|claw" } | Out-String).Trim() } catch {}
    $curGroupPolicy = ""
    try { $curGroupPolicy = (openclaw config get "channels.telegram.accounts.$agentId.groupPolicy" 2>$null | Out-String).Trim().Trim('"') } catch {}
    if (-not $curGroupPolicy) { $curGroupPolicy = "not set" }

    Write-Host ""
    Write-Info "Editing: $agentId  (Enter = keep current)"
    Write-Host ""
    Write-Host "  1. Change model   [$curModel]"
    Write-Host "  2. Change name    [$curName]"
    Write-Host "  3. Change bot token"
    Write-Host "  4. Change allowed IDs  [$curAllow]"
    Write-Host "  5. Change group policy  [$curGroupPolicy]"
    Write-Host "  0. Cancel"
    Write-Host ""
    $editChoice = Read-Host "What to edit"

    switch ($editChoice) {
        "1" {
            Write-Host ""
            Write-Host "  Available models:" -ForegroundColor White
            $providerOrder = @("google","groq","zai","anthropic","openai","openrouter")
            $modelList = @()
            $mi = 1
            foreach ($p in $providerOrder) {
                if (-not $PROVIDER_MODELS.ContainsKey($p)) { continue }
                $firstModel = $PROVIDER_MODELS[$p][0]
                $modelList += "$p/$firstModel"
                Write-Host ("    {0}) {1}/{2}" -f $mi, $p, $firstModel)
                $mi++
            }
            Write-Host ("    {0}) Enter custom model ID" -f $mi)
            Write-Host ""
            $newModel = Read-Host "New model - number or full string [$curModel]"
            # Resolve numeric selection
            if ($newModel -match '^\d+$') {
                $sel = [int]$newModel - 1
                if ($sel -ge 0 -and $sel -lt $modelList.Count) {
                    $newModel = $modelList[$sel]
                } elseif ($sel -eq $modelList.Count) {
                    $newModel = Read-Host "Custom model ID"
                } else {
                    $newModel = ""
                }
            }
            if ($newModel) {
                Set-AgentModel -AgentId $agentId -NewModel $newModel
                $newProvider = ($newModel -split "/")[0]
                $newKey = Read-Host "API key for $newProvider (Enter to skip)"
                if ($newKey) { Write-AuthProfiles -AgentId $agentId -Provider $newProvider -ApiKey $newKey }
            } else {
                Write-Info "Model unchanged"
            }
        }
        "2" {
            $newName = Read-Host "New name [$curName]"
            if (-not $newName) {
                Write-Info "Name unchanged"
            } else {
                openclaw agents set-identity --agent $agentId --name $newName 2>$null | Out-Null
                if ($LASTEXITCODE -eq 0) { Write-Success "Name updated to '$newName'" }
                else { Write-Err "Failed to update name for '$agentId'" }
            }
        }
        "3" {
            $newBot = Read-Host "New bot token"
            if ($newBot) { Add-TelegramChannel -AccountId $agentId -BotToken $newBot -DisplayName $curName }
        }
        "4" {
            $newAllow = Read-Host "Allowed Telegram IDs (comma-separated, * for open) [$curAllow]"
            if ($newAllow) { Set-TelegramAllowlist -AccountId $agentId -AllowIds $newAllow }
        }
        "5" {
            Write-Host ""
            Write-Host "  1) open       - anyone in the group"
            Write-Host "  2) allowlist  - only allowed IDs"
            Write-Host "  3) off        - ignore group messages"
            $gpChoice = Read-Host "Group policy [1-3]"
            $gpVal = switch ($gpChoice) { "1" { "open" } "2" { "allowlist" } "3" { "off" } default { "" } }
            if ($gpVal) {
                openclaw config set "channels.telegram.accounts.$agentId.groupPolicy" $gpVal 2>$null | Out-Null
                Write-Success "Group policy: $gpVal"
            } else { Write-Info "Group policy unchanged" }
        }
        "0" { return }
    }

    Write-Success "Agent '$agentId' updated"
}

function Remove-Agent {
    Write-Header "Delete Agent"

    # Primary: OpenClaw CLI; fallback: local agents.json
    $agents = @()
    if (Test-Command "openclaw") {
        $cliJson = openclaw agents list --json 2>&1 | Out-String
        try { $agents = ($cliJson | ConvertFrom-Json) | ForEach-Object { $_.id } } catch {}
    }
    if ($agents.Count -eq 0 -and (Test-Path $AGENTS_CONFIG)) {
        try { $agents = (Get-Content $AGENTS_CONFIG -Raw | ConvertFrom-Json).agents.PSObject.Properties.Name } catch {}
    }
    if ($agents.Count -eq 0) { Write-Warn "No agents configured"; return }

    for ($i = 0; $i -lt $agents.Count; $i++) {
        Write-Host ("  {0}) {1}" -f ($i+1), $agents[$i])
    }
    $choice = [int](Read-Host "Select agent to delete") - 1
    if ($choice -lt 0 -or $choice -ge $agents.Count) { Write-Err "Invalid selection"; return }

    $agentId = $agents[$choice]
    if (Confirm-Action "Delete '$agentId'? Removes from OpenClaw too." "n") {
        openclaw agents delete $agentId 2>$null | Out-Null
        $cliOk = ($LASTEXITCODE -eq 0)
        # Also remove from local tracking if present
        if (Test-Path $AGENTS_CONFIG) {
            try {
                $cfg = Get-Content $AGENTS_CONFIG -Raw | ConvertFrom-Json
                $cfg.agents.PSObject.Properties.Remove($agentId)
                $cfg | ConvertTo-Json -Depth 10 | Set-Content $AGENTS_CONFIG -Encoding UTF8
            } catch {}
        }
        if ($cliOk) { Write-Success "Agent '$agentId' deleted" }
        else { Write-Warn "OpenClaw CLI reported failure for '$agentId'; removed from local tracking only" }
    }
}

# =============================================================================
# GATEWAY MANAGEMENT
# =============================================================================

function Test-PortInUse {
    param([int]$Port)
    $conn = Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue
    return [bool]$conn
}

function Start-Gateway {
    Write-Header "Activate Agents (Start Gateway)"

    if (-not (Test-Command "openclaw")) {
        Write-Err "OpenClaw not installed. Run option 1 first."
        return
    }

    Ensure-OpenClawPrerequisites

    # Install gateway service (idempotent — safe to call multiple times)
    # Uses node runtime (Node 24+). If IPv6 issues cause Telegram timeouts,
    # disable IPv6 via: netsh interface ipv6 set state disabled
    Write-Info "Installing gateway service (node runtime)..."
    openclaw gateway install --runtime node 2>$null | Out-Null
    if ($LASTEXITCODE -eq 0) {
        Write-Success "Gateway service installed (Task Scheduler)"
    } else {
        Write-Warn "Gateway service install returned non-zero (may already be installed)"
    }

    # Start or restart
    $gwStatus = openclaw gateway status 2>$null
    $started  = $false

    if ($gwStatus -match "running|active") {
        Write-Info "Gateway running; restarting to apply config..."
        openclaw gateway restart 2>$null | Out-Null
        $started = ($LASTEXITCODE -eq 0)
    } else {
        openclaw gateway start 2>$null | Out-Null
        if ($LASTEXITCODE -eq 0) {
            $started = $true
        } else {
            Write-Warn "Service start failed; starting in foreground (background process)..."
            $proc = Start-Process -FilePath "openclaw" -ArgumentList "gateway run" `
                -WindowStyle Hidden -PassThru
            Start-Sleep -Seconds 5
            $started = Test-PortInUse -Port 18789
        }
    }

    if (-not $started) {
        Write-Err "Gateway failed to start"
        Write-Info "Check logs: openclaw logs"
        return
    }

    Write-Success "Gateway started"
    Start-Sleep -Seconds 3
    Show-Checklist
}

# =============================================================================
# FINAL CHECKLIST
# =============================================================================

function Show-Checklist {
    Write-Header "Active System Checklist"

    Write-Host ""
    Write-Info "── Dependencies ──"
    foreach ($cmd in @("openclaw","node","jq","curl")) {
        if (Test-Command $cmd) {
            $ver = & $cmd --version 2>$null | Select-Object -First 1
            Write-Host ("  {0,-3} {1,-12} {2}" -f "✓", $cmd, $ver) -ForegroundColor Green
        } else {
            Write-Host ("  {0,-3} {1,-12} NOT FOUND" -f "✗", $cmd) -ForegroundColor Red
        }
    }

    Write-Host ""
    Write-Info "── Gateway ──"
    $gwRunning = $false
    $health = openclaw health 2>$null
    if ($health -match "OK") { $gwRunning = $true }
    elseif (Test-PortInUse -Port 18789) { $gwRunning = $true }
    if ($gwRunning) {
        Write-Host "  ✓ Gateway: running (port 18789)" -ForegroundColor Green
    } else {
        Write-Host "  ✗ Gateway: not responding" -ForegroundColor Red
        Write-Info "    Start with: openclaw gateway start"
    }

    # Task Scheduler persistence
    $task = Get-ScheduledTask -TaskName "OpenClaw Gateway" -ErrorAction SilentlyContinue
    if ($task -and $task.State -ne "Disabled") {
        Write-Host "  ✓ Task Scheduler: registered (survives reboot)" -ForegroundColor Green
    } else {
        Write-Host "  ⚠ Task Scheduler: not registered (run Activate Agents to install)" -ForegroundColor Yellow
    }

    Write-Host ""
    Write-Info "── Agents ──"
    $agentJson = openclaw agents list --json 2>&1 | Out-String
    if ($agentJson) {
        try {
            $agList = $agentJson | ConvertFrom-Json
            Write-Host ("  ✓ {0} agent(s) configured:" -f $agList.Count) -ForegroundColor Green
            foreach ($ag in $agList) {
                $star   = if ($ag.isDefault) { "★" } else { " " }
                $bdstr  = if ($ag.bindingDetails) { $ag.bindingDetails -join ", " } else { "no bindings" }
                Write-Host ("    $star {0,-15} model={1}  {2}" -f $ag.id, ($ag.model ?? "inherited"), $bdstr)
            }
        } catch {
            Write-Host "  ⚠ Could not parse agent list" -ForegroundColor Yellow
        }
    } else {
        Write-Host "  ⚠ No agents configured (use option 3)" -ForegroundColor Yellow
    }

    Write-Host ""
    Write-Info "── Telegram Channels ──"
    $chStatus = openclaw channels status 2>$null
    if ($chStatus) {
        $chStatus -split "`n" | Where-Object { $_ -match "telegram|Telegram" } | ForEach-Object {
            $color = if ($_ -match "running")        { "Green"  }
                     elseif ($_ -match "error|stop") { "Red"    }
                     else                             { "Blue"   }
            Write-Host "  $_" -ForegroundColor $color
        }
    } else {
        Write-Host "  ⚠ Could not query channel status" -ForegroundColor Yellow
    }

    Write-Host ""
    Write-Info "── Skills ──"
    if (Test-Command "openclaw") {
        $sc = (openclaw skills list 2>$null | Measure-Object -Line).Lines
        if ($sc -gt 1) {
            Write-Host ("  ✓ Skills available: {0}" -f $sc) -ForegroundColor Green
        } else {
            Write-Host "  ⚠ No skills (use option 2 to import)" -ForegroundColor Yellow
        }
    }

    Write-Host ""
    Write-Info "── Voice Transcription (Whisper) ──"
    $voiceEnabled = ""
    try { $voiceEnabled = (openclaw config get "voiceTranscription.enabled" 2>$null | Where-Object { $_ -notmatch "^\s*$|lobster|claw" } | Out-String).Trim().Trim('"') } catch {}
    if ($voiceEnabled -eq "true") {
        if (Test-Path $VOICE_RUNNER) {
            Write-Host "  ✓ Runner: $VOICE_RUNNER" -ForegroundColor Green
        } else {
            Write-Host "  ✗ Runner not found: $VOICE_RUNNER" -ForegroundColor Red
        }
        if (Test-Path $VOICE_VENV_DIR) {
            Write-Host "  ✓ Python venv: $VOICE_VENV_DIR" -ForegroundColor Green
        } else {
            Write-Host "  ⚠ Python venv not found (re-run setup)" -ForegroundColor Yellow
        }
        if (Test-Path $VOICE_MODEL_FILE) {
            $wm = (Get-Content $VOICE_MODEL_FILE -Raw).Trim()
            Write-Host "  ✓ Model: $wm" -ForegroundColor Green
        } else {
            Write-Host "  ⚠ No model file at $VOICE_MODEL_FILE" -ForegroundColor Yellow
        }
    } else {
        Write-Host "  ℹ Voice transcription not enabled (run setup to configure)" -ForegroundColor Blue
    }

    # Save to status file
    try {
        $statusPath = Join-Path $CONFIG_DIR "status.md"
        @(
            "# OpenClaw Status — $(Get-Date)",
            "", "## Agents",
            (openclaw agents list 2>$null),
            "", "## Channels",
            (openclaw channels status 2>$null),
            "", "## Gateway",
            (openclaw gateway status 2>$null)
        ) | Set-Content $statusPath -Encoding UTF8
        Write-Host ""
        Write-Info "Status saved to: $statusPath"
    } catch {}
}

# =============================================================================
# TELEGRAM BOT UTILITIES
# =============================================================================

function Get-TelegramUserId {
    Write-Header "Get Telegram User ID"
    if (-not (Require-Jq)) { return }

    $botToken = ""
    if (Test-Path $AGENTS_CONFIG) {
        try {
            $cfg = Get-Content $AGENTS_CONFIG -Raw | ConvertFrom-Json
            $bot = $cfg.agents.PSObject.Properties.Value | Where-Object { $_.bot_token } | Select-Object -First 1
            if ($bot) { $botToken = $bot.bot_token }
        } catch {}
    }
    if (-not $botToken) { $botToken = Read-Host "Enter bot token" }
    if (-not $botToken) { Write-Err "No bot token provided"; return }

    Write-Info "Send a message to your bot, then press Enter..."
    Read-Host | Out-Null

    try {
        $resp = Invoke-RestMethod "https://api.telegram.org/bot$botToken/getUpdates" -Method Get -TimeoutSec 10
        $last = $resp.result | Select-Object -Last 1
        if ($last) {
            $uid   = $last.message.from.id
            $uname = $last.message.from.username
            $fname = $last.message.from.first_name
            Write-Host ""
            Write-Success "User found:"
            Write-Host "  ID:       $uid"
            if ($uname) { Write-Host "  Username: @$uname" }
            if ($fname) { Write-Host "  Name:     $fname" }
            Write-Host ""
            Write-Info "Add this ID to an agent's allowlist via option 4 (Edit Agent)"
        } else {
            Write-Err "No messages found — did you send a message to your bot?"
        }
    } catch {
        Write-Err "Failed to reach Telegram API: $_"
    }
}

function Test-TelegramBot {
    Write-Header "Test Telegram Bot"
    $botToken = ""
    if (Test-Path $AGENTS_CONFIG) {
        try {
            $cfg = Get-Content $AGENTS_CONFIG -Raw | ConvertFrom-Json
            $bot = $cfg.agents.PSObject.Properties.Value | Where-Object { $_.bot_token } | Select-Object -First 1
            if ($bot) { $botToken = $bot.bot_token }
        } catch {}
    }
    if (-not $botToken) { $botToken = Read-Host "Enter bot token" }
    if (-not $botToken) { Write-Err "No bot token provided"; return }

    Write-Info "Testing bot connection..."
    try {
        $me = Invoke-RestMethod "https://api.telegram.org/bot$botToken/getMe" -TimeoutSec 10
        if ($me.ok) {
            Write-Success "Bot connected: $($me.result.first_name) (@$($me.result.username))"
        } else {
            Write-Err "Bot connection failed: $($me.description)"
        }
    } catch {
        Write-Err "Request failed: $_"
    }
}

# =============================================================================
# VOICE TRANSCRIPTION (WHISPER)
# =============================================================================

function Select-WhisperModel {
    Write-Host ""
    Write-Step "Select Whisper model:"
    $notes = @{ "tiny"="~75MB fastest"; "base"="~145MB recommended"; "small"="~490MB better"; "medium"="~1.5GB high"; "large-v3"="~3.1GB best" }
    for ($i = 0; $i -lt $WHISPER_MODELS.Count; $i++) {
        $m = $WHISPER_MODELS[$i]
        Write-Host ("  {0}) {1}  - {2}" -f ($i+1), $m, $notes[$m])
    }
    Write-Host ""
    $mc = Read-Host "Select model [default=2 base]"
    if ([string]::IsNullOrWhiteSpace($mc)) { $mc = "2" }
    if ($mc -match '^\d+$') {
        $idx = [int]$mc - 1
        if ($idx -ge 0 -and $idx -lt $WHISPER_MODELS.Count) { return $WHISPER_MODELS[$idx] }
    }
    return "base"
}

function Install-WhisperPython {
    Write-Step "Setting up Python venv for Whisper..."
    $py = if (Test-Command "python3") { "python3" } elseif (Test-Command "python") { "python" } else { $null }
    if (-not $py) { Write-Err "Python not found. Install Python 3.9+ first."; return $false }
    New-Item -ItemType Directory -Force -Path $VOICE_DIR | Out-Null
    if (-not (Test-Path $VOICE_VENV_DIR)) {
        & $py -m venv $VOICE_VENV_DIR 2>$null
        if ($LASTEXITCODE -ne 0) { Write-Err "Failed to create venv at $VOICE_VENV_DIR"; return $false }
        Write-Success "Python venv created at $VOICE_VENV_DIR"
    } else { Write-Info "Python venv already exists" }
    $pip = if (Test-Path (Join-Path $VOICE_VENV_DIR "Scripts\pip.exe")) { Join-Path $VOICE_VENV_DIR "Scripts\pip.exe" } else { Join-Path $VOICE_VENV_DIR "bin\pip" }
    Write-Step "Installing $WHISPER_PY_PACKAGE (may take a few minutes)..."
    & $pip install --quiet --upgrade pip 2>$null | Out-Null
    & $pip install --quiet $WHISPER_PY_PACKAGE 2>$null | Out-Null
    if ($LASTEXITCODE -eq 0) { Write-Success "$WHISPER_PY_PACKAGE installed"; return $true }
    Write-Err "pip install $WHISPER_PY_PACKAGE failed"; return $false
}

function Write-WhisperScript {
    New-Item -ItemType Directory -Force -Path $VOICE_DIR | Out-Null
    $pyLines = @(
        '#!/usr/bin/env python3',
        '"""OpenClaw Studio - local Whisper transcription script."""',
        'import argparse, os, sys, pathlib',
        '',
        'def main():',
        '    ap = argparse.ArgumentParser(description="Transcribe audio with local Whisper")',
        '    ap.add_argument("audio", nargs="?", help="Input audio file")',
        '    ap.add_argument("--model", default=None)',
        '    ap.add_argument("--language", default=None)',
        '    ap.add_argument("--prefetch", action="store_true")',
        '    args = ap.parse_args()',
        '    model_file = os.environ.get("WHISPER_MODEL_FILE", os.path.expanduser("~/.openclaw/voice/model"))',
        '    model = args.model',
        '    if not model and os.path.isfile(model_file):',
        '        model = pathlib.Path(model_file).read_text().strip()',
        '    if not model: model = "base"',
        '    cache_dir = os.environ.get("WHISPER_CACHE_DIR", os.path.join(os.path.expanduser("~"), ".cache", "whisper"))',
        '    os.makedirs(cache_dir, exist_ok=True)',
        '    try:',
        '        import whisper',
        '    except ImportError:',
        '        print("openai-whisper not installed in this venv", file=sys.stderr); sys.exit(1)',
        '    print(f"Loading model \'{model}\'...", file=sys.stderr)',
        '    m = whisper.load_model(model, download_root=cache_dir)',
        '    if args.prefetch:',
        '        print(f"Model \'{model}\' ready", file=sys.stderr); return',
        '    if not args.audio: print("No audio file provided", file=sys.stderr); sys.exit(1)',
        '    if not os.path.isfile(args.audio): print(f"File not found: {args.audio}", file=sys.stderr); sys.exit(1)',
        '    result = m.transcribe(args.audio, language=args.language)',
        '    print(result["text"].strip())',
        '',
        'if __name__ == "__main__": main()'
    )
    $pyLines | Set-Content -Path $VOICE_SCRIPT -Encoding UTF8
    Write-Success "Whisper transcription script written to $VOICE_SCRIPT"
}

function Write-WhisperRunner {
    New-Item -ItemType Directory -Force -Path $VOICE_BIN_DIR | Out-Null
    $venvPy = Join-Path $VOICE_VENV_DIR "Scripts\python.exe"
    if (-not (Test-Path $venvPy)) { $venvPy = Join-Path $VOICE_VENV_DIR "bin\python3" }
    $lines = @(
        '# OpenClaw Studio - voice-transcribe runner (auto-generated)',
        "param([string]`$AudioFile, [string]`$Model = `"`", [string]`$Language = `"`", [switch]`$Prefetch)",
        "`$env:WHISPER_CACHE_DIR  = if (`$env:WHISPER_CACHE_DIR)  { `$env:WHISPER_CACHE_DIR }  else { `"$VOICE_CACHE_DIR`" }",
        "`$env:WHISPER_MODEL_FILE = if (`$env:WHISPER_MODEL_FILE) { `$env:WHISPER_MODEL_FILE } else { `"$VOICE_MODEL_FILE`" }",
        "`$py = `"$venvPy`"",
        "`$args2 = @()",
        "if (`$Prefetch)  { `$args2 += '--prefetch' }",
        "if (`$AudioFile) { `$args2 += `$AudioFile }",
        "if (`$Model)     { `$args2 += '--model'; `$args2 += `$Model }",
        "if (`$Language)  { `$args2 += '--language'; `$args2 += `$Language }",
        "& `$py `"$VOICE_SCRIPT`" @args2"
    )
    $lines | Set-Content -Path $VOICE_RUNNER -Encoding UTF8
    Write-Success "Voice runner installed at $VOICE_RUNNER"
}

function Write-WhisperEnv {
    New-Item -ItemType Directory -Force -Path $VOICE_DIR | Out-Null
    @(
        '# Auto-generated by OpenClaw Studio - dot-source to expose WHISPER_* vars',
        "`$env:WHISPER_RUNNER     = `"$VOICE_RUNNER`"",
        "`$env:WHISPER_MODEL_FILE = `"$VOICE_MODEL_FILE`"",
        "`$env:WHISPER_CACHE_DIR  = `"$VOICE_CACHE_DIR`"",
        "`$env:WHISPER_VENV       = `"$VOICE_VENV_DIR`"",
        "`$env:PATH               = `"$VOICE_BIN_DIR;`" + `$env:PATH"
    ) | Set-Content -Path $VOICE_ENV_FILE -Encoding UTF8
    Write-Info "Env file: $VOICE_ENV_FILE  (dot-source to load WHISPER_* vars)"
}

function Prefetch-WhisperModel {
    param([string]$Model)
    if (-not (Test-Path $VOICE_RUNNER)) { return }
    Write-Info "Pre-downloading Whisper model '$Model' (this may take a while)..."
    $psExe = if (Get-Command "pwsh" -ErrorAction SilentlyContinue) { "pwsh" } else { "powershell" }
    & $psExe -NoProfile -File $VOICE_RUNNER -Prefetch -Model $Model 2>$null | Out-Null
    if ($LASTEXITCODE -eq 0) { Write-Success "Model '$Model' cached at $VOICE_CACHE_DIR" }
    else { Write-Warn "Prefetch failed - model will download on first transcription" }
}

function Configure-VoiceTranscription {
    param([bool]$Enabled, [string]$Model = "")
    $val = if ($Enabled) { "true" } else { "false" }
    openclaw config set "voiceTranscription.enabled" $val 2>$null | Out-Null
    if ($Model) { openclaw config set "voiceTranscription.model" $Model 2>$null | Out-Null }
    openclaw config set "voiceTranscription.runner" $VOICE_RUNNER 2>$null | Out-Null
}

function Setup-WhisperTranscription {
    Write-Header "Voice Transcription (Whisper)"
    Write-Host ""
    Write-Info "Enables local speech-to-text for Telegram voice notes."
    Write-Info "No API key required - runs fully on-device using openai-whisper."
    Write-Host ""

    if (-not (Confirm-Action "Enable Telegram voice-note transcription with local Whisper?" "y")) {
        Configure-VoiceTranscription -Enabled:$false -Model:""
        Write-Info "Voice transcription disabled"
        return
    }

    $model = Select-WhisperModel
    Set-Content -Path $VOICE_MODEL_FILE -Value $model -Encoding UTF8
    Write-Info "Selected model: $model"

    if (-not (Install-WhisperPython)) { return }
    Write-WhisperScript
    Write-WhisperRunner
    Write-WhisperEnv
    Prefetch-WhisperModel -Model $model
    Configure-VoiceTranscription -Enabled:$true -Model:$model

    Write-Success "Voice transcription enabled (model: $model)"
    Write-Info "Runner:   $VOICE_RUNNER"
    Write-Info "Env file: $VOICE_ENV_FILE"
}

# =============================================================================
# HEALTH CHECK
# =============================================================================

function Test-Health {
    Write-Header "System Health Check"
    $passed = 0; $warnings = 0; $failed = 0

    Write-Host ""
    Write-Info "Checking dependencies..."
    foreach ($cmd in @("curl","git","jq","node","npm")) {
        if (Test-Command $cmd) {
            $ver = & $cmd --version 2>$null | Select-Object -First 1
            Write-Success "$cmd : $ver"
            $passed++
        } else {
            Write-Err "$cmd : NOT FOUND"
            $failed++
        }
    }
    Write-Host ""
    Write-Info "Checking OpenClaw..."
    if (Test-Command "openclaw") {
        Write-Success "OpenClaw: $(openclaw --version 2>$null)"
        $passed++
    } else {
        Write-Err "OpenClaw: NOT INSTALLED"
        $failed++
    }

    Write-Host ""
    Write-Info "Checking gateway..."
    $gwRunning = $false
    $health = openclaw health 2>$null
    if ($health -match "OK") { $gwRunning = $true }
    elseif (Test-PortInUse -Port 18789) { $gwRunning = $true }
    if ($gwRunning) {
        Write-Success "Gateway: running (port 18789)"
        $passed++
    } else {
        Write-Warn "Gateway: not running (use option 7 to start)"
        $warnings++
    }

    Write-Host ""
    Write-Info "Checking configuration..."
    if (Test-Path $AGENTS_CONFIG) {
        try {
            $count = ((Get-Content $AGENTS_CONFIG -Raw | ConvertFrom-Json).agents.PSObject.Properties | Measure-Object).Count
            Write-Success "Agents configured: $count"
            $passed++
        } catch {
            Write-Warn "Could not parse agents.json"
            $warnings++
        }
    } else {
        Write-Warn "No agents configured"
        $warnings++
    }

    Write-Host ""
    Write-Info "Checking Telegram bots..."
    if (Test-Path $AGENTS_CONFIG) {
        try {
            $cfg = Get-Content $AGENTS_CONFIG -Raw | ConvertFrom-Json
            $botCount = ($cfg.agents.PSObject.Properties | Where-Object { $_.Value.bot_token } | Measure-Object).Count
            if ($botCount -gt 0) {
                Write-Success "$botCount Telegram bot(s) configured"
                $passed++
            } else {
                Write-Warn "No Telegram bots configured"
                $warnings++
            }
        } catch {}
    }

    Write-Host ""
    Write-Info "Checking voice transcription (Whisper)..."
    $voiceEnabled = ""
    try { $voiceEnabled = (openclaw config get "voiceTranscription.enabled" 2>$null | Where-Object { $_ -notmatch "^\s*$|lobster|claw" } | Out-String).Trim().Trim('"') } catch {}
    if ($voiceEnabled -eq "true") {
        if (Test-Path $VOICE_RUNNER) {
            Write-Success "Whisper runner: $VOICE_RUNNER"
            $passed++
        } else {
            Write-Err "Whisper runner not found: $VOICE_RUNNER"
            $failed++
        }
        if (Test-Path $VOICE_VENV_DIR) {
            Write-Success "Whisper venv: $VOICE_VENV_DIR"
            $passed++
        } else {
            Write-Warn "Whisper venv not found (re-run setup)"
            $warnings++
        }
        if (Test-Path $VOICE_MODEL_FILE) {
            $wmodel = (Get-Content $VOICE_MODEL_FILE -Raw).Trim()
            Write-Success "Whisper model: $wmodel"
            $passed++
        } else {
            Write-Warn "No Whisper model file at $VOICE_MODEL_FILE"
            $warnings++
        }
    } else {
        Write-Info "Voice transcription not enabled (run setup to configure)"
    }

    Write-Host ""
    Write-Header "Health Check Summary"
    Write-Success "$passed checks passed"
    if ($warnings -gt 0) { Write-Warn "$warnings warnings" }
    if ($failed   -gt 0) { Write-Err  "$failed checks failed" }
}

# =============================================================================
# BACKUP & RESTORE
# =============================================================================

function New-Backup {
    Write-Header "Creating Backup"
    New-Item -ItemType Directory -Force -Path $BACKUP_DIR | Out-Null
    $timestamp  = Get-Date -Format "yyyyMMdd_HHmmss"
    $backupFile = Join-Path $BACKUP_DIR "openclaw_backup_$timestamp.zip"
    try {
        Compress-Archive -Path $CONFIG_DIR -DestinationPath $backupFile -Force
        $size = [math]::Round((Get-Item $backupFile).Length / 1MB, 2)
        Write-Success "Backup created: $backupFile (${size}MB)"
    } catch {
        Write-Err "Backup failed: $_"
    }
}

function Restore-Backup {
    Write-Header "Restore from Backup"
    $backups = Get-ChildItem $BACKUP_DIR -Filter "openclaw_backup_*.zip" -ErrorAction SilentlyContinue |
               Sort-Object LastWriteTime -Descending
    if ($backups.Count -eq 0) { Write-Warn "No backups found"; return }

    for ($i = 0; $i -lt $backups.Count; $i++) {
        $sz = [math]::Round($backups[$i].Length / 1MB, 2)
        Write-Host ("  {0}) {1} ({2}MB)" -f ($i+1), $backups[$i].Name, $sz)
    }
    $choice = [int](Read-Host "Select backup to restore") - 1
    if ($choice -lt 0 -or $choice -ge $backups.Count) { Write-Err "Invalid selection"; return }

    if (Confirm-Action "This will overwrite ~/.openclaw. Continue?" "n") {
        try {
            Expand-Archive -Path $backups[$choice].FullName -DestinationPath $env:USERPROFILE -Force
            Write-Success "Backup restored"
        } catch {
            Write-Err "Restore failed: $_"
        }
    }
}

# =============================================================================
# MAIN MENU
# =============================================================================

function Show-MainMenu {
    Show-Banner
    Write-Host "  Main Menu" -ForegroundColor White
    Write-Host ""
    Write-Host "  Setup" -ForegroundColor Bold
    Write-Host "  " -NoNewline; Write-Host "1." -ForegroundColor Cyan -NoNewline; Write-Host " Install/Update OpenClaw"
    Write-Host "  " -NoNewline; Write-Host "2." -ForegroundColor Cyan -NoNewline; Write-Host " Import Skills from everything-claude-code"
    Write-Host ""
    Write-Host "  Multi-Agent Management" -ForegroundColor White
    Write-Host "  " -NoNewline; Write-Host "3." -ForegroundColor Cyan -NoNewline; Write-Host " Configure Agents (Create/Edit/Delete)"
    Write-Host "  " -NoNewline; Write-Host "4." -ForegroundColor Cyan -NoNewline; Write-Host " Deploy from agent-pool.json"
    Write-Host "  " -NoNewline; Write-Host "5." -ForegroundColor Cyan -NoNewline; Write-Host " List Configured Agents"
    Write-Host "  " -NoNewline; Write-Host "6." -ForegroundColor Cyan -NoNewline; Write-Host " Show Active Checklist"
    Write-Host "  " -NoNewline; Write-Host "7." -ForegroundColor Cyan -NoNewline; Write-Host " Activate Agents (Start Gateway)"
    Write-Host ""
    Write-Host "  Telegram Bot" -ForegroundColor White
    Write-Host "  " -NoNewline; Write-Host "8." -ForegroundColor Cyan -NoNewline; Write-Host " Get Telegram User ID"
    Write-Host "  " -NoNewline; Write-Host "9." -ForegroundColor Cyan -NoNewline; Write-Host " Test Telegram Bot Connection"
    Write-Host ""
    Write-Host "  System" -ForegroundColor White
    Write-Host "  " -NoNewline; Write-Host "10." -ForegroundColor Cyan -NoNewline; Write-Host " Health Check"
    Write-Host "  " -NoNewline; Write-Host "11." -ForegroundColor Cyan -NoNewline; Write-Host " Backup/Restore"
    Write-Host ""
    Write-Host "  " -NoNewline; Write-Host "0." -ForegroundColor Magenta -NoNewline; Write-Host " Exit"
    Write-Host ""
}

function Show-InstallMenu {
    Show-Banner
    Write-Header "Installation & Setup"

    Install-Dependencies
    Install-Node

    Install-OpenClaw
    Ensure-OpenClawPrerequisites

    # Auto-import skills — agents need these out-of-the-box
    Import-Skills

    # Optional: local Whisper voice transcription
    Setup-WhisperTranscription

    Press-Enter
}

function Show-AgentMenu {
    while ($true) {
        Show-Banner
        Write-Header "Agent Management"
        Write-Host "  Quick Actions" -ForegroundColor White
        Write-Host "  " -NoNewline; Write-Host "1." -ForegroundColor Cyan -NoNewline; Write-Host " Create New Agent"
        Write-Host "  " -NoNewline; Write-Host "2." -ForegroundColor Cyan -NoNewline; Write-Host " Setup Multiple Agents"
        Write-Host "  " -NoNewline; Write-Host "3." -ForegroundColor Cyan -NoNewline; Write-Host " List Agents"
        Write-Host "  " -NoNewline; Write-Host "4." -ForegroundColor Cyan -NoNewline; Write-Host " Edit Agent"
        Write-Host "  " -NoNewline; Write-Host "5." -ForegroundColor Cyan -NoNewline; Write-Host " Delete Agent"
        Write-Host ""
        Write-Host "  Skills" -ForegroundColor White
        Write-Host "  " -NoNewline; Write-Host "6." -ForegroundColor Cyan -NoNewline; Write-Host " List Available Skills"
        Write-Host "  " -NoNewline; Write-Host "7." -ForegroundColor Cyan -NoNewline; Write-Host " Import Skills"
        Write-Host ""
        Write-Host "  " -NoNewline; Write-Host "0." -ForegroundColor Magenta -NoNewline; Write-Host " Back"
        Write-Host ""

        $choice = Read-Host "Select option"
        switch ($choice) {
            "1" { New-AgentInteractive -AgentNum 1 -TotalAgents 1; Press-Enter }
            "2" { Setup-MultiAgent; Press-Enter }
            "3" { Get-Agents; Press-Enter }
            "4" { Edit-Agent; Press-Enter }
            "5" { Remove-Agent; Press-Enter }
            "6" { Get-Skills; Press-Enter }
            "7" { Import-Skills; Press-Enter }
            "0" { return }
            default { Write-Warn "Invalid option"; Start-Sleep -Seconds 1 }
        }
    }
}

# =============================================================================
# ENTRY POINT
# =============================================================================

function Main {
    New-Item -ItemType Directory -Force -Path $CONFIG_DIR,$BACKUP_DIR | Out-Null
    "" | Out-File -FilePath $LOG_FILE -Encoding UTF8 -Append

    switch ($Action.ToLower()) {
        "install"  { Show-InstallMenu; return }
        "setup"    { Show-InstallMenu; return }
        "skills"   { Import-Skills; return }
        "agents"   { Show-AgentMenu; return }
        "health"   { Test-Health; return }
        "check"    { Test-Health; return }
        "backup"   { New-Backup; return }
        "restore"  { Restore-Backup; return }
        "activate" { Start-Gateway; return }
        "checklist"{ Show-Checklist; return }
        "prereqs"  { Ensure-OpenClawPrerequisites; return }
    }

    while ($true) {
        Show-MainMenu
        $choice = Read-Host "Select option"
        switch ($choice) {
            "1"  { Show-InstallMenu }
            "2"  { Import-Skills; Press-Enter }
            "3"  { Show-AgentMenu }
            "4"  { Deploy-FromAgentPool; Press-Enter }
            "5"  { Get-Agents; Press-Enter }
            "6"  { Show-Checklist; Press-Enter }
            "7"  { Start-Gateway; Press-Enter }
            "8"  { Get-TelegramUserId; Press-Enter }
            "9"  { Test-TelegramBot; Press-Enter }
            "10" { Test-Health; Press-Enter }
            "11" {
                Show-Banner
                Write-Header "Backup & Restore"
                Write-Host "  " -NoNewline; Write-Host "1." -ForegroundColor Cyan -NoNewline; Write-Host " Create Backup"
                Write-Host "  " -NoNewline; Write-Host "2." -ForegroundColor Cyan -NoNewline; Write-Host " Restore Backup"
                Write-Host ""
                Write-Host "  " -NoNewline; Write-Host "0." -ForegroundColor Magenta -NoNewline; Write-Host " Back"
                $sub = Read-Host "Select option"
                switch ($sub) { "1" { New-Backup } "2" { Restore-Backup } }
                Press-Enter
            }
            "0"  { Show-Banner; Write-Host "Goodbye!" -ForegroundColor Green; exit }
            default { Write-Warn "Invalid option"; Start-Sleep -Seconds 1 }
        }
    }
}

# =============================================================================
# SHOW HELP
# =============================================================================
if ($Help) {
    Write-Host @"
OpenClaw Studio v$VERSION - Multi-Agent Orchestration Platform

Usage: .\openclaw-studio.ps1 [-Action <action>] [-Debug] [-Help]

Actions:
  install    Install OpenClaw and dependencies
  skills     Import skills from everything-claude-code
  agents     Manage agents
  health     Run system health check
  backup     Create backup
  restore    Restore from backup
  activate   Start gateway with configured agents
  checklist  Show live status checklist
  prereqs    Configure gateway.mode + enable Telegram plugin

Options:
  -Debug     Enable verbose debug output
  -Help      Show this help message
"@
    exit
}

Main
