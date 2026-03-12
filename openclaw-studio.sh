#!/usr/bin/env bash
#
# OpenClaw Studio - Multi-Agent Orchestration Platform
# Version: 5.2.0
#
# v5.2.0 — Cloud-only, thin config layer:
#   - BREAKING: Dropped local model (Ollama) support entirely — cloud providers only
#   - Removed: install_ollama, ensure_ollama_running, recommend_context_window, write_models_json
#   - Default provider: google/gemini-2.0-flash (free tier)
#   - Studio is a thin config writer: writes openclaw.json presets, calls CLI, done
#   - Gateway ~800MB is OpenClaw's baseline — not something Studio can reduce
#
# v5.1.0:
#   - Node 24 + npm (dropped bun), IPv6 fix, skills auto-import
#   - auth-profiles.json merge, context window sizing
#
# v5.0.0 (verified against OpenClaw 2026.3.8):
#   - Telegram plugin enabled before channel add
#   - allowFrom set via 'openclaw config set'
#   - API keys in auth-profiles.json
#   - Gateway persistence via 'openclaw gateway install'
#   - Model defaults: gemini-2.0-flash (google)
#
# Works on: Linux, macOS, Windows WSL
#

# =============================================================================
# CONSTANTS & CONFIGURATION
# =============================================================================

VERSION="5.2.0"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_DIR="${HOME}/.openclaw"
WORKSPACE_DIR="${HOME}/.openclaw/workspace"
AGENTS_DIR="${HOME}/.openclaw/agents"
BACKUP_DIR="${HOME}/.openclaw-backups"
LOG_FILE="${CONFIG_DIR}/setup.log"
AGENTS_CONFIG="${CONFIG_DIR}/agents.json"
DEBUG_MODE=0

# Handle --debug flag before anything else
if [[ "${1:-}" == "--debug" ]]; then
    DEBUG_MODE=1
    set -x
    shift
fi

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
MAGENTA='\033[0;35m'
CYAN='\033[0;36m'
WHITE='\033[1;37m'
BOLD='\033[1m'
NC='\033[0m'

SPINNER_FRAMES=('⠋' '⠙' '⠹' '⠸' '⠼' '⠴' '⠦' '⠧' '⠇' '⠏')

declare -A PROVIDERS=(
    ["google"]="Google Gemini (Free tier)"
    ["groq"]="Groq (Free tier)"
    ["zhipu"]="Zhipu GLM (Free tier)"
    ["anthropic"]="Anthropic Claude (Paid)"
    ["openai"]="OpenAI GPT (Paid)"
    ["openrouter"]="OpenRouter (Multi-provider)"
    ["deepseek"]="DeepSeek (Low cost)"
)

declare -A PROVIDER_FREE=(["google"]=1 ["zhipu"]=1 ["groq"]=1)

declare -A PROVIDER_MODELS=(
    ["google"]="gemini-2.0-flash|gemini-1.5-pro|gemini-2.5-flash|gemini-1.5-flash"
    ["groq"]="llama-3.3-70b|llama-3.1-8b|mixtral-8x7b"
    ["zhipu"]="glm-4-flash|glm-4|glm-4-plus"
    ["anthropic"]="claude-sonnet-4|claude-opus-4|claude-3.5-sonnet"
    ["openai"]="gpt-4o|gpt-4-turbo|gpt-3.5-turbo"
    ["openrouter"]="anthropic/claude-sonnet-4|openai/gpt-4o|meta-llama/llama-3.1-70b"
    ["deepseek"]="deepseek-chat|deepseek-coder"
)

# Auth profile provider IDs (for auth-profiles.json)
declare -A PROVIDER_AUTH_ID=(
    ["google"]="google" ["anthropic"]="anthropic" ["openai"]="openai"
    ["groq"]="groq" ["openrouter"]="openrouter" ["deepseek"]="deepseek" ["zhipu"]="zai"
)

# =============================================================================
# UTILITY FUNCTIONS
# =============================================================================

log() {
    local timestamp
    timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    echo "[$timestamp] $1" >> "$LOG_FILE" 2>/dev/null || true
}

debug() { [[ $DEBUG_MODE -eq 1 ]] && echo -e "${YELLOW}[DEBUG]${NC} $1" >&2; }

banner() {
    clear
    echo -e "${CYAN}"
    cat << 'EOF'
 ██████╗ ██████╗ ███████╗███╗   ██╗ ██████╗██╗      █████╗ ██╗    ██╗
██╔═══██╗██╔══██╗██╔════╝████╗  ██║██╔════╝██║     ██╔══██╗██║    ██║
██║   ██║██████╔╝█████╗  ██╔██╗ ██║██║     ██║     ███████║██║ █╗ ██║
██║   ██║██╔═══╝ ██╔══╝  ██║╚██╗██║██║     ██║     ██╔══██║██║███╗██║
╚██████╔╝██║     ███████╗██║ ╚████║╚██████╗███████╗██║  ██║╚███╔███╔╝
 ╚═════╝ ╚═╝     ╚══════╝╚═╝  ╚═══╝ ╚═════╝╚══════╝╚═╝  ╚═╝ ╚══╝╚══╝
EOF
    echo -e "${WHITE}         ─────────────  S T U D I O  ─────────────  v${VERSION}${NC}"
    echo -e "${YELLOW}            Multi-Agent Orchestration Platform${NC}"
    echo ""
}

spinner() {
    local pid=$1 message=$2 i=0
    while kill -0 "$pid" 2>/dev/null; do
        printf "\r${CYAN}${SPINNER_FRAMES[$((i % 10))]}${NC} ${message}"
        i=$((i + 1))
        sleep 0.1
    done
    printf "\r"
}

print_header() {
    echo -e "\n${MAGENTA}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${WHITE}  $1${NC}"
    echo -e "${MAGENTA}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}\n"
}

print_success() { echo -e "${GREEN}✓${NC} $1"; log "OK: $1"; }
print_error()   { echo -e "${RED}✗${NC} $1"; log "ERROR: $1"; }
print_warning() { echo -e "${YELLOW}⚠${NC} $1"; log "WARN: $1"; }
print_info()    { echo -e "${BLUE}ℹ${NC} $1"; }
print_step()    { echo -e "${CYAN}→${NC} $1"; }

confirm() {
    local prompt=$1 default=${2:-n} yn
    if [[ "$default" == "y" ]]; then
        read -rp "$(echo -e "${CYAN}?${NC} ${prompt} [Y/n]: ")" yn
        [[ -z "$yn" || "$yn" =~ ^[Yy] ]]
    else
        read -rp "$(echo -e "${CYAN}?${NC} ${prompt} [y/N]: ")" yn
        [[ "$yn" =~ ^[Yy] ]]
    fi
}

press_enter() {
    echo ""
    read -rp "$(echo -e "${CYAN}Press Enter to continue...${NC}")" _
}

require_jq() {
    if ! check_command jq; then
        print_error "jq is required but not installed. Run option 1 (Install/Update OpenClaw) first."
        return 1
    fi
}

# =============================================================================
# OS DETECTION  (defined early — used by menu_setup)
# =============================================================================

detect_os() {
    if [[ "$OSTYPE" == "linux-gnu"* ]]; then
        if [[ -f /etc/debian_version ]]; then
            DISTRO="Debian"
        elif command -v lsb_release &>/dev/null; then
            DISTRO=$(lsb_release -si 2>/dev/null || echo "Linux")
        else
            DISTRO="Linux"
        fi
        OS="linux"
    elif [[ "$OSTYPE" == "darwin"* ]]; then
        OS="macos"; DISTRO="macOS"
    elif [[ "$OSTYPE" == "msys" || "$OSTYPE" == "cygwin" ]]; then
        OS="windows"; DISTRO="Windows"
    else
        OS="unknown"; DISTRO="Unknown"
    fi
}

is_debian_based() {
    [[ -f /etc/debian_version ]] \
    || [[ "${DISTRO:-}" == "Ubuntu" ]] \
    || [[ "${DISTRO:-}" == "Debian" ]] \
    || [[ "${DISTRO:-}" == "Linux Mint" ]] \
    || [[ "${DISTRO:-}" == "Pop!_OS" ]] \
    || [[ "${DISTRO:-}" == "Parrot" ]]
}

check_command() { command -v "$1" &>/dev/null; }

# =============================================================================
# DEPENDENCY INSTALLATION
# =============================================================================

