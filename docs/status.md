# Voxi 实施状态

> 项目历史实施与变更记录。最后更新：2026-11-15。

## 环境

- Xcode 27.2（`DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`）
- 部署目标 macOS 13.0
- 签名身份：`Voxi Self-Signed Code Signing`（本地自签名，非 Developer ID，未 notarize）
- Bundle ID：`com.voxi.app`

## 已完成并验证

| Phase | 内容 | 验证 |
| --- | --- | --- |
| 0.1 | Xcode 工程（Voxi + VoxiTests）、git、.gitignore | `xcodebuild -list`、Debug 构建、`git status` 不含 build/dist |
| 0.2 | 自签名 identity 与 Manual 签名 | `scripts/setup/create-local-signing-identity.sh`；`codesign --verify --deep --strict` 通过 |
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

自动化测试：`xcodebuild test ...` 共 **202 项**（2 项真实服务集成测试默认跳过，避免误用凭据），其余全部通过。

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

## 第三轮功能新增（2026-11-14 傍晚）

1. **Fn / 右 Option 单键快捷键**
   - Carbon 热键无法注册左右修饰键，新增 `NSEvent` 全局/本地 `flagsChanged` 监听。
   - 仅在配置为 `Fn`（keyCode 63）或 `右 Option`（keyCode 61）时启用；普通字母/数字仍需修饰键。
   - 依赖辅助功能权限；未授权时保存会提示。
   - 注意：部分键盘的 Fn/Globe 键可能被系统占用，需实机确认。
2. **Dock 上方录音浮条**
   - `RecordingIndicatorController`：268×60 无边框面板，位于当前屏幕 Dock 上方居中。
   - 显示红点、计时与 18 段实时音量波形；`ignoresMouseEvents = true`，不抢焦点。
   - 仅在 `recording` 状态显示，停止后立即隐藏。
3. **应用图标**
   - `scripts/dev/generate-app-icon.swift` 生成 1024 底图与 16–512@2x 全套 PNG。
   - 蓝紫渐变 + 白色波形；接入 `Assets.xcassets/AppIcon`。
4. **音频文件转文字**
   - 菜单栏新增「转写音频…」；`AudioFileConverter` 统一转成 16 kHz 单声道 PCM16 WAV。
   - OpenAI-compatible：整段上传；火山：按 200ms 分片以 150ms 间隔流式发送。
   - 结果窗口支持复制与插入前台应用；临时文件在关闭/取消时删除。
   - 火山长文件耗时接近音频时长，界面会显示进度与临时文本。
5. **稳定性补充**
   - 菜单栏触发录音时恢复上一个前台应用；识别开始前锁定 PID。
   - 连接期间缓冲音频并在就绪后按 100ms 节奏补发；连接中松键改为完成而非丢弃。
   - WebSocket 握手/首包 8s 超时；Keychain 读取移到后台，避免阻塞主线程。

### 待用户实测

- Fn / 右 Option 单键触发（需先选“始终允许”钥匙串授权）。
- 录音浮条位置、波形与计时；确认不遮挡/不抢点击。
- Finder 中 App 图标显示。
- 「转写音频…」用 mp3/m4a/wav 各试一次，两种 provider 的复制/插入。

## 第四轮反馈修复（2026-11-14 傍晚）

1. **API Key 无法粘贴**
   - 根因：纯 AppKit 应用没有主菜单，文本框的 ⌘V/⌘C/⌘A 不会路由到第一响应者。
   - 新增 `MainMenuBuilder`：App 菜单（关于/设置/隐藏/退出）+ 编辑菜单（撤销/重做/剪切/复制/粘贴/删除/全选）+ 窗口菜单。
   - 自动化测试断言编辑菜单包含 paste:/copy:/selectAll:。
2. **录音浮条简化**
   - 只保留实时波形（26 段），去掉红点、文字与计时。
   - 音量改为把每个 200ms 音频包拆成 5 个约 40ms 子段（25Hz 更新），波形更接近实时。
   - 尺寸 200×44；`NSVisualEffectView(.hudWindow)` 毛玻璃胶囊；移除所有阴影（面板 hasShadow=false，无 SwiftUI shadow）。
