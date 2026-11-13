# Voxi 实施状态

> 对应 `PLAN.md` 的分阶段实施结果。最后更新：2026-11-14 01:15。

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
| 0.3 | 状态模型与设置持久化 | 单元测试覆盖状态流转、round-trip、旧配置迁移、无 secret 写入 UserDefaults；重启后 profile/Keychain 引用保留 |
| 0.4 | 菜单栏、AppState、单一 AppCoordinator、设置窗口 | 实际点击验证开始/停止/设置/退出；重复开始不产生新 session |
| 1.1 | 权限 | 首次录音触发系统麦克风授权框；拒绝路径、恢复按钮有测试与 UI |
| 1.2 | Carbon 全局快捷键 | 实机 ⌃⌥Space 按住/松开驱动状态；失焦与松键丢失保护有测试 |
| 1.3 | 音频采集 | 5 秒录音经 `afinfo` 验证：1 ch / 16000 Hz / Int16；临时 WAV 结束后删除（`VOXI_KEEP_RECORDINGS=1` 仅用于诊断） |
| 2.1 | multipart 与端点编辑器 | multipart 字节级测试；secret 只存 Keychain；保留字段名拒绝规则 |
| 2.2 | OpenAI-compatible provider | URLProtocol stub 测试请求字段、鉴权、解析、401/429/5xx/超时/取消/空文本 |
| 2.3 | 内网 SenseVoice 端点（真实） | curl 与 provider 层均返回正确文本；App 真实录音 → 上传 → TextEdit 自动输入成功 |
| 3.1–3.3 | 火山流式协议 | 官方文档核实帧顺序；修正序号规则（初始化帧序号 1，音频从 2 开始）；gzip、codec、fake transport、认证模式、初始化 JSON、中间结果替换、最终包、超时、取消均有测试 |
| 3.4 | 火山真实服务 | `scripts/dev/run-real-service-check.sh`：真实录音 3.6s → 8 次中间结果 → 最终文本正确，记录 `X-Tt-Logid`；App 内真实录音 → TextEdit 自动输入成功 |
| 4.1 | 文本模式传递 | OpenAI 字段与火山初始化 JSON 映射测试；标点/换行本地后处理测试 |
| 4.2 | 协调器状态机 | 火山 connecting 状态；迟到结果丢弃；取消与 final 竞争；PID 锁定逻辑测试 |
| 4.3 | 自动输入 | TextEdit 实测辅助功能插入成功；浏览器输入框实测剪贴板粘贴回退并恢复剪贴板；安全输入框/终端/权限缺失/前台切换有测试 |
| 5.1 | Release 自签名构建 | `dist/Voxi.app` codesign 有效；`spctl` 本机 accepted（因本机信任该证书） |
| 5.2 | 打包与首次启动 | `dist/Voxi.zip` + `README-FIRST-LAUNCH.txt` + `manifest.txt`；用户已在 Gatekeeper 弹窗中手动“打开”，App 随后正常运行 |

自动化测试：`xcodebuild test ...` 共 **148 项**（2 项真实服务集成测试默认跳过，避免误用凭据），其余全部通过。

## 本轮修复的问题

1. **火山序号校验**：服务端返回 `autoAssignedSequence (2) mismatch sequence in request (1)`。
   初始化帧改为带正序号 1，音频包从 2 开始。
2. **MenuBarExtra 反复开合后失灵**：macOS 26/27 上 SwiftUI `MenuBarExtra` 多次打开后不再响应。
   已替换为 AppKit `NSStatusItem + NSPopover`（`StatusItemController`），连续开合验证正常。
3. **CoreAudio 设备切换阻塞主线程**：音频引擎启动/收尾移到后台并加 10s 超时。
4. **设置数据被误清空**（本次开发操作失误）：已重新配置并验证重启后仍保留；
   两套凭据均保存在 Keychain，profile 引用持久化。

## 早上继续的待测清单

按优先级：

1. **干净环境首次启动（Phase 5.2.4）**
   - 在未安装 `Voxi Self-Signed Code Signing` 证书的独立 macOS 用户或测试机上，
     下载 `dist/Voxi.zip`，按 `README-FIRST-LAUNCH.txt` 完成 Gatekeeper 首次启动。
   - 验证麦克风、辅助功能授权在“安装新版本”后是否保留。
2. **多 App 输入兼容性（Phase 4.3 手工清单）**
   - Notes、Safari/Chrome 网页输入框、Slack（Electron）、VS Code。
   - 记录哪些控件走辅助功能、哪些走剪贴板、哪些只能手动复制。
3. **异常路径手工回归**
   - 错误火山 API Key / 错误 Resource ID / 断网 / 服务超时。
   - 识别中切换前台应用；按住模式权限弹窗期间松键；切换录音模式后重复触发。
4. **长录音与稳定性**
   - 火山 30s+ 连续说话：确认中间结果只更新预览、最终文本唯一、无 45000081 超时。
   - OpenAI 端点大文件上传与 60s 超时行为。
5. **发布复核**
   - 重新生成 `dist` 后核对 `manifest.txt` 的 SHA-256 与证书指纹。
   - 确认 `dist/Voxi.zip` 与当前源码一致（本次已重新打包）。

## 常用命令

```bash
# 构建 + 测试
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  xcodebuild test -project Voxi.xcodeproj -scheme Voxi \
  -destination 'platform=macOS' -derivedDataPath build/DerivedData

# 真实服务连通性（凭据仅通过环境变量传入）
VOLC_API_KEY=... OPENAI_API_KEY=... \
  OPENAI_ENDPOINT=https://host/v1/audio/transcriptions OPENAI_MODEL=sensevoice \
  scripts/dev/run-real-service-check.sh

# 本地 mock ASR
python3 scripts/dev/mock_asr_server.py --port 8765 [--status 401] [--seconds 2]

# Release 打包
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  xcodebuild build -project Voxi.xcodeproj -scheme Voxi -configuration Release \
  -derivedDataPath build/DerivedData \
  CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY="Voxi Self-Signed Code Signing"
```

## 已知设计取舍

- Swift 5 语言模式（`SWIFT_STRICT_CONCURRENCY=minimal`），便于 Carbon/AVFoundation 集成。
- 火山音频包与初始化包使用 gzip；服务端响应同时兼容 gzip 与未压缩 JSON。
- 火山 `finish` 保留最后一个 200 ms 分片并以结束 flag 发送，避免空结束包。
- 菜单栏使用 AppKit `NSStatusItem + NSPopover`，不使用 SwiftUI `MenuBarExtra`。
- OpenAI-compatible 在录音期间不发请求，也不伪造中间文本。
- 自动输入仅在辅助功能可信、目标 PID 未变、非安全输入框、非终端类应用时执行；
  否则保留文本并提示复制。
