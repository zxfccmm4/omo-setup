#!/usr/bin/env bash
#
# omo-setup.sh - install OmO if missing, then configure a provider, step by step.
#
# Targets Linux and macOS. For Windows use omo-setup.ps1.
#
# Remote one-liner (downloads and runs):
#   curl -fsSL https://raw.githubusercontent.com/zxfccmm4/omo-setup/main/omo-setup.sh | bash
#
# Local use:
#   ./omo-setup.sh                     # interactive wizard
#   ./omo-setup.sh -i                  # force the wizard
#   ./omo-setup.sh --base-url URL --api-key KEY --models a,b   # non-interactive
#
# Flags:
#   -i, --interactive     always run the step-by-step wizard
#   --base-url URL        endpoint base url            (env OMO_BASE_URL)
#   --api-key KEY         provider api key             (env OMO_API_KEY)
#   --models a,b,c        comma-separated model ids    (env OMO_MODELS)
#   --models-file FILE    read "id<TAB>name" lines as the model list
#   --lang en|zh          wizard and output language  (env OMO_LANG, default: en)
#   --provider NAME       provider id                  (default: derived from host)
#   --api-type TYPE       openai-completions|openai-responses|anthropic-messages
#   --default-model ID    default model to select      (default: provider/<first>)
#   --no-default          do not touch settings.json defaults
#   --dry-run             print planned changes, write nothing
#   --skip-install        never install, only configure
#   --allow-root          allow installing omo as root (sets OMO_INSTALL_ALLOW_SUDO=1)
#
# Multi-agent flags (write ~/.omo/omo.jsonc; repeatable where noted):
#   --advice                        print the official recommendations and exit
#   --preset NAME                   start from an official example: claude-openai,
#                                   kimi-glm, deepseek-alternative (repeatable)
#   --category NAME=MODEL[:LEVEL]   pin a task category (repeatable)
#   --agent NAME=MODEL[:LEVEL]      pin an agent, e.g. explore (repeatable)
#   --task KEY=VALUE                set a task engine key (repeatable)
#   --memory on|off                 toggle the memory subsystem
#   --team NAME=JSON                define a team (repeatable)
#   --set-json JSON                 deep-merge arbitrary JSON into omo.jsonc
#   --omo-json FILE                 deep-merge a JSON/JSONC file into omo.jsonc
#   --no-agent-config               never touch omo.jsonc
#   --no-advice                     skip the risky-combination advice lines
#   -h, --help            show this help
#
set -euo pipefail

RAW_BASE="https://raw.githubusercontent.com/zxfccmm4/omo-setup/main"

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd || echo "$PWD")"

BASE_URL="${OMO_BASE_URL:-}"
API_KEY="${OMO_API_KEY:-}"
MODELS="${OMO_MODELS:-}"
MODELS_FILE=""
LANG_CODE="${OMO_LANG:-en}"
PROVIDER="${OMO_PROVIDER:-}"
API_TYPE="${OMO_API_TYPE:-}"
DEFAULT_MODEL="${OMO_DEFAULT_MODEL:-}"
NO_DEFAULT=0
DRY_RUN=0
SKIP_INSTALL=0
FORCE_INTERACTIVE=0
CONFIG_SCRIPT=""
TMP_CONFIG=""
TMP_CONFIG_DIR=""
TMP_MODELS=""
TMP_MODELS_ERR=""
FETCH_ERROR=""

# Model list fetched from the endpoint (parallel arrays: id + display name).
MODEL_IDS=()
MODEL_NAMES=()
SELECTED_IDS=()
SELECTED_NAMES=()

# Multi-agent config (written to omo.jsonc by omo-config.mjs)
MEMORY=""
OMO_JSON=""
NO_AGENT_CONFIG=0
NO_ADVICE=0
SHOW_ADVICE=0
CATEGORIES=()
AGENTS=()
TASKS=()
TEAMS=()
SET_JSONS=()
PRESETS=()

info() { printf '\033[1;34m==>\033[0m %s\n' "$*" >&2; }
warn() { printf '\033[1;33m!!\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31mxx\033[0m %s\n' "$*" >&2; exit 1; }

ECHO_SAVED=""

restore_echo() {
  if [ -n "$ECHO_SAVED" ]; then
    stty "$ECHO_SAVED" < /dev/tty 2>/dev/null || stty echo < /dev/tty 2>/dev/null || true
    ECHO_SAVED=""
  fi
}

cleanup() {
  restore_echo
  if [ -n "$TMP_CONFIG" ] && [ -f "$TMP_CONFIG" ]; then rm -f "$TMP_CONFIG"; fi
  if [ -n "$TMP_CONFIG_DIR" ] && [ -d "$TMP_CONFIG_DIR" ]; then rm -rf "$TMP_CONFIG_DIR"; fi
  if [ -n "$TMP_MODELS" ] && [ -f "$TMP_MODELS" ]; then rm -f "$TMP_MODELS"; fi
  if [ -n "$TMP_MODELS_ERR" ] && [ -f "$TMP_MODELS_ERR" ]; then rm -f "$TMP_MODELS_ERR"; fi
  return 0
}
trap cleanup EXIT

