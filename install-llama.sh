#!/usr/bin/env bash
#
# install-llama.sh — Fully automatic llama.cpp installer for Linux
#
# Downloads pre-built binaries from GitHub releases, installs them,
# optionally downloads a GGUF model, sets up a systemd service,
# and starts the server.
#
# Usage:
#   chmod +x install-llama.sh
#   sudo ./install-llama.sh          # full install (may need sudo for /usr/local)
#   ./install-llama.sh --prefix ~/.local  # user-local install (no sudo)
#
# Options:
#   --help, -h          show this help
#   --status            show installation status and check GitHub for updates
#   --check-update      only check for a newer build on GitHub
#   --download-update   download the latest Linux build from GitHub
#   --upgrade           = --download-update + --update + [--install-service]
#   --update            update from a local archive (no model download)
#   --list-models       list available model presets
#   --choose-model      interactive model selection
#   --model PRESET      qwen14 | qwen7 | llama8 | qwen32
#   --install-service   install systemd service (requires root)
#   --uninstall-service remove systemd service
#   --skip-download     skip model download
#   --skip-server       don't start llama-server at the end
#   --install-only      = --skip-download --skip-server
#   --port 8080         HTTP port (default: 8080)
#   --context 8192      context size (default: 8192)
#   --host 0.0.0.0      bind address (default: 0.0.0.0)
#   --prefix DIR        install prefix (default: /usr/local; use ~/.local for user)
#   --model-repo REPO   Hugging Face repo
#   --model-file FILE   GGUF filename
#   --models-dir DIR    model storage directory
#   --no-github-check   skip GitHub check in --status
#   --build-from-source build from source instead of using pre-built binaries
#
# Requirements:
#   - bash 4+
#   - curl, tar, gzip (for pre-built binary install)
#   - cmake, git, make, g++ (for --build-from-source)
#   - huggingface-cli (for model downloads: pip install huggingface_hub)
#   - systemd (for --install-service)
#

set -euo pipefail

# ── Colors ─────────────────────────────────────────────────────────────────────
if [[ -t 1 ]]; then
  RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
else
  RED=''; GREEN=''; YELLOW=''; BLUE=''; NC=''
fi

info()  { echo -e "${BLUE}[INFO]${NC}  $*" >&2; }
ok()    { echo -e "${GREEN}[OK]${NC}    $*" >&2; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $*" >&2; }
err()   { echo -e "${RED}[ERROR]${NC} $*" >&2; }
die()   { err "$@"; exit 1; }

# ── Default configuration ──────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

INSTALL_PREFIX="${LLAMA_INSTALL_PREFIX:-/usr/local}"
LOCAL_BIN="${INSTALL_PREFIX}/bin"
LOCAL_LIB="${INSTALL_PREFIX}/lib"
MODELS_DIR="${HOME}/models"
CONFIG_DIR="${HOME}/.config/llama"
CONFIG_FILE="${CONFIG_DIR}/server.conf"
SYSTEMD_SERVICE_NAME="llama-server"
SYSTEMD_SERVICE_FILE="/etc/systemd/system/${SYSTEMD_SERVICE_NAME}.service"
START_SCRIPT="/usr/local/bin/llama-server-start.sh"
LOG_DIR="/var/log/llama"
LOG_OUT="${LOG_DIR}/llama-server.log"
LOG_ERR="${LOG_DIR}/llama-server.err.log"

PORT=8080
CONTEXT=8192
HOST="0.0.0.0"
MODE_UPDATE=0
MODE_STATUS=0
MODE_CHECK_UPDATE=0
MODE_DOWNLOAD_UPDATE=0
MODE_UPGRADE=0
SKIP_GITHUB_CHECK=0
MODE_CHOOSE_MODEL=0
MODE_LIST_MODELS=0
GITHUB_REPO="ggml-org/llama.cpp"
GITHUB_API="https://api.github.com/repos/ggml-org/llama.cpp/releases/latest"
SKIP_DOWNLOAD=0
SKIP_SERVER=0
INSTALL_SERVICE=0
UNINSTALL_SERVICE=0
RUN_MAIN=1
MODEL_PRESET=""
BUILD_FROM_SOURCE=0

MODEL_REPO="bartowski/Qwen2.5-14B-Instruct-GGUF"
MODEL_FILE="Qwen2.5-14B-Instruct-Q4_K_M.gguf"
MODEL_PATH="${MODELS_DIR}/${MODEL_FILE}"
MODEL_LABEL="Qwen2.5 14B Q4_K_M"

HF_CLI=""

# ── Argument parsing ───────────────────────────────────────────────────────────
usage() {
  sed -n '2,40p' "$0" | sed 's/^# \{0,1\}//'
  exit 0
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --status)            MODE_STATUS=1; RUN_MAIN=0 ;;
    --check-update)      MODE_CHECK_UPDATE=1; RUN_MAIN=0 ;;
    --download-update)   MODE_DOWNLOAD_UPDATE=1; RUN_MAIN=0 ;;
    --upgrade)           MODE_UPGRADE=1; RUN_MAIN=0 ;;
    --no-github-check)   SKIP_GITHUB_CHECK=1 ;;
    --list-models)       MODE_LIST_MODELS=1; RUN_MAIN=0 ;;
    --choose-model)      MODE_CHOOSE_MODEL=1 ;;
    --model)             MODEL_PRESET="$2"; shift ;;
    --update)            MODE_UPDATE=1; SKIP_DOWNLOAD=1 ;;
    --install-service)   INSTALL_SERVICE=1 ;;
    --uninstall-service) UNINSTALL_SERVICE=1; RUN_MAIN=0 ;;
    --skip-download)     SKIP_DOWNLOAD=1 ;;
    --skip-server)       SKIP_SERVER=1 ;;
    --install-only)      SKIP_DOWNLOAD=1; SKIP_SERVER=1 ;;
    --port)              PORT="$2"; shift ;;
    --context)           CONTEXT="$2"; shift ;;
    --host)              HOST="$2"; shift ;;
    --prefix)            INSTALL_PREFIX="$2"; LOCAL_BIN="${INSTALL_PREFIX}/bin"; LOCAL_LIB="${INSTALL_PREFIX}/lib"; shift ;;
    --models-dir)        MODELS_DIR="$2"; MODEL_PATH="${MODELS_DIR}/${MODEL_FILE}"; shift ;;
    --model-repo)        MODEL_REPO="$2"; shift ;;
    --model-file)        MODEL_FILE="$2"; MODEL_PATH="${MODELS_DIR}/${MODEL_FILE}"; shift ;;
    --build-from-source) BUILD_FROM_SOURCE=1 ;;
    -h|--help)           usage ;;
    *)                   die "Unknown argument: $1 (use --help)" ;;
  esac
  shift