3. **应用图标重做**
   - 深蓝→靛紫渐变 + 7 段白色波形，去掉渐变暗点/硬边；16–1024 全套重新生成。
4. **豆包文件转写 -1009**
   - 用真实火山服务复现文件转写流程：AIFF 源文件 → 16k WAV → 150ms 分片 → 最终文本正确（含中英混说）。
   - 结论：用户遇到的 -1009 是瞬时网络问题。
   - 改进：NSURLError 统一映射为可读文案（提示检查网络/VPN/代理），文件转写遇到瞬时网络错误自动重试一次。
5. **右 Option 单键**：用户已实测可用。

### 待确认

- Fn 单键是否可用（部分键盘的 Fn/Globe 被系统占用）。
- 录音浮条外观、位置与实时感；是否还有阴影。
- 新图标观感。
- API Key 输入框 ⌘V 粘贴。
- 豆包文件转写重试（含 mp3/m4a、长文件）。

## 第五轮修复（2026-11-14 晚）

1. **豆包“固定长度中断”根因**
   - `VolcengineStreamingProvider.start` 的初始化超时竞速任务在超时后**无条件**调用 `transport.close()`，即使会话早已就绪。默认初始化超时 8 秒，因此任何持续超过 8 秒的录音/文件流都会在 8 秒处被客户端自己掐断，发送下一包时报 `-1009`（transport 的未连接错误）。
   - 修复：`OnceResume.resume` 返回是否赢得竞速，只有超时真正获胜才关闭连接；新增回归测试 `testReadySessionIsNotClosedByInitializationTimeout`。
   - 真实服务验证：78 秒音频自动分两段（50s + 28s），两段均成功返回。
2. **长文件分段**
   - 火山流式单连接适合 ≤60 秒，文件转写按 50 秒分段、逐段新建会话并拼接文本（纯中文不加空格，ASCII 边界补空格）。
   - 进度按整段音频推进；段间摘要实时更新。
3. **SenseVoice 长文件超时**
   - 文件转写的请求超时改为 `max(端点超时, 时长×1.2+60s)`，长音频不再固定 60 秒超时。
4. **录音浮条配色**
   - 去掉 HUD 毛玻璃，改为随系统外观切换：浅色为白底深色波形，深色为黑底浅色波形；仍无阴影。

## 第六轮（2026-11-14 夜）

1. **文件转写导出 TXT**
   - 结果区新增“导出 TXT…”，默认文件名为原音频名 + `.txt`，UTF-8 写入；成功/失败在窗口顶部提示。
2. **设置页改为 OpenVoice 风格**
   - 左侧 184pt `regularMaterial` 侧边栏：应用图标、名称/版本、彩色图标导航（通用/文本/识别服务/关于）。
   - 隐藏标题栏文字，内容延伸到标题栏；页面大标题 20pt，卡片标题 11pt 辅助色，10pt 连续圆角、controlBackgroundColor 与 0.07 描边。
   - 窗口默认 900×620，容纳识别服务的左右分栏。
3. **录音提示条改为 OpenVoice 风格**
   - `.ultraThinMaterial` + 黑色 45% 叠加、22pt 连续圆角、上亮下暗渐变描边，强制深色外观；仍只显示实时波形、无阴影。
4. **文件转写窗口样式**
   - 文件信息与结果文本改用 controlBackgroundColor 卡片 + 10pt 连续圆角 + 0.07 描边，与设置页统一。

## 第七轮：全面对齐 OpenVoice（2026-11-14 深夜）

对照本机 OpenVoice 源码（SettingsWindow / FloatingPanel）重做：

1. **设置窗口**
   - 720×520，178pt `regularMaterial` 侧边栏，与 OpenVoice 一致。
   - 侧边栏：64pt 应用图标、名称/版本、彩色圆角图标导航；图标与配色采用 OpenVoice 的 general/models/about 方案。
   - 标题栏文字隐藏、全尺寸内容；页面大标题 20pt 放进滚动内容顶部（34pt），不再固定一条标题栏。
   - 卡片/行/描边/字体全部按 OpenVoice 的 11pt 卡片标题、13/11pt 行、10pt 连续圆角、0.07 描边。