mask() {
  local s="$1" n=${#1}
  if [ "$n" -le 10 ]; then printf '********'; else printf '%s...%s' "${s:0:5}" "${s: -5}"; fi
}

have_tty() { { : </dev/tty; } 2>/dev/null; }

read_tty() {
  if have_tty; then IFS= read -r "$@" < /dev/tty; else IFS= read -r "$@"; fi
}

while [ $# -gt 0 ]; do
  case "$1" in
    -i|--interactive) FORCE_INTERACTIVE=1; shift ;;
    --allow-root) export OMO_INSTALL_ALLOW_SUDO=1; shift ;;
    --skip-install) SKIP_INSTALL=1; shift ;;
    --dry-run) DRY_RUN=1; shift ;;
    --no-default) NO_DEFAULT=1; shift ;;
    -h|--help) sed -n '2,40p' "${BASH_SOURCE[0]:-$0}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    --base-url) BASE_URL="$2"; shift 2 ;;
    --api-key) API_KEY="$2"; shift 2 ;;
    --models) MODELS="$2"; shift 2 ;;
    --models-file) MODELS_FILE="$2"; shift 2 ;;
    --lang) LANG_CODE="$2"; shift 2 ;;
    --provider) PROVIDER="$2"; shift 2 ;;
    --api-type) API_TYPE="$2"; shift 2 ;;
    --default-model) DEFAULT_MODEL="$2"; shift 2 ;;
    --base-url=*) BASE_URL="${1#*=}"; shift ;;
    --api-key=*) API_KEY="${1#*=}"; shift ;;
    --models=*) MODELS="${1#*=}"; shift ;;
    --models-file=*) MODELS_FILE="${1#*=}"; shift ;;
    --lang=*) LANG_CODE="${1#*=}"; shift ;;
    --provider=*) PROVIDER="${1#*=}"; shift ;;
    --api-type=*) API_TYPE="${1#*=}"; shift ;;
    --default-model=*) DEFAULT_MODEL="${1#*=}"; shift ;;
    --memory) MEMORY="$2"; shift 2 ;;
    --omo-json) OMO_JSON="$2"; shift 2 ;;
    --no-agent-config) NO_AGENT_CONFIG=1; shift ;;
    --advice) SHOW_ADVICE=1; shift ;;
    --no-advice) NO_ADVICE=1; shift ;;
    --preset) PRESETS+=("$2"); shift 2 ;;
    --category) CATEGORIES+=("$2"); shift 2 ;;
    --agent) AGENTS+=("$2"); shift 2 ;;
    --task) TASKS+=("$2"); shift 2 ;;
    --team) TEAMS+=("$2"); shift 2 ;;
    --set-json) SET_JSONS+=("$2"); shift 2 ;;
    --memory=*) MEMORY="${1#*=}"; shift ;;
    --omo-json=*) OMO_JSON="${1#*=}"; shift ;;
    --category=*) CATEGORIES+=("${1#*=}"); shift ;;
    --agent=*) AGENTS+=("${1#*=}"); shift ;;
    --task=*) TASKS+=("${1#*=}"); shift ;;
    --team=*) TEAMS+=("${1#*=}"); shift ;;
    --set-json=*) SET_JSONS+=("${1#*=}"); shift ;;
    --preset=*) PRESETS+=("${1#*=}"); shift ;;
    *) die "unknown option: $1" ;;
  esac
done

ask() {
  local msg="$1" def="${2-}" val
  if [ -n "$def" ]; then printf '%s [%s]: ' "$msg" "$def" >&2; else printf '%s: ' "$msg" >&2; fi
  read_tty val || true
  printf '%s' "${val:-$def}"
}

# API keys: one * per typed character, so a failed paste or a typo is obvious
# without printing the key; after Enter the line is replaced by the first and
# last 5 characters, and the summary prints the same mask.
ask_secret() {
  local msg="$1" val="" masked c
  if have_tty; then
    # Echo is disabled before the prompt is printed, so even an immediate
    # paste cannot reach the terminal's own echo.
    ECHO_SAVED="$(stty -g < /dev/tty 2>/dev/null || true)"
    if [ -n "$ECHO_SAVED" ]; then stty -echo < /dev/tty 2>/dev/null || true; fi
    printf '%s: ' "$msg" >&2
    while IFS= read -r -n1 c < /dev/tty; do
      case "$c" in
        $'\177'|$'\b')
          if [ -n "$val" ]; then val="${val%?}"; printf '\b \b' >&2; fi
          ;;
        ''|$'\n'|$'\r') break ;;
        *) val="$val$c"; printf '*' >&2 ;;
      esac
    done
    printf '\n' >&2
    restore_echo
    masked="$(mask "$val")"
    printf '\033[A\r\033[K%s: %s\n' "$msg" "$masked" >&2
  else
    printf '%s: ' "$msg" >&2
    IFS= read -r val || true
  fi
  printf '%s' "$val"
}

ask_yes() {
  local msg="$1" def="${2:-n}" val
  printf '%s [%s]: ' "$msg" "$def" >&2
  read_tty val || true
  val="${val:-$def}"
  case "$val" in y|Y|yes|YES|Yes) return 0 ;; *) return 1 ;; esac
}

# lc "english" "中文" - print the string for the selected language.
lc() {
  if [ "$LANG_CODE" = zh ]; then printf '%s' "$2"; else printf '%s' "$1"; fi
}