done

# ── System checks ──────────────────────────────────────────────────────────────
[[ "$(uname -s)" == "Linux" ]] || die "This script is for Linux only."

command -v curl >/dev/null 2>&1 || die "Missing 'curl'. Install it with your package manager."
command -v tar >/dev/null 2>&1  || die "Missing 'tar'."
command -v gzip >/dev/null 2>&1 || die "Missing 'gzip'."

# ── Architecture detection ─────────────────────────────────────────────────────
get_system_arch() {
  case "$(uname -m)" in
    x86_64|amd64)  echo "x86_64" ;;
    aarch64|arm64) echo "aarch64" ;;
    *)             echo "$(uname -m)" ;;
  esac
}

get_binary_arch() {
  local bin="$1"
  [[ -f "$bin" ]] || { echo "unknown"; return; }
  local info
  info="$(file -b "$bin" 2>/dev/null || true)"
  if [[ "$info" == *"x86-64"* ]]; then
    echo "x86_64"
  elif [[ "$info" == *"aarch64"* || "$info" == *"ARM aarch64"* ]]; then
    echo "aarch64"
  else
    echo "unknown"
  fi
}

# ── CUDA / GPU detection ───────────────────────────────────────────────────────
detect_gpu_backend() {
  if command -v nvidia-smi >/dev/null 2>&1; then
    echo "cuda"
  elif command -v rocm-smi >/dev/null 2>&1; then
    echo "rocm"
  elif command -v vulkaninfo >/dev/null 2>&1; then
    echo "vulkan"
  else
    echo "cpu"
  fi
}

# ── Shell RC file detection ────────────────────────────────────────────────────
detect_shell_rc_files() {
  local shell_path shell_name rc_files=()
  shell_path="${SHELL:-}"
  shell_name="$(basename "${shell_path:-bash}")"

  case "$shell_name" in
    zsh)  rc_files=("${HOME}/.zshrc") ;;
    bash)
      if [[ -f "${HOME}/.bashrc" ]]; then
        rc_files=("${HOME}/.bashrc")
      elif [[ -f "${HOME}/.bash_profile" ]]; then
        rc_files=("${HOME}/.bash_profile")
      else
        rc_files=("${HOME}/.profile")
      fi
      ;;
    fish) rc_files=("${HOME}/.config/fish/config.fish") ;;
    *)    rc_files=("${HOME}/.profile") ;;
  esac

  echo "${rc_files[@]}"
}

# ── huggingface-cli discovery ─────────────────────────────────────────────────
find_hf_cli() {
  local candidate
  for candidate in \
    "$(command -v huggingface-cli 2>/dev/null || true)" \
    "${HOME}/.local/bin/huggingface-cli" \
    "${HOME}/miniconda3/bin/huggingface-cli" \
    "${HOME}/anaconda3/bin/huggingface-cli" \
    "/usr/local/bin/huggingface-cli"
  do
    [[ -n "$candidate" && -x "$candidate" ]] && { echo "$candidate"; return 0; }
  done
  return 1
}

# ── Configuration and model management ────────────────────────────────────────
sync_model_path() {
  MODEL_PATH="${MODELS_DIR}/${MODEL_FILE}"
}

load_config() {
  [[ -f "$CONFIG_FILE" ]] || return 0
  # shellcheck disable=SC1090
  source "$CONFIG_FILE"
  sync_model_path
}

save_config() {
  local llama_ver=""
  mkdir -p "$CONFIG_DIR"
  [[ -x "${LOCAL_BIN}/llama-server" ]] && llama_ver="$(get_llama_version_string "${LOCAL_BIN}/llama-server")"
  cat > "$CONFIG_FILE" <<EOF
# llama.cpp — generated by install-llama.sh
LLAMA_VERSION="${llama_ver}"
MODEL_LABEL="${MODEL_LABEL}"
MODEL_REPO="${MODEL_REPO}"
MODEL_FILE="${MODEL_FILE}"
MODEL_PATH="${MODEL_PATH}"
PORT=${PORT}
CONTEXT=${CONTEXT}
HOST="${HOST}"
INSTALL_PREFIX="${INSTALL_PREFIX}"
EOF
}