2. **模型页逻辑**
   - 移除左右分栏；改为单列「模型来源」卡片：来源行含图标、名称、类型·模型、密钥状态、修改、删除；底部“添加模型来源”。
   - 添加来源使用 OpenVoice 式供应方选择弹窗（OpenAI-compatible / 火山引擎两张卡片）。
   - 「语音识别模型」卡片显示当前使用中的模型、测试按钮和切换模型 Picker。
   - 编辑改为弹窗表单（EndpointEditorView），保存后回到列表；删除来源时一并清理 Keychain 密钥。
3. **录音提示条**
   - 完全采用 OpenVoice 的聆听态：呼吸绿点 + 5 段波形 + “正在聆听”，波形高度 3+13×level、0.12s easeOut。
   - 转录阶段显示转圈 + “正在转录…”，面板宽度在 138/128 间切换。
   - 深色 `.ultraThinMaterial` + 45% 黑 + 上亮下暗描边，21pt 连续圆角；0.15s 淡入；位置距屏幕底部 64pt；恢复系统窗口阴影。

## 第八轮：多模型回退 + 个人词库 + 设置细节对齐（2026-11-15）

1. **多模型优先级 / 自动回退**
   - 模型顺序即回退顺序（首选 = 列表第一个）；设置页支持上移/下移、添加、删除。
   - 录音开始：按顺序尝试建立会话；流式模型连不上时自动换下一个，音频继续缓冲。
   - 录音结束：首选模型失败/返回空结果时，用已写好的 WAV 依次重跑剩余模型（火山按 150ms 分片补发）。
   - 流式模型中途断开：不丢弃录音，继续采集；结束后自动用备用模型转写整段音频。
   - 文件转写：同一转换结果按顺序尝试所有模型，全部失败时汇总每个模型的失败原因。
   - 删除来源时同步删除 Keychain 密钥；旧配置的 active profile 迁移到回退链首位。
2. **个人词库**
   - 新增「词库」页：术语 + 常见误写（逗号/顿号分隔）、搜索、导入/导出 txt。
   - 术语作为识别提示：OpenAI-compatible 追加到 prompt；火山写入 `request.corpus.context` 热词（已验证服务端接受）。
   - 识别完成后本地把常见误写替换成正确写法（大小写不敏感，长词优先），再走标点/换行处理。
3. **设置细节对齐 OpenVoice**
   - 移除底部“保存/还原”栏，改为即时保存；设置窗口只保留内容与侧边栏。
   - 通用/文本页改为 OpenVoice 行式布局：左标题/说明、右控件，行间分隔线；开关用 `.switch` + small，Picker 固定尺寸。
   - 模型来源/模型/词库使用连续行卡片（`SettingsListCard`），行内边距 12/9。
   - 模型编辑弹窗改为同样的行式卡片，去掉重复的大标题。
   - 关于页使用应用图标；词库页图标/配色采用 OpenVoice Glossary 的橙色书本。
4. 未新增任何提供方。

## 第九轮：转写风格 + 通用 OpenAI 语言模型（2026-11-15）

> 用户明确要求增加“识别后调用语言模型整理”，此前“不做第二次 LLM 改写”的约束在本轮被替换。

1. **文本页改为「风格」页**
   - 侧边栏图标改为 `wand.and.stars`，标题「风格」。
   - 内置四种卡片：原文、简单整理、清晰结构、正式表达；选中显示强调描边/勾选。
   - 三种预设都带完整中文系统提示词；「原文」不调用语言模型。
   - 自定义提示词区域：右上角小加号 → 弹窗输入名称/提示词 → 保存为卡片；卡片可选中、删除。
   - 选中需要 LLM 的风格但未配置语言模型时，显示提示和「去配置」按钮。
   - 原识别语言/标点/换行/识别提示移到「识别与输出」卡片，设置即时保存。
2. **通用 OpenAI 语言模型接入**
   - 新增 `LanguageModelProfile`：名称、Chat Completions Endpoint（可填到 /v1，自动补全）、model、Bearer/无鉴权、Keychain API Key、超时、temperature。
   - 模型页新增「语言模型」行，带绿色标签；语音识别行带蓝色「语音识别」标签。
   - 「添加模型来源」弹窗分组：语音识别（OpenAI-compatible / 火山）与语言模型（通用 OpenAI 接入）。
   - 删除语言模型时清理 Keychain；再次添加时若已存在则直接编辑。