join_by() { local sep="$1"; shift; local IFS="$sep"; printf '%s' "$*"; }

choose_language() {
  local v
  case "$LANG_CODE" in zh|zh-cn|zh-hans|cn) LANG_CODE=zh ;; *) LANG_CODE=en ;; esac
  printf '0) Language / 语言:  1) English  2) 简体中文\n' >&2
  v="$(ask "$(lc '   choose [1-2]' '   请选择 [1-2]')" "$([ "$LANG_CODE" = zh ] && echo 2 || echo 1)")"
  case "$v" in
    2) LANG_CODE=zh ;;
    1) LANG_CODE=en ;;
  esac
  info "$(lc 'language: English' '语言：简体中文')"
}

# Ask omo-config.mjs for the provider id derived from the base URL.
provider_name() {
  if [ -n "$PROVIDER" ]; then printf '%s' "$PROVIDER"; return 0; fi
  local out
  out="$(run_config --print-provider --base-url "$BASE_URL" --lang "$LANG_CODE" 2>/dev/null)" || return 1
  PROVIDER="$out"
  printf '%s' "$PROVIDER"
}

# Fetch <baseUrl>/models into MODEL_IDS / MODEL_NAMES.
fetch_models() {
  local rc=0
  FETCH_ERROR=""
  [ -n "$BASE_URL" ] || return 1
  if [ -z "$TMP_MODELS" ]; then
    TMP_MODELS="$(mktemp "${TMPDIR:-/tmp}/omo-models.XXXXXX")"
    TMP_MODELS_ERR="${TMP_MODELS}.err"
  fi
  run_config --fetch-models --base-url "$BASE_URL" --api-key "$API_KEY" \
    --lang "$LANG_CODE" >"$TMP_MODELS" 2>"$TMP_MODELS_ERR" || rc=$?
  if [ "$rc" -ne 0 ]; then
    FETCH_ERROR="$(grep -v '^[[:space:]]*$' "$TMP_MODELS_ERR" 2>/dev/null | tail -n 1 || true)"
    warn "$(lc 'could not fetch the model list from the endpoint' '无法从该端点获取模型列表')"
    if [ -n "$FETCH_ERROR" ]; then printf '   %s\n' "$FETCH_ERROR" >&2; fi
    return 1
  fi
  MODEL_IDS=()
  MODEL_NAMES=()
  local line id name
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    id="${line%%$'\t'*}"
    if [ "$id" = "$line" ]; then name="$id"; else name="${line#*$'\t'}"; fi
    MODEL_IDS+=("$id")
    MODEL_NAMES+=("$name")
  done < "$TMP_MODELS"
  [ ${#MODEL_IDS[@]} -gt 0 ]
}

VIEW_IDS=()
VIEW_NAMES=()

# Fill VIEW_IDS / VIEW_NAMES with the models matching $1 (case-insensitive).
build_view() {
  local filter i hay
  filter="$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')"
  VIEW_IDS=()
  VIEW_NAMES=()
  for ((i = 0; i < ${#MODEL_IDS[@]}; i++)); do
    hay="$(printf '%s %s' "${MODEL_IDS[$i]}" "${MODEL_NAMES[$i]}" | tr '[:upper:]' '[:lower:]')"
    if [ -n "$filter" ]; then
      case "$hay" in *"$filter"*) : ;; *) continue ;; esac
    fi
    VIEW_IDS+=("${MODEL_IDS[$i]}")
    VIEW_NAMES+=("${MODEL_NAMES[$i]}")
  done
  [ ${#VIEW_IDS[@]} -gt 0 ]
}

# Print at most $1 entries of the current view, numbered by view position.
print_view() {
  local max="${1:-15}" i total=${#VIEW_IDS[@]}
  for ((i = 0; i < total; i++)); do
    if [ "$((i + 1))" -le "$max" ]; then
      printf '   %d) %s\t%s\n' "$((i + 1))" "${VIEW_IDS[$i]}" "${VIEW_NAMES[$i]}" >&2
    fi
  done
  if [ "$total" -gt "$max" ]; then
    printf '   ... %s\n' "$(lc "$((total - max)) more - type text to filter, or r for the full list" "还有 $((total - max)) 个 - 输入文字过滤，或输入 r 显示全部")" >&2
  fi
  printf '%s\n' "$(lc "   ($total shown)" "   （共 $total 个）")" >&2
}

# "1,3 5-7" -> SELECTED_IDS / SELECTED_NAMES by 1-based view index.
parse_selection() {
  local input="$1" token a b i
  input="${input//,/ }"
  SELECTED_IDS=()
  SELECTED_NAMES=()
  for token in $input; do
    case "$token" in
      *-*) a="${token%%-*}"; b="${token##*-}" ;;
      *) a="$token"; b="$token" ;;
    esac
    case "$a" in ''|*[!0-9]*) return 1 ;; esac
    case "$b" in ''|*[!0-9]*) return 1 ;; esac
    if [ "$a" -lt 1 ] || [ "$b" -gt ${#VIEW_IDS[@]} ] || [ "$a" -gt "$b" ]; then return 1; fi
    for ((i = a; i <= b; i++)); do
      SELECTED_IDS+=("${VIEW_IDS[$((i - 1))]}")
      SELECTED_NAMES+=("${VIEW_NAMES[$((i - 1))]}")
    done
  done
  [ ${#SELECTED_IDS[@]} -gt 0 ]
}

collect_view() {
  SELECTED_IDS=("${VIEW_IDS[@]}")
  SELECTED_NAMES=("${VIEW_NAMES[@]}")
  [ ${#SELECTED_IDS[@]} -gt 0 ]
}

# Multi-select picker: fills SELECTED_IDS / SELECTED_NAMES.
pick_models() {
  local input filter="" sel
  [ ${#MODEL_IDS[@]} -gt 0 ] || return 1
  while :; do
    if ! build_view "$filter"; then
      warn "$(lc 'nothing matched that filter' '没有匹配的模型')"
      filter=""
      continue
    fi
    printf '\n%s\n' "$(lc "models from $BASE_URL:" "来自 $BASE_URL 的模型：")" >&2
    print_view 60
    input="$(ask "$(lc 'select: all / 1,3 / 2-4 / text filter (blank = all)' '请选择：all / 1,3 / 2-4 / 过滤词（留空=全部）')" '')"
    sel="${input//[0-9]/}"
    sel="${sel// /}"
    sel="${sel//,/}"
    sel="${sel//-/}"
    if [ -z "$input" ] || [ "$input" = all ] || [ "$input" = ALL ]; then
      if collect_view; then return 0; fi
    elif [ -z "$sel" ]; then
      if parse_selection "$input"; then return 0; fi
      warn "$(lc "invalid selection '$input'" "无效的选择 '$input'")"
    else
      filter="$input"
    fi
  done
}

# Single-model picker: number to pick, text to filter, r for the full list.
# Prints "provider/model" on success; returns 1 when skipped.
pick_one_model() {
  local input filter="" max=15
  [ ${#MODEL_IDS[@]} -gt 0 ] || return 1
  while :; do
    if ! build_view "$filter"; then
      warn "$(lc 'nothing matched that filter' '没有匹配的模型')"
      filter=""
      continue
    fi
    printf '\n%s\n' "$(lc 'pick a model:' '选择模型：')" >&2
    print_view "$max"
    input="$(ask "$(lc 'number / text to filter / r = all / blank = skip' '编号 / 文字过滤 / r 全部 / 留空跳过')" '')"
    case "$input" in
      '') return 1 ;;
      r|R|all|ALL) max=200; continue ;;
      *[!0-9]*) filter="$input"; continue ;;
    esac
    if [ "$input" -ge 1 ] && [ "$input" -le ${#VIEW_IDS[@]} ]; then
      local prov
      prov="$(provider_name)" || return 1
      printf '%s/%s' "$prov" "${VIEW_IDS[$((input - 1))]}"
      return 0
    fi
    warn "$(lc "invalid number '$input'" "无效编号 '$input'")"
  done
}

ask_reasoning() {
  local v
  v="$(ask "$(lc 'reasoning level: off|minimal|low|medium|high|xhigh|max (blank = default)' '推理档位：off|minimal|low|medium|high|xhigh|max（留空=默认）')" '')"
  printf '%s' "$v"
}

find_omo() {
  if command -v omo >/dev/null 2>&1; then command -v omo; return 0; fi
  for d in "$HOME/.bun/bin" "$HOME/.local/bin" "$HOME/.omo/bin" "/usr/local/bin"; do
    if [ -x "$d/omo" ]; then echo "$d/omo"; return 0; fi
  done
  return 1
}

ensure_runtime() {
  if command -v node >/dev/null 2>&1; then
    export PATH="$(dirname "$(command -v node)"):$PATH"
    return 0
  fi
  if command -v bun >/dev/null 2>&1; then
    export PATH="$HOME/.bun/bin:$PATH"
    return 0
  fi

  info "node.js / bun not found; installing a JavaScript runtime automatically"

  case "$(uname -s)" in
    Darwin)
      if command -v brew >/dev/null 2>&1; then
        brew install node || die "failed to install node.js via Homebrew"
        export PATH="$(dirname "$(command -v node)"):$PATH"
        return 0
      fi
      ;;
    Linux)
      if command -v apt-get >/dev/null 2>&1; then
        local sudo_cmd=""
        if [ "$(id -u)" -ne 0 ] && command -v sudo >/dev/null 2>&1; then
          sudo_cmd="sudo"
        fi
        $sudo_cmd apt-get update
        $sudo_cmd apt-get install -y ca-certificates curl gnupg
        if [ ! -f /etc/apt/keyrings/nodesource.gpg ] || [ ! -f /etc/apt/sources.list.d/nodesource.list ]; then
          mkdir -p /etc/apt/keyrings
          curl -fsSL https://deb.nodesource.com/gpgkey/nodesource-repo.gpg.key | gpg --dearmor -o /etc/apt/keyrings/nodesource.gpg
          echo "deb [signed-by=/etc/apt/keyrings/nodesource.gpg] https://deb.nodesource.com/node_20.x nodistro main" | $sudo_cmd tee /etc/apt/sources.list.d/nodesource.list >/dev/null
        fi
        $sudo_cmd apt-get update
        $sudo_cmd apt-get install -y nodejs
        if command -v node >/dev/null 2>&1; then
          export PATH="$(dirname "$(command -v node)"):$PATH"
          return 0
        fi
      fi
      ;;
  esac

  if command -v curl >/dev/null 2>&1; then
    info "falling back to a Bun install"
    export BUN_INSTALL="$HOME/.bun"
    curl -fsSL https://bun.sh/install | bash || die "failed to install Bun"
    export PATH="$HOME/.bun/bin:$PATH"
    if command -v bun >/dev/null 2>&1; then
      return 0
    fi
  fi

  die "could not install node.js or bun automatically on this platform"
}

install_omo() {
  info "installing OmO Native"
  if [ "$(id -u)" -eq 0 ] && [ "${OMO_INSTALL_ALLOW_SUDO:-}" != "1" ]; then
    warn "the omo installer refuses to run as root"
    if [ -n "${SUDO_USER:-}" ] && [ "$SUDO_USER" != "root" ]; then
      warn "you are root via sudo; installing as '$SUDO_USER' is recommended"
    fi
    if have_tty; then
      if ask_yes "Continue as root anyway (sets OMO_INSTALL_ALLOW_SUDO=1)?" "y"; then
        export OMO_INSTALL_ALLOW_SUDO=1
      else
        die "aborted: run as a non-root user, or pass --allow-root / set OMO_INSTALL_ALLOW_SUDO=1"
      fi
    else
      die "running as root; pass --allow-root or set OMO_INSTALL_ALLOW_SUDO=1 to override"
    fi
  fi
  if command -v curl >/dev/null 2>&1; then
    curl -fsSL https://get.omo.dev/install.sh | bash || die "official installer failed"
  elif command -v bun >/dev/null 2>&1; then
    bun add -g omo-ai || die "bun add -g omo-ai failed"
  elif command -v npm >/dev/null 2>&1; then
    npm i -g omo-ai || die "npm i -g omo-ai failed"
  else
    die "no curl/bun/npm available to install omo"
  fi
}

ensure_config_script() {
  local local_path="$SCRIPT_DIR/omo-config.mjs"
  if [ -f "$local_path" ]; then CONFIG_SCRIPT="$local_path"; return; fi
  # BSD mktemp (macOS) only substitutes X's at the END of a template, so
  # "omo-config.XXXXXX.mjs" would become a literal filename that collides on
  # the second run. Create a temp directory instead and put the helper inside
  # it with the .mjs extension node needs for ESM.
  local tmpdir tmp
  tmpdir="$(mktemp -d "${TMPDIR:-/tmp}/omo-config.XXXXXX")" || die "cannot create a temp directory under ${TMPDIR:-/tmp}"
  tmp="$tmpdir/omo-config.mjs"
  info "downloading omo-config.mjs" >&2
  # raw.githubusercontent.com is the canonical source; jsDelivr mirrors the
  # same repo and stays reachable where raw is blocked (e.g. CN-region VMs).
  local url ok=0
  for url in "$RAW_BASE/omo-config.mjs" \
             "https://cdn.jsdelivr.net/gh/zxfccmm4/omo-setup@main/omo-config.mjs"; do
    if command -v curl >/dev/null 2>&1; then
      curl -fsSL --connect-timeout 10 --max-time 120 "$url" -o "$tmp" && ok=1
    elif command -v wget >/dev/null 2>&1; then
      wget -q --timeout=120 -O "$tmp" "$url" && ok=1
    else
      die "need curl or wget to download omo-config.mjs"
    fi
    if [ "$ok" -eq 1 ] && [ -s "$tmp" ]; then break; fi
    ok=0
  done
  if [ "$ok" -ne 1 ] || [ ! -s "$tmp" ]; then
    rm -rf "$tmpdir"
    die "failed to download omo-config.mjs (tried raw.githubusercontent.com and cdn.jsdelivr.net)"
  fi
  TMP_CONFIG_DIR="$tmpdir"
  TMP_CONFIG="$tmp"
  CONFIG_SCRIPT="$tmp"
}

run_config() {
  ensure_runtime
  ensure_config_script
  if command -v node >/dev/null 2>&1; then
    node "$CONFIG_SCRIPT" "$@"
  elif command -v bun >/dev/null 2>&1; then
    bun "$CONFIG_SCRIPT" "$@"
  else
    die "need node or bun to write omo config"
  fi
}

wizard() {
  printf '\n' >&2
  choose_language
  printf '\n' >&2
  info "$(lc 'step-by-step setup (press Enter to accept the [default])' '逐步配置（直接回车 = 采用 [默认值]）')"
  printf '\n' >&2

  local v
  v="$(ask "$(lc '1) Endpoint base URL (e.g. https://api.example.com/v1)' '1) 接口 base URL（例：https://api.example.com/v1）')" "$BASE_URL")"
  [ -n "$v" ] || die "$(lc 'base URL is required' 'base URL 必填')"
  BASE_URL="$v"

  v="$(ask_secret "$(lc '2) API key' '2) API key')")"
  [ -n "$v" ] && API_KEY="$v"
  [ -n "$API_KEY" ] || die "$(lc 'API key is required' 'API key 必填')"

  # Try the endpoint's /models listing first; fall back to typing ids by hand.
  if [ -z "$MODELS" ] && [ -z "$MODELS_FILE" ] && [ ${#SELECTED_IDS[@]} -eq 0 ]; then
    info "$(lc 'fetching the model list from the endpoint...' '正在从端点获取模型列表...')"
    if fetch_models; then
      info "$(lc "found ${#MODEL_IDS[@]} models" "共发现 ${#MODEL_IDS[@]} 个模型")"
      if pick_models; then
        MODELS="$(join_by , "${SELECTED_IDS[@]}")"
      fi
    else
      warn "$(lc 'falling back to typing model ids by hand' '改用手动输入模型 id')"
    fi
  fi
  if [ -z "$MODELS" ] && [ -z "$MODELS_FILE" ]; then
    v="$(ask "$(lc '3) Model ids, comma-separated (e.g. gpt-4o,gpt-4o-mini)' '3) 模型 id，逗号分隔（例：gpt-4o,gpt-4o-mini）')" "$MODELS")"
    [ -n "$v" ] || die "$(lc 'at least one model is required' '至少需要一个模型')"
    MODELS="$v"
  fi

  v="$(ask "$(lc '4) Provider name (blank = auto from host)' '4) Provider 名称（留空 = 由域名自动推导）')" "$PROVIDER")"
  PROVIDER="$v"
  if [ -z "$PROVIDER" ]; then provider_name >/dev/null 2>&1 || true; fi

  printf '%s\n' "$(lc '5) API protocol:  1) openai-completions (default)  2) openai-responses  3) anthropic-messages' '5) API 协议：1) openai-completions（默认） 2) openai-responses 3) anthropic-messages')" >&2
  v="$(ask "$(lc '   choose [1-3]' '   请选择 [1-3]')" '1')"
  case "$v" in
    1) API_TYPE="openai-completions" ;;
    2) API_TYPE="openai-responses" ;;
    3) API_TYPE="anthropic-messages" ;;
    *) warn "$(lc "unknown choice '$v', using openai-completions" "未知选项 '$v'，改用 openai-completions")"; API_TYPE="openai-completions" ;;
  esac

  v="$(ask "$(lc '6) Default model (blank = provider/<first model>)' '6) 默认模型（留空 = provider/<第一个模型>）')" "$DEFAULT_MODEL")"
  DEFAULT_MODEL="$v"

  printf '\n' >&2
  info "$(lc 'about to write:' '即将写入：')"
  printf '   %s : %s\n' "$(lc 'Base URL' 'Base URL')" "$BASE_URL" >&2
  printf '   %s : %s\n' "$(lc 'API key ' 'API key ')" "$(mask "$API_KEY")" >&2
  printf '   %s : %s\n' "$(lc 'Models  ' '模型    ')" "$(summarize_ids ${MODELS//,/ })" >&2
  printf '   %s : %s\n' "$(lc 'Provider' 'Provider')" "${PROVIDER:-(auto)}" >&2
  printf '   %s : %s\n' "$(lc 'Protocol' '协议    ')" "$API_TYPE" >&2
  if [ "$NO_DEFAULT" -eq 0 ]; then
    printf '   %s : %s\n' "$(lc 'Default ' '默认模型')" "${DEFAULT_MODEL:-(provider/<first model>)}" >&2
  fi
  printf '\n' >&2
  if ! ask_yes "$(lc '7) Write this config?' '7) 写入以上配置？')" "n"; then info "$(lc 'cancelled' '已取消')"; exit 0; fi

  printf '\n' >&2
  if ask_yes "$(lc '8) Configure multi-agent features now (categories / agents / task / memory) into ~/.omo/omo.jsonc?' '8) 现在配置多智能体（任务分类 / 子代理 / 任务引擎 / 记忆）并写入 ~/.omo/omo.jsonc？')" "n"; then
    agent_wizard
  fi
}

show_advice() {
  ensure_runtime
  ensure_config_script
  if command -v node >/dev/null 2>&1; then
    node "$CONFIG_SCRIPT" --advice
  elif command -v bun >/dev/null 2>&1; then
    bun "$CONFIG_SCRIPT" --advice
  else
    die "need node or bun to show recommendations"
  fi
}

# Comma-joined list of the first 6 entries plus a "+K more" tail, so a long
# selection does not flood the summary. Call as: summarize_ids "${ids[@]}"
summarize_ids() {
  local max=6 joined="" i total=$#
  local -a ids=("$@")
  for ((i = 0; i < total; i++)); do
    if [ "$((i + 1))" -le "$max" ]; then
      if [ -n "$joined" ]; then joined="$joined,${ids[$i]}"; else joined="${ids[$i]}"; fi
    fi
  done
  if [ "$total" -gt "$max" ]; then
    joined="$joined,$(lc "+$((total - max)) more" "等共 $total 个")"
  fi
  printf '%s' "$joined"
}

# Menu of the well-known built-in names; 0 = type it by hand.
CATEGORY_NAMES="architect artistry quick deep-low deep-high ultrabrain unspecified-low unspecified-high visual-engineering writing"
AGENT_NAMES="explore librarian plan-consultant plan-reviewer"

pick_name() {
  local kind="$1" names i input
  if [ "$kind" = category ]; then names="$CATEGORY_NAMES"; else names="$AGENT_NAMES"; fi
  printf '%s\n' "$(lc '   built-in names:' '   内置名称：')" >&2
  i=0
  for n in $names; do
    i=$((i + 1))
    printf '     %d) %s\n' "$i" "$n" >&2
  done
  printf '     %s\n' "$(lc '0) type a custom name' '0) 手动输入名称')" >&2
  input="$(ask "$(lc '   choose [0-N]' '   请选择 [0-N]')" '0')"
  case "$input" in
    ''|0) printf '%s' "$(ask "$(lc '   name' '   名称')" '')" ;;
    *[!0-9]*) printf '%s' "$input" ;;
    *)
      i=0
      for n in $names; do
        i=$((i + 1))
        if [ "$i" -eq "$input" ]; then printf '%s' "$n"; return 0; fi
      done
      printf '%s' "$(ask "$(lc '   name' '   名称')" '')"
      ;;
  esac
}

agent_wizard() {
  local v spec level
  printf '\n' >&2
  info "$(lc 'multi-agent setup (blank = keep current / skip)' '多智能体配置（留空 = 保持现状 / 跳过）')"
  printf '\n' >&2

  printf '%s\n' "$(lc '0) Start from an official example preset?' '0) 从官方示例预设开始？')" >&2
  printf '%s\n' "$(lc '   1) claude-openai  2) kimi-glm  3) deepseek-alternative  4) none (default)' '   1) claude-openai  2) kimi-glm  3) deepseek-alternative  4) 不使用（默认）')" >&2
  v="$(ask "$(lc '   choose [1-4]' '   请选择 [1-4]')" '4')"
  case "$v" in
    1) PRESETS+=(claude-openai) ;;
    2) PRESETS+=(kimi-glm) ;;
    3) PRESETS+=(deepseek-alternative) ;;
    *) : ;;
  esac

  # Offer the endpoint's model list for picking, so users type fewer ids.
  if [ ${#MODEL_IDS[@]} -eq 0 ] && [ -n "$BASE_URL" ]; then
    if fetch_models; then
      info "$(lc "found ${#MODEL_IDS[@]} models on the endpoint" "在端点上发现 ${#MODEL_IDS[@]} 个模型")"
    fi
  fi

  printf '%s\n' "$(lc 'a) Pin a task category (blank = skip)' 'a) 固定任务分类的模型（留空=跳过）')" >&2
  v="$(ask "$(lc '   add a category? [y/N]' '   要固定分类吗？[y/N]')" 'n')"
  case "$v" in y|Y|yes|YES) : ;; *) v="" ;; esac
  if [ -n "$v" ]; then v="$(pick_name category)"; fi
  while [ -n "$v" ]; do
    if [ ${#MODEL_IDS[@]} -gt 0 ]; then
      spec="$(pick_one_model)" || spec=""
      if [ -n "$spec" ]; then
        level="$(ask_reasoning)"
        if [ -n "$level" ]; then spec="$spec:$level"; fi
      fi
    else
      spec="$(ask "$(lc '   model as provider/model[:level]' '   模型，格式 provider/model[:档位]')" '')"
    fi
    if [ -n "$spec" ]; then CATEGORIES+=("$v=$spec"); fi
    v="$(ask "$(lc '   another category? [y/N]' '   还要固定其他分类吗？[y/N]')" 'n')"
    case "$v" in y|Y|yes|YES) v="$(pick_name category)" ;; *) v="" ;; esac
  done

  printf '%s\n' "$(lc 'b) Pin an agent (blank = skip)' 'b) 固定子代理的模型（留空=跳过）')" >&2
  v="$(ask "$(lc '   add an agent? [y/N]' '   要固定子代理吗？[y/N]')" 'n')"
  case "$v" in y|Y|yes|YES) : ;; *) v="" ;; esac
  if [ -n "$v" ]; then v="$(pick_name agent)"; fi
  while [ -n "$v" ]; do
    if [ ${#MODEL_IDS[@]} -gt 0 ]; then
      spec="$(pick_one_model)" || spec=""
      if [ -n "$spec" ]; then
        level="$(ask_reasoning)"
        if [ -n "$level" ]; then spec="$spec:$level"; fi
      fi
    else
      spec="$(ask "$(lc '   model as provider/model[:level]' '   模型，格式 provider/model[:档位]')" '')"
    fi
    if [ -n "$spec" ]; then AGENTS+=("$v=$spec"); fi
    v="$(ask "$(lc '   another agent? [y/N]' '   还要固定其他子代理吗？[y/N]')" 'n')"
    case "$v" in y|Y|yes|YES) v="$(pick_name agent)" ;; *) v="" ;; esac
  done

  v="$(ask "$(lc 'c) Task engine setting as KEY=VALUE (e.g. default_concurrency=4)' 'c) 任务引擎设置 KEY=VALUE（例：default_concurrency=4）')" '')"
  while [ -n "$v" ]; do
    TASKS+=("$v")
    v="$(ask "$(lc '   another task key (blank = done)' '   另一个任务键（留空=完成）')" '')"
  done

  v="$(ask "$(lc 'd) Memory subsystem: 1) enable  2) disable  (blank = leave unchanged)' 'd) 记忆子系统：1) 开启  2) 关闭（留空=不变）')" '')"
  case "$v" in
    1) MEMORY="on" ;;
    2) MEMORY="off" ;;
    *) : ;;
  esac

  v="$(ask "$(lc 'e) Define a team as NAME=JSON (blank = skip)' 'e) 定义团队 NAME=JSON（留空=跳过）')" '')"
  while [ -n "$v" ]; do
    TEAMS+=("$v")
    v="$(ask "$(lc '   another team (blank = done)' '   另一个团队（留空=完成）')" '')"
  done
}