install_debian_deps() {
    print_header "Installing System Dependencies"
    local deps=("curl" "git" "jq" "build-essential")
    print_info "Running apt-get update..."
    sudo apt-get update -qq 2>/dev/null || { print_warning "apt-get update failed; continuing anyway"; }
    for dep in "${deps[@]}"; do
        if ! check_command "$dep"; then
            printf "  Installing %s..." "$dep"
            if sudo apt-get install -y -qq "$dep" >/dev/null 2>&1; then
                print_success "$dep installed"
            else
                print_warning "$dep installation failed (may be ok)"
            fi
        else
            print_success "$dep already present"
        fi
    done
}

install_node() {
    print_header "Installing Node.js 24 (via nvm)"

    # Install nvm if missing
    if [[ ! -s "$HOME/.nvm/nvm.sh" ]]; then
        print_info "Installing nvm..."
        curl -fsSL https://raw.githubusercontent.com/nvm-sh/nvm/v0.40.3/install.sh | bash 2>/dev/null || true
    fi
    export NVM_DIR="$HOME/.nvm"
    # shellcheck source=/dev/null
    [[ -s "$NVM_DIR/nvm.sh" ]] && . "$NVM_DIR/nvm.sh"

    if check_command node; then
        local cur_ver
        cur_ver=$(node -v 2>/dev/null | sed 's/^v//' | cut -d. -f1)
        if [[ "$cur_ver" -ge 24 ]]; then
            print_success "Node.js $(node -v) already installed"
            return 0
        else
            print_info "Current Node.js $(node -v) is below v24. Upgrading..."
        fi
    fi

    if command -v nvm &>/dev/null; then
        print_info "Installing Node.js 24 via nvm..."
        nvm install 24 2>&1 | tail -3
        nvm use 24 2>/dev/null
        nvm alias default 24 2>/dev/null
        export PATH="$HOME/.nvm/versions/node/$(nvm version 24 2>/dev/null)/bin:$PATH"
        print_success "Node.js $(node -v) installed (npm $(npm -v))"
    else
        print_error "nvm not available — install Node.js 24+ manually from nodejs.org"
        return 1
    fi
}

# =============================================================================
# OPENCLAW INSTALLATION
# =============================================================================

install_openclaw() {
    print_header "Installing OpenClaw"

    if check_command openclaw; then
        local ver
        ver=$(openclaw --version 2>/dev/null || echo "installed")
        print_success "OpenClaw already installed ($ver)"
        if ! confirm "Reinstall/update OpenClaw?" "n"; then
            return 0
        fi
    fi

    print_info "Installing OpenClaw via npm..."
    npm install -g openclaw 2>&1 | tail -5 || true

    if check_command openclaw; then
        print_success "OpenClaw installed ($(openclaw --version 2>/dev/null))"
        mkdir -p "$CONFIG_DIR" "$WORKSPACE_DIR" "$AGENTS_DIR" "$BACKUP_DIR"
    else
        print_error "OpenClaw installation failed — check npm and internet connection"
        return 1
    fi
}

# =============================================================================
# OPENCLAW PREREQUISITES  (NEW — required before agents/gateway work)
# =============================================================================

ensure_openclaw_prerequisites() {
    print_header "Configuring OpenClaw Prerequisites"

    if ! check_command openclaw; then
        print_error "OpenClaw not installed. Run option 1 first."
        return 1
    fi

    # Seed openclaw.json if it doesn't exist (fresh install)
    local oc_config="${CONFIG_DIR}/openclaw.json"
    if [[ ! -f "$oc_config" ]]; then
        print_info "Seeding openclaw.json (fresh install)..."
        mkdir -p "$CONFIG_DIR"
        printf '{"gateway":{"mode":"local"}}\n' > "$oc_config"
        print_success "Created openclaw.json with gateway.mode=local"
    fi

    # 1. Set gateway.mode = local (REQUIRED — gateway refuses to start without it)
    local cur_mode
    cur_mode=$(openclaw config get gateway.mode 2>/dev/null | tr -d '[:space:]')
    if [[ "$cur_mode" != "local" && "$cur_mode" != "remote" ]]; then
        print_info "Setting gateway.mode = local..."
        if openclaw config set gateway.mode local 2>/dev/null; then
            print_success "gateway.mode set to local"
        else
            # Fallback: write directly to JSON (CLI may fail on fresh config)
            print_warning "CLI config set failed; writing gateway.mode directly..."
            if command -v python3 &>/dev/null; then
                python3 -c "
import json,os
f='$oc_config'
d=json.load(open(f)) if os.path.exists(f) else {}
d.setdefault('gateway',{})['mode']='local'
json.dump(d,open(f,'w'),indent=2)
" 2>/dev/null && print_success "gateway.mode written via fallback" \
                    || print_error "CRITICAL: Could not set gateway.mode — gateway will not start"
            else
                # Last resort: jq
                local tmp
                tmp=$(jq '.gateway.mode = "local"' "$oc_config" 2>/dev/null) \
                    && printf '%s\n' "$tmp" > "$oc_config" \
                    && print_success "gateway.mode written via jq fallback" \
                    || print_error "CRITICAL: Could not set gateway.mode — gateway will not start"
            fi
        fi
    else
        print_success "gateway.mode already set ($cur_mode)"
    fi

    # 2. Enable Telegram plugin (required before 'openclaw channels add --channel telegram')
    local tg_status
    tg_status=$(openclaw plugins list 2>/dev/null | grep -i "telegram" | grep -i "loaded\|enabled" || true)
    if [[ -z "$tg_status" ]]; then
        print_info "Enabling Telegram plugin..."
        if openclaw plugins enable telegram 2>/dev/null; then
            print_success "Telegram plugin enabled (restart gateway to apply)"
        else
            print_warning "Could not enable Telegram plugin — may already be enabled or unavailable"
        fi
    else
        print_success "Telegram plugin already enabled"
    fi

    print_success "Prerequisites configured"
}

# =============================================================================
# SKILLS MANAGEMENT
# =============================================================================

import_skills() {
    print_header "Importing Skills from everything-claude-code"

    local tmp_dir="/tmp/everything-claude-code"

    if [[ -d "$tmp_dir" ]]; then
        print_info "Updating skills repository..."
        (cd "$tmp_dir" && git pull -q 2>/dev/null) || true
    else
        print_info "Cloning skills repository..."
        git clone --depth 1 https://github.com/affaan-m/everything-claude-code "$tmp_dir" -q 2>/dev/null \
            || { print_error "Failed to clone skills repo (check internet)"; return 1; }
    fi

    # Find openclaw skills directory
    local openclaw_skills=""
    if check_command openclaw; then
        local oc_bin
        oc_bin=$(which openclaw 2>/dev/null)
        local oc_dir
        oc_dir=$(dirname "$oc_bin")
        # Try npm global path
        for candidate in \
            "${oc_dir}/../lib/node_modules/openclaw/skills" \
            "$(npm root -g 2>/dev/null)/openclaw/skills"; do
            if [[ -d "$candidate" ]]; then
                openclaw_skills="$candidate"
                break
            fi
        done
        # Try nvm path
        if [[ -z "$openclaw_skills" && -d "$HOME/.nvm/versions/node" ]]; then
            local nv
            nv=$(ls "$HOME/.nvm/versions/node" 2>/dev/null | head -1)
            [[ -n "$nv" ]] && openclaw_skills="$HOME/.nvm/versions/node/$nv/lib/node_modules/openclaw/skills"
        fi
    fi

    if [[ -z "$openclaw_skills" || ! -d "$openclaw_skills" ]]; then
        print_error "Could not locate OpenClaw skills directory"
        print_info "Install OpenClaw first (option 1), then retry"
        return 1
    fi

    local before after
    before=$(ls -1 "$openclaw_skills" 2>/dev/null | wc -l)
    cp -r "$tmp_dir/skills/"* "$openclaw_skills/" 2>/dev/null || true
    after=$(ls -1 "$openclaw_skills" 2>/dev/null | wc -l)
    print_success "$((after - before)) new skills imported ($after total) → $openclaw_skills"

    mkdir -p "$AGENTS_DIR"
    cp "$tmp_dir/agents/"*.md "$AGENTS_DIR/" 2>/dev/null && print_success "Agent definitions copied"
}

list_skills() {
    print_header "Available Skills"
    if check_command openclaw; then
        openclaw skills list 2>/dev/null | head -50
    else
        print_warning "OpenClaw not installed"
    fi
}

# =============================================================================
# NATIVE CLI INTEGRATION LAYER  (corrected for OpenClaw 2026.3.8)
# =============================================================================

