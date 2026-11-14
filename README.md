<div align="center">

<img alt="Voxi" src="./Voxi/Resources/Assets.xcassets/AppIcon.appiconset/icon_256.png" width="128">

# Voxi

**macOS 菜单栏语音输入 —— 自带语音识别与语言模型。**

[![Release](https://img.shields.io/github/v/release/sseaan/Voxi?logo=github&logoColor=white&labelColor=24292f&color=155eef)](https://github.com/sseaan/Voxi/releases)
[![Release build](https://img.shields.io/github/actions/workflow/status/sseaan/Voxi/release.yml?logo=github&logoColor=white&label=release&labelColor=7a5af8&color=9b8afb)](https://github.com/sseaan/Voxi/actions/workflows/release.yml)
![macOS](https://img.shields.io/badge/macOS-13%2B-000000?logo=apple&logoColor=white&labelColor=545759&color=1d1d1f)
![SwiftUI](https://img.shields.io/badge/SwiftUI-native-f05138?logo=swift&logoColor=white&labelColor=1d1d1f&color=f05138)
![XcodeGen](https://img.shields.io/badge/XcodeGen-project%20source-2f6fed?labelColor=545759&color=4078f2)
[![Last commit](https://img.shields.io/github/last-commit/sseaan/Voxi?logo=github&logoColor=white&labelColor=8098f9&color=444ce7)](https://github.com/sseaan/Voxi/commits/main)

</div>

> 按住快捷键说话，文字直接出现在光标处。Voxi 不提供账号，也不托管语音服务：你选择 ASR 端点、填自己的 Key，音频只发给这个端点；选择整理风格时，识别后的文本才会发给你配置的语言模型。

**适合你，如果：**
- 想用自己已有的 OpenAI-compatible 或火山引擎语音识别服务
- 希望 API Key 只留在本机 Keychain
- 需要中英文混合、长录音、按住/切换两种输入方式
- 想要“简单整理 / 清晰结构 / 正式表达”这类转写后处理

**不适合你，如果：**
- 需要 iPhone / iPad 客户端
- 想要开箱即用的托管服务或 Voxi 账号
- 希望完全离线、不配置任何模型

---

<details>
<summary><strong>目录</strong></summary>

- [功能](#功能)
- [安装](#安装)
- [快速开始](#快速开始)
- [从源码构建](#从源码构建)
- [架构](#架构)
- [数据与隐私](#数据与隐私)
- [文档](#文档)
- [版本与许可证](#版本与许可证)

</details>

---

## 功能

<details open>
<summary><strong>识别与回退</strong></summary>

- **两种 ASR**：OpenAI-compatible `v1/audio/transcriptions`（整段上传）与火山引擎豆包双向流式 WebSocket。
- **多来源、多模型**：一个来源可启用多个模型，按「来源顺序 × 模型顺序」自动回退；录音结束失败会用录制好的 WAV 重跑备用模型。
- **长录音/长文件**：火山单连接按 50 秒分段转写；8 秒超时误关连接的问题已修复。
- **音频文件转写**：菜单栏「转写音频…」，支持 mp3 / m4a / wav / aiff 等，结果可复制、插入或导出 TXT。
</details>

<details>
<summary><strong>整理与词库</strong></summary>

- **四种内置风格**：原文 / 简单整理 / 清晰结构 / 正式表达；卡片内含效果示例。
- **自定义提示词**：添加自己的整理指令，保存为卡片随时切换。
- **语言模型**：通用 OpenAI Chat Completions，以及 OpenCode Go 专用端点适配。
- **个人词库**：术语 + 常见误写；作为识别提示（OpenAI prompt / 火山热词），并在本地替换误写。
- **失败不丢文本**：语言模型不可用时自动使用原文，并明确提示。
</details>

<details>
<summary><strong>输入与系统集成</strong></summary>

- 菜单栏常驻，无 Dock 图标；按住说话或按下开始/再次按下结束。
- Fn / 右 Option 单键，或任意组合键；新安装默认右 Option。
- Dock 上方实时波形浮条；辅助功能写入光标，失败时回退剪贴板 + ⌘V 并恢复原剪贴板。
- 首次打开四页引导：权限、Keychain、快捷键、模型（可跳过）、登录启动。
- 登录时启动（SMAppService）、个人词库、看板统计。
</details>

---

## 安装

从 [GitHub Releases](https://github.com/sseaan/Voxi/releases) 下载 `Voxi.zip`。

| 项目 | 说明 |
|---|---|
| 系统 | macOS 13 Ventura 或更高 |
| 架构 | GitHub Actions 发布包为 universal（arm64 + x86_64） |
| 签名 | 本地发布使用自签名证书；CI 构建使用 ad-hoc 签名，均**未 notarize** |

首次启动可能被 Gatekeeper 拦截：

1. 解压后把 `Voxi.app` 拖入「应用程序」。
2. 在 Finder 中右键 `Voxi.app` → **打开** → 再次确认。
3. 如仍被拦截：系统设置 → 隐私与安全性 → 安全性 → **仍要打开**。
4. 只有确认来源和 SHA-256 后，才可仅对这个 App 移除隔离标记：

```bash
xattr -dr com.apple.quarantine /Applications/Voxi.app
```

不要关闭整机 Gatekeeper。发布页的 `manifest.txt` 提供 zip 和二进制 SHA-256。

---

## 快速开始

1. 启动 Voxi，完成首次引导：
   - 授予麦克风 / 辅助功能；
   - 测试 Keychain；
   - 确认快捷键（默认右 Option）；
   - 配置识别模型，或暂时跳过；
   - 选择是否登录时启动。
2. 打开 **设置 → 模型**：
   - 添加模型来源：OpenAI-compatible 或火山引擎；
   - 填 Endpoint、model、API Key；
   - 点「获取模型列表…」勾选多个模型，调整来源/模型顺序。
3. 可选：在 **设置 → 模型** 添加语言模型（通用 OpenAI / OpenCode Go），再到 **风格** 选择整理方式。
4. 把光标放到任意输入框，按快捷键说话，再按一次结束。结果会自动输入。

看板会记录口述时间、字数、次数和近 7 天趋势；只存计数，不存文本。

---

## 从源码构建

### 依赖

- macOS 13+
- Xcode 27.2（或能打开 objectVersion 77 工程的新版 Xcode）
- [XcodeGen](https://github.com/yonaskolb/XcodeGen)
- 自签名 identity：`Voxi Self-Signed Code Signing`（本地发布用）

```bash
git clone https://github.com/sseaan/Voxi.git
cd Voxi

# 首次本地发布时创建/确认自签名 identity
scripts/setup/create-local-signing-identity.sh

xcodegen generate
```

### 测试

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
xcodebuild test \
  -project Voxi.xcodeproj \
  -scheme Voxi \
  -destination 'platform=macOS' \
  -derivedDataPath build/DerivedData
```

当前基线：202 项通过（2 项真实服务测试默认跳过）。

真实服务联调：

```bash
VOLC_API_KEY=... \
OPENAI_API_KEY=... \
OPENAI_ENDPOINT=https://host/v1/audio/transcriptions \
scripts/dev/run-real-service-check.sh
```

### Release

```bash
xcodebuild build \
  -project Voxi.xcodeproj -scheme Voxi \
  -configuration Release -derivedDataPath build/DerivedData-release \
  CODE_SIGN_STYLE=Manual \
  CODE_SIGN_IDENTITY="Voxi Self-Signed Code Signing"

codesign --verify --deep --strict build/DerivedData-release/Build/Products/Release/Voxi.app
```

GitHub Actions（`.github/workflows/release.yml`）在推送 `v*` tag 时构建 universal Release，使用 ad-hoc 签名，生成 zip/manifest 并上传 GitHub Release。CI 没有本地自签名证书，因此 CI 产物的 TCC 授权与本地发布包不同。

> `project.yml` 是工程唯一源文件；增删文件后重新执行 `xcodegen generate`，不要手改 `project.pbxproj`。

---

## 架构

```text
快捷键 / 菜单 / 文件
        │
   AppCoordinator ── 状态机、session、前台 PID、回退
        │
  AudioCapture（AVAudioEngine → 16 kHz mono PCM16 + 临时 WAV）
        │
  ASR provider（OpenAI-compatible 上传 / 火山 WebSocket 流式）
        │
  个人词库替换 → 可选风格（语言模型）→ 标点/换行
        │
  Accessibility 写入 / 剪贴板 + ⌘V 回退
```

```
Voxi/
├── App/       入口、AppState、AppCoordinator
├── Models/    Codable 配置、风格、词库、用量统计
├── Services/  ASR/LLM provider、Keychain、音频、权限、快捷键、插入
├── Support/   菜单栏/设置/引导窗口、协议 codec、WAV/日志
├── UI/        设置页、看板、模型/风格/词库、录音浮条
├── Resources/ AppIcon
└── Info.plist
```

- 所有入口经过单一 `AppCoordinator`；异步结果写回前校验 session ID 与前台 PID。
- ASR 结果只在最终确认后输入；中间结果只用于菜单栏预览。
- `enabledModels` 为空时回落到单模型，旧配置无需迁移。
- 风格提示词只发给语言模型；ASR prompt / 火山 `corpus.context` 只承担识别提示与热词。

---

## 数据与隐私

- **密钥**：API Key、App/Access Key、secret header 只存 macOS Keychain；设置 JSON 只保存 item UUID。
- **音频**：只在一次识别流程内存在，临时 WAV 流程结束后删除；`VOXI_KEEP_RECORDINGS=1` 仅用于诊断。
- **看板**：只保存总时长、总字数、总次数和每日字数；不保存转写文本。
- **网络**：音频发给你配置的 ASR 端点；选择整理风格时，识别后的文本发给你配置的语言模型端点。
- **无账号、无遥测、无 Voxi 托管服务**。

更新构建后首次读取旧密钥时，macOS 可能要求登录密码；请选择「始终允许」。签名身份改变会导致麦克风/辅助功能重新授权。

---

## 文档

- [火山引擎 v3 协议夹具](docs/volcengine-protocol.md)
- [实施与变更记录](docs/status.md)
- [首次启动说明模板](packaging/README-FIRST-LAUNCH.txt)

---

## 版本与许可证

当前版本 `1.0.0`。版本说明见 [GitHub Releases](https://github.com/sseaan/Voxi/releases)。

个人项目，仓库暂未附开源许可证。
