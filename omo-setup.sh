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
#   --provider NAME       provider id                  (default: derived from host)
#   --api-type TYPE       openai-completions|openai-responses|anthropic-messages
#   --default-model ID    default model to select      (default: provider/<first>)
#   --no-default          do not touch settings.json defaults
#   --dry-run             print planned changes, write nothing
#   --skip-install        never install, only configure
#   --allow-root          allow installing omo as root (sets OMO_INSTALL_ALLOW_SUDO=1)
#   -h, --help            show this help
#
set -euo pipefail

RAW_BASE="https://raw.githubusercontent.com/zxfccmm4/omo-setup/main"

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd || echo "$PWD")"

BASE_URL="${OMO_BASE_URL:-}"
API_KEY="${OMO_API_KEY:-}"
MODELS="${OMO_MODELS:-}"
PROVIDER="${OMO_PROVIDER:-}"
API_TYPE="${OMO_API_TYPE:-}"
DEFAULT_MODEL="${OMO_DEFAULT_MODEL:-}"
NO_DEFAULT=0
DRY_RUN=0
SKIP_INSTALL=0
FORCE_INTERACTIVE=0
CONFIG_SCRIPT=""
TMP_CONFIG=""

info() { printf '\033[1;34m==>\033[0m %s\n' "$*" >&2; }
warn() { printf '\033[1;33m!!\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31mxx\033[0m %s\n' "$*" >&2; exit 1; }

cleanup() { [ -n "$TMP_CONFIG" ] && [ -f "$TMP_CONFIG" ] && rm -f "$TMP_CONFIG"; }
trap cleanup EXIT

mask() {
  local s="$1" n=${#1}
  if [ "$n" -le 8 ]; then printf '********'; else printf '%s...%s' "${s:0:4}" "${s: -4}"; fi
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
    -h|--help) sed -n '2,28p' "${BASH_SOURCE[0]:-$0}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    --base-url) BASE_URL="$2"; shift 2 ;;
    --api-key) API_KEY="$2"; shift 2 ;;
    --models) MODELS="$2"; shift 2 ;;
    --provider) PROVIDER="$2"; shift 2 ;;
    --api-type) API_TYPE="$2"; shift 2 ;;
    --default-model) DEFAULT_MODEL="$2"; shift 2 ;;
    --base-url=*) BASE_URL="${1#*=}"; shift ;;
    --api-key=*) API_KEY="${1#*=}"; shift ;;
    --models=*) MODELS="${1#*=}"; shift ;;
    --provider=*) PROVIDER="${1#*=}"; shift ;;
    --api-type=*) API_TYPE="${1#*=}"; shift ;;
    --default-model=*) DEFAULT_MODEL="${1#*=}"; shift ;;
    *) die "unknown option: $1" ;;
  esac
done

ask() {
  local msg="$1" def="${2-}" val
  if [ -n "$def" ]; then printf '%s [%s]: ' "$msg" "$def" >&2; else printf '%s: ' "$msg" >&2; fi
  read_tty val || true
  printf '%s' "${val:-$def}"
}

ask_secret() {
  local msg="$1" val
  printf '%s: ' "$msg" >&2
  if have_tty; then IFS= read -rs val < /dev/tty || true; else IFS= read -rs val || true; fi
  printf '\n' >&2
  printf '%s' "$val"
}

ask_yes() {
  local msg="$1" def="${2:-n}" val
  printf '%s [%s]: ' "$msg" "$def" >&2
  read_tty val || true
  val="${val:-$def}"
  case "$val" in y|Y|yes|YES|Yes) return 0 ;; *) return 1 ;; esac
}

