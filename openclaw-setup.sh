#!/usr/bin/env bash
#╔═══════════════════════════════════════════════════════════════════════╗
#║  OpenClaw Studio - Multi-Agent Orchestrator Setup v2.6.1              ║
#║  Cross-Platform | Enhanced TUI | Full System Verification             ║
#╚═══════════════════════════════════════════════════════════════════════╝
set -eEuo pipefail

# ── Traps ──────────────────────────────────────────────────────────────
trap 'error_handler $? $LINENO "$BASH_COMMAND"' ERR
trap 'cleanup_on_exit' EXIT
trap 'echo -e "\n\033[0;31m✗ Setup interrupted by user.\033[0m"; exit 130' INT TERM

# ── Constants ───────────────────────────────────────────────────────────
readonly SCRIPT_VERSION="2.6.1"
readonly SCRIPT_NAME="$(basename "$0")"
readonly OPENCLAW_DIR="$HOME/.openclaw"
readonly BACKUP_DIR="$OPENCLAW_DIR/backups"
readonly LOG_DIR="$OPENCLAW_DIR/logs"
readonly STATE_FILE="$OPENCLAW_DIR/.setup_state"
readonly LOCK_FILE="/tmp/openclaw-setup.lock"
readonly NODE_MAJOR=24
readonly GATEWAY_PORT=18789
readonly SYSTEMD_DIR="$HOME/.config/systemd/user"

# ── Mode Flags & OS Detection ──────────────────────────────────────────
FAST_MODE=false
DRY_RUN=false
VERBOSE=false
UNINSTALL_MODE=false
BACKUP_MODE=false
HEALTH_CHECK=false

OS_TYPE="unknown"
case "$(uname -s)" in
    Linux*)     OS_TYPE="linux";;
    Darwin*)    OS_TYPE="mac";;
    CYGWIN*|MINGW*|MSYS*) OS_TYPE="windows";;
esac

# ── Colors & UI ────────────────────────────────────────────────────────
if [[ -t 1 ]] && [[ -z "${NO_COLOR:-}" ]]; then
  RED='\033[0;31m' GREEN='\033[0;32m' YELLOW='\033[1;33m'
  BLUE='\033[0;34m' MAGENTA='\033[0;35m' CYAN='\033[0;36m'
  WHITE='\033[1;37m' DIM='\033[2m' BOLD='\033[1m' NC='\033[0m'
else
  RED='' GREEN='' YELLOW='' BLUE='' MAGENTA='' CYAN='' WHITE='' DIM='' BOLD='' NC=''
fi

# ── State Arrays ───────────────────────────────────────────────────────
declare -a AGENT_IDS=()
declare -a AGENT_NAMES=()
declare -a AGENT_EMOJIS=()
declare -a AGENT_THEMES=()
declare -a AGENT_TOKENS=()
declare -a AGENT_PROVIDERS=()
declare -a AGENT_MODELS=()
declare -a AGENT_API_KEYS=()
declare -a AGENT_TEMPLATES=()
declare -A PROVIDER_KEYS=()
declare -A USED_PORTS=()
declare -a TEMP_FILES=()

# ╔═════════════════════════════════════════════════════════════════════╗
# ║  UNIFIED MODEL CATALOG                                              ║
# ╚═════════════════════════════════════════════════════════════════════╝

declare -A MODEL_CATALOG

MODEL_CATALOG["google"]="\
gemini-2.5-flash|Flash 2.5|free|1M|Recommended
gemini-2.5-pro|Pro 2.5|free|1M|Best quality
gemini-2.0-flash|Flash 2.0|free|1M|Fast
gemini-1.5-flash|Flash 1.5|free|1M|Legacy
gemini-1.5-pro|Pro 1.5|free|2M|Long context"

MODEL_CATALOG["anthropic"]="\
claude-sonnet-4-20250514|Sonnet 4|paid|200K|Best value
claude-3-5-sonnet-20241022|Sonnet 3.5|paid|200K|Previous
claude-3-5-haiku-20241022|Haiku 3.5|paid|200K|Fastest
claude-opus-4-20250514|Opus 4|paid|200K|Most capable"

MODEL_CATALOG["zai"]="\
glm-4.7-flash|GLM-4.7 Flash|free|128K|Fast & free
glm-4.7|GLM-4.7|paid|128K|Advanced
glm-4.5|GLM-4.5|paid|128K|Flagship
glm-5|GLM-5|paid|200K|State of the art"

MODEL_CATALOG["groq"]="\
llama-3.3-70b-versatile|Llama 3.3 70B|free-ltd|128K|Best open
llama-3.1-8b-instant|Llama 3.1 8B|free|128K|Fastest
deepseek-r1-distill-llama-70b|DeepSeek R1 70B|free|128K|Reasoning
gemma2-9b-it|Gemma 2 9B|free|8K|Compact
qwen-qwq-32b|QwQ 32B|free|128K|Reasoning"

MODEL_CATALOG["ollama"]="\
llama3.2:latest|Llama 3.2|local|128K|3GB
qwen2.5:7b|Qwen 2.5 7B|local|32K|4.7GB
deepseek-r1:8b|DeepSeek R1|local|64K|5.2GB
codellama:7b|Code Llama|local|16K|4GB
mistral:7b|Mistral 7B|local|32K|4.1GB"

declare -A PROVIDER_INFO=(
  ["google"]="Google Gemini|https://aistudio.google.com/apikey"
  ["anthropic"]="Anthropic Claude|https://console.anthropic.com"
  ["zai"]="Zhipu AI|https://open.bigmodel.cn"
  ["groq"]="Groq|https://console.groq.com"
  ["ollama"]="Ollama Local|http://localhost:11434"
)