apply_model_preset() {
  local preset
  preset="$(echo "$1" | tr '[:upper:]' '[:lower:]')"
  case "$preset" in
    1|qwen14)
      MODEL_LABEL="Qwen2.5 14B Q4_K_M (~8.4 GB)"
      MODEL_REPO="bartowski/Qwen2.5-14B-Instruct-GGUF"
      MODEL_FILE="Qwen2.5-14B-Instruct-Q4_K_M.gguf"
      ;;
    2|qwen7)
      MODEL_LABEL="Qwen2.5 7B Q4_K_M (~4.7 GB)"
      MODEL_REPO="bartowski/Qwen2.5-7B-Instruct-GGUF"
      MODEL_FILE="Qwen2.5-7B-Instruct-Q4_K_M.gguf"
      ;;
    3|llama8)
      MODEL_LABEL="Llama 3.1 8B Q4_K_M (~5 GB)"
      MODEL_REPO="bartowski/Meta-Llama-3.1-8B-Instruct-GGUF"
      MODEL_FILE="Meta-Llama-3.1-8B-Instruct-Q4_K_M.gguf"
      ;;
    4|qwen32)
      MODEL_LABEL="Qwen2.5 32B Q4_K_M (~19 GB)"
      MODEL_REPO="bartowski/Qwen2.5-32B-Instruct-GGUF"
      MODEL_FILE="Qwen2.5-32B-Instruct-Q4_K_M.gguf"
      ;;
    *)
      die "Unknown preset: $1. Use: qwen14 | qwen7 | llama8 | qwen32  (or --list-models)"
      ;;
  esac
  sync_model_path
  ok "Model: ${MODEL_LABEL}"
}

list_models_catalog() {
  echo ""
  echo "Available models (--model PRESET):"
  echo ""
  echo "  qwen14  (1)  Qwen2.5 14B Q4_K_M   ~8.4 GB  — balanced (recommended)"
  echo "  qwen7   (2)  Qwen2.5 7B Q4_K_M    ~4.7 GB  — faster"
  echo "  llama8  (3)  Llama 3.1 8B Q4_K_M  ~5 GB    — fast"
  echo "  qwen32  (4)  Qwen2.5 32B Q4_K_M   ~19 GB   — best quality (24 GB+ RAM)"
  echo ""
  echo "Examples:"
  echo "  ./install-llama.sh --model qwen7"
  echo "  ./install-llama.sh --choose-model"
  echo ""
}

choose_model_interactive() {
  local choice
  list_models_catalog
  if [[ ! -t 0 ]]; then
    die "Interactive selection requires a TTY. Use: --model qwen14"
  fi
  read -r -p "Choose [1-4] or preset name (qwen14): " choice
  choice="${choice:-1}"
  apply_model_preset "$choice"
  save_config
}

resolve_model_selection() {
  load_config
  if [[ -n "$MODEL_PRESET" ]]; then
    apply_model_preset "$MODEL_PRESET"
    save_config
  elif [[ "$MODE_CHOOSE_MODEL" -eq 1 ]]; then
    choose_model_interactive
  fi
}

if [[ "$MODE_LIST_MODELS" -eq 1 ]]; then
  list_models_catalog
  exit 0
fi

if [[ "$SKIP_DOWNLOAD" -eq 0 && "$RUN_MAIN" -eq 1 ]]; then
  HF_CLI="$(find_hf_cli || true)"
  [[ -n "$HF_CLI" ]] || warn "huggingface-cli not found. Model downloads will fail. Install: pip install huggingface_hub"
fi

# ── Version utilities ──────────────────────────────────────────────────────────
get_llama_version_string() {
  local bin="$1"
  if [[ ! -x "$bin" ]]; then
    echo "not installed"
    return
  fi

  local ver=""
  ver="$("${bin}" --version 2>&1 | head -1 | tr -d '\r' || true)"
  [[ -n "$ver" ]] && { echo "$ver"; return; }

  echo "unknown"
}

get_installed_build_number() {
  local v
  if [[ -x "${LOCAL_BIN}/llama-server" ]]; then
    v="$(get_llama_version_string "${LOCAL_BIN}/llama-server")"
    v="$(echo "$v" | grep -oE 'b[0-9]+|[0-9]{4,}' | head -1 | tr -d 'b')"
    [[ -n "$v" ]] && { echo "$v"; return; }
  fi
  echo "0"
}

# Extract build number from path like llama-b9159
bundle_build_number() {
  local name="$1"
  local n
  n="$(basename "$name" | grep -oE '[bB][0-9]+' | tr -d 'bB' | head -1 || true)"
  if [[ -n "$n" ]]; then
    echo "$n"
  else
    echo "0"
  fi
}

# ── GitHub — check and download new releases ───────────────────────────────────
github_fetch_latest_tag() {
  local json tag
  json="$(curl -fsSL --connect-timeout 8 --max-time 25 \
    -H "Accept: application/vnd.github+json" \
    "${GITHUB_API}" 2>/dev/null)" || return 1
  tag="$(echo "$json" | grep -m1 '"tag_name"' \
    | sed -E 's/.*"tag_name"[[:space:]]*:[[:space:]]*"([^"]+)".*/\1/')"
  [[ -n "$tag" ]] && echo "$tag"
}

github_normalize_tag() {
  local t="$1"
  t="${t#b}"
  t="${t#B}"
  echo "b${t}"
}

github_asset_name() {
  local tag arch gpu
  tag="$(github_normalize_tag "$1")"
  arch="$(get_system_arch)"
  gpu="$(detect_gpu_backend)"

  if [[ "$gpu" == "cuda" ]]; then
    case "$arch" in
      x86_64)  echo "llama-${tag}-bin-ubuntu-x64.tar.gz" ;;
      aarch64) echo "llama-${tag}-bin-ubuntu-aarch64.tar.gz" ;;
      *)       echo "" ;;
    esac
  else
    case "$arch" in
      x86_64)  echo "llama-${tag}-bin-ubuntu-x64.tar.gz" ;;
      aarch64) echo "llama-${tag}-bin-ubuntu-aarch64.tar.gz" ;;
      *)       echo "" ;;
    esac
  fi
}

