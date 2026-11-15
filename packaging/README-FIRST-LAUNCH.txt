Voxi 首次启动说明
=================

1. 先核对制品完整性：把下载的 DMG 的 SHA-256 与发布页/manifest.txt 中记录的值比较
   （macOS 上执行：shasum -a 256 Voxi-<版本>.dmg）。

2. 双击打开 DMG，把 Voxi 拖到 Applications（应用程序）文件夹。

3. 首次打开可能被 Gatekeeper 拦截：
   - 在 Finder 的“应用程序”里右键 Voxi → 打开 → 再次确认；
   - 如仍被拦截：系统设置 → 隐私与安全性 → 安全性 → “仍要打开”。

4. 只有确认来源与 SHA-256 后，才可仅对这个 App 移除隔离标记：
   xattr -dr com.apple.quarantine /Applications/Voxi.app

不要关闭整机 Gatekeeper。

5. 启动后按引导授予麦克风 / 辅助功能权限、确认快捷键、配置语音识别模型
   （也可暂时跳过，稍后在设置中完成）。

6. 识别历史默认保存在本机：设置 → 历史记录 可搜索、清空或关闭。

说明：CI 构建使用 ad-hoc 签名、未 notarize；TCC 授权可能与本地自签名版本不同。
