<div align="center">
  <img src="docs/assets/icon.png" width="112" height="112" alt="LuminaAI Icon" />
  <h1>LuminaAI</h1>
  <p><strong>Not another AI chat window — a mouse- &amp; keyboard-integrated native macOS AI utility.</strong></p>
  <p><em>Highlight text with your mouse. Trigger screenshot AI with a custom hotkey or mouse macro. Zero app switching.</em></p>

  <p>
    <img src="https://img.shields.io/badge/macOS-14.0%2B-1D1E20?style=flat-square&logo=apple&logoColor=white" alt="macOS 14+" />
    <img src="https://img.shields.io/badge/Apple%20Silicon-arm64-222326?style=flat-square" alt="Apple Silicon" />
    <img src="https://img.shields.io/badge/Swift-100%25%20Native-F05138?style=flat-square&logo=swift&logoColor=white" alt="Pure Swift" />
    <img src="https://img.shields.io/badge/Binary-~2.6%20MB-34A853?style=flat-square" alt="2.6 MB Binary" />
    <img src="https://img.shields.io/badge/Idle%20CPU-~0.0%25-4A78B8?style=flat-square" alt="0% Idle CPU" />
    <img src="https://img.shields.io/badge/License-MIT-C59B5F?style=flat-square" alt="MIT License" />
  </p>

  <p>
    <a href="#mouse-first--macro-ready-workflow">Mouse &amp; Macro Workflow</a> &nbsp;·&nbsp;
    <a href="#core-capabilities">Core Capabilities</a> &nbsp;·&nbsp;
    <a href="#quick-start">Quick Start</a> &nbsp;·&nbsp;
    <a href="#中文介绍">中文介绍</a>
  </p>
</div>

---

<div align="center">
  <img src="docs/assets/dashboard.png" width="880" alt="LuminaAI macOS Dashboard Screenshot" />
  <br />
  <sub><em>LuminaAI Control Center — Per-feature API routing, 7-day multi-API usage curves, and real-time cost estimator.</em></sub>
</div>

<br />

## What Makes LuminaAI Different?

Most AI desktop apps are heavy Electron wrappers around a web chat box that force you to `⌘Tab` away from your work, copy-paste context, and wait.

**LuminaAI is NOT a generic chatbot window.** It is a **system-wide, mouse- and keyboard-integrated macOS productivity suite** built from scratch in pure **Swift + AppKit + SwiftUI** (~3 MB binary, ~20–30 MB idle RAM, ~0.0% idle CPU). It stays invisible in your menu bar and brings four zero-context-switch native tools directly to your cursor:

1. **Global Text-Selection AI (划词 AI)** — Drag-select or double-click text in *any* macOS app to summon a draggable floating capsule right beside your cursor.
2. **Global Screenshot & Multimodal Vision AI (截屏 AI)** — Press your custom shortcut (or click a **mouse side button**) to capture any screen region for offline OCR, AI OCR, image translation, or visual Q&A.
3. **Frosted-Glass Radial Menu (快捷轮盘)** — Hold a dedicated hotkey or mouse macro to pop open a translucent glass bubble ring around your cursor; slide to any slot and release to launch/switch apps or send custom shortcuts without breaking focus.
4. **Minimalist Clipboard History (剪贴板历史)** — Press your shortcut (default `⌥V`) to summon a restrained light-glass clipboard history supporting plain text, native rich text (links, colors, inline images), and image thumbnails with one-click rich/plain paste switching.

---

## Mouse-First & Macro-Ready Workflow

LuminaAI is engineered to integrate deeply with **custom keyboard shortcuts and mouse macros** (Logitech Options+ / MX Master, Razer Synapse, SteerMouse, BetterTouchTool, LinearMouse, etc.):