github_release_url() {
  local tag asset
  tag="$(github_normalize_tag "$1")"
  asset="$(github_asset_name "$tag")"
  [[ -n "$asset" ]] || return 1
  echo "https://github.com/${GITHUB_REPO}/releases/download/${tag}/${asset}"
}

tag_build_number() {
  echo "$1" | tr -d 'bB' | grep -oE '^[0-9]+' || echo "0"
}

check_github_update() {
  local installed latest_tag latest_num url releases_url
  releases_url="https://github.com/${GITHUB_REPO}/releases"

  echo -e "  ${BLUE}GitHub:${NC}"
  latest_tag="$(github_fetch_latest_tag)" || {
    echo -e "    ${YELLOW}check failed${NC} (network or API rate limit)"
    echo -e "    ${releases_url}"
    return 1
  }

  installed="$(get_installed_build_number)"
  latest_num="$(tag_build_number "$latest_tag")"
  asset="$(github_asset_name "$latest_tag")"
  url="$(github_release_url "$latest_tag")"

  if [[ "$installed" == "0" ]]; then
    echo -e "    Latest build: ${GREEN}${latest_tag}${NC} (not installed)"
    echo -e "    ${releases_url}"
    [[ -n "$url" ]] && echo -e "    Download: ${url}"
    return 0
  fi

  if [[ "$installed" -ge "$latest_num" ]]; then
    echo -e "    ${GREEN}up to date${NC} — b${installed} (= ${latest_tag})"
  else
    echo -e "    ${YELLOW}newer version available${NC}: ${latest_tag} (installed: b${installed})"
    echo -e "    ${releases_url}"
    [[ -n "$url" ]] && echo -e "    Download: ${url}"
    print_update_next_steps
  fi
  return 0
}

print_update_next_steps() {
  echo ""
  info "Next step:"
  if [[ -f "${SYSTEMD_SERVICE_FILE}" ]]; then
    echo "  sudo ./install-llama.sh --update --skip-server --install-service"
    echo ""
    info "systemd service is active — the server will restart in the background (model stays untouched)."
  else
    echo "  sudo ./install-llama.sh --update --skip-server"
    echo ""
    info "For auto-start at boot:"
    echo "  sudo ./install-llama.sh --install-service"
  fi
}

download_github_update() {
  local installed latest_tag latest_num asset url dest
  latest_tag="$(github_fetch_latest_tag)" || die "Failed to connect to GitHub API.
Check your internet connection or visit: https://github.com/${GITHUB_REPO}/releases"

  installed="$(get_installed_build_number)"
  latest_num="$(tag_build_number "$latest_tag")"

  if [[ "$installed" != "0" && "$installed" -ge "$latest_num" ]]; then
    ok "You already have the latest version (${latest_tag})"
    return 0
  fi

  asset="$(github_asset_name "$latest_tag")"
  [[ -n "$asset" ]] || die "No Linux build available for architecture $(get_system_arch)"
  url="$(github_release_url "$latest_tag")"
  dest="${SCRIPT_DIR}/${asset}"

  info "Downloading ${latest_tag} for $(get_system_arch) …"
  warn "The file may be hundreds of MB — please wait…"
  curl -fL --progress-bar -o "$dest" "$url" || die "Download failed: ${url}"
  ok "Downloaded: ${dest}"
  print_update_next_steps
}

# ─── Bundle management ─────────────────────────────────────────────────────────
select_newest_bundle_dir() {
  local item best="" best_n=0 n
  for item in "${SCRIPT_DIR}"/llama-*; do
    [[ -d "$item" ]] || continue
    [[ -x "${item}/llama-server" ]] || continue
    n="$(bundle_build_number "$item")"
    if [[ -z "$best" ]] || [[ "$n" -gt "$best_n" ]]; then
      best="$item"
      best_n="$n"
    fi
  done
  [[ -n "$best" ]] && echo "$best"
}

select_newest_archive() {
  local item best="" best_n=0 n
  for item in "${SCRIPT_DIR}"/llama-*.tar.gz "${SCRIPT_DIR}"/llama-*.tgz; do
    [[ -f "$item" ]] || continue
    n="$(bundle_build_number "$item")"
    if [[ -z "$best" ]] || [[ "$n" -gt "$best_n" ]]; then
      best="$item"
      best_n="$n"
    fi
  done
  echo "$best"
}

extract_bundle() {
  local archive="$1" extract_dir bundle_dir permanent
  extract_dir="$(mktemp -d "${SCRIPT_DIR}/.llama-extract-XXXXXX")"
  info "Extracting: $(basename "$archive")"
  tar -xzf "$archive" -C "$extract_dir"

  bundle_dir="$(find "$extract_dir" -maxdepth 3 -name llama-server -type f 2>/dev/null | head -1)"
  if [[ -z "$bundle_dir" ]]; then
    rm -rf "$extract_dir"
    die "Archive $(basename "$archive") does not contain llama-server."
  fi
  bundle_dir="$(dirname "$bundle_dir")"

  permanent="${SCRIPT_DIR}/$(basename "$bundle_dir")"
  if [[ "$bundle_dir" != "$permanent" ]]; then
    rm -rf "$permanent" 2>/dev/null || true
    mv "$bundle_dir" "$permanent"
    bundle_dir="$permanent"
  fi
  rm -rf "$extract_dir"
  ok "Extracted bundle: $(basename "$bundle_dir")"
  echo "$bundle_dir"
}

