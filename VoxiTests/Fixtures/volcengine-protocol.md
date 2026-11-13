# 火山引擎流式语音识别协议记录（v3 sauc）

> 依据：官方《大模型流式语音识别 API》文档（docs.volcengine.com，2026-08 版）
> 以及《双向流式语音识别 WebSocket》。升级协议前必须先更新本文件并同步 fixtures。
>
> 本文件中的所有 ID、错误码均为测试固定值，不含真实凭据。

## 端点与鉴权

| 项目 | 值 |
| --- | --- |
| 双向流式（优化版） | `wss://openspeech.bytedance.com/api/v3/sauc/bigmodel_async` |
| 双向流式 | `wss://openspeech.bytedance.com/api/v3/sauc/bigmodel` |
| 流式输入 | `wss://openspeech.bytedance.com/api/v3/sauc/bigmodel_nostream` |
| Resource ID（2.0 小时版） | `volc.seedasr.sauc.duration` |
| Resource ID（2.0 并发版） | `volc.seedasr.sauc.concurrent` |
| Resource ID（1.0 小时版） | `volc.bigasr.sauc.duration` |
| 响应 Header | `X-Tt-Logid`（排障必记录） |

新版控制台（API Key）：

```
X-Api-Key: <api key>
X-Api-Resource-Id: volc.seedasr.sauc.duration
X-Api-Request-Id: <uuid>
X-Api-Connect-Id: <uuid>
X-Api-Sequence: -1（仅当所选接口要求时）
```

旧版控制台（App Key + Access Key，二者不可与 X-Api-Key 混用）：

```
X-Api-App-Key: <app id>
X-Api-Access-Key: <access token>
X-Api-Resource-Id: volc.bigasr.sauc.duration
X-Api-Connect-Id: <uuid>
X-Api-Sequence: -1
```

## 二进制帧

```
Byte 0: [protocol version:4][header size:4]   version=1, header size=1 (4 bytes)
Byte 1: [message type:4][flags:4]
Byte 2: [serialization:4][compression:4]
Byte 3: reserved
[Sequence]: 4 字节大端 int32，仅当 flags 最低位为 1（位于 payload size 之前）
Payload size: 4 字节大端 uint32
Payload
```

消息类型：

| 值 | 含义 |
| --- | --- |
| 0x1 | full client request（JSON） |
| 0x2 | audio only request（PCM） |
| 0x9 | full server response（JSON） |
| 0xB | audio only server response / ack |
| 0xF | error |

Flags：

| 值 | 含义 |
| --- | --- |
| 0x0 | 无 sequence |
| 0x1 | 有 sequence，正数 |
| 0x2 | 最后一包（无 sequence） |
| 0x3 | 最后一包（有 sequence，负数） |

序列化：0=无，1=JSON。压缩：0=无，1=gzip。
客户端 full client request 使用 `0x11 0x10 0x11 0x00`（JSON + gzip，无 sequence）。

## 初始化 JSON

```json
{
  "user": { "uid": "<uuid>" },
  "audio": {
    "format": "pcm",
    "codec": "raw",
    "rate": 16000,
    "bits": 16,
    "channel": 1,
    "language": "zh-CN"
  },
  "request": {
    "model_name": "bigmodel",
    "result_type": "full",
    "enable_punc": true,
    "enable_itn": true,
    "show_utterances": true
  }
}
```

说明：

- `audio.language` 官方标注仅流式输入模式（nostream）支持；双向流式传空或忽略。Voxi 会按 profile 传值，服务端可能忽略。
- `result_type=full`：每次返回累计全文，必须**替换**预览，不能拼接。
- `result_type=single`：增量返回；只拼接新出现的 `definite` 分句。
- `definite=true` 只代表分句稳定，不代表会话结束。

## 音频包

- 16 kHz / 16-bit signed little-endian / mono PCM。
- 每包约 200 ms（6400 字节）；发包间隔 100–200 ms，过慢会触发 `45000081 等包超时`。
- 官方示例：audio frame 使用 gzip 压缩、序列化 0、flags 0x1 或 0x2。
- 最后一包：flags 0x2（无 sequence），官方示例使用最后一包真实音频。Voxi 会保留最后一个 200 ms 分片在 `finish` 时以 0x2 发送。

## 服务端响应

```
Header (0x11, 0x9x / 0xBx, 0x11 或 0x10)
[Sequence 4B 大端, 若 flags & 1]
Payload size (4B 大端)
Payload: gzip JSON（部分实现返回未压缩 JSON，需同时支持）
```

JSON：

```json
{
  "audio_info": { "duration": 3696 },
  "result": {
    "text": "这是字节跳动，今日头条母公司。",
    "utterances": [
      { "text": "这是字节跳动，", "start_time": 0, "end_time": 1705, "definite": true }
    ]
  }
}
```

- `result` 在个别实现中是数组，取最后一项。
- 最终响应 flags = 0x3（最后一包结果）。

## 错误帧

官方图例：

```
Header (0x11, 0xF0, 0x10/0x00, 0x00)
Error code (4B 大端)
Error message size (4B 大端)
Error message (UTF-8)
```

部分实现会保留标准 payload size 字段（header + payloadSize + code + msgLen + msg），
解码器需同时兼容两种布局。

| 错误码 | 含义 |
| --- | --- |
| 20000000 | 成功 |
| 45000001 | 请求参数无效 |
| 45000002 | 空音频 |
| 45000081 | 等包超时 |
| 45000151 | 音频格式不正确 |
| 55000031 | 服务器繁忙 |

## 测试夹具约定

- 所有 UUID 使用测试固定值（如 `11111111-2222-3333-4444-555555555555`）。
- gzip 夹具由 Python `gzip.compress(data, mtime=0)` 生成，见 `VolcengineWebSocketCodecTests`。
- 夹具中不得出现真实 API Key、App Key、Access Key 或账户信息。
