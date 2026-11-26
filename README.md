# LuminaAI

一款轻量级、零依赖、原生 SwiftUI + AppKit 打造的 macOS 桌面 AI 助手，专注于替代全局划词与多模态截屏提问体验。

## 核心特性

- **全局划词悬浮胶囊**：在任意应用选中文字即可唤出翻译、解释、总结、追问浮窗，支持 SSE 流式输出、Markdown 富文本与代码块一键复制、默认折叠的深度思考（Thinking）过程展示。
- **全局快捷键截屏提问**：支持自定义任意组合快捷键，框选后可自由拖动选区与微调四边/四角尺寸，支持复制截图、本机 Vision 离线高精度 OCR、AI 翻译（支持自动检测与常用语种切换）及多模态 AI 提问。
- **按功能独立配置 API**：每个划词与截屏功能均可独立接入任意 OpenAI 兼容接口（默认适配火山方舟/豆包，也内置 OpenAI / DeepSeek 预设），支持一键复制 API 配置到其他功能、自定义预设提示词及 Thinking 强度开关。
- **近 7 天用量趋势与成本估算**：编辑风轻盈 Bento 仪表盘，支持多 API 平滑曲线对比、相对比例费用曲线与手动输入单价实时重算。
- **免重复授权更新与安全日志**：支持本机持久化代码签名证书（更新后保留辅助功能与屏幕录制授权），支持 GitHub Release 自动检查与静默重签更新，后台日志支持保留时长与最大行数限制及防刷屏限流。

## 隐私与安全

- 所有 API Key、个人配置与调用记录仅保存在本机 `~/Library/Application Support/LuminaAI/` 与 `~/Library/Logs/LuminaAI/` 中，**绝不写入代码仓库**。

## 从源码编译（仅需 Xcode Command Line Tools）

```bash
# （可选，推荐）首次创建本机持久化签名证书，以后每次编译/更新均无需重新授予系统权限
chmod +x setup_local_cert.sh && ./setup_local_cert.sh

# 编译并打包 LuminaAI.app
chmod +x build.sh && ./build.sh
```
