# Voxi 开发计划

> **产品**：仅 macOS 的全局语音输入工具。按住快捷键或切换快捷键录音，调用用户配置的 ASR 服务，把最终转写结果输入到当前光标位置。
>
> **计划状态**：首版产品方向和 API 范围已确认。下列任务按顺序执行；每项都说明产物和验证方式，可直接作为实现清单。
>
> **仓库状态**：当前只有本计划文件，尚无 Xcode 工程。

## 1. 已确认的产品决策

- **平台**：macOS 13 Ventura 及以上。
- **应用形态**：原生 Swift 菜单栏应用；SwiftUI 为主，需要时使用 AppKit。
- **录音操作**：设置中可选按住说话或按下开始/再次按下结束。
- **ASR 服务**：首版实现两种 provider：
  1. 可配置 HTTP URL 的 OpenAI-compatible `v1/audio/transcriptions` multipart 接口；
  2. 火山引擎豆包流式语音识别 WebSocket 服务。
- **火山引擎交互**：录音期间实时发送音频分片并接收中间结果；停止录音后等待最终结果，再自动输入，避免把中间文本重复插入。
- **OpenAI-compatible 交互**：停止录音后，将完整音频文件发送到用户配置的转写 URL；不显示伪造的流式识别结果。
- **文本模式**：只设置 ASR 语言、prompt、标点和换行偏好，不调用第二个模型，不承诺 LLM 改写。
- **首版语言目标**：简体中文和英文；实际语言能力仍取决于所选服务。
- **端点配置**：OpenAI-compatible 服务允许自定义完整 URL、模型、鉴权、请求头和 multipart 字段；不做任意脚本或响应 JSONPath。
- **隐私**：用户自行选择端点；发送前明确标注云端/本地；密钥保存在 Keychain；默认不保留录音和转写历史。
- **账号**：不要求 Voxi 账号，不提供 Voxi 托管服务。
- **签名**：不使用 Developer ID。使用开发者创建并长期保留的自签名 Code Signing identity；不做 Apple notarization。分发步骤必须包含 Gatekeeper 首次启动说明和实机验证。

## 2. 自签名分发的明确限制

自签名不等于 Apple Developer ID 签名。macOS 默认 Gatekeeper 不会把自签名证书识别为已验证开发者；从网络下载且带 quarantine 标记的 App，在其他 Mac 上可能被拦截。自签名也不能获得 Apple notarization。用户可能需要显式批准启动，或由本人按说明移除下载 quarantine 标记。**不通过关闭整台 Mac 的 Gatekeeper 来解决。**

实施约束：

1. 使用稳定的 bundle identifier（首版暂用 `com.voxi.app`，若已占用则在 Phase 0 一次性改定）；
2. 使用同一张长期保存的自签名证书签署每个构建；若 `security find-identity` 没有列出证书，先在 Keychain Access 检查证书与私钥是否成对、证书类型是否为 Code Signing，再重跑查询；不要用 ad-hoc `-` 作为正式签名；
3. 不删除/重建证书私钥；在更新构建上验证麦克风、辅助功能授权是否仍有效；
4. 每个公开构建均在带 Gatekeeper/quarantine 的干净 macOS 用户环境测试启动流程；
5. 若自签名导致目标用户不能接受的安装或权限问题，暂停发布并重新评估分发方式，不要悄悄换成 Developer ID。

## 3. 技术栈与架构决定

| 范围 | 技术 | 首版用途 |
| --- | --- | --- |
| App 与 UI | Swift 5.9+、SwiftUI、AppKit | 菜单栏、设置、系统集成 |
| 系统要求 | macOS 13+、Xcode 支持的 macOS SDK | 最低部署版本设为 13.0 |
| 音频 | AVAudioEngine、AVAudioConverter、AVAudioFile | 采集麦克风、重采样、产生临时 WAV/PCM |
| 全局快捷键 | Carbon `RegisterEventHotKey`；必要时用 CGEvent 辅助；封装 `ShortcutService` | 获取按下/松开事件，支持两种录音模式 |
| HTTP ASR | URLSession async/await | OpenAI-compatible multipart 上传 |
| WebSocket ASR | URLSessionWebSocketTask + 独立火山协议 codec | 火山引擎双向流式识别 |
| 凭据 | Security.framework / Keychain | OpenAI 凭据、火山引擎 API Key 或旧版鉴权密钥 |
| 设置 | Codable + UserDefaults | 非敏感设置及 provider profile；不保存 secret 值 |
| 日志 | OSLog / Logger | 状态、错误码、火山 `X-Tt-Logid`；脱敏 URL 和凭据 |
| 自动输入 | Accessibility API；剪贴板 + Cmd+V 回退 | 向当前前台应用输入最终文本 |
| 测试 | XCTest 或 Swift Testing、URLProtocol mock、注入式 WebSocket transport | 状态机、HTTP、二进制协议、权限与输入测试 |
| 工程 | Xcode project，尽量使用系统框架 | 空仓库起步；首版不引入大体量第三方依赖 |
| 签名 | 持久的本地自签名代码签名证书 | 构建可验证完整性；不代表 Gatekeeper 公证通过 |