if [ "$SKIP_INSTALL" -eq 0 ]; then
  if OMO_BIN="$(find_omo)"; then
    info "omo already installed: $("$OMO_BIN" --version 2>/dev/null || echo "$OMO_BIN") - skipping installation"
  else
    if have_tty; then
      if ask_yes "omo is not installed. Install it now?" "y"; then
        install_omo
      else
        die "omo is required; aborting"
      fi
    else
      install_omo
    fi
    OMO_BIN="$(find_omo)" || die "omo installed but not found on PATH; open a new shell and re-run"
    info "installed: $("$OMO_BIN" --version 2>/dev/null || echo "$OMO_BIN")"
  fi
else
  info "--skip-install set, not checking installation"
fi

HAVE_AGENT_FLAGS=0
if [ ${#CATEGORIES[@]} -gt 0 ] || [ ${#AGENTS[@]} -gt 0 ] || [ ${#TASKS[@]} -gt 0 ] || \
   [ ${#TEAMS[@]} -gt 0 ] || [ ${#SET_JSONS[@]} -gt 0 ] || [ ${#PRESETS[@]} -gt 0 ] || \
   [ -n "$MEMORY" ] || [ -n "$OMO_JSON" ]; then
  HAVE_AGENT_FLAGS=1
fi

# Run the provider wizard when forced, when provider flags were given but are
# incomplete, or when nothing at all was supplied (the interactive default).
# --advice is a pure print command, so it never runs the wizard.
if [ "$SHOW_ADVICE" -eq 1 ]; then
  :
elif [ "$FORCE_INTERACTIVE" -eq 1 ]; then
  wizard
elif [ -n "$BASE_URL" ] || [ -n "$API_KEY" ] || [ -n "$MODELS" ] || [ -n "$MODELS_FILE" ]; then
  if [ -z "$MODELS" ] && [ -z "$MODELS_FILE" ]; then wizard; fi
  if [ -z "$BASE_URL" ] || [ -z "$API_KEY" ]; then wizard; fi
elif [ "$HAVE_AGENT_FLAGS" -eq 0 ]; then
  wizard
fi

CONFIG_ARGS=(--base-url "$BASE_URL" --api-key "$API_KEY")
if [ -n "$MODELS_FILE" ]; then
  CONFIG_ARGS+=(--models-file "$MODELS_FILE")
else
  CONFIG_ARGS+=(--models "$MODELS")
fi
# Only pass provider flags when they are present; a multi-agent-only run must
# not send empty --base-url/--api-key/--models values.
if [ -z "$BASE_URL" ] && [ -z "$API_KEY" ] && [ -z "$MODELS" ] && [ -z "$MODELS_FILE" ]; then
  CONFIG_ARGS=()
fi
CONFIG_ARGS+=(--lang "$LANG_CODE")
if [ -n "$PROVIDER" ]; then CONFIG_ARGS+=(--provider "$PROVIDER"); fi
if [ -n "$API_TYPE" ]; then CONFIG_ARGS+=(--api-type "$API_TYPE"); fi
if [ -n "$DEFAULT_MODEL" ]; then CONFIG_ARGS+=(--default-model "$DEFAULT_MODEL"); fi
if [ "$NO_DEFAULT" -eq 1 ]; then CONFIG_ARGS+=(--no-default); fi
if [ "$DRY_RUN" -eq 1 ]; then CONFIG_ARGS+=(--dry-run); fi

if [ "$SHOW_ADVICE" -eq 1 ]; then
  show_advice
  exit 0
fi

if [ "$NO_AGENT_CONFIG" -eq 0 ]; then
  for item in "${PRESETS[@]+"${PRESETS[@]}"}"; do CONFIG_ARGS+=(--preset "$item"); done
  for item in "${CATEGORIES[@]+"${CATEGORIES[@]}"}"; do CONFIG_ARGS+=(--category "$item"); done
  for item in "${AGENTS[@]+"${AGENTS[@]}"}"; do CONFIG_ARGS+=(--agent "$item"); done
  for item in "${TASKS[@]+"${TASKS[@]}"}"; do CONFIG_ARGS+=(--task "$item"); done
  for item in "${TEAMS[@]+"${TEAMS[@]}"}"; do CONFIG_ARGS+=(--team "$item"); done
  for item in "${SET_JSONS[@]+"${SET_JSONS[@]}"}"; do CONFIG_ARGS+=(--set-json "$item"); done
  if [ -n "$MEMORY" ]; then CONFIG_ARGS+=(--memory "$MEMORY"); fi
  if [ -n "$OMO_JSON" ]; then CONFIG_ARGS+=(--omo-json "$OMO_JSON"); fi
fi
if [ "$NO_AGENT_CONFIG" -eq 1 ]; then CONFIG_ARGS+=(--no-agent-config); fi
if [ "$NO_ADVICE" -eq 1 ]; then CONFIG_ARGS+=(--no-advice); fi

info "writing config"
run_config "${CONFIG_ARGS[@]}"
