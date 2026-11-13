#!/usr/bin/env python3
"""本机 OpenAI-compatible ASR mock 服务，用于 Voxi 端点联调（Phase 2.3）。

用法:
    python3 scripts/dev/mock_asr_server.py [--port 8765] [--status 200] [--seconds 0]

行为:
    POST 任意路径 -> 返回 {"text": "..."}，并把收到的 multipart 字段名/大小写入日志。
    --status 可模拟 401/429/500 等错误；--seconds 可模拟慢响应。
"""
import argparse
import json
import re
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

LOG_PATH = "/tmp/voxi-mock-asr.log"


def parse_multipart(body: bytes, boundary: bytes):
    parts = []
    delimiter = b"--" + boundary
    for segment in body.split(delimiter):
        segment = segment.strip(b"\r\n")
        if not segment or segment == b"--":
            continue
        if b"\r\n\r\n" not in segment:
            continue
        raw_headers, content = segment.split(b"\r\n\r\n", 1)
        content = content[:-2] if content.endswith(b"\r\n") else content
        headers = {}
        for line in raw_headers.split(b"\r\n"):
            if b":" in line:
                key, value = line.split(b":", 1)
                headers[key.decode().strip().lower()] = value.decode().strip()
        disposition = headers.get("content-disposition", "")
        name_match = re.search(r'name="([^"]*)"', disposition)
        file_match = re.search(r'filename="([^"]*)"', disposition)
        parts.append(
            {
                "name": name_match.group(1) if name_match else None,
                "filename": file_match.group(1) if file_match else None,
                "content_type": headers.get("content-type"),
                "bytes": len(content),
                "preview": content[:64].decode("utf-8", "replace") if not file_match else "<binary>",
            }
        )
    return parts


class Handler(BaseHTTPRequestHandler):
    status = 200
    delay = 0.0
    text = "这是来自本机 mock 服务的识别结果。"

    def do_POST(self):  # noqa: N802
        length = int(self.headers.get("Content-Length", "0"))
        body = self.rfile.read(length)
        content_type = self.headers.get("Content-Type", "")
        boundary = b""
        if "boundary=" in content_type:
            boundary = content_type.split("boundary=", 1)[1].strip('"').encode()
        parts = parse_multipart(body, boundary) if boundary else []

        entry = {
            "time": time.strftime("%H:%M:%S"),
            "path": self.path,
            "method": "POST",
            "authorization_present": bool(self.headers.get("Authorization")),
            "content_type": content_type,
            "content_length": length,
            "parts": parts,
        }
        with open(LOG_PATH, "a", encoding="utf-8") as handle:
            handle.write(json.dumps(entry, ensure_ascii=False) + "\n")

        if self.delay:
            time.sleep(self.delay)

        if self.status >= 400:
            payload = json.dumps({"error": {"message": f"mock error {self.status}"}}).encode()
            self.send_response(self.status)
            self.send_header("Content-Type", "application/json")
            if self.status == 429:
                self.send_header("Retry-After", "5")
            self.send_header("Content-Length", str(len(payload)))
            self.end_headers()
            self.wfile.write(payload)
            return

        payload = json.dumps({"text": self.text}, ensure_ascii=False).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("x-request-id", "mock-request-id-123")
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)

    def log_message(self, fmt, *args):  # silence default stderr logging
        pass


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--port", type=int, default=8765)
    parser.add_argument("--status", type=int, default=200)
    parser.add_argument("--seconds", type=float, default=0.0)
    parser.add_argument("--text", default="这是来自本机 mock 服务的识别结果。")
    args = parser.parse_args()

    Handler.status = args.status
    Handler.delay = args.seconds
    Handler.text = args.text
    server = ThreadingHTTPServer(("127.0.0.1", args.port), Handler)
    print(f"mock ASR listening on http://127.0.0.1:{args.port} (log: {LOG_PATH})")
    server.serve_forever()


if __name__ == "__main__":
    main()