- **Pure Mouse-Only AI Operation**:
  - **Text Selection**: Simply highlight text with your left mouse button → floating capsule appears right at your cursor → click **Copy / Translate / Explain / Summarize / Ask** (and drag the capsule by its border if it overlaps an app's built-in toolbar).
  - **Screenshot AI via Mouse Side Button**: Bind LuminaAI's unrestricted custom global hotkey (supports any single F-key like `F1–F12` or any multi-modifier combo like `⌘⌥⇧A`) to a **mouse side button / thumb button macro**. One click of your thumb launches interactive screenshot capture — letting you invoke **every single AI feature using only your mouse**.
- **Never Steals Focus or Raises the Main Window**: Floating capsules and reply panels run as native chromeless macOS `NSPanel` windows (`.nonactivatingPanel`) with native 4-edge/4-corner resizing, click-outside auto-dismiss, and a **Pin** toggle — your workflow stays completely uninterrupted.

---

## Core Capabilities

### 1. Global Text-Selection AI (`划词`)
- **Draggable Floating Capsule**: Appears near your cursor upon selecting text in any app. Customize which actions appear and reorder them in Settings.
- **Smart / Force Copy**: Tries standard `⌘C` first; on webpages that block copying via JS `oncopy` / `preventDefault()`, automatically falls back to macOS Accessibility tree extraction to copy cleanly with an unobtrusive HUD toast.
- **Rich Floating Reply Panel**:
  - Live SSE streaming with **Markdown rich text, headings, lists, code blocks (with 1-click Copy), emojis, and native Markdown tables**.
  - **Translation Language Bar**: Quick source (`Auto-Detect`, Chinese, English, Japanese, Korean, French, German, Spanish) → target language switcher with 1-click re-translate.
  - **Collapsible Thinking Process**: Displays streaming reasoning tokens collapsed by default.

### 2. Global Screenshot & Multimodal Vision AI (`截屏`)
- **Flexible Post-Capture Adjustment**: Crisp black crosshair cursor, dimmed vignette overlay, and after releasing the mouse you can still **freely drag to move** or **resize any of the 4 edges & 4 corners** of the selection.
- **Four Instant Actions**:
  - **Copy Screenshot** to clipboard
  - **Extract Text (OCR)**: Uses on-device Apple **Vision** offline OCR (fast & free) by default, plus a one-click **"AI 提取"** button inside the popup header to re-extract with your multimodal LLM on demand
  - **AI Image Translation**: Translate text directly inside images with language selection
  - **Multimodal AI Q&A**: Ask questions about code errors, charts, UI designs, or documents with quick prompt chips

### 3. Frosted-Glass Radial Menu (`快捷轮盘`)
- **Hold-to-Show, Release-to-Trigger**: Hold your dedicated hotkey (default `⌥R`, compatible with F-keys, multi-modifier combos & mouse side-button macros) to open a bright translucent frosted-glass bubble ring (`NSVisualEffectView`) around your cursor. Slide onto a bubble and release to execute; release in the center hub to cancel.
- **Flexible Slot Actions & Icons**: Add, delete, and reorder slots freely. Bind each slot to either **Launch / Switch Application** or **Simulate Custom Shortcut** (`CGEvent`, zero focus interruption). Supports **native App icons** (independently selectable even for shortcut slots), **SF Symbols**, and **custom local images**.

### 4. Minimalist Light-Glass Clipboard History (`剪贴板历史`)
- **Zero-Clutter Native Glass Popup**: Trigger with `⌥V` (customizable) to summon a restrained light-glass panel right by your cursor. Navigate with mouse or `↑↓` + `Enter`, click outside to dismiss, or pin on top while still pasting directly into your foreground app.
- **Plain Text, Native Rich Text & Images**: Deduplicates via SHA256; renders true AppKit rich text (preserving colors, blue links, bold/italic, and inline logos while clamping max font size `≤15pt` and auto-folding long items at 4 lines with Expand/Collapse); caches image thumbnails on disk.
- **Dual Rich/Plain Paste & Storage Quotas**: Configure default paste mode (Rich Text vs Plain Text) with a hover-only one-off toggle (`切换为纯文本粘贴` / `切换为富文本粘贴`), plus configurable max item count (up to 500) and MB storage limit.

### 5. Per-Feature API Routing, Thinking Budgets & Analytics
- **Independent API per Feature**: Route each of the 7 text/vision features to different OpenAI-compatible providers (Volcengine Ark / Doubao, SiliconFlow, OpenAI, DeepSeek, or third-party relays like PackCode / OneAPI / NewAPI), with **1-click Copy API Config to other features** and **1-click Connectivity Test** (including real vision image probes).
- **Real Thinking Effort Control**: Supports Low / Medium / High thinking budgets across model families (`thinking_budget` for Qwen3 / SiliconFlow / DashScope, `budget_tokens` for Claude / Doubao, `reasoning_effort` for OpenAI / Gemini), plus per-feature **Preset System Prompts**.
- **7-Day Multi-API Usage & Cost Dashboard**: Smooth Bezier spline curves for Calls, Tokens, and relative proportional Cost with manual per-1M-token pricing.

### 6. Lightweight Native macOS Engineering
- **Ultra-Light Footprint**: ~2.6 MB native `arm64` binary, ~20–30 MB idle RAM (releases dashboard SwiftUI view tree when closed), ~0.0% idle CPU (zero drag-event polling).
- **Permission-Preserving Updates**: Built-in GitHub auto-updater with multi-version changelog + local persistent certificate signing (`setup_local_cert.sh`) so macOS Accessibility & Screen Recording permissions survive updates without re-authorizing.
- **Quality of Life**: Dock / Menu Bar presence toggle, optional **Launch at Login**, and rate-limited background logs (`1 Day / 1 Week / 1 Month` retention & line cap).

---

## Quick Start

> **Download**: Grab the latest `LuminaAI-v*.zip` from [**GitHub Releases**](https://github.com/oswin-creator/LuminaAI/releases/latest) (Apple Silicon / macOS 14.0+).

### Build from Source (Only Xcode Command Line Tools Required)

```bash
git clone https://github.com/oswin-creator/LuminaAI.git
cd LuminaAI

# 1. (Recommended) Create a local persistent signing certificate once so macOS preserves permissions across updates
chmod +x setup_local_cert.sh && ./setup_local_cert.sh

# 2. Compile & bundle LuminaAI.app
chmod +x build.sh && ./build.sh
```

> **Privacy First**: All API keys, prompts, usage records, and logs are stored strictly locally in `~/Library/Application Support/LuminaAI/` and `~/Library/Logs/LuminaAI/`. Requests go directly from your Mac to your configured API endpoints.

---

## 中文介绍

**LuminaAI 并不是一个普通的聊天 AI 窗口**，而是一款**与鼠标和键盘高度集成的原生 macOS 系统级 AI 效率工具**（纯 Swift + AppKit + SwiftUI 编写，体积仅 **~2.6 MB**，后台常驻内存仅 **~20–30 MB**，空闲 CPU 趋近 **0%**）。

### 为什么适合「鼠标党」与效率玩家？
- **只用鼠标就能调用全部功能**：
  1. **全局划词 AI**：在任意软件中用鼠标拖选或双击文字，光标旁立刻弹出可拖动悬浮胶囊，一键触发 **复制（含网页强力复制）/ 翻译 / 解释 / 总结 / 追问**，支持自定义按钮显示与排序，无需切换窗口。
  2. **全局截屏 AI + 鼠标宏无缝联动**：支持自由录制任意自定义全局快捷键（支持 `F1–F12` 单键或任意多修饰键组合），你可以直接将其绑定到 **罗技 MX Master / 雷蛇 / BetterTouchTool 等鼠标侧键宏** 上——大拇指一按即可框选截屏（松手后仍可自由平移与四边/四角微调），一键完成 **复制截图 / 离线 Vision OCR + 单次大模型 AI 提取 / 截图 AI 翻译 / 多模态识图提问**。
  3. **亮色毛玻璃快捷轮盘（Radial Menu）**：按住专属快捷键（默认 `⌥R`，兼容鼠标侧键宏）在鼠标四周呼出亮色半透明毛玻璃气泡圆环，滑动选中槽位松手即触发，中心区域松手取消；支持绑定 **打开/切换应用** 与 **无焦点模拟快捷键**，支持应用原生图标（快捷键槽位也可独立选任意 App 图标）、系统符号与自定义图片。
  4. **极简亮色玻璃剪贴板历史（Clipboard History）**：按下快捷键（默认 `⌥V`）在光标旁呼出克制极简的毛玻璃浮窗，支持纯文本、原生富文本（保留颜色/蓝链/加粗/内嵌图标，自动限字号与 4 行折叠）与图片缩略图；支持默认富文本/纯文本粘贴及悬停单次切换、置顶固定粘贴与条数/MB 级磁盘上限管理。
- **不打断工作流的原生交互**：流式回复浮窗支持 **Markdown 富文本、原生表格、代码块一键复制、默认折叠深度思考过程**，支持四边四角原生缩放、点击外部自动关闭与右上角图钉固定，且绝不把主控制台窗口弹到前面。
- **7 大功能独立配置 API 与思考强度**：支持为每个划词/截屏功能单独接入火山方舟/豆包、硅基流动、OpenAI、DeepSeek 及各类第三方中转站，支持一键复制 API 配置、一键测试连通性（含视觉探针）、自定义预设提示词与思考强度预算（低/中/高）。
- **近 7 天用量曲线 & 免重新授权自动更新**：内置编辑风 7 天多 API 曲线与手动单价成本核算；支持 Dock/菜单栏自由切换、开机自启、日志限流清理，以及内置 GitHub 一键更新（本地证书自动重签，更新后无需重新授予辅助功能与屏幕录制权限）。

---

## License

Released under the [MIT License](LICENSE).
