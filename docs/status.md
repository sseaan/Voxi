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
| 5.2 | 打包与首次启动 | `dist/Voxi.zip` + `README-FIRST-LAUNCH.txt` + `manifest.txt`；用户在干净环境完成 Gatekeeper 首次启动，无问题 |

自动化测试：`xcodebuild test ...` 共 **148 项**（2 项真实服务集成测试默认跳过，避免误用凭据），其余全部通过。

## 本轮修复的问题

1. **火山序号校验**：服务端返回 `autoAssignedSequence (2) mismatch sequence in request (1)`。
   初始化帧改为带正序号 1，音频包从 2 开始。
2. **菜单栏面板错位**：实测图标中心 914.25，NSPopover 内容中心 924（右偏约 10pt）。
   已在展示后按图标中心校正面板位置，靠近屏幕边缘时不做校正。
3. **MenuBarExtra 反复开合后失灵**：已改为 AppKit `NSStatusItem + NSPopover`。
4. **设置页排版与保存反馈**：
   - 统一为「顶部标签 + 居中内容 + 底部保存栏」结构，卡片式分组、标签列对齐；
   - 通用与文本页使用草稿模型，底部提供「保存 / 还原」与「已保存 HH:mm:ss」反馈；
   - 端点页固定底部操作栏，保存后显示「已保存并设为当前端点 · 时间」；
   - 设置窗口默认尺寸调整为 760×620。
5. **端点测试**：火山流式端点现在也会按 200ms 分片发送测试录音，并显示中间结果。
6. **CoreAudio 设备切换阻塞主线程**：音频引擎启动/收尾移到后台并加 10s 超时。
7. **Keychain 在更新构建后可能要求重新授权**：用户需在弹出的系统对话框输入登录密码并选择
   「始终允许」一次；错误提示已说明该操作。

## 上午实测结果（用户反馈）

- 干净环境 Gatekeeper 首次启动：已完成，无问题。
- 多 App 输入兼容：已确认无需额外测试。
- 本轮 UI 修订后，等待用户实际点击验证面板位置与设置页反馈。

## 仍需手工回归

1. 错误路径：错误火山 API Key / Resource ID、断网、服务超时。
2. 识别中切换前台应用；按住模式权限弹窗期间松键；切换录音模式后重复触发。
3. 长录音：火山 30s+ 与 SenseVoice 大文件（79.8s 测试录音已生成，待确认最终结果）。
4. 更新构建后 Keychain「始终允许」流程与 TCC 权限保留。

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

## 第二轮 UI/稳定性修订（2026-11-14 下午）

1. **菜单栏面板改为自绘 `NSPanel`**
   - 原因：系统 `NSPopover` 的窗口阴影左右不对称，箭头对齐时面板内容中心偏 10pt；
     手工移动窗口又会让箭头偏离图标。
   - 现在面板无箭头，内容严格以图标中心水平居中；高度按 SwiftUI 理想尺寸动态调整。
2. **菜单栏开始录音的焦点恢复**
   - 点击「开始录音」后收起面板并把前台还给上一个应用，避免识别结果粘回 Voxi。
   - 菜单触发与快捷键触发都会锁定录音开始时的前台 PID。
3. **连接期间音频缓冲**
   - 权限通过后立即开始采集；ASR 连接未就绪时缓冲 PCM，就绪后按 100ms 节奏补发。
   - 连接中松键不再丢弃录音，改为记录停止意图，连接完成后立即收尾识别。
   - 缓冲上限约 30 秒，防止异常连接无限占用内存。
4. **连接超时**
   - WebSocket 握手 + 初始化帧发送加入 8s 超时（不再使用 task group，避免等待失联任务）。
   - 复现过 72 秒握手卡住；现在会快速失败并给出错误。
5. **Keychain 读取移出主线程**
   - 系统授权弹窗会阻塞调用线程；现在在后台读取，UI 不会冻结。
   - 更新构建后首次读取需在系统对话框输入登录密码并选择「始终允许」。

### 当前待用户实测

- 面板是否位于图标正下方（已按几何日志验证图标中心与面板中心一致）。
- 菜单栏开始录音 → 焦点回到原应用 → 松键后文字是否输入到原应用。
- 设置页排版与保存反馈（上一轮已确认正常）。
- Keychain 弹窗选择「始终允许」后，重新启动 App 是否不再弹窗。
