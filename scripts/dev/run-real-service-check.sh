#!/usr/bin/env bash
# 真实 ASR 服务连通性检查（开发工具）。
#
# 需要环境变量：
#   VOLC_API_KEY            火山引擎 API Key（新版控制台）
#   VOLC_RESOURCE_ID        可选，默认 volc.seedasr.sauc.duration
#   OPENAI_API_KEY          OpenAI-compatible 端点 Key
#   OPENAI_ENDPOINT         完整 URL，例如 https://host/v1/audio/transcriptions
#   OPENAI_MODEL            可选，默认 sensevoice
#   AUDIO                   可选，16 kHz mono PCM16 WAV；缺省用 say + afconvert 生成
#
# 用法：
#   VOLC_API_KEY=... OPENAI_API_KEY=... OPENAI_ENDPOINT=... \
#     scripts/dev/run-real-service-check.sh
#
# 凭据只存在于进程环境变量中，脚本不会把它们写入文件。
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"

: "${VOLC_API_KEY:?请设置 VOLC_API_KEY}"
: "${OPENAI_API_KEY:?请设置 OPENAI_API_KEY}"
: "${OPENAI_ENDPOINT:?请设置 OPENAI_ENDPOINT}"
OPENAI_MODEL="${OPENAI_MODEL:-sensevoice}"
VOLC_RESOURCE_ID="${VOLC_RESOURCE_ID:-volc.seedasr.sauc.duration}"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

ARCH="$(uname -m)"
TARGET="arm64-apple-macosx13.0"
if [ "$ARCH" = "x86_64" ]; then
  TARGET="x86_64-apple-macosx13.0"
fi

echo "==> 编译检查程序（${ARCH}）"
clang -c -O2 Voxi/Support/GzipShim.m -I Voxi/Support -o "$WORK/gzip.o"
DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}" \
swiftc -O -target "$TARGET" \
  -import-objc-header Voxi/Support/Voxi-Bridging-Header.h \
  Voxi/Support/Gzip.swift \
  Voxi/Support/Logger.swift \
  Voxi/Support/MultipartFormData.swift \
  Voxi/Models/EndpointProfile.swift \
  Voxi/Models/TextMode.swift \
  Voxi/Models/TranscriptionResult.swift \
  Voxi/Services/TranscriptionProvider.swift \
  Voxi/Services/KeychainService.swift \
  Voxi/Services/OpenAICompatibleProvider.swift \
  Voxi/Services/VolcengineWebSocketCodec.swift \
  Voxi/Services/VolcengineWebSocketTransport.swift \
  Voxi/Services/VolcengineStreamingProvider.swift \
  scripts/dev/RealServiceCheck.swift \
  "$WORK/gzip.o" \
  -framework AVFoundation -framework Security -lz \
  -o "$WORK/RealServiceCheck"

AUDIO="${AUDIO:-}"
if [ -z "$AUDIO" ]; then
  echo "==> 生成测试语音（say + afconvert）"
  say -v Tingting -r 170 -o "$WORK/speech.aiff" "你好，这是一次真实的语音输入测试。"
  afconvert -f WAVE -d LEI16@16000 -c 1 "$WORK/speech.aiff" "$WORK/speech.wav"
  AUDIO="$WORK/speech.wav"
fi

export AUDIO VOLC_RESOURCE_ID OPENAI_MODEL

echo "==> 火山引擎双向流式"
"$WORK/RealServiceCheck" volcengine

echo "==> OpenAI-compatible 端点"
"$WORK/RealServiceCheck" openai

echo "==> 全部通过"
