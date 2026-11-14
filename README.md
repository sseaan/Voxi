# Voxi

纯 macOS 菜单栏语音输入工具：按住快捷键说话，识别结果会自动整理并输入到当前光标位置。

Voxi 不提供账号或托管服务。语音识别、语言模型都由使用者自行配置，密钥只保存在本机 Keychain。

## 功能

- 两种语音识别来源
  - OpenAI-compatible `v1/audio/transcriptions`（整段上传）
  - 火山引擎豆包双向流式 WebSocket ASR
- 一个来源可启用多个模型；按“来源顺序 × 模型顺序”自动回退
- 语音识别后可选整理风格
  - 原文 / 简单整理 / 清晰结构 / 正式表达
  - 自定义提示词
- 通用 OpenAI Chat Completions 与 OpenCode Go 语言模型接入
- 个人词库：术语 + 常见误写；作为识别提示并在本地替换
- 音频文件转写（mp3 / m4a / wav / aiff 等）与导出 TXT
- 按住说话 / 按下开始两种录音方式
- Fn / 右 Option 单键或任意组合键
- 首次打开四页引导、登录时启动、Dock 上方实时波形浮条

## 系统要求

- macOS 13 Ventura 或更高
- 构建需要 Xcode 27.2、[XcodeGen](https://github.com/yonaskolb/XcodeGen)

## 构建

```bash
xcodegen generate

DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
xcodebuild build \
  -project Voxi.xcodeproj \
  -scheme Voxi \
  -configuration Debug \
  -derivedDataPath build/DerivedData
```

测试：

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
xcodebuild test \
  -project Voxi.xcodeproj \
  -scheme Voxi \
  -destination 'platform=macOS' \
  -derivedDataPath build/DerivedData
```

## 签名与分发

本项目使用本地自签名 identity（默认名称 `Voxi Self-Signed Code Signing`），**不是** Apple Developer ID，**未**经过 notarization。

- 首次生成 identity：`scripts/setup/create-local-signing-identity.sh`
- 发布包为 `dist/Voxi.zip`，带 SHA-256 清单
- 从网络下载的构建可能被 Gatekeeper 拦截；请按发布包中的首次启动说明操作
- 不要通过关闭整机 Gatekeeper 来解决

## 隐私

- 不保存录音和转写历史
- API Key / Access Key 只存 macOS Keychain，不写入 UserDefaults 或仓库
- 音频发送到使用者配置的 ASR 端点
- 若选择整理风格，识别后的**文本**会发送到使用者配置的语言模型端点
- 临时 WAV 在录音流程结束后删除

## 开发

- 工程配置以 `project.yml` 为准；增删文件后重新运行 `xcodegen generate`
- 协议说明见 `docs/volcengine-protocol.md`
- 历史变更记录见 `docs/status.md`

## 状态

个人项目，持续迭代中。当前版本 `0.1.0`，自动化测试 195 项通过（2 项真实服务测试默认跳过）。