### 3.1 Provider 统一边界

实现统一的应用内转写结果模型，但不要强迫两种 API 采用相同网络交互：

```swift
protocol TranscriptionProvider {
    func makeSession(options: TranscriptionOptions) async throws -> any TranscriptionSession
}

protocol TranscriptionSession {
    var updates: AsyncThrowingStream<TranscriptionUpdate, Error> { get }
    func appendAudio(_ pcm16Mono16k: Data) async throws
    func finish(recordingURL: URL) async throws -> TranscriptionResult
    func cancel() async
}
```

具体规则：

- 火山 provider 在 `appendAudio` 中实时发送 16 kHz 单声道 PCM 分片，并从 `updates` 输出 provisional/final utterance 更新；`finish` 发送结束包并等待服务端最终包。
- OpenAI-compatible provider 的 `appendAudio` 不发送请求；在 `finish(recordingURL:)` 中上传完整录音文件并解析结果。
- `TranscriptionResult` 只含最终文本和可选诊断元数据；不得把临时识别结果当作最终结果插入当前应用。
- 每次录音有唯一 session ID。停止、取消、服务失败或前台目标失效后，迟到的异步结果不得再输入。

## 4. API 规格与实现边界

### 4.1 OpenAI-compatible `v1/audio/transcriptions`

配置及行为：

- `URL`：保存用户提供的完整 HTTP(S) URL；默认值示例为 `https://api.openai.com/v1/audio/transcriptions`，但不得将服务域名写死在 provider 中。
- `model`：必填 multipart 字段；
- `file`：录音 WAV 文件；
- `language`、`prompt`、`response_format`：按模式和端点设置附加；
- 自定义 headers 与 multipart 字段：按 profile 配置追加，重复的保留字段按明确规则处理，不允许用户覆盖 `file` 或破坏 boundary；
- Key：Keychain 存储。支持 `Authorization: Bearer …` 默认方式；若用户指定自定义鉴权 header，则避免同时重复添加默认 Authorization；
- 结果：首版最少解析 JSON `{ "text": "..." }`；如支持 `text` response format，也要按 Content-Type/用户设置解析纯文本；
- 网络失败、非 2xx、超时、取消、空文本、非预期 MIME 分开报错；不得无限自动重试。

### 4.2 火山引擎豆包双向流式 ASR

首版以官方流式 ASR v3 WebSocket 协议为实现目标：

- WebSocket URL 默认：`wss://openspeech.bytedance.com/api/v3/sauc/bigmodel_async`；设置中允许修改 endpoint，以便使用服务实际开通的兼容地址；
- 新版控制台鉴权：Keychain 保存 API Key；建连设置 `X-Api-Key`、`X-Api-Resource-Id`、`X-Api-Connect-Id`、`X-Api-Request-Id`；默认 Resource ID 使用官方文档中的 `volc.seedasr.sauc.duration`，用户可按控制台开通资源修改。协议夹具必须核对所选 v3 接口是否要求 `X-Api-Sequence`，若要求则按官方值发送；
- 兼容旧版控制台鉴权：提供 `X-Api-App-Key` + `X-Api-Access-Key` 配置，二者均存 Keychain，不与新版 API Key 模式混用；
- 初始化 JSON 明确设置 `audio.format = pcm`、`codec = raw`、`rate = 16000`、`bits = 16`、`channel = 1`，以及 `request.model_name = bigmodel`；请求中的语言和 `result_type` 由 profile 控制，默认使用全量结果并以最终包作为输出；
- 音频格式：PCM signed 16-bit little-endian、单声道、16 kHz；输入 AVAudioEngine 缓冲时必须先重采样，不能假设硬件采样率就是 16 kHz；
- 音频包：按约 200 ms 分片（16 kHz × 16 bit × mono，约 6,400 bytes PCM），按官方消息格式发送；
- 连接后先发送初始化/full-client-request 帧；收到初始化成功响应后才发送音频帧；停止时发带结束序号的最后音频帧；保持接收，直到识别完成/最后包，再关闭 WebSocket；
- response decoder 解析协议头、payload 长度、压缩 JSON、服务错误与最终包；记录并展示 `X-Tt-Logid`，绝不记录鉴权 headers；
- 中间结果根据协议标识更新临时预览，不能将每次累计全文直接拼接；最终文字以最后确认结果为准；
- 首版不支持火山实时对话、TTS、翻译或非 ASR WebSocket 协议。

