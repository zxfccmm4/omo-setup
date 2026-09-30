#!/usr/bin/env bash
#
# omo-setup.sh - install OmO if missing, then configure a custom provider
# (baseUrl + apiKey + models) in one shot.
#
# Targets Linux and macOS. For Windows use omo-setup.ps1.
#
# Examples:
#   ./omo-setup.sh --base-url https://api.example.com/v1 --api-key sk-xxx \
#                  --models gpt-4o,gpt-4o-mini
#
#   OMO_BASE_URL=https://api.example.com/v1 OMO_API_KEY=sk-xxx \
#     OMO_MODELS=gpt-4o ./omo-setup.sh
#
# Flags:
#   --base-url URL        endpoint base url            (env OMO_BASE_URL)
#   --api-key KEY         provider api key             (env OMO_API_KEY)
#   --models a,b,c        comma-separated model ids    (env OMO_MODELS)
#   --provider NAME       provider id                  (default: derived from host)
#   --api-type TYPE       openai-completions|openai-responses|anthropic-messages
#   --default-model ID    default model to select      (default: provider/<first>)
#   --no-default          do not touch settings.json defaults
#   --dry-run             print planned changes, write nothing
#   --skip-install        never install, only configure
#   --help                show this help
#
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

SKIP_INSTALL=0
CONFIG_ARGS=()

while [ $# -gt 0 ]; do
  case "$1" in
    --skip-install) SKIP_INSTALL=1; shift ;;
    --help|-h) sed -n '2,30p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    --base-url|--api-key|--models|--provider|--api-type|--default-model)
      CONFIG_ARGS+=("$1" "$2"); shift 2 ;;
    --base-url=*|--api-key=*|--models=*|--provider=*|--api-type=*|--default-model=*)
      CONFIG_ARGS+=("$1"); shift ;;
    --dry-run|--no-default)
      CONFIG_ARGS+=("$1"); shift ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
done

info() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m!!\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31mxx\033[0m %s\n' "$*" >&2; exit 1; }

find_omo() {
  if command -v omo >/dev/null 2>&1; then
    command -v omo
    return 0
  fi
  for d in "$HOME/.bun/bin" "$HOME/.local/bin" "$HOME/.omo/bin" "/usr/local/bin"; do
    if [ -x "$d/omo" ]; then echo "$d/omo"; return 0; fi
  done
  return 1
}

install_omo() {
  info "omo not found - installing OmO Native"
  if command -v curl >/dev/null 2>&1; then
    curl -fsSL https://get.omo.dev/install.sh | bash \
      || die "official installer failed"
  elif command -v bun >/dev/null 2>&1; then
    bun add -g omo-ai || die "bun add -g omo-ai failed"
  elif command -v npm >/dev/null 2>&1; then
    npm i -g omo-ai || die "npm i -g omo-ai failed"
  else
    die "no curl/bun/npm available to install omo"
  fi
}

if [ "$SKIP_INSTALL" -eq 0 ]; then
  if OMO_BIN="$(find_omo)"; then
    info "omo already installed: $(("$OMO_BIN" --version 2>/dev/null) || echo "$OMO_BIN")"
    info "skipping installation"
  else
    install_omo
    OMO_BIN="$(find_omo)" || die "omo installed but not found on PATH; open a new shell and re-run"
    info "installed: $(("$OMO_BIN" --version 2>/dev/null) || echo "$OMO_BIN")"
  fi
else
  info "--skip-install set, not checking installation"
fi

run_config() {
  if command -v node >/dev/null 2>&1; then
    node "$SCRIPT_DIR/omo-config.mjs" "$@"
  elif command -v bun >/dev/null 2>&1; then
    bun "$SCRIPT_DIR/omo-config.mjs" "$@"
  else
    die "need node or bun to write omo config"
  fi
}

info "configuring provider"
run_config "${CONFIG_ARGS[@]}"
