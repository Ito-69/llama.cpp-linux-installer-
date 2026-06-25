#!/usr/bin/env python3
"""
llama-ollama-bridge.py — Lightweight Ollama-compatible API proxy for llama.cpp.

Listens on port 11434 (default Ollama port) and translates Ollama API calls
to llama.cpp's OpenAI-compatible API. Enables IDE extensions (Cursor, Copilot,
Continue, etc.) to use llama.cpp as if it were a local Ollama server.

Routes:
  GET  /api/tags      → llama.cpp /v1/models
  GET  /api/version   → returns fake version
  POST /api/chat      → llama.cpp /v1/chat/completions
  POST /api/generate  → llama.cpp /v1/chat/completions
  POST /api/show      → returns model details

Model name mapping:
  By default, the bridge passes model IDs through as-is.
  To map complex llama.cpp model filenames to clean Ollama-style names,
  create ~/.config/llama-ollama-bridge/models.json with a flat dict:

    {"llama3.1:8b": "Meta-Llama-3.1-8B-Instruct", "qwen3.6:35b": "Qwen3.6-35B-A3B-UD-Q5_K_M"}

Usage:
  python3 llama-ollama-bridge.py [port]
"""

import json
import os
import sys
from http.server import HTTPServer, BaseHTTPRequestHandler
from urllib.request import Request, urlopen
from urllib.error import URLError

LLAMA_URL = os.environ.get("LLAMA_URL", "http://127.0.0.1:8080")
CONFIG_DIR = os.path.expanduser("~/.config/llama-ollama-bridge")
MODEL_MAP_PATH = os.path.join(CONFIG_DIR, "models.json")

def load_model_map():
    if os.path.isfile(MODEL_MAP_PATH):
        try:
            with open(MODEL_MAP_PATH) as f:
                return json.load(f)
        except (json.JSONDecodeError, OSError):
            print(f"Warning: failed to parse {MODEL_MAP_PATH}", file=sys.stderr)
    return {}

MODEL_MAP = load_model_map()
REVERSE_MAP = {v: k for k, v in MODEL_MAP.items()}

def resolve_model_id(name):
    if name in REVERSE_MAP:
        return REVERSE_MAP[name]
    return name.split(":")[0] if ":" in name else name

def convert_images_to_openai(messages):
    converted = []
    for msg in messages:
        role = msg.get("role", "user")
        images = msg.pop("images", None)
        if images:
            parts = [{"type": "text", "text": msg.get("content", "")}]
            for img_data in images:
                parts.append({"type": "image_url", "image_url": {"url": f"data:image/png;base64,{img_data}"}})
            converted.append({"role": role, "content": parts})
        else:
            converted.append(msg)
    return converted

def proxy_request(path, payload):
    data = json.dumps(payload).encode() if payload else None
    req = Request(f"{LLAMA_URL}{path}", data=data, headers={"Content-Type": "application/json"})
    with urlopen(req) as res:
        return json.loads(res.read().decode())

def proxy_stream(path, payload, handler):
    data = json.dumps(payload).encode()
    req = Request(f"{LLAMA_URL}{path}", data=data, headers={"Content-Type": "application/json"})
    with urlopen(req) as res:
        while True:
            line = res.readline()
            if not line:
                break
            raw = line.decode().strip()
            if not raw.startswith("data:"):
                continue
            content = raw[5:].strip()
            if content == "[DONE]":
                break
            yield content

class BridgeHandler(BaseHTTPRequestHandler):

    def do_GET(self):
        if self.path == "/api/tags":
            try:
                llama_data = proxy_request("/v1/models", None)
                models = []
                for m in llama_data.get("data", []):
                    mid = m.get("id", "")
                    mapped = MODEL_MAP.get(mid, mid.lower().replace(".", "-"))
                    if ":" not in mapped:
                        mapped = f"{mapped}:latest"
                    models.append({
                        "name": mapped, "model": mapped,
                        "modified_at": "2026-06-25T00:00:00Z",
                        "size": m.get("meta", {}).get("size", 8589934592),
                        "digest": f"sha256:{mid.replace('.', '').replace('-', '')[:64].ljust(64, '0')}",
                        "details": {"format": "gguf", "family": "llama", "families": ["llama"]}
                    })
                self._json(200, {"models": models})
            except Exception as e:
                self._json(500, {"error": str(e)})
        elif self.path == "/api/version":
            self._json(200, {"version": "0.6.5"})
        else:
            self._json(404, {"error": "not found"})

    def do_POST(self):
        body = self.rfile.read(int(self.headers.get("Content-Length", 0)))
        req = json.loads(body.decode())
        path = self.path
        stream = req.get("stream", False)

        if path == "/api/chat":
            messages = convert_images_to_openai(req.get("messages", []))
            payload = {
                "model": resolve_model_id(req.get("model", "")),
                "messages": messages,
                "stream": stream
            }
            if stream:
                self._stream("/v1/chat/completions", payload, lambda c: {
                    "model": req["model"], "message": {"role": "assistant", "content": c},
                    "done": False
                }, {"model": req["model"], "done": True})
            else:
                try:
                    res = proxy_request("/v1/chat/completions", payload)
                    msg = res.get("choices", [{}])[0].get("message", {"role": "assistant", "content": ""})
                    self._json(200, {"model": req["model"], "message": msg, "done": True})
                except Exception as e:
                    self._json(500, {"error": str(e)})

        elif path == "/api/generate":
            payload = {
                "model": resolve_model_id(req.get("model", "")),
                "messages": [{"role": "user", "content": req.get("prompt", "")}],
                "stream": stream
            }
            if stream:
                self._stream("/v1/chat/completions", payload, lambda c: {
                    "model": req["model"], "response": c, "done": False
                }, {"model": req["model"], "done": True})
            else:
                try:
                    res = proxy_request("/v1/chat/completions", payload)
                    text = res.get("choices", [{}])[0].get("message", {}).get("content", "")
                    self._json(200, {"model": req["model"], "response": text, "done": True})
                except Exception as e:
                    self._json(500, {"error": str(e)})

        elif path == "/api/show":
            clean = resolve_model_id(req.get("name", "") or req.get("model", ""))
            self._json(200, {
                "modelfile": f"# {clean}", "parameters": "", "template": "",
                "details": {"format": "gguf", "family": "llama", "families": ["llama"]}
            })
        else:
            self._json(404, {"error": "not found"})

    def _json(self, code, data):
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.end_headers()
        self.wfile.write(json.dumps(data).encode())

    def _stream(self, path, payload, map_chunk, final_chunk):
        self.send_response(200)
        self.send_header("Content-Type", "application/x-ndjson")
        self.end_headers()
        for s in proxy_stream(path, payload, self):
            try:
                choice = json.loads(s).get("choices", [{}])[0]
                content = choice.get("delta", {}).get("content", "")
                if content:
                    self.wfile.write((json.dumps(map_chunk(content)) + "\n").encode())
                    self.wfile.flush()
            except json.JSONDecodeError:
                pass
        self.wfile.write((json.dumps(final_chunk) + "\n").encode())
        self.wfile.flush()

def run(port=11434):
    server = HTTPServer(("0.0.0.0", port), BridgeHandler)
    print(f"llama-ollama-bridge listening on port {port} → {LLAMA_URL}")
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    print("Bridge stopped.")

if __name__ == "__main__":
    port = int(sys.argv[1]) if len(sys.argv) > 1 else 11434
    run(port)