**官方协议依据**（实现时复核最新文档，协议变更以官方为准）：

- [火山引擎流式语音识别 WebSocket API](https://docs.volcengine.com/docs/doubao-voice/large-model-streaming-automatic-speech-recognition-api-1?lang=zh)
- [火山引擎双向流式语音识别 WebSocket](https://docs.volcengine.com/docs/doubao-voice/bidirectional-streaming-automatic-speech-recognition-websocket)
- [Apple Code Signing Tasks](https://developer.apple.com/library/archive/documentation/Security/Conceptual/CodeSigningGuide/Procedures/Procedures.html)
- [Apple Xcode：在 Mac App Store 外分发](https://help.apple.com/xcode/mac/current/en.lproj/dev033e997ca.html)

## 5. 交互、权限和数据要求

### 5.1 菜单栏状态

状态必须由单一 `AppCoordinator` 管理：

```text
OpenAI-compatible:
idle -> requestingPermission -> recording -> finalizingAudio
     -> transcribing (upload + response) -> inserting -> idle

Volcengine streaming:
idle -> requestingPermission -> connecting -> recording (live stream)
     -> finalizingAudio -> transcribing (wait for final package)
     -> inserting -> idle

任何处理中状态 -> cancelling/cancelled 或 failed -> idle
```

菜单栏显示：待机、录音（计时/音量）、连接中、识别中（火山可显示临时文本）、输入中和可恢复错误。OpenAI 上传过程只显示上传/处理中，不显示假实时文字。

### 5.2 权限

- 麦克风权限在用户第一次明确开始录音时申请；
- 辅助功能权限在用户启用自动输入时解释并引导，不授权时显示结果供复制；
- 权限拒绝、系统设置关闭、设备无输入分别显示可操作错误；
- `Info.plist` 添加真实用途说明；用户拒绝后不反复弹系统权限请求。

### 5.3 音频与凭据

- 只在一次录音流程中生成随机临时文件；流程成功、失败或取消后删除；
- Volcengine 正在实时传 PCM 的同时，仍可在临时目录写完整 WAV，方便 OpenAI provider 共用输出及问题诊断；临时文件不得进入日志或历史；
- Keychain 保存所有 API key、Access Key 等 secret。UserDefaults 只存 Keychain item identifier 和普通配置；
- 日志不包含音频、完整转写、Key、Access Key、Authorization、敏感自定义 header；
- 每个 endpoint profile 标注“本机”或“发送到远程服务”。仅 loopback 明确允许用户选择 HTTP；远程 endpoint 必须 HTTPS；不绕过 TLS 验证。

## 6. 文件结构（按实现顺序创建）

```text
Voxi/
├── Voxi.xcodeproj/
├── Voxi/
│   ├── App/VoxiApp.swift
│   ├── App/AppCoordinator.swift
│   ├── App/AppState.swift
│   ├── Models/RecordingState.swift
│   ├── Models/RecordingMode.swift
│   ├── Models/EndpointProfile.swift
│   ├── Models/TextMode.swift
│   ├── Models/TranscriptionResult.swift
│   ├── Services/ShortcutService.swift
│   ├── Services/PermissionService.swift
│   ├── Services/AudioCaptureService.swift
│   ├── Services/TranscriptionProvider.swift
│   ├── Services/OpenAICompatibleProvider.swift
│   ├── Services/VolcengineStreamingProvider.swift
│   ├── Services/VolcengineWebSocketCodec.swift
│   ├── Services/VolcengineWebSocketTransport.swift
│   ├── Services/TextInsertionService.swift
│   ├── Services/KeychainService.swift
│   ├── Services/SettingsStore.swift
│   ├── UI/MenuBarView.swift
│   ├── UI/SettingsView.swift
│   ├── UI/EndpointEditorView.swift
│   ├── UI/TextModeEditorView.swift
│   └── Support/Logger.swift
└── VoxiTests/
    ├── RecordingStateTests.swift
    ├── AudioConversionTests.swift
    ├── OpenAICompatibleProviderTests.swift
    ├── VolcengineWebSocketCodecTests.swift
    ├── VolcengineStreamingProviderTests.swift
    ├── KeychainServiceTests.swift
    └── TextInsertionServiceTests.swift
```

## 7. 可直接执行的实施步骤

每一步完成后先执行该步骤的验证，再进入下一步。测试失败时修复当前步骤，不跳过验收。

### Phase 0：创建工程、签名身份与可启动菜单栏 App

#### 0.1 创建 Xcode 工程

1. 打开 Xcode，选择 **File → New → Project → macOS → App**。
2. 填写：Product Name `Voxi`、Interface `SwiftUI`、Language `Swift`、Testing System `XCTest`；Bundle Identifier 暂用 `com.voxi.app`；保存到仓库根目录。
3. 在 Target → General 中将 Minimum Deployments 设为 **macOS 13.0**；在 Signing & Capabilities 中不选 Developer Team，不启用 App Sandbox（自动输入和全局快捷键需实机验证）。
4. 在根目录执行：
   ```bash
   xcodebuild -list -project Voxi.xcodeproj
   ```
5. 确认输出包含 `Voxi` app scheme 和测试 target；确保最终 `Voxi.xcodeproj` 位于当前仓库根目录（如果 Xcode 在外层额外生成了 `Voxi/` 文件夹，将 `.xcodeproj`、app source 和 test source 一起上移一级，再打开工程并重跑 build）。在 Xcode Project Navigator 中按第 6 节目录创建 groups，将默认 Swift 文件拖入对应 group，并确认 Target Membership 中 app 文件属于 Voxi、测试文件属于 VoxiTests。
6. 在仓库根目录确保有 Git 和忽略构建产物：
   ```bash
   git rev-parse --is-inside-work-tree >/dev/null 2>&1 || git init
   cat > .gitignore <<'EOF'
   .DS_Store
   build/
   dist/
   *.xcuserstate
   xcuserdata/
   EOF
   ```
7. 执行 Debug 构建：
   ```bash
   xcodebuild build -project Voxi.xcodeproj -scheme Voxi -configuration Debug -derivedDataPath build/DerivedData
   ```

**验收**：Xcode 能启动空白 Voxi；`Voxi.xcodeproj` 位于仓库根目录，存在 app/test target；部署版本为 13.0；Debug 构建成功；`git status --short` 不包含 `build/` 或 `dist/`。

#### 0.2 生成并固定自签名证书

1. 打开 **Keychain Access → Certificate Assistant → Create a Certificate**。
2. 名称填写 `Voxi Self-Signed Code Signing`；Identity Type 选择 `Self Signed Root`；Certificate Type 选择 `Code Signing`；保存到当前用户的 login keychain。
3. 执行并确认身份可用于 code signing：
   ```bash
   security find-identity -v -p codesigning
   ```
   如果列表未出现 `Voxi Self-Signed Code Signing`，在 Keychain Access 中确认它与私钥成对且 certificate type 是 Code Signing；必要时只对这张证书设置当前用户的 Code Signing 信任，再重新执行查询。
4. 将私钥备份到仅本人可访问的安全介质；不得提交到 Git、制品或仓库。
5. 在 Xcode target 的 Build Settings 中设定 `Code Signing Style = Manual`、`Code Signing Identity = Voxi Self-Signed Code Signing`；对 Debug/Release 都使用该 identity，不使用 ad-hoc 签名。
6. 用该 identity 重建 Debug，再对实际产物执行签名验证：
   ```bash
   xcodebuild build -project Voxi.xcodeproj -scheme Voxi -configuration Debug -derivedDataPath build/DerivedData CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY="Voxi Self-Signed Code Signing"
   APP="build/DerivedData/Build/Products/Debug/Voxi.app"
   codesign --verify --deep --strict --verbose=2 "$APP"
   codesign -dv --verbose=4 "$APP" 2>&1 | grep -E 'Identifier|Authority|TeamIdentifier'
   ```

**验收**：签名验证成功，输出 bundle identifier 为确定值；私钥不在项目文件和 Git 状态中。Gatekeeper/公开分发问题不以本机开发成功代替，留到 Phase 5 测试。

#### 0.3 建立状态模型和设置持久化

1. 新建 `Voxi/Models/RecordingState.swift`，定义 `idle / requestingPermission / recording / finalizingAudio / connecting / transcribing / inserting / cancelling / failed`。
2. 新建 `RecordingMode.swift`，定义 `holdToTalk` 和 `toggle`。
3. 新建 `EndpointProfile.swift`，定义 provider 类型 `openAICompatible` / `volcengineStreaming`，保存普通配置、Keychain item 标识、endpoint、provider 选项；严禁把 secret 放进 Codable 模型。
4. 新建 `TextMode.swift`（语言、prompt、标点/换行选项）及 `TranscriptionResult.swift`（最终文本、provider、request ID、可选 log ID）。
5. 新建 `SettingsStore.swift`，读写 Codable 设置并提供默认值；新建最小 unit test，验证 encode/decode round-trip 和旧配置缺省值迁移。
6. 执行：
   ```bash
   xcodebuild test -project Voxi.xcodeproj -scheme Voxi -destination 'platform=macOS'
   ```

**验收**：状态、profile 和文本模式测试通过；保存后重启仍保留普通配置；搜索工程确认没有 API Key 字符串字段进入 UserDefaults Codable。

#### 0.4 建立菜单栏 UI 和单一协调器

1. 将 `VoxiApp.swift` 改成 `MenuBarExtra` 应用入口，菜单标题采用 Voxi 图标/状态图标。
2. 新建 `AppState.swift` 作为 `@MainActor ObservableObject`，只保存当前状态、错误、当前 provider 和临时识别预览。
3. 新建 `AppCoordinator.swift`，所有开始、停止、取消和异步结果都经由此对象；对每次录音生成 UUID session ID。
4. 新建 `MenuBarView.swift`，显示状态、开始/停止、设置和退出；新建最小 `SettingsView.swift`。
5. 构建并手动点选每个菜单栏项，确认状态更新不重复创建 session。

**Phase 0 验收**：可构建/测试/启动；应用在菜单栏可见；设置窗口可打开；用户可以退出；无麦克风读取、无网络请求；自签名验证成功。

### Phase 1：权限、快捷键和确定格式的音频采集

#### 1.1 添加权限与信息说明

1. 在 target Info 中设置 `NSMicrophoneUsageDescription`，文案说明 Voxi 只在快捷键触发时录音。
2. 新建 `PermissionService.swift`，封装麦克风授权、辅助功能授权查询和打开对应系统设置页面。
3. 用全新 macOS 用户或重置 TCC 权限的测试账户运行，验证首次录音会请求麦克风；拒绝后显示设置指引而不是崩溃。

**验收**：授权、拒绝、系统设置中关闭三种路径都能显示明确状态；待机时不启动 AVAudioEngine。

#### 1.2 实现 `ShortcutService`

1. 新建 `ShortcutService.swift`，用 Carbon 注册用户配置的全局组合键，并提供 keyDown/keyUp 事件到 `AppCoordinator`。
2. 实现快捷键设置控件、无效组合提示和冲突注册错误；启动时从 `SettingsStore` 读取快捷键。
3. 实现行为：`holdToTalk` 在 keyDown 开始、keyUp 停止；`toggle` 第一次 keyDown 开始、下一次 keyDown 停止；处理重复 keyDown、松键丢失和应用失焦保护。
4. 为事件解析和录音模式映射编写单元测试；手动在其他前台 App 测试快捷键。

**验收**：两种模式都只创建一次录音；松键丢失时菜单栏可停止，不会永久录音；无效/冲突快捷键有错误提示。

#### 1.3 实现音频捕获与转换

1. 新建 `AudioCaptureService.swift`，将 AVAudioEngine tap 的输入送入 `AVAudioConverter`。
2. 统一输出格式：16 kHz、mono、signed PCM16 little-endian；生成每约 200 ms 一块的 PCM `Data`。
3. 同时把转换后的 PCM 写到随机命名的临时 WAV；每次录音结束返回 URL 和录音元数据；取消、异常和完成均清理文件。
4. 通过 `AsyncStream` 将 PCM chunk 送给协调器/provider；实现结束流、背压和取消，不在音频 tap 中做网络请求。
5. 增加音频转换测试；在 TextEdit 录制 5 秒，将 `AudioCaptureService` 返回的临时 WAV URL 传给 `afinfo` 检查格式/时长，并用 `AVAudioFile` 测试断言采样率、声道、PCM 样本数和 WAV header。

**验收**：不同硬件输入采样率均转换为目标格式；生成的 WAV 可读取；没有麦克风授权时不启动；录音结束/取消/异常后临时文件被删除。

### Phase 2：OpenAI-compatible transcription endpoint

#### 2.1 实现 multipart builder 和配置界面

1. 新建 `Support/MultipartFormData.swift`（或 `Services/MultipartFormData.swift`），实现 boundary、字段、文件名、MIME type 和 CRLF 编码。
2. 新建 `EndpointEditorView.swift`，提供名称、完整 URL、模型、Key、语言、prompt、response format、timeout、custom headers 和 custom form fields。
3. 使用 `KeychainService` 保存 API Key；header/form field 标记为 secret 时也存 Keychain，普通设置只保存 Keychain item reference。
4. 验证 URL scheme；拒绝远端 HTTP；只允许用户对 loopback 明确开启 HTTP；禁止自定义 headers 覆盖 multipart Content-Type boundary。
5. 编写 multipart 单元测试，断言文件和字段内容、boundary、内容长度、header 冲突处理正确。

#### 2.2 实现 OpenAI-compatible provider

1. 新建 `OpenAICompatibleProvider.swift`，从 profile 读取完整 endpoint，不拼接/硬编码厂商域名。
2. `finish(recordingURL:)` 创建 URLRequest，设置 timeout、鉴权、自定义 headers 和 multipart body，使用 URLSession async 上传。
3. 解析 `{ "text": "..." }` JSON 与配置支持的纯文本响应；分类非 2xx、401/403、429、5xx、超时、取消、JSON 错误和空文本。
4. 确认取消 task 可传播到 UI；任何错误均不能将残缺文本插入目标应用。
5. 使用 `URLProtocol` stub 测试请求方法、URL、form fields、headers 脱敏、响应解析和错误映射。

#### 2.3 用本机 mock 验证用户配置端点

1. 在设置页增加“测试端点”按钮：要求用户录制一段明确提示用途的短音频，并由用户确认后发送；不得在没有音频的状态下声称完成 ASR 连通性测试。
2. 在设置页保存 endpoint profile，并将其设为当前 provider。
3. 手动录制中文/英文两段短音频，确认 HTTP 请求发到配置的完整 URL，响应文字在 Voxi 中显示出来。

**Phase 2 验收**：自定义 URL 可用；API Key 仅存 Keychain；发送字段正确；空文本及 HTTP 错误可恢复；完成录音前不发 HTTP 请求；成功结果进入 `TranscriptionResult`，尚未自动输入。

### Phase 3：火山引擎双向流式 ASR

#### 3.1 先固定官方协议版本与测试夹具

1. 阅读第 4.2 节的两篇火山官方文档，记录所用 WebSocket URL、认证模式、Resource ID、音频字段和帧定义到 `VoxiTests/Fixtures/volcengine-protocol.md`。
2. 新版控制台先实现 `X-Api-Key`；同时实现旧版控制台的 `X-Api-App-Key` + `X-Api-Access-Key`，设置界面必须明确只能选择一种认证模式。
3. 为每个协议消息编写无凭据的二进制 fixture；所有 UUID 用测试固定值。Fixtures 中不得出现真实密钥或账户数据。

#### 3.2 实现可单测的二进制 codec 和 transport

1. 新建 `VolcengineWebSocketCodec.swift`，定义 client full request、audio chunk、last chunk、server response、server error 的 encode/decode。
2. 按官方协议实现大端长度、版本/header、序列号、JSON/Gzip payload；所有长度边界、截断帧、非法压缩和未知消息 type 返回明确错误。
3. 新建 `VolcengineWebSocketTransport.swift`，封装 URLSessionWebSocketTask 的 connect/send/receive/close；通过协议注入 fake transport，测试 provider 不依赖真实网络。
4. 测试 0-byte/短帧/超长 payload/错误码/压缩响应；对协议文档示例做 round-trip 和字节级断言。

#### 3.3 实现 Volcengine provider session

1. 新建 `VolcengineStreamingProvider.swift`。`makeSession` 验证 endpoint、Resource ID 和凭据模式；通过 Keychain 取密钥后创建 WebSocket 握手 headers。
2. 保存握手响应的 `X-Tt-Logid` 到诊断元数据；Logger 只记录 log ID、request UUID、状态码和耗时，不输出 headers/payload 音频。
3. WebSocket 建立后发送初始化帧；确认服务器返回成功后，才调用音频发送循环。
4. 每次 `appendAudio` 发送 PCM16 mono 16 kHz 约 200 ms 分片；实时把可变中间结果发到 `updates`，在 UI 中显示预览但不写入前台应用。
5. `finish` 发送正确的最终负序号/结束帧，继续收消息直到最终包；按协议解析 final transcript，再关闭连接并返回结果。
6. `cancel` 发送协议支持的取消/结束动作或立即关闭连接，取消 receive task，并阻止任何迟到结果触发输入。
7. 注入 fake transport 测试连接失败、初始化失败、连续中间结果、累计文本替换、最终包、服务端错误、取消和未收到 final 的 timeout。

#### 3.4 真实服务端集成验证

1. 在设置页填入火山 API Key（或旧版两项凭据）与账号已开通的 Resource ID；凭据只进入 Keychain。
2. 按键开始录音，说一句中文并停顿，再说一句英文；确认中间结果在 Voxi 菜单栏预览中更新。
3. 松开/再次按快捷键后确认客户端发出结束帧、收到最终包；记录 X-Tt-Logid 并确认最终文本只出现一次。
4. 分别模拟断网、错误 Key、错误 Resource ID 和立即取消，确认状态回到 idle 且无残余 WebSocket/临时文件；最终结果先在 Voxi 中显示，不要求本阶段执行自动输入。

**Phase 3 验收**：协议 codec 的自动化测试通过；真实火山账号可完成一次录音全链路；中间结果只更新预览，最终结果唯一；连接结束前确实等待最终包。

### Phase 4：文本模式、协调器与自动输入

#### 4.1 实现文本模式传递

1. 在 `TextMode.swift` 提供中文、English、prompt、标点和换行偏好。
2. OpenAI provider 把支持的项作为 multipart 字段发送；火山 provider 把语言及对应配置写入初始化 JSON；只发送各协议文档支持的参数。
3. 对 provider 不支持的选项在设置页显示“此端点可能忽略该项”；不做本地/LLM 改写。
4. 写测试断言两种 provider 的字段映射和默认值。

#### 4.2 接通单一 AppCoordinator 状态机

1. 在 `AppCoordinator` 中实现 `startRecording()`, `stopRecording()`, `cancelCurrentSession()`；所有入口（快捷键、菜单栏）只调用这三处。
2. 每个操作先验证状态、权限和 endpoint profile；生成 session UUID；录音流和 ASR session 与该 UUID 绑定。
3. OpenAI provider 在录音停止后调用一次上传；Volcengine session 在录音中逐块发送并在停止后等待 final。
4. 记录快捷键触发时的前台应用 PID；输入前如果前台应用已变化，保留最终文本并要求用户手动粘贴，不向新应用误输入；所有异步结果均须确认当前 session ID 未变且用户未取消，之后才进入 `inserting`；所有异常统一转成可读的 AppState error。
5. 对重复快捷键、停止两次、取消与 final 同时返回、快速开始第二次录音编写状态机测试。

#### 4.3 实现文本自动输入

1. 新建 `TextInsertionService.swift`；先尝试经辅助功能权限执行插入；若无法安全定位目标控件，不假定插入成功。
2. 实现剪贴板回退：记录全部 pasteboard item/types，临时写入最终转写，发送 Cmd+V，等待粘贴完成后恢复先前内容。
3. 对 Secure Text Field、Terminal、无焦点控件、权限关闭和前台 App 切换返回“已识别，可复制”结果，不丢失文本。
4. 测试通过 XCTest mock clipboard/keyboard service 验证恢复和取消；手动在 TextEdit、Notes、Safari/Chrome、Slack、VS Code 输入测试句。
5. 火山中间结果只在 Voxi 预览，不参与 paste；最终文本只能粘贴一次。

**Phase 4 验收**：两种 provider 可由同一快捷键/状态机驱动；中文/英文模式字段经过测试；最终文本能在目标应用输入；失败时提供复制回退；重复触发不重复上传或输入。

### Phase 5：自签名构建、安装和分发测试

#### 5.1 配置 Release

1. 在 Xcode Release 配置确认 bundle ID、最低系统、`Info.plist` 权限描述及自签名 Code Signing identity 与 Debug 一致。
2. 在仓库根目录执行 Release 构建并复制 app：
   ```bash
   xcodebuild build \
     -project Voxi.xcodeproj \
     -scheme Voxi \
     -configuration Release \
     -derivedDataPath build/DerivedData \
     CODE_SIGN_STYLE=Manual \
     CODE_SIGN_IDENTITY="Voxi Self-Signed Code Signing"
   mkdir -p dist
   ditto build/DerivedData/Build/Products/Release/Voxi.app dist/Voxi.app
   ```
3. 执行 `codesign --verify --deep --strict --verbose=2 dist/Voxi.app`。
4. 使用 `spctl --assess --type execute --verbose dist/Voxi.app` 记录 Gatekeeper 结果；预期自签名应用可能不被默认策略接受，不把该结果伪报为通过。

#### 5.2 打包并验证新安装

1. 创建 `dist/README-FIRST-LAUNCH.txt`，说明优先使用 Finder 的“打开”/系统“仍要打开”操作；仅在用户确认制品来源与 SHA-256、明确接受自签名风险后，提供对单个 `Voxi.app` 移除 quarantine 标记的可选命令：`xattr -dr com.apple.quarantine /Applications/Voxi.app`。禁止建议关闭全局 Gatekeeper。
2. 用 `ditto` 将 App 和首次启动说明打成 zip，并保存签名 identity 指纹和 artifact SHA-256：
   ```bash
   mkdir -p dist/Voxi-package
   ditto dist/Voxi.app dist/Voxi-package/Voxi.app
   cp dist/README-FIRST-LAUNCH.txt dist/Voxi-package/README-FIRST-LAUNCH.txt
   ditto -c -k --sequesterRsrc --keepParent dist/Voxi-package dist/Voxi.zip
   shasum -a 256 dist/Voxi.zip
   security find-certificate -c "Voxi Self-Signed Code Signing" -p ~/Library/Keychains/login.keychain-db | shasum -a 256
   codesign -dv --verbose=4 dist/Voxi.app 2>&1
   ```
   把两条 SHA-256、版本号和 bundle ID 写入 `dist/manifest.txt`。
3. 在未安装开发证书的独立 macOS 用户/测试机中下载该制品，确认实际 quarantine/Gatekeeper 行为；按说明完成首次启动。若仍无法接受地运行，记录阻塞并停止发布。
4. 在同一测试环境验证麦克风、辅助功能、快捷键、OpenAI URL 和火山 WebSocket；安装新版本后重复验证 TCC 权限是否保留。
5. 只有完成以上流程才标记构建为可分发；不执行 `notarytool`，不配置 Developer ID，不在文档中声称 notarized。

**Phase 5 验收**：Release 签名稳定；artifact 校验值与记录一致；干净环境首次启动流程有真实验证；自签名限制和安装要求向用户透明说明。

## 8. 自动化与手动测试清单

### 8.1 自动化测试（每次改动均运行）

```bash
xcodebuild test -project Voxi.xcodeproj -scheme Voxi -destination 'platform=macOS'
```

至少覆盖：

- `RecordingState` 全部合法/非法转换、重复 stop、cancel 与迟到结果；
- 按住/切换模式的 keyDown/keyUp 映射；
- WAV header、16 kHz/mono/PCM16 数据长度、音频转换；
- HTTP multipart boundary、headers、form fields、响应与 HTTP 错误；
- URLSessionWebSocketTask 的 fake transport 生命周期；
- 火山帧 header、长度、序号、JSON/Gzip、最终包和错误帧；
- 新旧火山凭据模式不会混发 headers；
- 中间结果替换而非重复拼接；
- Keychain 存取；普通配置编码、日志与错误文本不包含 secret；
- 剪贴板原内容恢复、自动输入只发生一次。

### 8.2 每次候选发布进行的手动验证

1. TextEdit：录制中文、英文和中英混说，分别通过两种 provider 输入。
2. Notes 和浏览器文本框：快捷键不会误触当前应用快捷键，焦点位置收到最终文本。
3. Slack/Electron 与 VS Code：验证辅助功能/粘贴回退，记录不兼容控件。
4. 授权/拒绝麦克风、辅助功能、断网、服务超时、错误 API Key、错误火山 Resource ID。
5. 火山识别中取消、切换前台应用、松键事件异常；确认最后结果不会迟到写入别的应用。
6. 录音结束/失败后确认临时文件删除，待机状态不持续占用麦克风。
7. 自签名 Release 在 quarantine 环境执行首次启动和系统权限验证。

## 9. 风险与处理方式

| 风险 | 处理 |
| --- | --- |
| 自签名制品被 Gatekeeper 拦截 | 在计划中明确其非 Developer ID、非 notarized；先做干净环境实测，不能以开发机已信任证书作为验收 |
| 自签名证书改变导致 TCC 授权失效 | 固定 bundle ID 和证书私钥；禁止重建 identity；对升级做权限回归测试 |
| 火山协议或资源 ID 更新 | 以官方文档为依据，协议夹具记录版本；endpoint/resource 可配置；解析错误时展示 `X-Tt-Logid` |
| 流式返回全文和增量模式语义不同 | codec 归一为 interim/final 更新；全量中间文本替换预览，不盲目 append |
| 麦克风采样率与 ASR 格式不同 | AVAudioConverter 强制转 16 kHz mono PCM16LE，并用测试验证字节与时长 |
| 权限或焦点变化造成文字输入错误 | 输入前校验 session 与前台目标；不确定时保留文本供复制 |
| 自定义 HTTP header 泄露凭据 | 标注 secret 并放 Keychain；所有日志脱敏；禁止保存到普通配置 |

## 10. 已确认范围摘要

| 项目 | 决策 |
| --- | --- |
| 最低系统 | macOS 13 Ventura+ |
| ASR provider | OpenAI-compatible `v1/audio/transcriptions` + 火山引擎双向流式 WebSocket ASR |
| OpenAI-compatible 地址 | 用户配置完整 HTTP(S) endpoint；默认路径示例 `/v1/audio/transcriptions` |
| 火山 endpoint | 默认 `/api/v3/sauc/bigmodel_async`；Resource ID 和认证模式可配置 |
| 语言 | 简体中文、English |
| 文本处理 | ASR 参数和 prompt；不增加第二次模型调用 |
| 录音 | 按住说话或切换录音；火山实时发送分片，OpenAI-compatible 停止后上传完整音频 |
| 用户数据 | Keychain 凭据；临时音频；不保存历史，不要求 Voxi 账号 |
| 签名 | 本地持久自签名证书；不用 Developer ID，不做 notarization；Gatekeeper 首次安装必须实测 |

## 11. 首次执行顺序

按以下顺序开始，任一步的验收未通过前不要跳到下一步：

1. 执行 Phase 0.1 创建 Xcode project，并确认 `xcodebuild -list`；
2. 执行 Phase 0.2 生成自签名 identity，验证 app bundle code signature；
3. 执行 Phase 0.3–0.4 建立模型、测试、设置和菜单栏空壳；
4. 执行 Phase 1 完成本机权限、快捷键和音频文件验证；
5. 执行 Phase 2 先打通 HTTP provider 和 mock 测试；
6. 执行 Phase 3 独立完成火山协议 codec、fake transport、真实服务联调；
7. 执行 Phase 4 接通协调器、文本模式和跨 App 输入；
8. 执行 Phase 5 验证自签名制品在干净环境的启动与权限行为。