# Create agent via native CLI with optional Telegram binding
# Usage: create_agent_native <id> <model> <workspace> [telegram_account_id]
create_agent_native() {
    local agent_id="$1" model="$2" workspace="$3" tg_account="${4:-}"

    debug "create_agent_native: id=$agent_id model=$model workspace=$workspace tg=$tg_account"
    mkdir -p "$workspace"

    local bind_args=()
    [[ -n "$tg_account" ]] && bind_args=(--bind "telegram:${tg_account}")

    local out
    if out=$(openclaw agents add "$agent_id" \
        --model "$model" \
        --workspace "$workspace" \
        --non-interactive \
        "${bind_args[@]}" 2>&1); then
        print_success "Agent '$agent_id' created via OpenClaw CLI"
        debug "$out"
        return 0
    else
        print_error "openclaw agents add failed for '$agent_id'"
        print_info "Output: $out"
        return 1
    fi
}

# Add Telegram channel account to config
# Usage: add_telegram_channel <account_id> <bot_token> [display_name]
add_telegram_channel() {
    local account_id="$1" bot_token="$2" display_name="${3:-$1}"

    debug "add_telegram_channel: account=$account_id name=$display_name"

    local out
    if out=$(openclaw channels add \
        --channel telegram \
        --token "$bot_token" \
        --account "$account_id" \
        --name "$display_name" 2>&1); then
        print_success "Telegram account '$account_id' added"
        debug "$out"
        return 0
    else
        print_error "Failed to add Telegram channel for '$account_id'"
        print_info "Output: $out"
        return 1
    fi
}

# Configure Telegram DM policy and allowFrom for an account
# Usage: configure_telegram_allowlist <account_id> <allow_ids_csv_or_star>
configure_telegram_allowlist() {
    local account_id="$1" allow_ids="$2"

    debug "configure_telegram_allowlist: account=$account_id allow=$allow_ids"

    local allow_json dm_policy

    if [[ "$allow_ids" == "*" ]]; then
        allow_json='["*"]'
        dm_policy="open"
    else
        # Convert comma-separated IDs to JSON array (numeric IDs become numbers)
        allow_json=$(echo "$allow_ids" | jq -Rc \
            '[split(",") | .[] | gsub("^ +| +$";"") | if test("^[0-9]+$") then tonumber else . end]' \
            2>/dev/null)
        if [[ -z "$allow_json" ]]; then
            # jq fallback: build array manually
            allow_json=$(printf '["%s"]' "$(echo "$allow_ids" | tr ',' '","')")
        fi
        dm_policy="allowlist"
    fi

    # Set allowFrom first, then dmPolicy (order matters for validation)
    if openclaw config set "channels.telegram.accounts.${account_id}.allowFrom" \
        "$allow_json" --strict-json 2>/dev/null; then
        debug "allowFrom set to $allow_json"
    else
        print_warning "Could not set allowFrom for '$account_id' — check IDs"
    fi

    if openclaw config set "channels.telegram.accounts.${account_id}.dmPolicy" \
        "$dm_policy" 2>/dev/null; then
        print_success "Telegram DM policy: $dm_policy (allowFrom: $allow_ids)"
    else
        print_warning "Could not set dmPolicy for '$account_id'"
    fi
}

# Set agent display identity
# Usage: set_agent_identity <agent_id> <name> <emoji>
set_agent_identity() {
    local agent_id="$1" name="$2" emoji="${3:-🤖}"

    debug "set_agent_identity: id=$agent_id name=$name emoji=$emoji"

    if openclaw agents set-identity \
        --agent "$agent_id" \
        --name "$name" \
        --emoji "$emoji" 2>/dev/null; then
        print_success "Identity set: $emoji $name"
    else
        print_warning "Could not set identity via CLI — writing manually"
        local agent_dir="${AGENTS_DIR}/${agent_id}/agent"
        mkdir -p "$agent_dir"
        printf '{"name":"%s","emoji":"%s","theme":"default"}\n' "$name" "$emoji" \
            > "${agent_dir}/identity.json"
    fi
}