find_omo() {
  if command -v omo >/dev/null 2>&1; then command -v omo; return 0; fi
  for d in "$HOME/.bun/bin" "$HOME/.local/bin" "$HOME/.omo/bin" "/usr/local/bin"; do
    if [ -x "$d/omo" ]; then echo "$d/omo"; return 0; fi
  done
  return 1
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
  local tmp
  tmp="$(mktemp "${TMPDIR:-/tmp}/omo-config.XXXXXX.mjs")"
  info "downloading omo-config.mjs" >&2
  if command -v curl >/dev/null 2>&1; then
    curl -fsSL "$RAW_BASE/omo-config.mjs" -o "$tmp" || die "failed to download omo-config.mjs"
  elif command -v wget >/dev/null 2>&1; then
    wget -qO "$tmp" "$RAW_BASE/omo-config.mjs" || die "failed to download omo-config.mjs"
  else
    die "need curl or wget to download omo-config.mjs"
  fi
  TMP_CONFIG="$tmp"
  CONFIG_SCRIPT="$tmp"
}

run_config() {
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
  info "step-by-step setup (press Enter to accept the [default])"
  printf '\n' >&2

  local v
  v="$(ask '1) Endpoint base URL (e.g. https://api.example.com/v1)' "$BASE_URL")"
  [ -n "$v" ] || die "base URL is required"
  BASE_URL="$v"

  v="$(ask_secret '2) API key')"
  [ -n "$v" ] && API_KEY="$v"
  [ -n "$API_KEY" ] || die "API key is required"

  v="$(ask '3) Model ids, comma-separated (e.g. gpt-4o,gpt-4o-mini)' "$MODELS")"
  [ -n "$v" ] || die "at least one model is required"
  MODELS="$v"

  v="$(ask '4) Provider name (blank = auto from host)' "$PROVIDER")"
  PROVIDER="$v"

  printf '5) API protocol:  1) openai-completions (default)  2) openai-responses  3) anthropic-messages\n' >&2
  v="$(ask '   choose [1-3]' '1')"
  case "$v" in
    1) API_TYPE="openai-completions" ;;
    2) API_TYPE="openai-responses" ;;
    3) API_TYPE="anthropic-messages" ;;
    *) warn "unknown choice '$v', using openai-completions"; API_TYPE="openai-completions" ;;
  esac

  v="$(ask '6) Default model (blank = provider/<first model>)' "$DEFAULT_MODEL")"
  DEFAULT_MODEL="$v"

  printf '\n' >&2
  info "about to write:"
  printf '   Base URL : %s\n' "$BASE_URL" >&2
  printf '   API key  : %s\n' "$(mask "$API_KEY")" >&2
  printf '   Models   : %s\n' "$MODELS" >&2
  printf '   Provider : %s\n' "${PROVIDER:-(auto)}" >&2
  printf '   Protocol : %s\n' "$API_TYPE" >&2
  if [ "$NO_DEFAULT" -eq 0 ]; then
    printf '   Default  : %s\n' "${DEFAULT_MODEL:-(provider/<first model>)}" >&2
  fi
  printf '\n' >&2
  if ! ask_yes "7) Write this config?" "n"; then info "cancelled"; exit 0; fi
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

if [ "$FORCE_INTERACTIVE" -eq 1 ] || [ -z "$BASE_URL" ] || [ -z "$API_KEY" ] || [ -z "$MODELS" ]; then
  wizard
fi

CONFIG_ARGS=(--base-url "$BASE_URL" --api-key "$API_KEY" --models "$MODELS")
if [ -n "$PROVIDER" ]; then CONFIG_ARGS+=(--provider "$PROVIDER"); fi
if [ -n "$API_TYPE" ]; then CONFIG_ARGS+=(--api-type "$API_TYPE"); fi
if [ -n "$DEFAULT_MODEL" ]; then CONFIG_ARGS+=(--default-model "$DEFAULT_MODEL"); fi
if [ "$NO_DEFAULT" -eq 1 ]; then CONFIG_ARGS+=(--no-default); fi
if [ "$DRY_RUN" -eq 1 ]; then CONFIG_ARGS+=(--dry-run); fi

info "writing config"
run_config "${CONFIG_ARGS[@]}"