cleanup_old_bundle_dirs() {
  local keep_n="$1" item n
  [[ -n "$keep_n" ]] || return 0
  for item in "${SCRIPT_DIR}"/llama-*; do
    [[ -d "$item" ]] || continue
    [[ -x "${item}/llama-server" ]] || continue
    n="$(bundle_build_number "$item")"
    if [[ "$n" -lt "$keep_n" ]]; then
      info "Removing old folder: $(basename "$item") (b${n})"
      rm -rf "$item"
    fi
  done
}

find_and_prepare_bundle() {
  local bundle_dir="" bundle_n=0 archive="" archive_n=0

  info "Searching for llama bundle in: ${SCRIPT_DIR}"

  bundle_dir="$(select_newest_bundle_dir || true)"
  [[ -n "$bundle_dir" ]] && bundle_n="$(bundle_build_number "$bundle_dir")"

  archive="$(select_newest_archive || true)"
  [[ -n "$archive" ]] && archive_n="$(bundle_build_number "$archive")"

  if [[ -n "$archive" && ( -z "$bundle_dir" || "$archive_n" -gt "$bundle_n" ) ]]; then
    if [[ -n "$bundle_dir" ]]; then
      info "Archive b${archive_n} is newer than folder b${bundle_n} — extracting…"
    fi
    bundle_dir="$(extract_bundle "$archive")"
    [[ "$MODE_UPDATE" -eq 1 ]] && cleanup_old_bundle_dirs "$archive_n"
    echo "$bundle_dir"
    return 0
  fi

  if [[ -n "$bundle_dir" ]]; then
    ok "Found folder: $(basename "$bundle_dir") (b${bundle_n})"
    echo "$bundle_dir"
    return 0
  fi

  if [[ -n "$archive" ]]; then
    bundle_dir="$(extract_bundle "$archive")"
    echo "$bundle_dir"
    return 0
  fi

  die "No llama bundle found in ${SCRIPT_DIR}.
Place one of the following in the same directory as this script:
  • llama-b9159/                    (extracted folder)
  • llama-b9159-bin-ubuntu-x64.tar.gz  (pre-built binary archive)"
}

# ── Stop running server ────────────────────────────────────────────────────────
stop_llama_server() {
  if ! pgrep -x llama-server >/dev/null 2>&1; then
    return 0
  fi
  info "Stopping running llama-server …"
  pkill -x llama-server 2>/dev/null || pkill -f llama-server 2>/dev/null || true
  sleep 2
  if pgrep -x llama-server >/dev/null 2>&1; then
    warn "Force stopping (kill -9) …"
    pkill -9 -x llama-server 2>/dev/null || true
    sleep 1
  fi
  if command -v ss >/dev/null 2>&1; then
    if ss -tlnp "sport = :${PORT}" 2>/dev/null | grep -q llama-server; then
      local pid
      pid="$(ss -tlnp "sport = :${PORT}" 2>/dev/null | grep -oP 'pid=\K[0-9]+' | head -1)"
      [[ -n "$pid" ]] && kill -9 "$pid" 2>/dev/null || true
    fi
  fi
  pgrep -x llama-server >/dev/null 2>&1 && warn "llama-server may still be running" || ok "llama-server stopped"
}

# ── Install from source (git + cmake) ──────────────────────────────────────────
build_from_source() {
  local gpu
  gpu="$(detect_gpu_backend)"

  command -v git >/dev/null 2>&1  || die "Missing 'git'."
  command -v cmake >/dev/null 2>&1 || die "Missing 'cmake'."

  LLAMA_CPP_DIR="$(mktemp -d /tmp/llama.cpp-build-XXXXXX)"
  BUILD_DIR="${LLAMA_CPP_DIR}/build"

  info "Cloning llama.cpp from GitHub …"
  git clone --depth=1 "https://github.com/${GITHUB_REPO}.git" "$LLAMA_CPP_DIR"

  info "Configuring CMake build (backend: ${gpu}) …"
  local cmake_opts=("-B" "$BUILD_DIR" "-DCMAKE_INSTALL_PREFIX=${INSTALL_PREFIX}")

  case "$gpu" in
    cuda)   cmake_opts+=("-DGGML_CUDA=ON") ;;
    rocm)   cmake_opts+=("-DGGML_HIPBLAS=ON") ;;
    vulkan) cmake_opts+=("-DGGML_VULKAN=ON") ;;
    cpu)    cmake_opts+=("-DGGML_BLAS=ON" "-DGGML_BLAS_VENDOR=OpenBLAS") ;;
  esac

  cmake "$LLAMA_CPP_DIR" "${cmake_opts[@]}"

  info "Building (using $(nproc) cores) …"
  cmake --build "$BUILD_DIR" -j"$(nproc)"

  info "Installing to ${INSTALL_PREFIX} …"
  cmake --install "$BUILD_DIR"

  [[ "$INSTALL_PREFIX" == "/usr/local" ]] && ldconfig 2>/dev/null || true

  rm -rf "$LLAMA_CPP_DIR"
  ok "Build and install complete"
}

