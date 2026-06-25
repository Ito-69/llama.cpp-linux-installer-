# llama.cpp Linux Installer

A fully automated installer, updater, and manager for [llama.cpp](https://github.com/ggml-org/llama.cpp) on Linux (x86_64 & aarch64).

### Why this exists

llama.cpp releases ship as bare tarballs — no installer, no PATH setup, no auto-start, no easy update path. This script wraps the entire process into a single command: download pre-built binaries (or build from source), install them, pull a GGUF model from Hugging Face, set up a systemd service, and start the server.

## Features

- **One-command setup** — download or place an archive alongside the script, run it
- **Pre-built binary install** — downloads the latest release from GitHub directly
- **Source build** — `--build-from-source` for custom CMake flags (CUDA, ROCm, Vulkan)
- **Automatic architecture detection** — picks the right binaries (x86_64 / aarch64)
- **GPU detection** — auto-detects CUDA / ROCm / Vulkan / CPU
- **Model downloads** — built-in presets (Qwen2.5 14B, 7B, Llama 3.1 8B, Qwen2.5 32B) via Hugging Face
- **Auto-start at boot** — optional systemd service for background server operation
- **Effortless updates** — `--check-update`, `--download-update`, `--upgrade` from GitHub releases
- **Shell configuration** — automatically sets up `PATH` in your shell RC file
- **LAN access** — prints local network URL for accessing the API from other devices

## Quick Start

### Prerequisites

- Linux (x86_64 with AVX2, or aarch64)
- `curl`, `tar`, `gzip`
- `huggingface-cli` for model downloads: `pip install huggingface_hub`
- `git`, `cmake`, `make`, `g++` (only for `--build-from-source`)

### 1. Download (or build)

```bash
# Option A: Download the latest pre-built binaries automatically
sudo ./install-llama.sh --download-update
sudo ./install-llama.sh --update --skip-server

# Option B: Manually grab a build from GitHub releases
# https://github.com/ggml-org/llama.cpp/releases
# Place the archive in the same directory:
#   llama-bXXXX-bin-ubuntu-x64.tar.gz  (x86_64)
#   llama-bXXXX-bin-ubuntu-aarch64.tar.gz  (ARM)
sudo ./install-llama.sh
```

### 2. Run the installer

```bash
chmod +x install-llama.sh
sudo ./install-llama.sh
```

The script will:
1. Find and extract the llama bundle
2. Copy binaries to `/usr/local/bin/` and libraries to `/usr/local/lib/`
3. Configure your shell RC file
4. Download the default model (Qwen2.5 14B Q4_K_M, ~8.4 GB)
5. Start `llama-server` with an OpenAI-compatible API on port 8080

### User-local install (no sudo)

```bash
./install-llama.sh --prefix ~/.local
```

## Usage Reference

### Installation

| Command | Description |
|---------|-------------|
| `sudo ./install-llama.sh` | Full install: llama.cpp + model + start server |
| `./install-llama.sh --prefix ~/.local` | User-local install (no sudo) |
| `./install-llama.sh --model qwen7` | Install with a smaller/faster model |
| `./install-llama.sh --choose-model` | Interactive model menu |
| `./install-llama.sh --install-only` | llama.cpp only (no model, no server) |
| `./install-llama.sh --build-from-source` | Build from source (needs cmake, git, etc.) |
| `./install-llama.sh --model qwen14 --install-service --skip-server` | Install + systemd (headless server) |

### Status & Info

| Command | Description |
|---------|-------------|
| `./install-llama.sh --status` | Version, model, GPU, port, LAN URL, service status, GitHub check |
| `./install-llama.sh --status --no-github-check` | Status without internet request |
| `./install-llama.sh --check-update` | Check for newer build on GitHub |
| `./install-llama.sh --list-models` | List available model presets |
| `./install-llama.sh --help` | Short help text |

### Models

| Command | Description |
|---------|-------------|
| `--model qwen14` | Qwen2.5 14B Q4_K_M (~8.4 GB) — balanced (default) |
| `--model qwen7` | Qwen2.5 7B Q4_K_M (~4.7 GB) — faster |
| `--model llama8` | Llama 3.1 8B Q4_K_M (~5 GB) |
| `--model qwen32` | Qwen2.5 32B Q4_K_M (~19 GB) — best quality (24 GB+ RAM) |
| `--model-repo REPO --model-file FILE` | Custom Hugging Face repo and GGUF file |

Configuration is saved to `~/.config/llama/server.conf`.

### Updates

| Command | Description |
|---------|-------------|
| `./install-llama.sh --check-update` | Check for a newer build |
| `./install-llama.sh --download-update` | Download latest Linux build to current directory |
| `./install-llama.sh --update` | Install the newest local bundle (keeps model untouched) |
| `./install-llama.sh --upgrade` | **All-in-one:** download + update + restore systemd service |

**Recommended update workflow (with systemd):**

```bash
./install-llama.sh --check-update
sudo ./install-llama.sh --download-update
sudo ./install-llama.sh --update --skip-server --install-service
```

**Or a single command:**

```bash
sudo ./install-llama.sh --upgrade
```

### Systemd Service (auto-start at boot)

| Command | Description |
|---------|-------------|
| `sudo ./install-llama.sh --install-service` | Install/reload systemd service; server runs in background |
| `sudo ./install-llama.sh --uninstall-service` | Stop and remove systemd service |

**Service files:**

| File | Description |
|------|-------------|
| `/etc/systemd/system/llama-server.service` | systemd unit config |
| `/usr/local/bin/llama-server-start.sh` | Start script (do not delete manually) |
| `/var/log/llama/llama-server.log` | Standard output |
| `/var/log/llama/llama-server.err.log` | Error log |

### Server Options

| Option | Default | Description |
|--------|---------|-------------|
| `--port 8080` | `8080` | HTTP port |
| `--context 8192` | `8192` | Context size (tokens) |
| `--host` | `0.0.0.0` | `0.0.0.0` = local network; `127.0.0.1` = this machine only |
| `--prefix /usr/local` | `/usr/local` | Install prefix |
| `--models-dir ~/models` | `~/models` | Model storage directory |

Saved to `~/.config/llama/server.conf`.

### Common Scenarios

```bash
# Daily check
./install-llama.sh --status

# First-time headless server setup
sudo ./install-llama.sh --model qwen14 --install-service --skip-server

# Update llama.cpp to the latest build
sudo ./install-llama.sh --upgrade

# Reinstall current build (archive already in directory)
sudo ./install-llama.sh --update --skip-server --install-service

# Switch to a different model
./install-llama.sh --model qwen7

# Stop and remove systemd service
sudo ./install-llama.sh --uninstall-service
pkill -9 llama-server
```

### Build from source

```bash
# Build with CUDA support
sudo ./install-llama.sh --build-from-source --skip-download --skip-server --install-service

# Build for CPU only
sudo ./install-llama.sh --build-from-source
```

## Manual Commands

```bash
source ~/.bashrc

# Check server health
curl http://127.0.0.1:8080/health

# Who's using port 8080
ss -tlnp | grep 8080

# Kill all llama-server processes
pkill -9 llama-server

# Start server manually in terminal
llama-server -m ~/models/Qwen2.5-14B-Instruct-Q4_K_M.gguf \
  -c 8192 --port 8080 --host 0.0.0.0

# Follow systemd logs
journalctl -u llama-server --no-pager -n 50 -f
tail -f /var/log/llama/llama-server.log
```

## Files & Directories

| Path | Purpose |
|------|---------|
| `/usr/local/bin/` | llama.cpp binaries (`llama-server`, `llama-cli`, …) |
| `/usr/local/lib/` | Shared libraries (`libllama*.so`, `libggml*.so`) |
| `~/models/` | GGUF model files |
| `~/.config/llama/server.conf` | Server configuration |
| `/etc/systemd/system/llama-server.service` | systemd unit (if installed) |
| `/var/log/llama/llama-server.log` | Server stdout |
| `/var/log/llama/llama-server.err.log` | Server stderr |

## Uninstallation

```bash
# Stop and remove systemd service
sudo ./install-llama.sh --uninstall-service

# Remove binaries and libraries
sudo rm -rf /usr/local/bin/llama-* /usr/local/bin/rpc-server
sudo rm -f /usr/local/bin/llama-server-start.sh
sudo rm -f /usr/local/lib/libllama*.so /usr/local/lib/libggml*.so /usr/local/lib/libmtmd*.so

# Remove configuration
rm -rf ~/.config/llama

# Remove models (optional)
rm -rf ~/models/*.gguf

# Remove shell RC additions
# Edit ~/.bashrc (~/.zshrc) and remove the llama.cpp sections
```

## Requirements

- Linux (x86_64 with AVX2, or aarch64)
- Bash 4+
- `curl`, `tar`, `gzip`
- `git`, `cmake`, `make`, `g++` (only for `--build-from-source`)
- `huggingface-cli` for model downloads (`pip install huggingface_hub`)
- `systemd` (for `--install-service`, requires root)

## License

MIT — feel free to use, modify, and share.

---

*Inspired by the [llama.cpp](https://github.com/ggml-org/llama.cpp) project by ggerganov.*
