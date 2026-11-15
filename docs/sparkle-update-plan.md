# 更新方案评估（Sparkle vs 自研）

> 结论：**当前阶段使用自研轻量检查更新**（GitHub Releases API + DMG 下载页），
> 不引入 Sparkle。等分发方式变化（Developer ID + notarize、Homebrew Cask 正式化）后再评估迁移。

## 现状约束

| 约束 | 现状 |
| --- | --- |
| 分发 | GitHub Releases，本地 Release 用自签名证书，CI 用 ad-hoc 签名，**未 notarize** |
| 安装方式 | 手动下载 → 拖入“应用程序” |
| 工程依赖 | 无第三方框架，XcodeGen 生成工程，`project.yml` 是唯一源文件 |
| 安全模型 | API Key 只存 Keychain；不托管服务；最小依赖 |
| 更新入口 | 菜单「检查更新…」（第 8 项）与设置 → 关于 |

## 方案对比

### A. 自研轻量检查（当前实现）

- 数据源：`GET https://api.github.com/repos/sseaan/Voxi/releases/latest`
- 比对 `tag_name` 与 `CFBundleShortVersionString`，发现新版本弹窗提示，按钮打开 DMG / 发布页。
- 优点：零依赖、零签名密钥管理、实现约 200 行、可单元测试（注入 `URLSession`）。
- 缺点：不自动下载安装；GitHub API 未认证限流 60 次/小时（手动检查足够）。

### B. Sparkle 2

- 优点：自动下载、EdDSA 校验、增量更新、后台静默更新，生态成熟。
- 代价：
  1. SPM 依赖 + XcodeGen `packages` 配置，构建脚本与 CI 都要改；
  2. 需要 **EdDSA 私钥**（`generate_keys`），私钥放 CI secret，公钥进 Info.plist；
  3. 需要 `appcast.xml` 生成与托管（GitHub Pages / Releases 附件），每个版本都要签名更新条目；
  4. ad-hoc / 自签名 + 未 notarize 的包自动替换后，Gatekeeper 与 TCC（辅助功能/麦克风）可能重新弹权限；
  5. Sparkle 的 `SUFeedURL`、`SUPublicEDKey`、XPC 服务、`Installer` 权限模型都需要额外审计；
  6. 与「最小依赖、可审阅」的项目定位冲突。
- 迁移成本估算：1–2 天（含 CI appcast、签名、自动替换回归）。

### C. Homebrew Cask

- 优点：`brew upgrade --cask voxi` 一条命令；适合开发者用户。
- 代价：需要维护 cask 仓库/PR；未 notarize 的包会被 Gatekeeper 拦截；普通用户仍要手动下载。
- 定位：作为**补充渠道**而不是替代。

## 决策

1. 现阶段采用 **A**：
   - `UpdateChecker`（纯逻辑，可测）+ `UpdateController`（NSAlert 交互）。
   - 版本比较支持 `v` 前缀、预发布后缀（`1.1.0-beta` < `1.1.0`）。
   - 失败时提示可在浏览器打开 Releases 页面，不阻塞主流程。
2. 触发时机：
   - 菜单「检查更新…」；
   - 设置 → 关于 →「检查更新…」。
   - 不做启动静默检查，避免额外网络请求与未认证 API 限流。
3. CI 发布产物统一提供 **DMG**（`Voxi-<version>.dmg`），自研更新直接打开 DMG 下载链接。
4. 何时重新评估 Sparkle：
   - 引入 Developer ID 签名 + notarization；
   - 发布节奏稳定（每周/双周）；
   - 用户量达到需要静默更新的规模；
   - 有 CI secret 管理方案（EdDSA 私钥轮换、备份）。

## 安全注意

- 自研更新只做「提示 + 打开官方链接」，不自动执行下载的二进制，避免引入未签名代码执行路径。
- 所有下载链接固定为 `github.com/sseaan/Voxi`，不在运行时接受任意 URL。
- 若未来集成 Sparkle，必须开启 EdDSA 校验并禁用 `SUAllowsInsecureUpdates`。