# Write/merge auth-profiles.json for an agent.
# Usage: write_auth_profiles <agent_id> <provider> <api_key>
write_auth_profiles() {
    local agent_id="$1" provider="$2" api_key="$3"

    local agent_dir="${AGENTS_DIR}/${agent_id}/agent"
    mkdir -p "$agent_dir"
    local auth_file="${agent_dir}/auth-profiles.json"

    # Seed existing profiles from file (if any), stripping usageStats
    local existing_profiles="{}"
    if [[ -f "$auth_file" ]]; then
        existing_profiles=$(python3 -c "
import sys,json
try:
    d=json.load(open('$auth_file'))
    print(json.dumps(d.get('profiles',{})))
except: print('{}')
" 2>/dev/null || echo "{}")
    fi

    # Build new profile entry
    local auth_provider="${PROVIDER_AUTH_ID[$provider]:-$provider}"
    local profile_id="${auth_provider}:manual"
    local profile_key="${api_key}"

    debug "write_auth_profiles: agent=$agent_id profile=$profile_id file=$auth_file"

    # Merge new entry into existing profiles
    local merged
    merged=$(python3 -c "
import sys,json
profiles=json.loads(sys.argv[1])
profiles[sys.argv[2]]={'type':'api_key','provider':sys.argv[3],'key':sys.argv[4]}
print(json.dumps(profiles,indent=2))
" "$existing_profiles" "$profile_id" "${provider}" "$profile_key" 2>/dev/null)

    if [[ -z "$merged" ]]; then
        print_error "Failed to merge auth profiles for agent '$agent_id'"
        return 1
    fi

    printf '{\n  "version": 1,\n  "profiles": %s\n}\n' "$merged" > "$auth_file"
    chmod 600 "$auth_file"
    print_success "Auth profile '${profile_id}' stored for agent '$agent_id'"
}

# =============================================================================
# INTERACTIVE AGENT WIZARD  (corrected full workflow)
# =============================================================================

create_agent_interactive() {
    local agent_num=$1 total=$2

    print_header "Agent $agent_num of $total"

    local agent_id agent_name emoji profile model provider api_key bot_token allow_ids
    local -a skills=()

    # --- Agent ID ---
    echo ""
    read -rp "$(echo -e "${CYAN}Agent ID${NC} (lowercase, no spaces, e.g. 'assistant'): ")" agent_id
    [[ -z "$agent_id" ]] && agent_id="agent${agent_num}"
    agent_id=$(echo "$agent_id" | tr '[:upper:]' '[:lower:]' | tr -d ' ')

    # --- Agent Name ---
    read -rp "$(echo -e "${CYAN}Display Name${NC} (e.g. 'Personal Assistant'): ")" agent_name
    [[ -z "$agent_name" ]] && agent_name="$agent_id"

    # --- Emoji ---
    read -rp "$(echo -e "${CYAN}Emoji${NC} (default 🤖): ")" emoji
    [[ -z "$emoji" ]] && emoji="🤖"

    # --- Profile / Persona ---
    echo ""
    print_info "Agent profile describes the persona and specialization."
    read -rp "$(echo -e "${CYAN}Profile${NC} (optional, press Enter to skip): ")" profile

    # --- Model Provider ---
    echo ""
    print_step "Select model provider:"
    local provider_order=(google groq zhipu anthropic openai openrouter deepseek)
    local i=1
    for p in "${provider_order[@]}"; do
        local badge=""
        [[ "${PROVIDER_FREE[$p]:-0}" == "1" ]] && badge="${GREEN}[FREE]${NC} "
        [[ "${PROVIDER_FREE[$p]:-0}" != "1" ]] && badge="${YELLOW}[PAID]${NC} "
        printf "  %d) %b%s\n" "$i" "$badge" "${PROVIDERS[$p]}"
        ((i++))
    done
    echo ""
    read -rp "$(echo -e "${CYAN}Select provider${NC} [1-7, default=1 Google]: ")" provider_choice
    [[ -z "$provider_choice" ]] && provider_choice=1
    case $provider_choice in
        1) provider="google" ;;
        2) provider="groq" ;;
        3) provider="zhipu" ;;
        4) provider="anthropic" ;;
        5) provider="openai" ;;
        6) provider="openrouter" ;;
        7) provider="deepseek" ;;
        *) provider="google" ;;
    esac

    # --- Model Selection ---
    local models_str="${PROVIDER_MODELS[$provider]}"
    IFS='|' read -ra models <<< "$models_str"
    echo ""
    print_step "Select model for ${PROVIDERS[$provider]}:"
    for i in "${!models[@]}"; do
        printf "  %d) %s\n" "$((i+1))" "${models[$i]}"
    done
    printf "  %d) Enter custom model ID\n" "$((${#models[@]}+1))"
    read -rp "$(echo -e "${CYAN}Select model${NC} [default=1]: ")" model_choice
    [[ -z "$model_choice" ]] && model_choice=1

    if [[ "$model_choice" -eq $((${#models[@]}+1)) ]]; then
        read -rp "$(echo -e "${CYAN}Custom model ID${NC}: ")" custom_model
        model="${provider}/${custom_model:-${models[0]}}"
    elif [[ "$model_choice" -ge 1 && "$model_choice" -le "${#models[@]}" ]]; then
        model="${provider}/${models[$((model_choice-1))]}"
    else
        model="${provider}/${models[0]}"
    fi

    # --- API Key ---
    api_key=""
    echo ""
    local key_env_var="${provider^^}_API_KEY"
    print_step "API Key for ${PROVIDERS[$provider]}"
    read -rp "$(echo -e "${CYAN}API Key${NC} (or Enter to use \$${key_env_var}): ")" api_key
    if [[ -z "$api_key" ]]; then
        api_key="${!key_env_var:-}"
        [[ -n "$api_key" ]] && print_info "Using \$${key_env_var} from environment"
    fi

    # --- Skills ---
    echo ""
    print_step "Select skills (comma-separated numbers, 'all', or Enter to skip):"
    local skills_dir=""
    local oc_bin; oc_bin=$(which openclaw 2>/dev/null)
    for candidate in \
        "$(dirname "$oc_bin")/../lib/node_modules/openclaw/skills" \
        "$(npm root -g 2>/dev/null)/openclaw/skills"; do
        [[ -d "$candidate" ]] && { skills_dir="$candidate"; break; }
    done

    local skill_list=()
    if [[ -n "$skills_dir" ]]; then
        mapfile -t skill_list < <(ls -1 "$skills_dir" 2>/dev/null | head -30)
    else
        mapfile -t skill_list < <(ls -1 "${AGENTS_DIR}" 2>/dev/null | sed 's/\.md$//' | head -30)
    fi

    if [[ ${#skill_list[@]} -gt 0 ]]; then
        for i in "${!skill_list[@]}"; do
            printf "  %2d) %s\n" "$((i+1))" "${skill_list[$i]}"
        done
        read -rp "$(echo -e "${CYAN}Select skills${NC}: ")" skill_choice
        if [[ "$skill_choice" == "all" ]]; then
            skills=("${skill_list[@]}")
        elif [[ -n "$skill_choice" ]]; then
            IFS=',' read -ra indices <<< "$skill_choice"
            for idx in "${indices[@]}"; do
                idx=$(echo "$idx" | tr -d ' ')
                local pos=$((idx - 1))
                [[ $pos -ge 0 && $pos -lt ${#skill_list[@]} ]] && skills+=("${skill_list[$pos]}")
            done
        fi
    else
        print_info "No skills directory found — import skills first (option 2)"
    fi

    # --- Telegram Bot Token ---
    echo ""
    print_header "Telegram Bot Configuration"
    read -rp "$(echo -e "${CYAN}Bot Token${NC} (from @BotFather, or Enter to skip): ")" bot_token

    allow_ids=""
    if [[ -n "$bot_token" ]]; then
        echo ""
        print_step "Restrict bot to specific Telegram user IDs"
        print_info "Get your Telegram ID: use option 8 in main menu, or message @userinfobot"
        read -rp "$(echo -e "${CYAN}Allowed User IDs${NC} (comma-separated, or '*' for all): ")" allow_ids
        [[ -z "$allow_ids" ]] && allow_ids="*"
    fi

    # =========================================================================
    # EXECUTE: create channel → set allowlist → create agent → set identity
    # =========================================================================
    echo ""
    print_header "Creating Agent: $agent_name ($agent_id)"

    local workspace="${WORKSPACE_DIR}/${agent_id}"
    local native_success=1

    # Step 1: Add Telegram channel (must happen before agent binding)
    if [[ -n "$bot_token" ]]; then
        if add_telegram_channel "$agent_id" "$bot_token" "$agent_name"; then
            configure_telegram_allowlist "$agent_id" "$allow_ids"
        else
            print_warning "Telegram channel setup failed; agent will be created without Telegram"
            bot_token=""
        fi
    fi

    # Step 2: Create agent (with binding if Telegram configured)
    local tg_bind=""
    [[ -n "$bot_token" ]] && tg_bind="$agent_id"

    if ! create_agent_native "$agent_id" "$model" "$workspace" "$tg_bind"; then
        print_warning "Native CLI agent creation failed; saving config manually"
        native_success=0
    fi

    # Step 3: Set identity
    set_agent_identity "$agent_id" "$agent_name" "$emoji"

    # Step 4: Store auth in auth-profiles.json
    write_auth_profiles "$agent_id" "$provider" "$api_key"

    # Step 5: Write profile to workspace IDENTITY.md if provided
    if [[ -n "$profile" ]]; then
        mkdir -p "$workspace"
        cat > "${workspace}/IDENTITY.md" << EOF
# ${agent_name}

${profile}
EOF
        debug "Profile written to ${workspace}/IDENTITY.md"
    fi

    # Step 6: Track in agents.json
    local agent_record
    agent_record=$(jq -n \
        --arg id "$agent_id" \
        --arg name "$agent_name" \
        --arg emoji "$emoji" \
        --arg profile "$profile" \
        --arg model "$model" \
        --arg bot_token "$bot_token" \
        --arg allow_ids "$allow_ids" \
        --argjson skills "$(printf '%s\n' "${skills[@]}" | jq -R . | jq -s . 2>/dev/null || echo '[]')" \
        --arg created_at "$(date -Iseconds 2>/dev/null || date)" \
        --argjson native_cli "$([[ $native_success -eq 1 ]] && echo 'true' || echo 'false')" \
        '{id:$id,name:$name,emoji:$emoji,profile:$profile,model:$model,
          bot_token:$bot_token,allow_from:[$allow_ids],skills:$skills,
          created_at:$created_at,native_cli:$native_cli}' 2>/dev/null || echo '{}')

    mkdir -p "$CONFIG_DIR"
    if [[ ! -f "$AGENTS_CONFIG" ]]; then
        echo '{"agents":{},"default_agent":null}' > "$AGENTS_CONFIG"
    fi

    local tmp
    tmp=$(mktemp)
    if jq --argjson rec "$agent_record" ".agents[\"${agent_id}\"] = \$rec" \
        "$AGENTS_CONFIG" > "$tmp" 2>/dev/null; then
        mv "$tmp" "$AGENTS_CONFIG"
    fi

    # Set as default if first agent
    local cur_default
    cur_default=$(jq -r '.default_agent // empty' "$AGENTS_CONFIG" 2>/dev/null)
    if [[ -z "$cur_default" ]]; then
        if confirm "Set '${agent_name}' as the default agent?" "y"; then
            tmp=$(mktemp)
            jq ".default_agent = \"${agent_id}\"" "$AGENTS_CONFIG" > "$tmp" && mv "$tmp" "$AGENTS_CONFIG"
            print_success "Default agent: $agent_id"
        fi
    fi

    echo ""
    print_success "Agent '${emoji} ${agent_name}' (${agent_id}) configured"
    [[ -n "$bot_token" ]] && print_info "Telegram: @BotFather bot connected, dmPolicy=$( [[ "$allow_ids" == "*" ]] && echo open || echo allowlist)"
    print_info "Model: $model"
    print_info "Run option 7 (Activate Agents) to start the gateway"
}

setup_multi_agent() {
    print_header "Multi-Agent Setup"

    echo ""
    print_info "Configure multiple agents, each with their own:"
    echo "  • Telegram bot token + allowed user IDs"
    echo "  • Model, API key, and skills"
    echo "  • Display name and persona profile"
    echo ""

    local num_agents
    read -rp "$(echo -e "${CYAN}How many agents to configure?${NC} [1-10]: ")" num_agents
    num_agents=$(( num_agents < 1 ? 1 : (num_agents > 10 ? 10 : num_agents) ))

    for i in $(seq 1 "$num_agents"); do
        create_agent_interactive "$i" "$num_agents"
        echo ""
        [[ $i -lt $num_agents ]] && press_enter
    done

    print_header "Agents Configured"
    list_agents
}

# =============================================================================
# AGENT-POOL.JSON DEPLOYMENT
# =============================================================================

deploy_from_agent_pool() {
    print_header "Deploy from agent-pool.json"

    local pool_file="${SCRIPT_DIR}/agent-pool.json"

    if [[ ! -f "$pool_file" ]]; then
        print_warning "No agent-pool.json found"
        print_info "Creating sample at $pool_file..."
        cat > "$pool_file" << 'EOF'
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
      "skills": ["coding-agent", "backend-patterns"],
      "description": "Python backend specialist",
      "role": "Python development"
    }
  },
  "routing": {
    "python": ["python-dev"],
    "architecture": ["orchestrator"]
  }
}
EOF
        print_success "Sample agent-pool.json created — edit it and run this option again"
        return 0
    fi

    require_jq || return 1

    local agent_ids
    mapfile -t agent_ids < <(jq -r '.agents | keys[]' "$pool_file" 2>/dev/null)
    local agent_count=${#agent_ids[@]}

    if [[ $agent_count -eq 0 ]]; then
        print_error "No agents in agent-pool.json"
        return 1
    fi

    print_info "Found $agent_count agents to deploy:"
    echo ""
    for agent_id in "${agent_ids[@]}"; do
        local role skills_count
        role=$(jq -r ".agents[\"$agent_id\"].role // \"Agent\"" "$pool_file")
        skills_count=$(jq ".agents[\"$agent_id\"].skills | length" "$pool_file" 2>/dev/null || echo 0)
        printf "  ${GREEN}%-20s${NC} %s (%s skills)\n" "$agent_id" "$role" "$skills_count"
    done
    echo ""

    confirm "Deploy these ${agent_count} agents?" "y" || { print_info "Cancelled"; return 0; }

    local success_count=0 fail_count=0

    for agent_id in "${agent_ids[@]}"; do
        echo ""
        print_step "Deploying: $agent_id"
        local model role workspace
        model=$(jq -r ".agents[\"$agent_id\"].model // \"google/gemini-2.0-flash\"" "$pool_file")
        role=$(jq -r ".agents[\"$agent_id\"].role // \"Agent\"" "$pool_file")
        workspace="${WORKSPACE_DIR}/${agent_id}"

        if create_agent_native "$agent_id" "$model" "$workspace" ""; then
            ((success_count++))
            set_agent_identity "$agent_id" "$role" "🤖"

            # Write auth-profiles.json
            local pool_provider="${model%%/*}"
            local pool_api_key
            pool_api_key=$(jq -r ".agents[\"$agent_id\"].api_key // \"\"" "$pool_file" 2>/dev/null)
            write_auth_profiles "$agent_id" "$pool_provider" "$pool_api_key"

            # Track in agents.json
            mkdir -p "$CONFIG_DIR"
            [[ ! -f "$AGENTS_CONFIG" ]] && echo '{"agents":{},"default_agent":null}' > "$AGENTS_CONFIG"
            local rec
            rec=$(jq -n --arg id "$agent_id" --arg name "$role" --arg model "$model" \
                '{"id":$id,"name":$name,"emoji":"🤖","model":$model,"native_cli":true,"source":"agent-pool.json"}' 2>/dev/null || echo '{}')
            local tmp; tmp=$(mktemp)
            jq --argjson rec "$rec" ".agents[\"${agent_id}\"] = \$rec" "$AGENTS_CONFIG" > "$tmp" 2>/dev/null && mv "$tmp" "$AGENTS_CONFIG"
        else
            ((fail_count++))
        fi
    done

    echo ""
    print_header "Deployment Summary"
    print_success "Deployed: $success_count agents"
    [[ $fail_count -gt 0 ]] && print_error "Failed: $fail_count agents"

    # Show routing
    local routing_keys
    mapfile -t routing_keys < <(jq -r '.routing | keys[]' "$pool_file" 2>/dev/null)
    if [[ ${#routing_keys[@]} -gt 0 ]]; then
        echo ""
        print_info "Routing rules:"
        for key in "${routing_keys[@]}"; do
            local targets
            targets=$(jq -r ".routing[\"$key\"] | join(\", \")" "$pool_file" 2>/dev/null)
            printf "  ${CYAN}%-15s${NC} → %s\n" "$key" "$targets"
        done
    fi
}

# =============================================================================
# AGENT MANAGEMENT
# =============================================================================

list_agents() {
    print_header "Configured Agents"

    # Show from OpenClaw CLI first (authoritative)
    if check_command openclaw; then
        print_info "From OpenClaw CLI:"
        local cli_out
        cli_out=$(openclaw agents list --bindings 2>&1) || true
        if [[ -n "$cli_out" ]]; then
            # Strip doctor warning box lines (│ ├ ╮ ╯ ◇) for cleaner output
            echo "$cli_out" | grep -vE '^\s*[│├╮╯◇]|Doctor warnings|^\s*$' | grep -v '🦞' || true
        else
            print_warning "Could not query OpenClaw agent list"
        fi
    fi

    if [[ ! -f "$AGENTS_CONFIG" ]]; then
        print_info "(No local agents.json tracking file)"
        return
    fi

    require_jq || return 1
    local count
    count=$(jq '.agents | length' "$AGENTS_CONFIG" 2>/dev/null || echo 0)
    [[ "$count" -eq 0 ]] && return

    echo ""
    print_info "From local tracking (agents.json): $count agent(s)"
    jq -r '.agents | to_entries[] |
        "  \(.value.emoji // "🤖") \(.key): \(.value.name) [\(.value.model // "no model")]\n" +
        "    Bot: \(.value.bot_token // "none" | if . != "none" and . != "" then "configured" else "not set" end)\n" +
        "    Allowed: \(.value.allow_from // [] | join(", "))\n" +
        "    Skills: \(.value.skills // [] | length)"' \
        "$AGENTS_CONFIG" 2>/dev/null
    echo ""
    local default
    default=$(jq -r '.default_agent // "none"' "$AGENTS_CONFIG" 2>/dev/null)
    print_info "Default agent: $default"
}

# Change an existing agent's model in OpenClaw native config.
# Usage: set_agent_model <agent_id> <model_string>
set_agent_model() {
    local agent_id="$1" new_model="$2"

    local idx
    idx=$(openclaw agents list --json 2>/dev/null \
        | jq -r --arg id "$agent_id" 'to_entries[] | select(.value.id==$id) | .key' 2>/dev/null)

    if [[ -z "$idx" ]]; then
        print_error "Agent '$agent_id' not found in OpenClaw (openclaw agents list)"
        return 1
    fi

    if openclaw config set "agents.list.${idx}.model" "$new_model" 2>/dev/null; then
        print_success "Agent '$agent_id' model → $new_model"
        openclaw gateway restart 2>/dev/null && print_info "Gateway restarted" || true
    else
        print_error "openclaw config set failed for agents.list.${idx}.model"
        return 1
    fi
}

edit_agent() {
    print_header "Edit Agent"
    require_jq || return 1

    local agents=()
    mapfile -t agents < <(openclaw agents list --json 2>/dev/null | jq -r '.[].id' 2>/dev/null)
    [[ ${#agents[@]} -eq 0 ]] && { print_warning "No agents found in OpenClaw"; return; }

    # Read current values directly from OpenClaw native config
    local oc_agents_json
    oc_agents_json=$(openclaw agents list --json 2>/dev/null)

    echo ""
    for i in "${!agents[@]}"; do
        local cur_model
        cur_model=$(echo "$oc_agents_json" | jq -r --arg id "${agents[$i]}" '.[] | select(.id==$id) | .model // "(default)"' 2>/dev/null)
        printf "  %d) %-20s  model: %s\n" "$((i+1))" "${agents[$i]}" "$cur_model"
    done
    echo ""
    read -rp "$(echo -e "${CYAN}Select agent to edit${NC}: ")" choice
    local sel_idx=$((choice - 1))

    if [[ $sel_idx -ge 0 && $sel_idx -lt ${#agents[@]} ]]; then
        local agent_id="${agents[$sel_idx]}"
        local cur_name cur_model cur_bot cur_allow
        cur_name=$(echo "$oc_agents_json"   | jq -r --arg id "$agent_id" '.[] | select(.id==$id) | .identityName // .name // .id')
        cur_model=$(echo "$oc_agents_json"  | jq -r --arg id "$agent_id" '.[] | select(.id==$id) | .model // ""')
        cur_bot=$(openclaw config get "channels.telegram.accounts.${agent_id}.botToken" 2>/dev/null \
            | grep -v "^🦞" | grep -v "^$" | head -1 | tr -d '"' || echo "")
        cur_allow=$(openclaw config get "channels.telegram.accounts.${agent_id}.allowFrom" 2>/dev/null \
            | grep -v "^🦞" | python3 -c "import sys,json; v=json.load(sys.stdin); print(','.join(str(x) for x in v))" 2>/dev/null || echo "")

        echo ""
        print_info "Editing: $agent_id  (Enter = keep current)"
        echo ""
        echo -e "  ${CYAN}1.${NC} Change model   [$cur_model]"
        echo -e "  ${CYAN}2.${NC} Change name    [$cur_name]"
        echo -e "  ${CYAN}3.${NC} Change bot token"
        echo -e "  ${CYAN}4.${NC} Change allowed IDs  [$cur_allow]"
        echo -e "  ${MAGENTA}0.${NC} Cancel"
        echo ""
        read -rp "$(echo -e "${CYAN}What to edit${NC}: ")" edit_choice

        case $edit_choice in
            1)
                echo ""
                echo -e "  ${BOLD}Available models:${NC}"
                local i=1
                for p in "${!PROVIDER_MODELS[@]}"; do
                    local first_model="${PROVIDER_MODELS[$p]%%|*}"
                    printf "    %d) %s/%s\n" "$i" "$p" "$first_model"
                    i=$((i+1))
                done
                echo ""
                read -rp "$(echo -e "${CYAN}New model (e.g. google/gemini-2.0-flash)${NC} [$cur_model]: ")" new_model
                if [[ -n "$new_model" ]]; then
                    set_agent_model "$agent_id" "$new_model"
                    local new_provider="${new_model%%/*}"
                    local new_key=""
                    read -rp "$(echo -e "${CYAN}API key for $new_provider${NC} (Enter to skip): ")" new_key
                    write_auth_profiles "$agent_id" "$new_provider" "$new_key"
                else
                    print_info "Model unchanged"
                fi
                ;;
            2)
                read -rp "$(echo -e "${CYAN}New name${NC} [$cur_name]: ")" new_name
                [[ -n "$new_name" ]] && \
                    openclaw agents set-identity --agent "$agent_id" --name "$new_name" 2>/dev/null && \
                    print_success "Name updated to '$new_name'" || print_info "Name unchanged"
                ;;
            3)
                read -rp "$(echo -e "${CYAN}New bot token${NC}: ")" new_bot
                [[ -n "$new_bot" ]] && add_telegram_channel "$agent_id" "$new_bot" "$cur_name"
                ;;
            4)
                read -rp "$(echo -e "${CYAN}Allowed Telegram IDs${NC} (comma-separated, * for open) [$cur_allow]: ")" new_allow
                [[ -n "$new_allow" ]] && configure_telegram_allowlist "$agent_id" "$new_allow"
                ;;
            0) return ;;
        esac

        print_success "Agent '$agent_id' updated"
    fi
}

delete_agent() {
    print_header "Delete Agent"
    require_jq || return 1

    [[ ! -f "$AGENTS_CONFIG" ]] && { print_warning "No agents configured"; return; }
    local agents=()
    mapfile -t agents < <(jq -r '.agents | keys[]' "$AGENTS_CONFIG" 2>/dev/null)
    [[ ${#agents[@]} -eq 0 ]] && { print_warning "No agents configured"; return; }

    echo ""
    for i in "${!agents[@]}"; do
        local name
        name=$(jq -r ".agents[\"${agents[$i]}\"].name // \"${agents[$i]}\"" "$AGENTS_CONFIG")
        printf "  %d) %s: %s\n" "$((i+1))" "${agents[$i]}" "$name"
    done
    echo ""
    read -rp "$(echo -e "${CYAN}Select agent to delete${NC}: ")" choice
    local idx=$((choice - 1))

    if [[ $idx -ge 0 && $idx -lt ${#agents[@]} ]]; then
        local agent_id="${agents[$idx]}"
        if confirm "Delete agent '$agent_id'? This removes it from OpenClaw too." "n"; then
            # Remove from OpenClaw
            openclaw agents delete "$agent_id" 2>/dev/null && print_success "Removed from OpenClaw" || print_warning "Could not remove from OpenClaw CLI"
            # Remove from tracking
            local tmp; tmp=$(mktemp)
            jq "del(.agents[\"$agent_id\"])" "$AGENTS_CONFIG" > "$tmp" && mv "$tmp" "$AGENTS_CONFIG"
            print_success "Agent '$agent_id' deleted"
        fi
    fi
}

# =============================================================================
# GATEWAY MANAGEMENT  (corrected: uses openclaw gateway install/start)
# =============================================================================

is_port_in_use() {
    local port=$1
    if command -v ss &>/dev/null; then
        ss -lnpt 2>/dev/null | grep -qE ":${port}\s"
    elif command -v netstat &>/dev/null; then
        netstat -lnpt 2>/dev/null | grep -qE ":${port}\s"
    elif command -v lsof &>/dev/null; then
        lsof -i ":$port" -sTCP:LISTEN -t &>/dev/null
    else
        return 1
    fi
}

activate_agents() {
    print_header "Activate Agents (Start Gateway)"

    if ! check_command openclaw; then
        print_error "OpenClaw not installed. Run option 1 first."
        return 1
    fi

    # Ensure prerequisites
    ensure_openclaw_prerequisites

    # Install gateway service (idempotent — safe to call multiple times)
    # Uses node runtime (Node 24+). If IPv6 issues cause Telegram timeouts,
    # add 'precedence ::ffff:0:0/96  100' to /etc/gai.conf to prefer IPv4.
    print_info "Installing gateway service (node runtime)..."
    if openclaw gateway install --runtime node 2>/dev/null; then
        print_success "Gateway service installed (systemd user / launchd / schtasks)"
    else
        print_warning "Gateway service install step returned non-zero (may already be installed)"
    fi

    # Start/restart the gateway service
    print_info "Starting gateway service..."
    local started=0
    if openclaw gateway status 2>/dev/null | grep -qi "running\|active"; then
        print_info "Gateway already running; restarting to apply config..."
        if openclaw gateway restart 2>/dev/null; then
            print_success "Gateway restarted"
            started=1
        fi
    else
        if openclaw gateway start 2>/dev/null; then
            print_success "Gateway started"
            started=1
        else
            # Fallback: run in background
            print_warning "Service start failed; starting in background..."
            nohup openclaw gateway run > "${CONFIG_DIR}/gateway.log" 2>&1 &
            sleep 4
            is_port_in_use 18789 && started=1
        fi
    fi

    if [[ $started -eq 0 ]]; then
        print_error "Gateway failed to start"
        print_info "Check logs: openclaw logs  OR  journalctl --user -u openclaw-gateway.service"
        return 1
    fi

    # Brief pause for gateway to fully initialize channels
    sleep 3

    # Show live status
    show_checklist
}

# =============================================================================
# FINAL CHECKLIST  (NEW — live status of all components)
# =============================================================================

show_checklist() {
    print_header "Active System Checklist"

    local passed=0 warned=0 failed=0

    echo ""
    print_info "── Dependencies ──"

    for cmd in openclaw node jq curl; do
        if check_command "$cmd"; then
            local ver
            ver=$("$cmd" --version 2>/dev/null | head -1 | tr -d '\n' || echo "ok")
            printf "  ${GREEN}✓${NC} %-12s %s\n" "$cmd" "$ver"
            ((passed++))
        else
            printf "  ${RED}✗${NC} %-12s NOT FOUND\n" "$cmd"
            ((failed++))
        fi
    done

    echo ""
    print_info "── Gateway ──"

    local gw_health
    gw_health=$(openclaw health 2>/dev/null | head -3 || echo "unreachable")
    if echo "$gw_health" | grep -qi "ok"; then
        printf "  ${GREEN}✓${NC} Gateway: running (port 18789)\n"
        ((passed++))
    else
        printf "  ${RED}✗${NC} Gateway: not responding\n"
        print_info "    Start with: openclaw gateway start"
        ((failed++))
    fi

    # Service persistence
    if systemctl --user is-enabled openclaw-gateway.service &>/dev/null; then
        printf "  ${GREEN}✓${NC} Service: enabled (survives reboot)\n"
        ((passed++))
    elif [ -f "${HOME}/.config/systemd/user/openclaw-gateway.service" ]; then
        printf "  ${YELLOW}⚠${NC} Service file exists but may not be enabled\n"
        print_info "    Enable: systemctl --user enable --now openclaw-gateway.service"
        ((warned++))
    else
        printf "  ${YELLOW}⚠${NC} Service not registered (run Activate Agents to install)\n"
        ((warned++))
    fi

    echo ""
    print_info "── Agents ──"

    local agent_list
    agent_list=$(openclaw agents list --json 2>/dev/null || echo '[]')
    local agent_count
    agent_count=$(echo "$agent_list" | jq 'length' 2>/dev/null || echo 0)

    if [[ "$agent_count" -gt 0 ]]; then
        printf "  ${GREEN}✓${NC} %s agent(s) configured:\n" "$agent_count"
        echo "$agent_list" | jq -r '.[] |
            "    \(if .isDefault then "★ " else "  " end)\(.id): model=\(.model // "inherited") bindings=\(.bindingDetails // [] | join(", "))"' 2>/dev/null
        ((passed++))
    else
        printf "  ${YELLOW}⚠${NC} No agents configured (use option 3 to add agents)\n"
        ((warned++))
    fi

    echo ""
    print_info "── Telegram Channels ──"

    local ch_status
    ch_status=$(openclaw channels status 2>/dev/null || echo "")
    if [[ -n "$ch_status" ]]; then
        echo "$ch_status" | grep -i "telegram" | while IFS= read -r line; do
            if echo "$line" | grep -qi "running"; then
                printf "  ${GREEN}✓${NC} %s\n" "$line"
            elif echo "$line" | grep -qi "error\|stopped"; then
                printf "  ${RED}✗${NC} %s\n" "$line"
            else
                printf "  ${BLUE}ℹ${NC} %s\n" "$line"
            fi
        done || true
        if ! echo "$ch_status" | grep -qi "telegram"; then
            printf "  ${YELLOW}⚠${NC} No Telegram channels found\n"
            ((warned++))
        fi
    else
        printf "  ${YELLOW}⚠${NC} Could not query channel status\n"
        ((warned++))
    fi

    echo ""
    print_info "── Skills ──"

    local skill_count=0
    if check_command openclaw; then
        skill_count=$(openclaw skills list 2>/dev/null | grep -c "✓\|✗\|missing" || echo 0)
    fi
    if [[ $skill_count -gt 0 ]]; then
        printf "  ${GREEN}✓${NC} Skills available: %s\n" "$skill_count"
    else
        printf "  ${YELLOW}⚠${NC} No skills found (use option 2 to import)\n"
        ((warned++))
    fi

    # Summary
    echo ""
    print_header "Summary"
    [[ $passed -gt 0 ]]  && print_success "$passed checks passed"
    [[ $warned -gt 0 ]]  && print_warning "$warned warnings"
    [[ $failed -gt 0 ]]  && print_error "$failed checks failed"

    # Write status to file for post-reboot reference
    {
        echo "# OpenClaw Status — $(date)"
        echo ""
        echo "## Agents"
        openclaw agents list 2>/dev/null || echo "(not available)"
        echo ""
        echo "## Channels"
        openclaw channels status 2>/dev/null || echo "(not available)"
        echo ""
        echo "## Gateway"
        openclaw gateway status 2>/dev/null || echo "(not available)"
    } > "${CONFIG_DIR}/status.md" 2>/dev/null || true

    echo ""
    print_info "Status saved to: ${CONFIG_DIR}/status.md"
}

# =============================================================================
# TELEGRAM BOT UTILITIES
# =============================================================================

get_telegram_user_id() {
    print_header "Get Telegram User ID"

    require_jq || return 1
    local bot_token=""

    # Try to find first bot token
    if [[ -f "$AGENTS_CONFIG" ]]; then
        bot_token=$(jq -r '[.agents[] | select(.bot_token != null and .bot_token != "")] | .[0].bot_token // empty' \
            "$AGENTS_CONFIG" 2>/dev/null)
    fi

    if [[ -z "$bot_token" ]]; then
        read -rp "$(echo -e "${CYAN}Enter bot token${NC}: ")" bot_token
    fi

    [[ -z "$bot_token" ]] && { print_error "No bot token provided"; return 1; }

    print_info "Send a message to your bot, then press Enter to fetch your user ID..."
    read -rp "" _

    local updates
    updates=$(curl -s --max-time 10 "https://api.telegram.org/bot${bot_token}/getUpdates" 2>/dev/null)
    if [[ -z "$updates" ]]; then
        print_error "Failed to reach Telegram API (check internet/token)"
        return 1
    fi

    local user_id username first_name
    user_id=$(echo "$updates"    | jq -r '.result[-1].message.from.id // empty' 2>/dev/null)
    username=$(echo "$updates"   | jq -r '.result[-1].message.from.username // empty' 2>/dev/null)
    first_name=$(echo "$updates" | jq -r '.result[-1].message.from.first_name // empty' 2>/dev/null)

    if [[ -n "$user_id" ]]; then
        echo ""
        print_success "User found:"
        echo "  ID: $user_id"
        [[ -n "$username" ]]   && echo "  Username: @$username"
        [[ -n "$first_name" ]] && echo "  Name: $first_name"
        echo ""
        print_info "Add this ID to an agent's allowlist via option 4 (Edit Agent)"
    else
        print_error "No messages found. Did you send a message to your bot?"
        print_info "Raw response: $(echo "$updates" | jq -c '.result | length' 2>/dev/null || echo "$updates" | head -1)"
    fi
}

test_telegram_bot() {
    print_header "Test Telegram Bot"

    require_jq || return 1
    local bot_token=""

    if [[ -f "$AGENTS_CONFIG" ]]; then
        bot_token=$(jq -r '[.agents[] | select(.bot_token != null and .bot_token != "")] | .[0].bot_token // empty' \
            "$AGENTS_CONFIG" 2>/dev/null)
    fi

    [[ -z "$bot_token" ]] && read -rp "$(echo -e "${CYAN}Enter bot token${NC}: ")" bot_token
    [[ -z "$bot_token" ]] && { print_error "No bot token"; return 1; }

    print_info "Testing bot connection..."
    local me
    me=$(curl -s --max-time 10 "https://api.telegram.org/bot${bot_token}/getMe" 2>/dev/null)

    local ok
    ok=$(echo "$me" | jq -r '.ok // false' 2>/dev/null)
    if [[ "$ok" == "true" ]]; then
        local bot_name bot_username
        bot_name=$(echo "$me" | jq -r '.result.first_name // "Unknown"')
        bot_username=$(echo "$me" | jq -r '.result.username // "unknown"')
        print_success "Bot connected: $bot_name (@$bot_username)"
    else
        local err
        err=$(echo "$me" | jq -r '.description // "Unknown error"' 2>/dev/null)
        print_error "Bot connection failed: $err"
        return 1
    fi
}

# =============================================================================
# HEALTH CHECK
# =============================================================================

health_check() {
    print_header "System Health Check"

    local passed=0 failed=0 warnings=0

    echo ""
    print_info "Checking dependencies..."
    for cmd in curl git jq node npm; do
        if check_command "$cmd"; then
            local ver
            ver=$("$cmd" --version 2>/dev/null | head -1)
            print_success "$cmd: $ver"
            ((passed++))
        else
            print_error "$cmd: NOT FOUND"
            ((failed++))
        fi
    done

    check_command bun \
        && { print_success "bun: $(bun -v 2>/dev/null)"; ((passed++)); } \
        || { print_warning "bun: not installed (optional)"; ((warnings++)); }

    echo ""
    print_info "Checking OpenClaw..."
    if check_command openclaw; then
        print_success "OpenClaw: $(openclaw --version 2>/dev/null || echo 'installed')"
        ((passed++))
    else
        print_error "OpenClaw: NOT INSTALLED"
        ((failed++))
    fi

    echo ""
    print_info "Checking gateway..."
    if openclaw health 2>/dev/null | grep -qi "ok"; then
        print_success "Gateway: running"
        ((passed++))
    else
        print_warning "Gateway: not running (run option 7 to start)"
        ((warnings++))
    fi

    echo ""
    print_info "Checking configuration..."
    if [[ -f "$AGENTS_CONFIG" ]]; then
        local count
        count=$(jq '.agents | length' "$AGENTS_CONFIG" 2>/dev/null || echo 0)
        print_success "Agents configured: $count"
        ((passed++))
    else
        print_warning "No agents configured"
        ((warnings++))
    fi

    echo ""
    print_info "Checking Telegram bots..."
    if [[ -f "$AGENTS_CONFIG" ]]; then
        local bot_count
        bot_count=$(jq '[.agents[] | select(.bot_token != null and .bot_token != "")] | length' \
            "$AGENTS_CONFIG" 2>/dev/null || echo 0)
        if [[ "$bot_count" -gt 0 ]]; then
            print_success "$bot_count Telegram bot(s) configured"
            ((passed++))
        else
            print_warning "No Telegram bots configured"
            ((warnings++))
        fi
    fi

    echo ""
    print_header "Health Check Summary"
    print_success "$passed checks passed"
    [[ $warnings -gt 0 ]] && print_warning "$warnings warnings"
    [[ $failed -gt 0 ]]   && print_error   "$failed checks failed"

    # Return non-zero if any hard failures
    [[ $failed -eq 0 ]]
}

# =============================================================================
# BACKUP & RESTORE
# =============================================================================

create_backup() {
    print_header "Creating Backup"
    mkdir -p "$BACKUP_DIR"
    local timestamp backup_file
    timestamp=$(date +%Y%m%d_%H%M%S)
    backup_file="${BACKUP_DIR}/openclaw_backup_${timestamp}.tar.gz"
    print_info "Backing up ${CONFIG_DIR}..."
    if tar -czf "$backup_file" -C "${HOME}" ".openclaw" 2>/dev/null; then
        local size
        size=$(du -h "$backup_file" | cut -f1)
        print_success "Backup created: $backup_file ($size)"
    else
        print_error "Backup failed"
        return 1
    fi
}

restore_backup() {
    print_header "Restore from Backup"
    local backups=()
    mapfile -t backups < <(ls -t "${BACKUP_DIR}"/openclaw_backup_*.tar.gz 2>/dev/null)
    [[ ${#backups[@]} -eq 0 ]] && { print_warning "No backups found"; return; }

    echo ""
    for i in "${!backups[@]}"; do
        local size
        size=$(du -h "${backups[$i]}" | cut -f1)
        printf "  %d) %s (%s)\n" "$((i+1))" "$(basename "${backups[$i]}")" "$size"
    done
    echo ""
    read -rp "$(echo -e "${CYAN}Select backup to restore${NC}: ")" choice
    local idx=$((choice - 1))

    if [[ $idx -ge 0 && $idx -lt ${#backups[@]} ]]; then
        if confirm "This will overwrite ~/.openclaw. Continue?" "n"; then
            tar -xzf "${backups[$idx]}" -C "${HOME}" && print_success "Backup restored" || print_error "Restore failed"
        fi
    fi
}

# =============================================================================
# MAIN MENU
# =============================================================================

show_main_menu() {
    banner
    echo -e "  ${WHITE}Main Menu${NC}"
    echo ""
    echo -e "  ${BOLD}Setup${NC}"
    echo -e "  ${CYAN}1.${NC} Install/Update OpenClaw"
    echo -e "  ${CYAN}2.${NC} Import Skills from everything-claude-code"
    echo ""
    echo -e "  ${BOLD}Multi-Agent Management${NC}"
    echo -e "  ${CYAN}3.${NC} Configure Agents (Create/Edit/Delete)"
    echo -e "  ${CYAN}4.${NC} Deploy from agent-pool.json"
    echo -e "  ${CYAN}5.${NC} List Configured Agents"
    echo -e "  ${CYAN}6.${NC} Show Active Checklist"
    echo -e "  ${CYAN}7.${NC} Activate Agents (Start Gateway)"
    echo ""
    echo -e "  ${BOLD}Telegram Bot${NC}"
    echo -e "  ${CYAN}8.${NC} Get Telegram User ID"
    echo -e "  ${CYAN}9.${NC} Test Telegram Bot Connection"
    echo ""
    echo -e "  ${BOLD}System${NC}"
    echo -e "  ${CYAN}10.${NC} Health Check"
    echo -e "  ${CYAN}11.${NC} Backup/Restore"
    echo ""
    echo -e "  ${MAGENTA}0.${NC} Exit"
    echo ""
}

menu_setup() {
    banner
    print_header "Installation & Setup"

    detect_os
    print_info "Detected OS: ${DISTRO:-Unknown}"

    if is_debian_based; then
        if ! check_command curl || ! check_command jq || ! check_command git; then
            confirm "Install system dependencies (apt)?" "y" && install_debian_deps
        else
            print_success "System dependencies already present"
        fi
    fi

    if ! check_command node || [[ "$(node -v 2>/dev/null | sed 's/^v//' | cut -d. -f1)" -lt 24 ]]; then
        confirm "Install/upgrade to Node.js 24?" "y" && install_node
    else
        print_success "Node.js $(node -v) already available"
    fi

    install_openclaw

    ensure_openclaw_prerequisites

    # Auto-import skills — agents need these out-of-the-box
    import_skills

    press_enter
}

menu_agents() {
    while true; do
        banner
        print_header "Agent Management"
        echo -e "  ${BOLD}Quick Actions${NC}"
        echo -e "  ${CYAN}1.${NC} Create New Agent"
        echo -e "  ${CYAN}2.${NC} Setup Multiple Agents"
        echo -e "  ${CYAN}3.${NC} List Agents"
        echo -e "  ${CYAN}4.${NC} Edit Agent"
        echo -e "  ${CYAN}5.${NC} Delete Agent"
        echo ""
        echo -e "  ${BOLD}Skills${NC}"
        echo -e "  ${CYAN}6.${NC} List Available Skills"
        echo -e "  ${CYAN}7.${NC} Import Skills"
        echo ""
        echo -e "  ${MAGENTA}0.${NC} Back"
        echo ""
        read -rp "$(echo -e "${CYAN}Select option${NC}: ")" choice
        case $choice in
            1) create_agent_interactive 1 1; press_enter ;;
            2) setup_multi_agent; press_enter ;;
            3) list_agents; press_enter ;;
            4) edit_agent; press_enter ;;
            5) delete_agent; press_enter ;;
            6) list_skills; press_enter ;;
            7) import_skills; press_enter ;;
            0) return ;;
            *) print_error "Invalid option"; sleep 1 ;;
        esac
    done
}

# =============================================================================
# ENTRY POINT
# =============================================================================

main() {
    mkdir -p "$CONFIG_DIR" "$AGENTS_DIR" "$BACKUP_DIR"
    touch "$LOG_FILE" 2>/dev/null || true
    detect_os
    log "OpenClaw Studio v${VERSION} started on ${OS:-unknown}/${DISTRO:-unknown}"

    case "${1:-}" in
        "install"|"setup")  menu_setup ;;
        "skills")           import_skills ;;
        "agents")           menu_agents ;;
        "model")            set_agent_model "${2:?Usage: $0 model <agent-id> <model>}" "${3:?Usage: $0 model <agent-id> <model>}" ;;
        "health"|"check")   health_check ;;
        "backup")           create_backup ;;
        "restore")          restore_backup ;;
        "activate")         activate_agents ;;
        "checklist")        show_checklist ;;
        "prereqs")          ensure_openclaw_prerequisites ;;
        *)
            while true; do
                show_main_menu
                read -rp "$(echo -e "${CYAN}Select option${NC}: ")" choice
                case $choice in
                    1)  menu_setup ;;
                    2)  import_skills; press_enter ;;
                    3)  menu_agents ;;
                    4)  deploy_from_agent_pool; press_enter ;;
                    5)  list_agents; press_enter ;;
                    6)  show_checklist; press_enter ;;
                    7)  activate_agents; press_enter ;;
                    8)  get_telegram_user_id; press_enter ;;
                    9)  test_telegram_bot; press_enter ;;
                    10) health_check; press_enter ;;
                    11)
                        banner
                        print_header "Backup & Restore"
                        echo -e "  ${CYAN}1.${NC} Create Backup"
                        echo -e "  ${CYAN}2.${NC} Restore Backup"
                        echo -e "  ${MAGENTA}0.${NC} Back"
                        read -rp "$(echo -e "${CYAN}Select option${NC}: ")" sub
                        case $sub in
                            1) create_backup ;;
                            2) restore_backup ;;
                        esac
                        press_enter
                        ;;
                    0|q|quit|exit)
                        banner
                        echo -e "${GREEN}Goodbye!${NC}"
                        exit 0
                        ;;
                    *)  print_error "Invalid option"; sleep 1 ;;
                esac
            done
            ;;
    esac
}

# =============================================================================
# RUN  (this line was missing in v4 — script did nothing without it)
# =============================================================================
main "$@"