3. **风格处理接入**
   - 录音：ASR 成功后、插入前调用语言模型；失败时插入原文并通过 notice 提示。
   - 文件：转写完成后按风格整理再显示；失败保留原文。
   - LLM 只接收文本，不接收录音；识别提示仍只作为 ASR 提示。

## 第十轮：模型列表 + 多模型启用 + LLM 错误可读化（2026-11-15）

1. **语言模型失败定位**
   - 日志显示上次失败为 HTTP 402：`Insufficient balance`（OpenCode 账户余额不足），端点和 Key 本身可用。
   - `ChatCompletionService` 对 401/402/403/404/429 增加中文提示（如“账户余额不足或额度用尽”），并保留原始响应。
2. **一个来源启用多个模型**
   - `EndpointProfile.openAI.enabledModels` / `LanguageModelProfile.enabledModels` 保存勾选列表。
   - 编辑来源新增“获取模型列表…”：从 `/models` 拉取（支持 `/v1/audio/transcriptions`、`/v1/chat/completions`、`/v1`、裸域名推导），弹窗搜索/全选/勾选后应用。
   - 勾选的模型进入模型页：语音识别模型按来源分组展示、同一来源内可上移/下移/测试/移除；来源顺序可上移/下移。
   - 语言模型页新增列表：显示所有勾选的语言模型，点击选择实际用于风格整理的模型。
   - 运行时候选 = 来源顺序 × 模型顺序；录音/文件回退都按此链执行。
3. **兼容**
   - `enabledModels` 为可选字段，旧配置无此字段时回落到原来的单模型。

## 第十一轮：OpenCode Go 专用适配（2026-11-15）

- OpenCode 的 OpenAI 兼容地址与通用 OpenAI 不同，旧地址 `.../inference/openai/v1/chat/completions` 会在 Go 上返回 400。
- 新增语言模型类型 `OpenCode Go`：
  - Chat：`https://opencode.ai/inference/go/openai/v1/chat/completions`
  - Models：`https://opencode.ai/inference/go/v1/models`
  - 请求头：`x-opencode-session`（稳定会话）、`x-opencode-request`、`x-opencode-client`、`x-opencode-project`、`User-Agent`。
  - 请求体：OpenAI Chat Completions + `max_tokens`，**不发送 temperature**（避免推理模型 400）。
  - 400/500 无明确错误体时自动重试一次；400 文案提示“请求格式或模型参数不被接受”。
- 添加来源的“语言模型”分组现在有「通用 OpenAI 接入」和「OpenCode Go」两张卡片。
- 语言模型编辑页新增“服务类型”Picker；切到 OpenCode Go 会自动填入专用 Endpoint、隐藏手工 Endpoint，并保留原 API Key。
- 旧配置没有 kind 字段时仍按通用 OpenAI 处理；在编辑器里切换服务类型即可迁移。

## 第十二轮：风格卡片效果示例（2026-11-15）

- 四种内置风格的卡片新增「效果示例」，用同一句原始转写展示：
  - 原文：保留口头禅
  - 简单整理：去口头禅、补标点
  - 清晰结构：输出要点列表
  - 正式表达：正式书面语
- 自定义提示词卡片展示提示词内容，并在添加弹窗中明确“提示词发送给语言模型，语音识别模型只负责转写”。
- 说明：Whisper 类 ASR 的 `prompt` 是上下文/术语提示，不是改写指令；火山 `corpus.context` 只接受热词。把风格提示词塞给 ASR 不能可靠实现结构化/正式表达，仍由语言模型执行。

## 第十三轮：首次打开引导（2026-11-15）

- 新增 480×640 竖向引导窗口，不复用设置页；完成后才打开设置页。
- 四页：
  1. 权限与钥匙串：麦克风、辅助功能、Keychain 测试（读取已有 Key 或创建临时条目）；未授权辅助功能会给提示。
  2. 快捷键：默认右 Option（新安装默认值改为右 Option），可录制组合键，提供右 Option / Fn / ⌃⌥Space 预设。
  3. 模型：显示已配置模型，可打开完整模型编辑弹窗；提供「暂时跳过模型配置」开关。
  4. 启动与输出：登录时启动、录音方式、自动输入、菜单栏临时文本、保留标点。