# ── Install pre-built binaries ─────────────────────────────────────────────────
install_prebuilt_binaries() {
  local bundle="$1"

  info "Installing to ${LOCAL_BIN} and ${LOCAL_LIB} …"
  mkdir -p "$LOCAL_BIN" "$LOCAL_LIB" "$MODELS_DIR"

  if [[ "$MODE_UPDATE" -eq 1 ]]; then
    cleanup_old_install
  fi

  cp -f "${bundle}"/llama-* "$LOCAL_BIN/" 2>/dev/null || true
  [[ -f "${bundle}/rpc-server" ]] && cp -f "${bundle}/rpc-server" "$LOCAL_BIN/"
  cp -f "${bundle}"/*.so* "$LOCAL_LIB/" 2>/dev/null || true

  chmod +x "${LOCAL_BIN}"/llama-* 2>/dev/null || true

  if [[ "$INSTALL_PREFIX" == "/usr/local" ]]; then
    ldconfig 2>/dev/null || true
  fi

  ok "Copied binaries and libraries to ${INSTALL_PREFIX}"
}

cleanup_old_install() {
  local f base
  info "Removing old installation …"
  for f in "${LOCAL_BIN}"/llama-*; do
    [[ -e "$f" ]] || continue
    base="$(basename "$f")"
    [[ "$base" == "llama-server-start.sh" ]] && continue
    rm -f "$f"
  done
  rm -f "${LOCAL_BIN}"/rpc-server 2>/dev/null || true
  rm -f "${LOCAL_LIB}"/libllama*.so* "${LOCAL_LIB}"/libggml*.so* "${LOCAL_LIB}"/libmtmd*.so* 2>/dev/null || true
  ok "Old files removed"
}

# ── Shell configuration ────────────────────────────────────────────────────────
configure_shell() {
  local marker="# llama.cpp (install-llama.sh)"
  local rc_files rc updated=0

  rc_files=($(detect_shell_rc_files))

  for rc in "${rc_files[@]}"; do
    touch "$rc" 2>/dev/null || continue
    if grep -qF "$marker" "$rc" 2>/dev/null; then
      continue
    fi
    info "Adding settings to ${rc} …"
    cat >> "$rc" <<'EOF'

# llama.cpp (install-llama.sh)
export PATH="/usr/local/bin:$HOME/.local/bin:$PATH"
export LD_LIBRARY_PATH="/usr/local/lib:$HOME/.local/lib:$LD_LIBRARY_PATH"
EOF
    updated=1
    ok "Updated: ${rc}"
  done

  if [[ "$updated" -eq 0 ]]; then
    ok "Shell RC files are already configured"
  fi
}

# ── Verify ─────────────────────────────────────────────────────────────────────
verify_install() {
  info "Verifying llama-server …"
  set +o pipefail
  if "${LOCAL_BIN}/llama-server" --help 2>&1 | grep -qE 'help|usage|version'; then
    set -o pipefail
    ok "llama-server works"
  else
    set -o pipefail
    die "llama-server failed to start."
  fi
}

# ── Download model ──────────────────────────────────────────────────────────────
model_is_valid() {
  [[ -f "$MODEL_PATH" && ! -L "$MODEL_PATH" ]] && [[ "$(stat -c%s "$MODEL_PATH" 2>/dev/null || echo 0)" -gt 1000000000 ]]
}

download_model() {
  if model_is_valid; then
    ok "Model already exists: ${MODEL_PATH} ($(du -h "$MODEL_PATH" | cut -f1))"
    return 0
  fi

  if [[ -L "$MODEL_PATH" ]] || [[ ! -f "$MODEL_PATH" ]]; then
    rm -f "$MODEL_PATH"
  fi

  info "Downloading model: ${MODEL_REPO} / ${MODEL_FILE}"

  "$HF_CLI" download "$MODEL_REPO" "$MODEL_FILE" \
    --local-dir "$MODELS_DIR" \
    --local-dir-use-symlinks False

  if model_is_valid; then
    ok "Model downloaded: ${MODEL_PATH}"
  else
    die "Download failed — file missing or too small: ${MODEL_PATH}"
  fi
}

# ── LAN IP ──────────────────────────────────────────────────────────────────────
print_network_info() {
  local ip
  ip="$(ip route get 1 2>/dev/null | grep -oP 'src \K[0-9.]+' | head -1 || true)"
  [[ -z "$ip" ]] && ip="$(hostname -I 2>/dev/null | awk '{print $1}' || true)"
  echo ""
  ok "Server listening on all interfaces (local network)"
  echo -e "  ${GREEN}Local:${NC}   http://127.0.0.1:${PORT}/v1"
  if [[ -n "$ip" ]]; then
    echo -e "  ${GREEN}LAN:${NC}       http://${ip}:${PORT}/v1"
    echo -e "  ${GREEN}Health:${NC}    http://${ip}:${PORT}/health"
  fi
  echo ""
}

# ── systemd service ────────────────────────────────────────────────────────────
write_start_script() {
  load_config
  local script_path="${START_SCRIPT}"

  if [[ "$INSTALL_PREFIX" != "/usr/local" ]]; then
    script_path="${INSTALL_PREFIX}/bin/llama-server-start.sh"
  fi

  mkdir -p "$(dirname "$script_path")"
  cat > "$script_path" <<SCRIPT
#!/usr/bin/env bash
set -euo pipefail
CONFIG="${CONFIG_FILE}"
[[ -f "\$CONFIG" ]] && source "\$CONFIG"
export PATH="${LOCAL_BIN}:\${PATH}"
exec "${LOCAL_BIN}/llama-server" \\
  -m "\${MODEL_PATH}" \\
  -c "\${CONTEXT}" \\
  --port "\${PORT}" \\
  --host "\${HOST}"
SCRIPT
  chmod +x "$script_path"
  ok "Start script: ${script_path}"
  echo "$script_path"
}

install_systemd_service() {
  [[ -x "${LOCAL_BIN}/llama-server" ]] || die "Please install llama.cpp first (without --install-only)."
  model_is_valid || die "No valid model. Download one with: ./install-llama.sh --model qwen14"

  save_config
  local script_path
  script_path="$(write_start_script)"
  stop_llama_server

  mkdir -p "$LOG_DIR"

  cat > "$SYSTEMD_SERVICE_FILE" <<UNIT
[Unit]
Description=llama.cpp Server
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=$(whoami)
ExecStart=${script_path}
Restart=always
RestartSec=5
StandardOutput=append:${LOG_OUT}
StandardError=append:${LOG_ERR}
Environment=LD_LIBRARY_PATH=${LOCAL_LIB}

[Install]
WantedBy=multi-user.target
UNIT

  systemctl daemon-reload
  systemctl enable "${SYSTEMD_SERVICE_NAME}.service"
  systemctl restart "${SYSTEMD_SERVICE_NAME}.service"

  ok "systemd service installed and started"
  info "Status: systemctl status ${SYSTEMD_SERVICE_NAME}"
  info "Logs:   ${LOG_OUT}"
  info "Errors: ${LOG_ERR}"

  if systemctl is-active --quiet "${SYSTEMD_SERVICE_NAME}.service"; then
    ok "llama-server is running via systemd"
    print_network_info
  else
    warn "Service didn't start. Check: journalctl -u ${SYSTEMD_SERVICE_NAME} --no-pager -n 50"
  fi
}

uninstall_systemd_service() {
  if [[ -f "$SYSTEMD_SERVICE_FILE" ]]; then
    systemctl stop "${SYSTEMD_SERVICE_NAME}.service" 2>/dev/null || true
    systemctl disable "${SYSTEMD_SERVICE_NAME}.service" 2>/dev/null || true
    rm -f "$SYSTEMD_SERVICE_FILE"
    systemctl daemon-reload
    ok "systemd service removed"
  else
    info "systemd service is not installed"
  fi
}

# ── Status ──────────────────────────────────────────────────────────────────────
server_is_running() {
  pgrep -x llama-server >/dev/null 2>&1
}

service_is_active() {
  systemctl is-active --quiet "${SYSTEMD_SERVICE_NAME}.service" 2>/dev/null
}

service_is_enabled() {
  systemctl is-enabled --quiet "${SYSTEMD_SERVICE_NAME}.service" 2>/dev/null
}

show_status() {
  local ip ver model_status server_status svc_status
  load_config
  ip="$(ip route get 1 2>/dev/null | grep -oP 'src \K[0-9.]+' | head -1 || true)"
  [[ -z "$ip" ]] && ip="$(hostname -I 2>/dev/null | awk '{print $1}' || true)"

  echo ""
  echo -e "${BLUE}══════════════════════════════════════════════════════════${NC}"
  echo -e "${BLUE}  llama.cpp — Status (Linux)${NC}"
  echo -e "${BLUE}══════════════════════════════════════════════════════════${NC}"
  echo ""

  if [[ -x "${LOCAL_BIN}/llama-server" ]]; then
    ver="${LLAMA_VERSION:-}"
    if [[ -z "$ver" || "$ver" == "unknown" ]]; then
      ver="$(get_llama_version_string "${LOCAL_BIN}/llama-server")"
    fi
    echo -e "  ${GREEN}llama.cpp:${NC}  ${ver}"
    echo -e "  ${GREEN}Prefix:${NC}     ${INSTALL_PREFIX}"
  else
    echo -e "  ${RED}llama.cpp:${NC}  not installed"
  fi

  echo -e "  ${GREEN}GPU:${NC}        $(detect_gpu_backend | tr '[:lower:]' '[:upper:]')"
  echo -e "  ${GREEN}Arch:${NC}       $(get_system_arch)"
  echo -e "  ${GREEN}Model:${NC}      ${MODEL_LABEL:-—}"

  if model_is_valid; then
    model_status="$(du -h "$MODEL_PATH" 2>/dev/null | cut -f1) — OK"
    echo -e "  ${GREEN}File:${NC}       ${model_status}"
  else
    echo -e "  ${YELLOW}File:${NC}       missing or incomplete"
  fi

  if server_is_running; then
    server_status="${GREEN}running${NC} (PID $(pgrep -x llama-server | head -1))"
  else
    server_status="${YELLOW}stopped${NC}"
  fi
  echo -e "  ${GREEN}Server:${NC}     ${server_status}"

  echo -e "  ${GREEN}Port:${NC}       ${PORT}"
  echo -e "  ${GREEN}API:${NC}        http://127.0.0.1:${PORT}/v1"
  [[ -n "$ip" ]] && echo -e "  ${GREEN}LAN:${NC}        http://${ip}:${PORT}/v1"

  if command -v systemctl >/dev/null 2>&1 && [[ -f "$SYSTEMD_SERVICE_FILE" ]]; then
    if service_is_active; then
      svc_status="${GREEN}active${NC} (systemd)"
    elif service_is_enabled; then
      svc_status="${YELLOW}enabled, not running${NC}"
    else
      svc_status="${YELLOW}installed, not enabled${NC}"
    fi
    echo -e "  ${GREEN}systemd:${NC}    ${svc_status}"
  fi

  [[ -f "$CONFIG_FILE" ]] && echo -e "  ${GREEN}Config:${NC}     ${CONFIG_FILE}"

  if [[ "$SKIP_GITHUB_CHECK" -eq 0 ]]; then
    echo ""
    check_github_update || true
  fi
  echo ""
}

# ── Start the server ───────────────────────────────────────────────────────────
start_server() {
  if command -v ss >/dev/null 2>&1; then
    if ss -tlnp "sport = :${PORT}" 2>/dev/null | grep -q LISTEN; then
      warn "Port ${PORT} is already in use. Stopping old process …"
      pkill -f "llama-server.*--port ${PORT}" 2>/dev/null || true
      sleep 1
    fi
  fi

  info "Starting llama-server (Ctrl+C to stop) …"
  print_network_info

  exec "${LOCAL_BIN}/llama-server" \
    -m "$MODEL_PATH" \
    -c "$CONTEXT" \
    --port "$PORT" \
    --host "$HOST"
}

# ── MAIN ───────────────────────────────────────────────────────────────────────
main() {
  local bundle old_ver new_ver gpu

  echo ""
  echo -e "${BLUE}══════════════════════════════════════════════════════════${NC}"
  if [[ "$MODE_UPDATE" -eq 1 ]]; then
    echo -e "${BLUE}  llama.cpp — UPDATE (Linux)${NC}"
  else
    echo -e "${BLUE}  llama.cpp — Automated Installer (Linux)${NC}"
  fi
  echo -e "${BLUE}══════════════════════════════════════════════════════════${NC}"
  echo ""

  resolve_model_selection

  gpu="$(detect_gpu_backend)"
  info "Linux $(uname -r) | Arch: $(get_system_arch) | GPU: ${gpu}"
  info "Model: ${MODEL_LABEL} → ${MODEL_FILE}"
  info "Install prefix: ${INSTALL_PREFIX}"

  if [[ "$MODE_UPDATE" -eq 1 ]]; then
    old_ver="$(get_llama_version_string "${LOCAL_BIN}/llama-server")"
    info "Current version: ${old_ver}"
    stop_llama_server
  fi

  if [[ "$BUILD_FROM_SOURCE" -eq 1 ]]; then
    build_from_source
    new_ver="$(get_llama_version_string "${LOCAL_BIN}/llama-server")"
  else
    bundle="$(find_and_prepare_bundle)"
    bundle="${bundle//$'\n'/}"
    bundle="${bundle%%$'\r'*}"
    [[ -d "$bundle" && -x "${bundle}/llama-server" ]] \
      || die "Invalid bundle path: ${bundle}"
    new_ver="$(get_llama_version_string "${bundle}/llama-server")"
    info "Bundle: $(basename "$bundle") (${new_ver})"

    install_prebuilt_binaries "$bundle"
  fi

  configure_shell
  verify_install

  if [[ "$SKIP_DOWNLOAD" -eq 0 ]]; then
    download_model
  else
    if [[ "$MODE_UPDATE" -eq 1 ]]; then
      info "Update: model stays untouched (still in ${MODELS_DIR})"
    else
      info "Skipping model download (--skip-download)"
    fi
    model_is_valid || warn "Model missing: ${MODEL_PATH}"
  fi

  echo ""
  if [[ "$MODE_UPDATE" -eq 1 ]]; then
    ok "Update complete!"
    echo -e "  ${YELLOW}Before:${NC}  ${old_ver}"
    echo -e "  ${GREEN}Now:${NC}     ${new_ver}"
  else
    ok "Installation complete!"
    echo -e "  Version:   ${new_ver}"
  fi
  echo -e "  Prefix:    ${INSTALL_PREFIX}"
  echo -e "  Models:    ${MODELS_DIR}"
  echo ""

  save_config

  if [[ "$INSTALL_SERVICE" -eq 1 ]]; then
    install_systemd_service
    return 0
  fi

  if [[ "$SKIP_SERVER" -eq 0 ]]; then
    if model_is_valid; then
      start_server
    else
      die "No valid model. Run: ./install-llama.sh --model qwen14"
    fi
  else
    info "Start manually:"
    echo "  llama-server -m \"${MODEL_PATH}\" -c ${CONTEXT} --port ${PORT} --host ${HOST}"
    info "Or auto-start: sudo ./install-llama.sh --install-service"
  fi
}

# ── Entry point ────────────────────────────────────────────────────────────────
if [[ "$MODE_CHECK_UPDATE" -eq 1 ]]; then
  echo ""
  echo -e "${BLUE}  llama.cpp — update check (GitHub)${NC}"
  echo ""
  installed="$(get_installed_build_number)"
  [[ "$installed" != "0" ]] && echo -e "  Installed: b${installed}"
  check_github_update || true
  echo ""
  exit 0
fi

if [[ "$MODE_DOWNLOAD_UPDATE" -eq 1 ]]; then
  echo ""
  echo -e "${BLUE}  llama.cpp — downloading from GitHub${NC}"
  echo ""
  download_github_update
  exit 0
fi

if [[ "$MODE_UPGRADE" -eq 1 ]]; then
  echo ""
  echo -e "${BLUE}  llama.cpp — full upgrade${NC}"
  echo ""
  download_github_update
  MODE_UPDATE=1
  SKIP_DOWNLOAD=1
  SKIP_SERVER=1
  [[ -f "$SYSTEMD_SERVICE_FILE" ]] && INSTALL_SERVICE=1
  RUN_MAIN=1
  main "$@"
  exit 0
fi

if [[ "$MODE_STATUS" -eq 1 ]]; then
  show_status
  exit 0
fi

if [[ "$UNINSTALL_SERVICE" -eq 1 ]]; then
  uninstall_systemd_service
  exit 0
fi

if [[ "$INSTALL_SERVICE" -eq 1 && "$RUN_MAIN" -eq 0 ]]; then
  load_config
  resolve_model_selection
  install_systemd_service
  exit 0
fi

if [[ "$RUN_MAIN" -eq 1 ]]; then
  main "$@"
fi
