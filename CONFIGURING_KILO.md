# Configuring Kilo with Local llama.cpp

This guide explains how to configure [Kilo](https://kilo.ai) (and other OpenAI-compatible coding assistants) to work with a local `llama-server` instance, including multi-model router mode and vision support.

## Prerequisites

- `llama-server` installed and running (see [`install-llama.sh`](./install-llama.sh))
- A GGUF model downloaded (or use `--install-service` to keep it running in the background)
- Kilo installed with a config file (`~/.config/kilo/kilo.jsonc` or project-local `kilo.jsonc`)
- `ffmpeg` — required by `llama-server` for image processing in vision models (`sudo apt install ffmpeg`)

## Basic Setup

### 1. Start llama-server

```bash
# If installed as a systemd service:
sudo systemctl status llama-server

# Or manually:
llama-server -m ~/models/Qwen2.5-14B-Instruct-Q4_K_M.gguf \
  -c 8192 --port 8080 --host 0.0.0.0
```

Verify it works:

```bash
curl http://127.0.0.1:8080/v1/models
curl http://127.0.0.1:8080/health
```

### 2. Configure Kilo

Add an OpenAI-compatible provider in `kilo.jsonc` using the `@ai-sdk/openai-compatible` adapter:

```jsonc
{
  "provider": {
    "llama_local": {
      "name": "Local llama.cpp",
      "npm": "@ai-sdk/openai-compatible",
      "options": {
        "baseURL": "http://localhost:8080/v1"
      },
      "models": {
        "qwen2.5-14b": {
          "name": "Qwen2.5 14B"
        }
      }
    }
  }
}
```

Each entry under `models` is a key-value pair where the key is the model ID that `llama-server` reports (from `GET /v1/models`) and the value contains the display name. For text-only models, no additional fields are needed — a plain `name` is sufficient.

An example config with all common models is available at [`kilo.jsonc.example`](./kilo.jsonc.example).

## Router Mode (Multiple Models)

`llama-server` can serve multiple models and switch between them on demand using **router mode**. This lets you use different models for different tasks — for example, a fast 8B model for quick edits and a 32B model for complex reasoning, plus a vision model for image tasks.

### 1. Create a model preset file

`/home/ito/models/models.ini`:

```ini
[llama3.1-8b]
model = /home/ito/models/Meta-Llama-3.1-8B-Instruct.gguf

[qwen2.5-14b]
model = /home/ito/models/Qwen2.5-14B-Instruct-Q4_K_M.gguf

[gemma4-vision]
model = /home/ito/models/gemma-4-31B-it-abliterated.Q5_K_M.gguf
mmproj = /home/ito/models/gemma-4-31b-vision/ggml-model-mmproj-q4_0.gguf
```

### 2. Start server in router mode

```bash
llama-server \
  --host 0.0.0.0 --port 8080 \
  --models-dir /home/ito/models \
  --models-preset /home/ito/models/models.ini \
  --models-max 1
```

**Flags explained:**

| Flag | Purpose |
|------|---------|
| `--models-dir` | Directory containing model files |
| `--models-preset` | Path to the `.ini` preset file |
| `--models-max 1` | Load at most 1 model at a time (frees VRAM when switching) |

### 3. Configure Kilo with multiple models

```jsonc
{
  "provider": {
    "llama_local": {
      "name": "Local llama.cpp",
      "npm": "@ai-sdk/openai-compatible",
      "options": {
        "baseURL": "http://localhost:8080/v1"
      },
      "models": {
        "llama3.1-8b": {
          "name": "Llama 3.1 8B"
        },
        "qwen2.5-14b": {
          "name": "Qwen2.5 14B"
        }
      }
    }
  }
}
```

The model key (e.g. `llama3.1-8b`) must match the section name in `models.ini`. When Kilo sends a request with `model: "llama3.1-8b"`, the router loads and serves that model.

### Systemd service with router mode

```ini
# /etc/systemd/system/llama-server.service
[Unit]
Description=llama.cpp Unified Server (Router Mode)
After=network-online.target

[Service]
Type=simple
User=ito
Environment="CUDA_VISIBLE_DEVICES=0,1"
ExecStart=/usr/local/bin/llama-server \
  --host 0.0.0.0 --port 8080 \
  --models-dir /home/ito/models \
  --models-preset /home/ito/models/models.ini \
  --models-max 1
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
```

## Vision Models

Vision models (multimodal) require an additional `mmproj` file — a projection matrix that maps image embeddings into the text model's token space.

### Supported vision models

| Model | mmproj | VRAM |
|-------|--------|------|
| Qwen2.5-VL-7B / 72B | Included in Hugging Face repo | ~5 GB / ~45 GB |
| Gemma 4 31B Vision | Separate `.gguf` file | ~25 GB |
| LLaVA-based models | `mmproj-model-q4_0.gguf` | varies |

### Configuration

In the router preset, add `mmproj` to the model section:

```ini
[gemma4-vision]
model = /home/ito/models/gemma-4-31B-it-abliterated.Q5_K_M.gguf
mmproj = /home/ito/models/gemma-4-31b-vision/ggml-model-mmproj-q4_0.gguf
```

### Kilo provider for vision

Vision models in Kilo require **two** extra fields: `"attachment": true` and a `modalities` block. Without `modalities`, Kilo's client-side check (`capabilities.input.image`) stays `false` and blocks image attachments — this is a known issue (Kilo Code issue [#10102](https://github.com/nicepkg/kilo-code/issues/10102)).

```jsonc
{
  "provider": {
    "llama_local": {
      "name": "Local llama.cpp",
      "npm": "@ai-sdk/openai-compatible",
      "options": {
        "baseURL": "http://localhost:8080/v1"
      },
      "models": {
        "gemma4-vision": {
          "name": "Gemma 4 Vision",
          "attachment": true,
          "modalities": {
            "input": ["text", "image"],
            "output": ["text"]
          }
        }
      }
    }
  }
}
```

> **Note:** `"attachment": true` alone is NOT sufficient — the `modalities` block is mandatory. Both must be present for vision to work.

### Testing vision

```bash
# Encode an image to base64
IMG_BASE64=$(base64 -w0 /path/to/image.png)

# Send a vision request
curl http://127.0.0.1:8080/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{
    "model": "gemma4-vision",
    "messages": [
      {
        "role": "user",
        "content": [
          {"type": "image_url", "image_url": {"url": "data:image/png;base64,'"$IMG_BASE64"'"}},
          {"type": "text", "text": "Describe this image in detail."}
        ]
      }
    ]
  }'
```

## Using the Ollama Bridge

Some coding tools speak only the Ollama protocol. The [`llama-ollama-bridge.py`](./llama-ollama-bridge.py) in this repo translates between Ollama and llama.cpp formats.

### 1. Start the bridge

```bash
python3 llama-ollama-bridge.py
```

By default it listens on port **11434** and forwards to `llama-server` on port **8080`.

### 2. Configure Kilo (Ollama provider)

```jsonc
{
  "providers": [
    {
      "name": "llama-via-ollama",
      "model": "qwen2.5-14b:latest",
      "baseUrl": "http://127.0.0.1:11434/v1",
      "apiKey": "noop",
      "provider": "ollama"
    }
  ]
}
```

With the bridge, the model name can be either:
- A **mapped name** (if you have `~/.config/llama-ollama-bridge/models.json` configured)
- The **raw llama.cpp model ID** (passed through lowercased)

### 3. Bridge + router mode

The bridge works transparently with router mode. When the router receives a model name matching a preset section, it loads that model on demand.

```jsonc
// Example model mapping for the bridge
{
  "llama3.1:8b":      "Meta-Llama-3.1-8B-Instruct",
  "qwen2.5:14b":      "Qwen2.5-14B-Instruct-Q4_K_M",
  "gemma4-vision:31b": "gemma-4-31B-it-abliterated.Q5_K_M"
}
```

## GPU Configuration

### Single GPU (CUDA_VISIBLE_DEVICES)

By default `llama-server` uses all visible GPUs. To pin a model to a specific GPU:

```bash
CUDA_VISIBLE_DEVICES=0 llama-server -m model.gguf --port 8080
CUDA_VISIBLE_DEVICES=1 llama-server -m vision-model.gguf --port 8081
```

### Split a model across multiple GPUs

```bash
llama-server -m ~/models/Qwen2.5-32B-Instruct-Q4_K_M.gguf \
  --n-gpu-layers 99 \
  --port 8080 \
  --host 0.0.0.0
```

The model is automatically split across all visible GPUs. Use `CUDA_VISIBLE_DEVICES` to restrict which GPUs are used.

## Performance Tips

| Setting | Recommendation | Why |
|---------|---------------|-----|
| Context size | `--context 8192` | Good balance for code; increase to 16384 for large repo analysis |
| Batch size | `--ubatch-size 512` | Higher throughput on modern GPUs |
| GPU layers | `--n-gpu-layers 99` | Offload all layers to GPU (set lower if VRAM is limited) |
| Flash attention | `--flash-attn` | Reduces VRAM usage for long contexts |
| Parallel requests | `--parallel 4` | Allow 4 concurrent requests from Kilo |

## Troubleshooting

### "Model not found" in Kilo

- Check that the model name in `kilo.jsonc` matches the preset section name in `models.ini`
- Verify the model file exists at the path specified in `models.ini`
- If using router mode, check that `--models-preset` points to the correct file

### Vision requests fail

- Ensure `mmproj` is set correctly in `models.ini`
- The vision model must support the OpenAI vision format (`content` as an array with `type: "image_url"`)
- Check that `mmproj` files are downloaded (they are separate from the main GGUF)
- **In Kilo Code:** verify the model entry in `kilo.jsonc` has **both** `"attachment": true` and the full `modalities` block. Without `modalities`, `capabilities.input.image` stays `false` and Kilo blocks images at the client level (see issue [#10102](https://github.com/nicepkg/kilo-code/issues/10102)). See [`kilo.jsonc.example`](./kilo.jsonc.example) for the correct format.

### Port already in use

```bash
ss -tlnp | grep 8080
# Or
lsof -i :8080
```

### Kilo shows "connection refused"

- Make sure `llama-server` is running: `systemctl status llama-server`
- Check the host: use `--host 0.0.0.0` for LAN access, `127.0.0.1` for local-only
- Firewall: `sudo ufw status` (allow port 8080 if needed)

### Out of memory (VRAM)

- Use a smaller model (e.g., 7B instead of 32B)
- Reduce context size: `--context 4096`
- Reduce GPU layers: `--n-gpu-layers 20`
- Set `--models-max 1` in router mode to unload models when not in use