- 登录时启动使用 `SMAppService`；通用设置也新增同一开关。
- 首启标记 `hasCompletedOnboarding`：新安装默认 false；旧配置没有该字段时按 true 处理，升级用户不会被强制引导。

## 第十四轮：看板、发布工作流与 README（2026-11-15）

- 设置新增「看板」并作为默认首页：口述时间/字数/次数/平均速度、近 7 天每日字数折线图、模型链与词库概览；支持全部/今天/近 7 天筛选。
- 新增 `UsageStats`：只记录计数与每日字数，不保存转写文本；文件转写不计入口述看板。
- 新增 `.github/workflows/release.yml`：推送 `v*` tag 或手动指定 tag，构建 universal Release（ad-hoc 签名），生成 zip/manifest 并上传 GitHub Release。
- 新增 `packaging/README-FIRST-LAUNCH.txt` 发布包说明模板。
- README 按项目类型重写，补充安装、权限、隐私、构建与架构说明。

## Voxi 1.0.0 发布（2026-11-15）

- MARKETING_VERSION 提升到 1.0.0。
- 首次通过 GitHub Actions 构建 universal Release（ad-hoc 签名）并上传 GitHub Release。
- 发布包包含 `Voxi.zip`、`manifest.txt` 和首次启动说明。

## 第十五轮：Rime 个人词库导入（2026-11-15）

- 词库页顶部新增「Rime 个人词库」卡片：显示目录、上次同步与来源统计，可修改 Rime 目录、最低上屏次数、是否导入自定义短语，并提供「同步词条 / 清除」与前 50 条热词预览。
- 只读读取三类来源，不修改 Rime 用户目录：
  1. `~/Library/Rime/*.userdb`：直接解析 LevelDB（SSTable + WAL），支持 snappy 压缩块；
  2. `sync/<设备>/*.userdb.txt` 或根目录的用户词典快照；
  3. `custom_phrase*.txt`。
- 过滤规则：只保留 2–20 个字符的词条，排除单字、纯符号/数字、含 Rime 转义/占位符的词条；用户词典要求上屏次数达到阈值（默认 8，可在词库页调整）。统计、序列等内部词典（编码含 `/`）与元数据键会自动排除。
- 排序：自定义短语优先（权重 → 含英文/数字 → 长度 → 文件顺序），其后按上屏次数；默认最多 300 条。
- 导入结果写入 `PersonalLexicon.rimeTerms`，只作为识别提示（OpenAI prompt / 火山热词，分别取前 50 / 40 个）；**不参与本地误写替换**，避免几千条替换拖慢或改坏文本。手动词条不受「清除 Rime 热词」影响。
- 设置新增 `VoxiSettings.rime`（目录、阈值、自定义短语开关、上次同步时间）；旧配置与旧词库 JSON 缺少新字段时按空导入状态迁移。
- 测试：新增 LevelDB 读取（SSTable/log/snappy/删除标记）与 Rime 导入过滤、排序、快照合并、设置迁移用例；全量 226 项：223 项通过，3 项按环境跳过。

## Voxi 1.0.1 发布（2026-11-15）

- MARKETING_VERSION 提升到 1.0.1（build 2）。
- 新增 Rime 个人词库导入：只读解析 `~/Library/Rime` 的 `*.userdb`（LevelDB + snappy）、同步快照与 `custom_phrase*.txt`，把多字词导入为识别热词；默认上屏门槛 8 次，可在词库页调整；不修改 Rime 文件，也不参与本地误写替换。
- 词库页新增「Rime 个人词库」卡片；看板词库计数包含 Rime 热词；旧配置缺少新字段时按空导入状态迁移。
- 测试：226 项，223 通过，3 项按环境跳过。
- GitHub Actions 在推送 `v1.0.1` tag 后构建 universal Release（ad-hoc 签名）；本地自签名 Release 与 `dist/manifest.txt` 同步更新。