# ╔═════════════════════════════════════════════════════════════════════╗
# ║  TUI & Utilities                                                    ║
# ╚═════════════════════════════════════════════════════════════════════╝

draw_banner() {
  clear
  echo -e "${CYAN}"
  echo "  ___                 ___ _             ___ _           _ _     "
  echo " / _ \\ _ __  ___ _ _ / __| |__ _ __ __ / __| |_ _  _ __| (_)___ "
  echo "| (_) | '_ \\/ -_) ' \\ (__| / _' |\\ V  V /\\__ \\  _| || / _\` | / _ \\"
  echo " \\___/| .__/\\___|_||_\\___|_\\__,_| \\_/\\_/ |___/\\__|\\_,_\\__,_|_\\___/"
  echo "      |_|                                                       "
  echo -e " ${NC}${DIM} ──────── Orchestrator Setup v${SCRIPT_VERSION} ────────${NC}\n"
  
  if $DRY_RUN; then
    echo -e "  ${YELLOW}⚠ RUNNING IN DRY-RUN MODE${NC}\n"
  fi
}

error_handler() {
  echo -e "\n${RED}✗ Error at line $2: $3${NC}" >&2
  if [[ -f "$LOG_FILE" ]]; then
    echo "[ERROR] Line $2: $3" >> "$LOG_FILE"
  fi
}

cleanup_on_exit() {
  for f in "${TEMP_FILES[@]:-}"; do 
    rm -f "$f" 2>/dev/null || true
  done
  rm -f "$LOCK_FILE" 2>/dev/null || true
}

acquire_lock() {
  if [[ -f "$LOCK_FILE" ]]; then
    local pid=$(cat "$LOCK_FILE" 2>/dev/null)
    if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
      echo -e "${RED}✗ Another setup instance running (PID: $pid)${NC}" >&2
      exit 1
    fi
  fi
  echo $$ > "$LOCK_FILE"
}

# Logging
LOG_FILE="$LOG_DIR/setup-$(date +%Y%m%d-%H%M%S).log"
log() {
  local lvl="$1" msg="$2"
  mkdir -p "$LOG_DIR" 2>/dev/null
  echo "[$(date '+%H:%M:%S')] [$lvl] $msg" >> "$LOG_FILE"
  case "$lvl" in
    ERROR) echo -e " ${RED}✗${NC} $msg" ;;
    WARN)  echo -e " ${YELLOW}⚠${NC} $msg" ;;
    INFO)  echo -e " ${CYAN}ℹ${NC} $msg" ;;
    SUCCESS) echo -e " ${GREEN}✓${NC} $msg" ;;
    DEBUG) 
      if [[ "$VERBOSE" == "true" ]]; then
        echo -e " ${DIM}[D] $msg${NC}"
      fi 
      ;;
  esac
}

info()    { log "INFO" "$1"; }
warn()    { log "WARN" "$1"; }
error()   { log "ERROR" "$1"; }
success() { log "SUCCESS" "$1"; }
debug()   { log "DEBUG" "$1"; }
step()    { echo -e "\n${MAGENTA}▶ ${WHITE}${BOLD}$1${NC}"; }

mask() {
  local v="$1"
  if [[ ${#v} -gt 8 ]]; then
    echo "${v:0:4}****${v: -4}"
  else
    echo "****"
  fi
}

# ╔═════════════════════════════════════════════════════════════════════╗
# ║  Conflict Detection & Validation                                    ║
# ╚═════════════════════════════════════════════════════════════════════╝

check_agent_conflict() {
  local id="$1" name="$2"
  for existing_id in "${AGENT_IDS[@]}"; do
    if [[ "$existing_id" == "$id" ]]; then
      error "Agent ID '$id' already exists"
      return 1
    fi
  done
  for existing_name in "${AGENT_NAMES[@]}"; do
    if [[ "$existing_name" == "$name" ]]; then
      warn "Agent name '$name' already exists."
      return 2
    fi
  done
  return 0
}

get_next_available_port() {
  local base_port=$((GATEWAY_PORT + 1))
  while [[ -n "${USED_PORTS[$base_port]:-}" ]]; do
    ((base_port++)) || true
  done
  echo "$base_port"
}

validate_telegram_token() {
  local token="$1"
  if [[ ! "$token" =~ ^[0-9]+:[A-Za-z0-9_-]+$ ]]; then
    error "Invalid token format. Expected: 123456789:ABC..."
    return 1
  fi
  info "Validating token $(mask "$token")..."
  local resp
  if resp=$(curl -fsSL --max-time 10 "https://api.telegram.org/bot${token}/getMe" 2>/dev/null); then
    if echo "$resp" | jq -e '.ok' &>/dev/null; then
      local bot=$(echo "$resp" | jq -r '.result.username')
      success "Valid! Bot: @$bot"
      return 0
    fi
  fi
  error "Token validation failed"
  return 1
}

check_provider_conflict() {
  local provider="$1" api_key="$2"
  if [[ -n "${PROVIDER_KEYS[$provider]:-}" ]]; then
    if [[ "${PROVIDER_KEYS[$provider]}" != "$api_key" ]]; then
      warn "Provider '$provider' already configured with different API key"
      echo "  Existing: $(mask "${PROVIDER_KEYS[$provider]}")"
      echo "  New:      $(mask "$api_key")"
      if ! confirm "Use different API key for this agent?" "n"; then
        return 1
      fi
    fi
  fi
  return 0
}

# ╔═════════════════════════════════════════════════════════════════════╗
# ║  Model Selection System                                             ║
# ╚═════════════════════════════════════════════════════════════════════╝

get_tier_badge() {
  local tier="$1"
  case "$tier" in
    free)     echo "${GREEN}[FREE]${NC}" ;;
    free-ltd) echo "${YELLOW}[FREE*]${NC}" ;;
    paid)     echo "${RED}[PAID]${NC}" ;;
    local)    echo "${CYAN}[LOCAL]${NC}" ;;
  esac
}

