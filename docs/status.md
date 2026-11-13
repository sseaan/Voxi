# Voxi 实施状态

> 对应 `PLAN.md` 的分阶段实施结果。最后更新：2026-11-14。

## 环境

- Xcode 27.2（`DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`）
- 部署目标 macOS 13.0
- 签名身份：`Voxi Self-Signed Code Signing`（本地自签名，非 Developer ID，未 notarize）
- Bundle ID：`com.voxi.app`

## 已完成并验证

| Phase | 内容 | 验证 |
| --- | --- | --- |
| 0.1 | Xcode 工程（Voxi + VoxiTests）、git、.gitignore | `xcodebuild -list`、Debug 构建、`git status` 不含 build/dist |
| 0.2 | 自签名 identity 与 Manual 签名 | `scripts/create-local-signing-identity.sh`；`codesign --verify --deep --strict` 通过 |
| 0.3 | RecordingState / RecordingMode / EndpointProfile / TextMode / SettingsStore | 146 项单元测试包含状态流转、设置 round-trip、旧配置迁移、无 secret 写入 UserDefaults |
| 0.4 | MenuBarExtra、AppState、单一 AppCoordinator、设置窗口 | 实际点击菜单栏验证开始/停止/设置/退出；重复开始不产生新 session |
| 1.1 | 权限 | 首次录音触发系统麦克风授权框；拒绝路径、恢复按钮有测试与 UI |
| 1.2 | Carbon 全局快捷键 | 实机 ⌃⌥Space 按住/松开驱动状态；失焦与松键丢失保护有测试 |
| 1.3 | 音频采集 | 5 秒录音经 `afinfo` 验证：1 ch / 16000 Hz / Int16；临时 WAV 流程结束后删除（`VOXI_KEEP_RECORDINGS=1` 仅用于诊断） |
| 2.1 | multipart 与端点编辑器 | multipart 字节级测试；secret 只存 Keychain；保留字段名拒绝规则 |
| 2.2 | OpenAI-compatible provider | URLProtocol stub 测试请求字段、鉴权、JSON/纯文本解析、401/429/5xx/超时/取消/空文本 |
| 2.3 | 本机 mock 联调 | `scripts/dev/mock_asr_server.py`；真实录音 → multipart 上传 → 返回文本 → 菜单栏显示；401 时显示可恢复错误 |
| 3.1–3.3 | 火山流式协议 | 官方文档核实帧顺序（header → [sequence] → payload size → payload）；gzip（zlib shim）、codec、fake transport、认证模式、初始化 JSON、中间结果替换、最终包、超时、取消均有测试 |
| 4.1 | 文本模式传递 | OpenAI 字段与火山初始化 JSON 映射测试；标点/换行本地后处理测试 |
| 4.2 | 协调器状态机 | 火山 connecting 状态；迟到结果丢弃；取消与 final 竞争；PID 锁定逻辑测试 |
| 4.3 | 自动输入 | TextEdit 实测辅助功能插入成功；Chrome 地址栏实测成功且剪贴板未受影响；安全输入框/终端/权限缺失/前台切换回退“可复制”有测试 |
| 5.1 | Release 自签名构建 | `dist/Voxi.app` codesign 有效；`spctl` 本机 accepted（因本机信任该证书） |
| 5.2 | 打包 | `dist/Voxi.zip`、`README-FIRST-LAUNCH.txt`、`manifest.txt`（zip/二进制/证书 SHA-256） |

自动化测试：`xcodebuild test ... -derivedDataPath build/DerivedData`，**146 项全部通过**（含全新 DerivedData 构建）。

## 尚未完成 / 阻塞

1. **Phase 3.4 真实火山账号联调**：需要用户提供已开通的 API Key（或旧版 App/Access Key）
   与 Resource ID。当前仅完成协议 codec、fake transport 与本地流程验证，未对真实服务发过请求。
2. **Phase 5.2.3 干净环境首次启动验证**：需要在未安装 `Voxi Self-Signed Code Signing`
   证书的独立 macOS 用户或测试机上执行。本机 quarantine 测试因证书已受信任而放行，
   不能替代该验证。
3. 手动兼容性清单尚缺 Notes / Slack / VS Code 的逐一实测（TextEdit、Chrome 已验证）。
4. macOS 27 上 MenuBarExtra 弹窗偶发显示在锁屏/失焦图层之下，需要在目标系统版本复核。

## 常用命令

```bash
# 构建 + 测试
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  xcodebuild test -project Voxi.xcodeproj -scheme Voxi \
  -destination 'platform=macOS' -derivedDataPath build/DerivedData

# Release 打包
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  xcodebuild build -project Voxi.xcodeproj -scheme Voxi -configuration Release \
  -derivedDataPath build/DerivedData \
  CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY="Voxi Self-Signed Code Signing"

# 本地 mock ASR（Phase 2 联调）
python3 scripts/dev/mock_asr_server.py --port 8765 [--status 401] [--seconds 2]
```

## 已知设计取舍

- Swift 5 语言模式（`SWIFT_STRICT_CONCURRENCY=minimal`），便于 Carbon/AVFoundation 集成。
- 火山音频包按官方示例使用 gzip；服务端响应同时兼容 gzip 与未压缩 JSON。
- 火山 `finish` 会保留最后一个 200 ms 分片，并以结束 flag 发送，避免发送空结束包。
- OpenAI-compatible 在录音期间不发请求，也不伪造中间文本。
- 自动输入仅在辅助功能可信、目标 PID 未变、非安全输入框、非终端类应用时执行；
  否则保留文本并提示复制。
