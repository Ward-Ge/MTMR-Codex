# MTMR-Codex 安装说明

MTMR-Codex 使用用户电脑上已有的 Codex 组件读取额度，不再把体积较大的
Codex App Server 内置进安装包。使用前需要安装并登录 Codex App、ChatGPT App
或 [Codex CLI](https://learn.chatgpt.com/docs/codex/cli)。不需要 Python、Xcode
或 LaunchAgent。

## 安装

1. 确认已安装并登录 Codex App、ChatGPT App 或 Codex CLI。
2. 从 GitHub Releases 下载 `MTMR-Codex-*-macOS-universal.dmg`。
3. 打开 DMG，把 `MTMR.app` 拖到 `Applications`。
4. 首次打开时，如果 macOS 阻止运行：
   - 打开“系统设置 → 隐私与安全性”；
   - 找到 MTMR，点击“仍要打开”。
5. 在“系统设置 → 隐私与安全性 → 辅助功能”中允许 MTMR。虚拟 Esc 依赖这项权限。
   如果升级后 Esc 无效，请先删除列表中的旧 MTMR，再重新添加
   `/Applications/MTMR.app`，随后退出并重新打开 MTMR。
6. 如果尚未登录，请先在 Codex App、ChatGPT App 或 Codex CLI 中完成登录。

MTMR 会使用 Codex 官方 App Server 登录流程，不读取或复制用户的 Token。
额度默认每 60 秒刷新一次，可在顶部系统菜单中按秒自定义刷新间隔；保存后会立即刷新。
如果到点时上一轮查询尚未结束，MTMR 会在查询结束后自动补刷，不再丢弃这一轮。
网络失败时保留上一次数据，并等待下一个刷新周期。
升级自旧版时，App 会识别并清理旧的 Python 刷新脚本和对应 LaunchAgent，
避免两个刷新器同时覆盖额度显示；其他用户配置不会被覆盖。

## 免费签名限制

本项目使用 ad-hoc 签名发布，因此首次打开需要手动确认。只有 Apple Developer
Program 的 Developer ID 签名和 Apple 公证才能移除这一步。由于免费签名会随
版本变化，升级安装包后，macOS 可能要求重新授予辅助功能权限。

## 本地打包

安装 Xcode 后，在项目根目录运行：

```bash
./scripts/package-free.sh
```

安装包生成在 `Release/`。