select_provider() {
  local var_name="$1"
  if $FAST_MODE; then
    eval "$var_name=\"google\""
    return 0
  fi
  draw_banner
  step "Select AI Provider"
  
  local i=1
  for provider in google anthropic zai groq ollama; do
    local info="${PROVIDER_INFO[$provider]}"
    local name="${info%%|*}"
    echo -e "  ${CYAN}$i)${NC} ${BOLD}$name${NC}"
    ((i++)) || true
  done
  
  echo -en "\n  ${GREEN}▸${NC} Select [1-5]: "
  read -r choice
  
  local providers=("google" "anthropic" "zai" "groq" "ollama")
  if [[ "$choice" =~ ^[1-5]$ ]]; then
    eval "$var_name=\"${providers[$((choice-1))]}\""
  else
    eval "$var_name=\"google\""
  fi
}

select_model() {
  local provider="$1" var_name="$2"
  local models="${MODEL_CATALOG[$provider]}"
  if $FAST_MODE; then
    eval "$var_name=\"$(echo "$models" | head -1 | cut -d'|' -f1)\""
    return 0
  fi
  
  draw_banner
  step "Select Model for ${provider^}"
  echo -e "  ${DIM}Model                  Context   Tier     Notes${NC}"
  echo -e "  ${DIM}──────────────────────────────────────────────────${NC}"
  
  local i=1
  local total=0
  
  # Print models and count them cleanly
  while IFS='|' read -r id name tier ctx notes; do
    if [[ -n "$id" ]]; then
      local badge=$(get_tier_badge "$tier")
      local raw_badge="[$tier]"
      [[ "$tier" == "free-ltd" ]] && raw_badge="[FREE*]"
      [[ "$tier" == "free" ]] && raw_badge="[FREE]"
      [[ "$tier" == "paid" ]] && raw_badge="[PAID]"
      [[ "$tier" == "local" ]] && raw_badge="[LOCAL]"
      local pad_len=$(( 10 - ${#raw_badge} ))
      local padding=""
      if (( pad_len > 0 )); then padding=$(printf '%*s' "$pad_len" ""); fi
      printf "  ${CYAN}%2d)${NC} %-25s ${DIM}%-9s${NC} %s%s %s\n" "$i" "$name" "$ctx" "${badge}" "$padding" "$notes"
      ((i++)) || true
      ((total++)) || true
    fi
  done <<< "$models"
  
  echo -en "\n  ${GREEN}▸${NC} Select [1-$total]: "
  read -r choice
  
  if [[ "$choice" =~ ^[0-9]+$ ]]; then
    local selected=$(echo "$models" | sed -n "${choice}p")
    eval "$var_name=\"${selected%%|*}\""
  else
    eval "$var_name=\"$(echo "$models" | head -1 | cut -d'|' -f1)\""
  fi
}

# ╔═════════════════════════════════════════════════════════════════════╗
# ║  Agent Configuration                                                ║
# ╚═════════════════════════════════════════════════════════════════════╝

TEMPLATES=("general|General Assistant|🚀" "developer|Developer|🔧" "researcher|Researcher|🧠" "devops|DevOps|🏗️")
THEMES=("purple" "blue" "green" "orange" "red" "cyan" "pink" "gold")
EMOJIS=("🏢" "🤖" "🧠" "🔧" "🚀" "⚡" "🎯" "🦊" "🐙" "🌟")

prompt() {
  local var="$1" text="$2" default="${3:-}"
  if $FAST_MODE; then
    eval "$var=\"${default}\""
    return 0
  fi
  [[ -n "$default" ]] && text="$text ${DIM}[$default]${NC}"
  echo -en "  ${GREEN}▸${NC} $text: "
  read -r input
  eval "$var=\"${input:-$default}\""
}

prompt_secret() {
  local var="$1" text="$2"
  if $FAST_MODE; then
    eval "$var=\"fast-key\""
    return 0
  fi
  echo -en "  ${GREEN}▸${NC} $text: "
  read -rs input
  echo ""
  eval "$var=\"$input\""
}

confirm() {
  local msg="$1" def="${2:-n}"
  if $FAST_MODE && [[ "$def" == "y" ]]; then 
    return 0
  fi
  local hint; [[ "$def" == "y" ]] && hint="[Y/n]" || hint="[y/N]"
  echo -en "  ${YELLOW}?${NC} $msg ${DIM}$hint${NC}: "
  read -r r
  if [[ -z "$r" ]] && [[ "$def" == "y" ]]; then 
    return 0
  fi
  [[ "$r" =~ ^[Yy] ]]
}

load_existing_config() {
  local cfg="$OPENCLAW_DIR/openclaw.json"
  if [[ ! -f "$cfg" ]]; then
    return 0
  fi
  
  info "Loading existing configuration..."
  
  # Load agents in a single pass to keep arrays in sync
  local agent_data=$(jq -c '.agents.list[] | {id: (.id // ""), name: (.identity.name // ""), emoji: (.identity.emoji // ""), theme: (.identity.theme // ""), model: (.model // "")}' "$cfg" 2>/dev/null || true)
  
  if [[ -z "$agent_data" ]]; then
    return 0
  fi
  
  local i=0
  while IFS= read -r line; do
    local id=$(echo "$line" | jq -r '.id')
    local name=$(echo "$line" | jq -r '.name')
    local emoji=$(echo "$line" | jq -r '.emoji')
    local theme=$(echo "$line" | jq -r '.theme')
    local full_model=$(echo "$line" | jq -r '.model')
    
    # Sanitize
    if [[ -z "$id" || "$id" == "null" ]]; then
      if [[ $i -eq 0 ]]; then id="main"; else id="agent-$i"; fi
    fi
    if [[ -z "$name" || "$name" == "null" ]]; then
      name="Assistant $((i+1))"
    fi
    
    AGENT_IDS[$i]="$id"
    AGENT_NAMES[$i]="$name"
    AGENT_EMOJIS[$i]="${emoji:-🚀}"
    AGENT_THEMES[$i]="${theme:-purple}"
    
    local provider="${full_model%%/*}"
    # Migrate legacy 'zhipu' to 'zai'
    if [[ "$provider" == "zhipu" ]]; then
      provider="zai"
      full_model="zai/${full_model#*/}"
    fi
    # OpenClaw 2.x often uses zai for Zhipu internally
    [[ "$provider" == "zhipu" ]] && provider="zai"
    
    AGENT_PROVIDERS[$i]="$provider"
    AGENT_MODELS[$i]="${full_model#*/}"
    AGENT_TEMPLATES[$i]="general"
    
    local acc_id="$id"
    if [[ -z "$acc_id" || "$i" -eq 0 ]]; then acc_id="default"; fi
    AGENT_TOKENS[$i]=$(jq -r ".channels.telegram.accounts[\"$acc_id\"].botToken // \"\"" "$cfg" 2>/dev/null || true)
    
    local prof_cfg="$OPENCLAW_DIR/auth-profiles.json"
    local api_key=$(jq -r ".auth.profiles[\"${provider}:manual\"].apiKey // .auth.profiles[\"${provider}:manual\"].token // \"\"" "$cfg" 2>/dev/null || true)
    if [[ "$api_key" == "null" || -z "$api_key" ]]; then
      api_key=$(jq -r ".profiles[\"${provider}:manual\"].key // .profiles[\"${provider}:manual\"].apiKey // \"\"" "$prof_cfg" 2>/dev/null || true)
    fi
    [[ "$api_key" == "null" ]] && api_key=""
    
    PROVIDER_KEYS["$provider"]="$api_key"
    AGENT_API_KEYS[$i]="$api_key"
    
    local port=$((GATEWAY_PORT + i + 1))
    USED_PORTS[$port]="$id"
    
    ((i++)) || true
  done <<< "$agent_data"
  
  success "Loaded ${#AGENT_IDS[@]} existing agent(s)"
  if [[ "$VERBOSE" == "true" ]]; then
    for j in "${!AGENT_IDS[@]}"; do
      info "  Debug: Agent $j: ID='${AGENT_IDS[$j]}' Name='${AGENT_NAMES[$j]}'"
    done
  fi
}

modify_agent() {
  draw_banner
  step "Modify Agent"
  echo -e "\n  ${WHITE}Select agent to modify:${NC}"
  for i in "${!AGENT_IDS[@]}"; do
    echo -e "    ${CYAN}$((i+1)))${NC} ${AGENT_NAMES[$i]} (${AGENT_PROVIDERS[$i]}/${AGENT_MODELS[$i]})"
  done
  
  prompt idx "Select" "1"
  local i=$((idx-1))
  
  if ((i < 0 || i >= ${#AGENT_IDS[@]})); then 
    error "Invalid selection"
    return 1
  fi
  
  echo -e "\n  ${WHITE}Modifying: ${AGENT_NAMES[$i]}${NC}"
  select_provider provider
  select_model "$provider" model
  
  AGENT_PROVIDERS[$i]="$provider"
  AGENT_MODELS[$i]="$model"
  
  if [[ "$provider" != "ollama" ]] && ! check_provider_conflict "$provider" "${AGENT_API_KEYS[$i]:-}"; then
    prompt_secret api_key "$provider API Key"
    PROVIDER_KEYS["$provider"]="$api_key"
    AGENT_API_KEYS[$i]="$api_key"
  fi
  
  success "Updated ${AGENT_NAMES[$i]}"
}

configure_single_agent() {
  local idx="$1"
  local name id provider model token api_key emoji theme template
  
  draw_banner
  step "Agent $((idx+1)) Configuration"
  
  while true; do
    prompt name "Display name" "${name:-Assistant}"
    [[ -n "$name" || $FAST_MODE ]] && break
    error "Name is required"
  done
  [[ -z "$name" ]] && name="Assistant"
  
  id=$(echo "$name" | tr '[:upper:]' '[:lower:]' | tr -cd 'a-z0-9_-')
  if [[ $idx -eq 0 ]]; then
    id="main"
  elif [[ -z "$id" ]]; then
    id="agent-$idx"
  fi
  
  check_agent_conflict "$id" "$name" || return 1
  
  # Persona
  echo -e "\n  ${WHITE}Select Persona:${NC}"
  local i=1
  for t in "${TEMPLATES[@]}"; do
    IFS='|' read -r tid tname temoji <<< "$t"
    echo -e "    ${CYAN}$i)${NC} $temoji $tname"
    ((i++)) || true
  done
  prompt tpl "Choice" "1"
  IFS='|' read -r template _ emoji <<< "${TEMPLATES[$((tpl-1))]}"
  
  # Telegram token
  # Telegram token
  while true; do
    prompt token "Telegram bot token (leave empty to skip)" ""
    if [[ -z "$token" ]]; then
      break
    fi
    if validate_telegram_token "$token"; then
      break
    fi
    if $FAST_MODE; then
      token=""
      break
    fi
    confirm "Try again?" "y" || { token=""; break; }
  done
  
  select_provider provider
  select_model "$provider" model
  
  # API Key
  local env_key="${provider^^}_API_KEY"
  if [[ -n "${!env_key:-}" ]]; then
    api_key="${!env_key}"
    info "Using $env_key from environment"
  elif [[ -n "${PROVIDER_KEYS[$provider]:-}" ]]; then
    api_key="${PROVIDER_KEYS[$provider]}"
    info "Reusing existing $provider key"
  elif [[ "$provider" == "ollama" ]]; then
    api_key="local"
    info "Ollama uses local inference - no API key needed"
  else
    prompt_secret api_key "$provider API Key"
  fi
  
  check_provider_conflict "$provider" "$api_key" || true
  PROVIDER_KEYS["$provider"]="$api_key"
  
  theme="${THEMES[$((idx % ${#THEMES[@]}))]}"
  
  AGENT_IDS+=("$id")
  AGENT_NAMES+=("$name")
  AGENT_EMOJIS+=("$emoji")
  AGENT_THEMES+=("$theme")
  AGENT_TOKENS+=("$token")
  AGENT_PROVIDERS+=("$provider")
  AGENT_MODELS+=("$model")
  AGENT_API_KEYS+=("$api_key")
  AGENT_TEMPLATES+=("$template")
  USED_PORTS[$(get_next_available_port)]="$id"
}

configure_agents() {
  draw_banner
  step "Agent Configuration"
  load_existing_config
  
  if [[ ${#AGENT_IDS[@]} -gt 0 ]]; then
    echo -e "  ${WHITE}Existing agents found:${NC}"
    for i in "${!AGENT_IDS[@]}"; do
      echo -e "    ${GREEN}•${NC} ${AGENT_NAMES[$i]} (${AGENT_PROVIDERS[$i]}/${AGENT_MODELS[$i]})"
    done
    echo ""
    echo -e "    ${CYAN}1)${NC} Keep existing"
    echo -e "    ${CYAN}2)${NC} Add more agents"
    echo -e "    ${CYAN}3)${NC} Modify an agent"
    echo -e "    ${CYAN}4)${NC} Start fresh"
    
    prompt choice "Action" "1"
    
    case "$choice" in
      1) return 0 ;;
      2) 
        local count; prompt count "How many to add" "1"
        local start=${#AGENT_IDS[@]}
        for ((i=start; i<start+count; i++)); do
          configure_single_agent "$i"
        done
        return 0
        ;;
      3) modify_agent; return 0 ;;
      4) 
        uninstall "force"
        AGENT_IDS=(); AGENT_NAMES=(); AGENT_EMOJIS=(); AGENT_THEMES=()
        AGENT_TOKENS=(); AGENT_PROVIDERS=(); AGENT_MODELS=(); AGENT_API_KEYS=()
        AGENT_TEMPLATES=(); USED_PORTS=()
        ;;
    esac
  fi
  
  local count; prompt count "Number of agents" "1"
  for ((i=0; i<count; i++)); do
    configure_single_agent "$i"
  done
}

# ╔═════════════════════════════════════════════════════════════════════╗
# ║  Requirements & Generation                                          ║
# ╚═════════════════════════════════════════════════════════════════════╝

install_node() {
  if [[ "$OS_TYPE" == "windows" ]]; then
    error "Please install Node.js v$NODE_MAJOR manually for Windows."
    info "You can use Winget: winget install OpenJS.NodeJS"
    exit 1
  elif [[ "$OS_TYPE" == "mac" ]]; then
    error "Please install Node.js v$NODE_MAJOR manually for Mac."
    info "You can use Homebrew: brew install node"
    exit 1
  fi
  if [[ ! -d "$HOME/.nvm" ]]; then
    curl -fsSL https://raw.githubusercontent.com/nvm-sh/nvm/v0.40.3/install.sh | bash
  fi
  export NVM_DIR="$HOME/.nvm"
  source "$NVM_DIR/nvm.sh"
  nvm install $NODE_MAJOR --default
  success "Node.js $(node --version)"
}

check_requirements() {
  draw_banner
  step "System Check ($OS_TYPE)"
  
  for cmd in curl jq; do
    if command -v $cmd &>/dev/null; then
      success "$cmd installed"
    else
      warn "$cmd missing."
      if [[ "$OS_TYPE" == "linux" ]]; then
        info "Attempting to install $cmd..."
        sudo apt-get update -qq && sudo apt-get install -y -qq $cmd
      elif [[ "$OS_TYPE" == "windows" ]]; then
        error "Please install $cmd manually for Windows."
        info "You can use Winget: winget install $cmd"
        exit 1
      else
        error "Please install $cmd manually for Mac."
        info "You can use Homebrew: brew install $cmd"
        exit 1
      fi
    fi
  done

  if command -v node &>/dev/null; then
    local v=$(node --version | tr -d 'v')
    local major=${v%%.*}
    if ((major >= NODE_MAJOR)); then
      success "Node.js v$v"
    else
      warn "Node.js v$v too old, attempting to install v$NODE_MAJOR..."
      install_node
    fi
  else
    warn "Node.js not found."
    install_node
  fi

  if command -v bun &>/dev/null; then
    success "Bun $(bun --version)"
  else
    warn "Bun missing."
    if [[ "$OS_TYPE" == "linux" || "$OS_TYPE" == "mac" ]]; then
       info "Installing Bun..."
       curl -fsSL https://bun.sh/install | bash
       export PATH="$HOME/.bun/bin:$PATH"
    else
       info "Using NPM as fallback for Windows."
    fi
  fi

}

install_openclaw() {
  if command -v openclaw &>/dev/null; then
    success "OpenClaw installed"
  else
    warn "Installing OpenClaw..."
    if command -v bun &>/dev/null; then
      bun install -g openclaw
    else
      npm install -g openclaw
    fi
  fi
}

generate_configs() {
  draw_banner
  step "Generating Configuration"
  if $DRY_RUN; then 
    info "[DRY RUN] Would generate configs"
    return 0
  fi
  
  mkdir -p "$OPENCLAW_DIR" "$LOG_DIR"
  
  local cfg="$OPENCLAW_DIR/openclaw.json"
  touch "$cfg"; chmod 600 "$cfg"
  
  local agents_json=""
  local auth_json=""
  local profile_secrets=""
  local tg_json=""
  local seen_providers=""
  
  for i in "${!AGENT_IDS[@]}"; do
    local id="${AGENT_IDS[$i]}"
    [[ -z "$id" ]] && id="main"
    local name="${AGENT_NAMES[$i]}"
    [[ -z "$name" ]] && name="Assistant"
    local provider="${AGENT_PROVIDERS[$i]}"
    local model="${AGENT_MODELS[$i]}"
    local full_model="${provider}/${model}"
    local ws="$OPENCLAW_DIR/workspace"
    
    if [[ "$id" != "main" ]]; then
      ws="$OPENCLAW_DIR/workspace_${id}"
    fi
    
    if [[ -n "$agents_json" ]]; then
      agents_json+=","
    fi
    agents_json+="{\"id\":\"$id\",\"workspace\":\"$ws\",\"model\":\"$full_model\",\"identity\":{\"name\":\"$name\",\"theme\":\"${AGENT_THEMES[$i]}\",\"emoji\":\"${AGENT_EMOJIS[$i]}\"}}"
    
    if [[ "$seen_providers" != *"$provider"* ]]; then
      if [[ -n "$auth_json" ]]; then
         auth_json+=","
         profile_secrets+=","
      fi
      auth_json+="\"$provider:manual\":{\"provider\":\"$provider\",\"mode\":\"api_key\"}"
      profile_secrets+="\"$provider:manual\":{\"type\":\"api_key\",\"provider\":\"$provider\",\"key\":\"${AGENT_API_KEYS[$i]}\"}"
      seen_providers+=" $provider"
    fi
    
    local acc_id="default"
    if [[ $i -gt 0 ]]; then 
      acc_id="$id"
    fi

    if [[ -n "$tg_json" ]]; then 
      tg_json+=","
    fi
    tg_json+="\"$acc_id\":{\"botToken\":\"${AGENT_TOKENS[$i]}\",\"allowFrom\":[],\"groupPolicy\":\"open\",\"streaming\":false}"
    
    mkdir -p "$ws" "$OPENCLAW_DIR/agents/$id/agent" "$OPENCLAW_DIR/agents/$id/sessions"
    
    cat > "$OPENCLAW_DIR/agents/$id/agent/auth.json" << AUTH
{"$provider":{"type":"api_key","key":"${AGENT_API_KEYS[$i]}"}}
AUTH
    chmod 600 "$OPENCLAW_DIR/agents/$id/agent/auth.json"
    
    echo '{"sessions":{}}' > "$OPENCLAW_DIR/agents/$id/sessions/sessions.json"
    
    local goals=""
    case "${AGENT_TEMPLATES[$i]}" in
      developer)  goals="Build robust software, debug complex issues." ;;
      researcher) goals="Research technical topics, create summaries." ;;
      devops)     goals="Manage infrastructure, automate deployments." ;;
      *)          goals="Assist with various tasks and workflows." ;;
    esac
    
    cat > "$ws/IDENTITY.md" << ID
---
name: $name
emoji: ${AGENT_EMOJIS[$i]}
theme: ${AGENT_THEMES[$i]}
template: ${AGENT_TEMPLATES[$i]}
---
I am $name. My objectives: $goals
ID
  done
  
  # Write main config JSON
  cat > "$cfg" << JSON
{
  "auth":{"profiles":{$auth_json}},
  "agents":{
    "defaults":{"model":{"primary":"${AGENT_PROVIDERS[0]}/${AGENT_MODELS[0]}"},"workspace":"$OPENCLAW_DIR/workspace"},
    "list":[$agents_json]
  },
  "channels":{"telegram":{"enabled":true,"accounts":{$tg_json}}},
  "gateway":{"port":$GATEWAY_PORT,"mode":"local","auth":{"mode":"token","token":"$(openssl rand -hex 16 2>/dev/null || echo $RANDOM$RANDOM)"}}
}
JSON

  # Write secrets file
  cat > "$OPENCLAW_DIR/auth-profiles.json" << JSON
{
  "profiles": {$profile_secrets}
}
JSON
  chmod 600 "$OPENCLAW_DIR/auth-profiles.json"
  
  success "Configuration saved to $cfg"
}

setup_daemon() {
  step "Service Registration"
  if [[ "$OS_TYPE" == "windows" ]]; then
    warn "Systemd is not available on Windows."
    info "To run OpenClaw in the background on Windows, install PM2:"
    echo -e "  ${DIM}npm install -g pm2${NC}"
    echo -e "  ${DIM}pm2 start openclaw --name openclaw-gateway -- gateway --port $GATEWAY_PORT${NC}"
    return 0
  fi

  [[ -d "$SYSTEMD_DIR" ]] || mkdir -p "$SYSTEMD_DIR"
  if $DRY_RUN; then
    return 0
  fi
  
  local exec_cmd=""
  local bin_path=""
  
  if command -v openclaw &>/dev/null; then
    bin_path="$(command -v openclaw)"
  elif [[ -x "$HOME/.bun/bin/openclaw" ]]; then
    bin_path="$HOME/.bun/bin/openclaw"
  elif [[ -x "$HOME/.npm-global/bin/openclaw" ]]; then
    bin_path="$HOME/.npm-global/bin/openclaw"
  elif command -v npm &>/dev/null && [[ -x "$(npm bin -g 2>/dev/null || true)/openclaw" ]]; then
    bin_path="$(npm bin -g)/openclaw"
  else
    bin_path="openclaw"
  fi
  
  exec_cmd="$bin_path gateway --port $GATEWAY_PORT"

  cat > "$SYSTEMD_DIR/openclaw-gateway.service" << SVC
[Unit]
Description=OpenClaw Gateway
After=network-online.target

[Service]
ExecStart=$exec_cmd
Restart=always
RestartSec=10
Environment=HOME=$HOME
Environment=PATH=$PATH

[Install]
WantedBy=default.target
SVC
  
  systemctl --user daemon-reload
  systemctl --user enable openclaw-gateway.service
  
  if systemctl --user start openclaw-gateway.service; then
    success "Systemd service started"
  else
    error "Failed to start systemd service. Check logs."
  fi
}

verify_installation() {
  draw_banner
  step "Post-Installation Verification"

  local errors=0
  local warnings=0

  # 1. Check Configuration syntax / presence
  echo -en "  ${CYAN}•${NC} Configuration File: "
  if [[ -f "$OPENCLAW_DIR/openclaw.json" ]] && jq -e . "$OPENCLAW_DIR/openclaw.json" >/dev/null 2>&1; then
    echo -e "${GREEN}✓ OK${NC}"
  else
    echo -e "${RED}✗ Missing or Invalid JSON${NC}"
    ((errors++)) || true
  fi

  # 2. Check Directories
  echo -en "  ${CYAN}•${NC} Agent Workspaces:   "
  local missing_ws=""
  for i in "${!AGENT_IDS[@]}"; do
    local id="${AGENT_IDS[$i]}"
    [[ -z "$id" || "$id" == "null" ]] && continue
    local ws_dir="$OPENCLAW_DIR/workspace"
    if [[ "$id" != "main" ]]; then
      ws_dir="$OPENCLAW_DIR/workspace_$id"
    fi
    if [[ ! -d "$ws_dir" ]]; then
      missing_ws+="$ws_dir "
    fi
  done
  
  if [[ -z "$missing_ws" ]]; then
    echo -e "${GREEN}✓ Provisioned${NC}"
  else
    echo -e "${RED}✗ Missing ($missing_ws)${NC}"
    ((errors++)) || true
  fi

  # 3. Process Status Check
  echo -en "  ${CYAN}•${NC} Gateway Service:    "
  if [[ "$OS_TYPE" == "linux" ]]; then
    if systemctl --user is-active openclaw-gateway >/dev/null 2>&1; then
      echo -e "${GREEN}✓ Running${NC}"
    else
      echo -e "${RED}✗ Failed to stay active${NC}"
      ((errors++)) || true
    fi
  else
    echo -e "${YELLOW}⚠ Awaiting Manual Start ($OS_TYPE)${NC}"
  fi

  # 4. Port Binding & Connection Check
  if [[ "$OS_TYPE" == "linux" || "$OS_TYPE" == "windows" ]]; then
    echo -en "  ${CYAN}•${NC} Network Bind (:$GATEWAY_PORT): "
    
    local max_attempts=10
    local attempt=1
    local port_ready=false
    
    while (( attempt <= max_attempts )); do
      # Use curl if available, otherwise fallback to bash tcp ping capability.
      if curl -s -m 1 "http://127.0.0.1:$GATEWAY_PORT" >/dev/null 2>&1 || timeout 1 bash -c "</dev/tcp/127.0.0.1/$GATEWAY_PORT" 2>/dev/null; then
        port_ready=true
        break
      fi
      sleep 1
      ((attempt++)) || true
    done
    
    if $port_ready; then
      echo -e "${GREEN}✓ Listening & Responsive${NC}"
    else
      echo -e "${YELLOW}⚠ Not responding yet (Service may still be starting)${NC}"
      ((warnings++)) || true
    fi
  fi

  echo ""
  if [[ $errors -eq 0 && $warnings -eq 0 ]]; then
    success "All systems go! OpenClaw is operational."
  elif [[ $errors -eq 0 ]]; then
    warn "Verification passed with warnings. Service is likely still booting."
  else
    error "Verification failed with $errors error(s). Please review systemctl logs."
  fi
}

# ╔═════════════════════════════════════════════════════════════════════╗
# ║  Backup / Restore / Health / Uninstall                              ║
# ╚═════════════════════════════════════════════════════════════════════╝

create_backup() {
  if [[ ! -d "$OPENCLAW_DIR" ]]; then 
    error "No installation to backup"
    return 1
  fi
  mkdir -p "$BACKUP_DIR"
  local file="$BACKUP_DIR/backup-$(date +%Y%m%d-%H%M%S).tar.gz"
  tar -czf "$file" --exclude="$BACKUP_DIR" -C "$HOME" ".openclaw"
  chmod 600 "$file"
  success "Backup: $file"
}

restore_backup() {
  local file="$1"
  if [[ ! -f "$file" ]]; then 
    error "Backup not found: $file"
    return 1
  fi
  confirm "This replaces current config. Continue?" "n" || return
  systemctl --user stop openclaw-gateway 2>/dev/null || true
  rm -rf "$OPENCLAW_DIR"
  tar -xzf "$file" -C "$HOME"
  success "Restored from $file"
}

run_health_check() {
  draw_banner
  step "Health Check"
  local issues=0
  
  echo -e "  ${WHITE}System:${NC}"
  echo -en "    OpenClaw: "
  command -v openclaw &>/dev/null && echo -e "${GREEN}✓${NC}" || { echo -e "${RED}✗${NC}"; ((issues++)) || true; }
  
  echo -en "    Config:   "
  [[ -f "$OPENCLAW_DIR/openclaw.json" ]] && echo -e "${GREEN}✓${NC}" || { echo -e "${RED}✗${NC}"; ((issues++)) || true; }
  
  echo -en "    Service:  "
  if [[ "$OS_TYPE" == "linux" ]]; then
      systemctl --user is-active openclaw-gateway &>/dev/null && echo -e "${GREEN}running${NC}" || echo -e "${YELLOW}stopped${NC}"
  else
      echo -e "${YELLOW}Manual (Windows/Mac)${NC}"
  fi
  
  echo -e "\n  ${WHITE}Agents:${NC}"
  load_existing_config >/dev/null 2>&1
  for id in "${AGENT_IDS[@]:-}"; do
    echo -e "    ${GREEN}•${NC} $id"
  done
  
  if [[ ${#AGENT_IDS[@]} -eq 0 ]]; then
    echo "    None configured"
  fi
  
  echo -e "\n  ${WHITE}Result:${NC} ${issues:-0} issue(s)"
  return $issues
}

uninstall() {
  local force="${1:-}"
  if [[ "$force" != "force" ]]; then
    draw_banner
    confirm "Remove all OpenClaw data?" "n" || return
  fi
  
  if [[ "$OS_TYPE" == "linux" ]]; then
      systemctl --user stop openclaw-gateway 2>/dev/null || true
      systemctl --user disable openclaw-gateway 2>/dev/null || true
      rm -f "$SYSTEMD_DIR/openclaw-gateway.service"
      systemctl --user daemon-reload || true
  fi
  
  if [[ -d "$OPENCLAW_DIR" ]]; then 
    if [[ "$force" != "force" ]] && confirm "Create backup first?" "y"; then
      create_backup || true
    fi
  fi
  
  rm -rf "$OPENCLAW_DIR"
  
  if command -v bun &>/dev/null; then
    bun remove -g openclaw 2>/dev/null || true
  fi
  if command -v npm &>/dev/null; then
    npm uninstall -g openclaw 2>/dev/null || true
  fi
  success "OpenClaw uninstalled"
}

# ╔═════════════════════════════════════════════════════════════════════╗
# ║  Main Execution                                                     ║
# ╚═════════════════════════════════════════════════════════════════════╝

show_help() {
  cat << EOF
${BOLD}OpenClaw Studio v${SCRIPT_VERSION}${NC}

${CYAN}USAGE:${NC} $SCRIPT_NAME [OPTIONS]

${CYAN}OPTIONS:${NC}
  -h, --help       Show help
  -v, --verbose    Verbose output
  -f, --fast       Fast mode (auto-fill defaults)
  -d, --dry-run    Preview without changes
  --backup         Create backup
  --restore FILE   Restore from backup
  --health         Health check
  --uninstall      Remove OpenClaw

${CYAN}MODEL TIERS:${NC}
  ${GREEN}[FREE]${NC}      No cost, generous limits
  ${YELLOW}[FREE*]${NC}     Free with rate limits
  ${RED}[PAID]${NC}      Requires payment
  ${CYAN}[LOCAL]${NC}     Runs locally via Ollama

EOF
}

main() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -h|--help)    show_help; exit 0 ;;
      -v|--verbose) VERBOSE=true ;;
      -f|--fast)    FAST_MODE=true ;;
      -d|--dry-run) DRY_RUN=true ;;
      --backup)     BACKUP_MODE=true ;;
      --health)     HEALTH_CHECK=true ;;
      --uninstall)  UNINSTALL_MODE=true ;;
      --restore)    shift; restore_backup "$1"; exit 0 ;;
      *)            error "Unknown: $1"; exit 1 ;;
    esac
    shift
  done
  
  acquire_lock
  
  if $HEALTH_CHECK; then run_health_check; exit 0; fi
  if $BACKUP_MODE; then create_backup; exit 0; fi
  if $UNINSTALL_MODE; then uninstall; exit 0; fi
  
  check_requirements
  configure_agents
  install_openclaw
  generate_configs
  setup_daemon
  
  # Run Post-Installation Verification
  if ! $DRY_RUN; then
    verify_installation
  fi
  
  echo -e "\n ${GREEN}✓ Setup Complete!${NC}\n"
  
  if [[ "$OS_TYPE" == "linux" ]]; then
      echo -e "  ${CYAN}•${NC} Status:   ${DIM}systemctl --user status openclaw-gateway${NC}"
      echo -e "  ${CYAN}•${NC} Logs:     ${DIM}journalctl --user -u openclaw-gateway -f${NC}"
  else
      echo -e "  ${CYAN}•${NC} Run Now:  ${DIM}openclaw gateway --port $GATEWAY_PORT${NC}"
  fi
  echo ""
}

main "$@"