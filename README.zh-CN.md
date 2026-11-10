<div align="center">

# claude-desktop-zh

**为 Claude Desktop 提供完整的简体中文本地化 — 100% 界面覆盖**

[![Version](https://img.shields.io/badge/version-1.0.0-blue)](CHANGELOG.md)
[![Claude Desktop](https://img.shields.io/badge/Claude%20Desktop-4.x-7C3AED)](https://claude.ai/download)
[![UI Translation](https://img.shields.io/badge/UI%20translation-100%25%20(41771%20%E6%9D%A1)-brightgreen)](#%E7%89%B9%E6%80%A7)
[![Platform](https://img.shields.io/badge/platform-Windows%20%7C%20macOS-lightgrey)](#%E5%B9%B3%E5%8F%B0%E6%94%AF%E6%8C%81)
[![Runtime](https://img.shields.io/badge/runtime-Python%203.8%2B-informational)](#%E7%8E%AF%E5%A2%83%E8%A6%81%E6%B1%82)
[![License](https://img.shields.io/badge/license-CC%20BY--NC--SA%204.0-orange)](#%E8%AE%B8%E5%8F%AF%E8%AF%81)

**简体中文** | [English](README.md)

*非官方本地化项目 · 与 Anthropic 无关*

</div>

---

> [!IMPORTANT]
> Claude Desktop 4.x 将界面与 i18n 资源打包进 `ion-dist.asar`，并在 `claude.exe`
> 中嵌入了 SHA-256 完整性校验。本项目自带补丁工具，已完整处理这两层机制——
> 简单粗暴的"复制 JSON 文件"方案在当前版本上要么静默失效，要么导致白屏。

## 特性

- 🎯 **100% 界面覆盖** — 全部 **41,771** 条界面文案均已翻译为简体中文
  （与 Claude Desktop 4.x 的 `i18n/en-US.json` 逐一比对核验）
- 🧩 **适配新架构** — 自动解包 `ion-dist.asar`，在渲染进程语言表与语言选择器中
  注册 `zh-CN`，注入翻译 JSON，并以**重新生成的分块完整性校验**重新打包
- 🔐 **完整性安全** — 原位更新 `claude.exe` 中内嵌的 SHA-256 头部摘要，
  确保应用正常启动而非静默拒绝运行
- 💾 **无损可回滚** — 补丁前自动备份原文件到 `%TEMP%\claude-zh-cn-backup`，
  卸载脚本一键还原
- 🤖 **内置 AI 翻译流水线** — Claude 更新后重新提取文案模板，调用任意
  OpenAI 兼容接口增量翻译
- 🧰 **零重依赖** — asar 工具仅使用 Python 标准库

## 环境要求

| | |
|---|---|
| 操作系统 | Windows 10 / 11（macOS 见[平台支持](#平台支持)） |
| Claude Desktop | 已安装，任意近期 4.x 版本 |
| Python | 3.8+（[python.org](https://www.python.org/downloads/)），仅标准库 |
| 权限 | 管理员（安装器会通过 UAC 自动提权） |

> 可选项：OpenAI 兼容 API Key，**仅**在 Claude 更新后需要增量翻译时使用。
> 安装本自带翻译完全不需要 API。

## 快速开始（Windows）

1. **完全退出 Claude Desktop**（包括托盘图标）。
2. 运行 **installer/install.bat**，在 UAC 弹窗中点击 **是**。
3. 启动 Claude，进入 **Settings → Language**，选择 **简体中文**。

完成。如需回滚，随时运行 **installer/uninstall.bat**。

### 命令行方式

```powershell
powershell -ExecutionPolicy Bypass -File .\installer\install.ps1            # 安装
powershell -ExecutionPolicy Bypass -File .\installer\install.ps1 -Uninstall # 还原备份
```

## 目录结构

```
installer/     install.ps1 + 启动器（备份、补丁、摘要更新、回滚）
tools/         asar_tool.py（asar 解包/重建/完整性）
               translator.py（AI 增量翻译流水线 + 质检）
data/          zh-CN.json — 41771 条主翻译目录（安装器输入）
               dynamic/ shell/ overrides/ — 辅助目录
               template/ — 翻译流水线用的英文原文模板
```

## 工作原理

新版 Claude Desktop（4.x）不再以散文件形式保存 Web 资源——渲染层、i18n JSON
目录和语言表全部打包在 `ion-dist.asar` 内，且当归档头部与 `claude.exe` 中
内嵌的 SHA-256 摘要不匹配时，应用会静默拒绝启动。

因此安装器按以下顺序执行：

1. **备份** — 将 `ion-dist.asar` 与 `claude.exe` 复制到临时备份目录。
2. **解包** — `tools/asar_tool.py` 解开归档（纯 pickle 格式解析，仅用标准库）。
3. **补丁** — 在渲染进程语言数组与语言名称映射表中注册 `"zh-CN"`；
   注入 `i18n/zh-CN.json` 与 `i18n/dynamic/zh-CN.json`。
4. **重打包** — 重建归档，并为每个文件**重新生成 SHA-256 分块完整性校验**
   （`hash` + 4 MiB `blocks`），与 `@electron/asar` 的产物保持一致。
5. **重签摘要** — 原位替换 `claude.exe` 中内嵌的 64 字符头部哈希，
   使 asar 完整性校验通过、应用正常启动。
6. **配置** — 将 `config.json` 的 locale 设为 `zh-CN`，重启 Claude。

## Claude 更新之后

版本更新会覆盖 `claude.exe` 与 `ion-dist.asar`，补丁随之失效。在新版本上
恢复 100% 覆盖：

```bash
# 1. 提取新版文案模板
python tools/asar_tool.py extract "<Claude>\app\resources\ion-dist.asar" work\extracted
#    用 work\extracted\i18n\en-US.json 覆盖 data/template/app-en-US.json
#    用 work\extracted\i18n\dynamic\en-US.json 覆盖 data/template/dynamic-en-US.json

# 2. 重新运行安装器 — 新版布局已端到端支持
```

仍然存在的旧 key 会自动复用已有翻译，只有增量部分需要重新翻译。

### AI 翻译流水线

```bash
copy .env.example .env          # 编辑：接口地址、API Key、模型名
python tools/translator.py translate app --workers 4
python tools/translator.py check app       # 质检：回退、缺失、占位符配平
python tools/translator.py clean app       # 清理新版已移除的 key
```

支持任意 OpenAI 兼容接口（已在智谱 `glm-5.3-flash` 上实测）。
系统提示词强制约束：key 一一对应、占位符原样保留（`{count}`、ICU 复数）、
译文长度与原文相称。

> [!TIP]
> 请留意接口商的速率限制。重试逻辑会跳过失败批次而不是把英文原文写进
> 翻译目录——重新运行一遍即可补齐缺口。

## 平台支持

| 平台 | 状态 | 说明 |
|---|---|---|
| **Windows** 10/11 | ✅ 完整支持 | asar 补丁 + `claude.exe` 摘要更新，已端到端实测 |
| **macOS** | ⚠️ 规划中 | `tools/asar_tool.py` 本身跨平台；macOS 上 asar 摘要保存在 `Info.plist`（`ElectronAsarIntegrity`），且修改后需要 ad-hoc 重签名（`codesign --force --deep -s -`）。欢迎 PR。 |

## 常见问题

<details>
<summary><b>打补丁后 Claude 白屏 / 空白窗口</b></summary>

asar 头部摘要或某个文件的完整性分块不匹配。请始终使用本仓库的
`tools/asar_tool.py` 重建（它会为每个文件重新生成 integrity），并让安装器同步
更新 `claude.exe`。紧急恢复：运行 installer/uninstall.bat 还原备份。
</details>

<details>
<summary><b>界面有部分地方仍是英文</b></summary>

Claude 每个版本都会新增文案，且服务端下发的实验文案无法本地翻译。
大版本更新后请重新执行模板提取 + 翻译流水线。
</details>

<details>
<summary><b>杀毒软件 / SmartScreen 拦截安装器</b></summary>

属正常现象——脚本会对 `C:\Program Files\WindowsApps` 内的文件取得所有权
并回写补丁后的二进制。它只修改 Claude 自身资源，失败时会还原备份。
如不放心，可先审阅 `installer/install.ps1` 源码再运行。
</details>

<details>
<summary><b>安全吗？违反 Anthropic 服务条款吗？</b></summary>

补丁只修改你自己电脑上的文件，用于个人无障碍使用，不接触 Anthropic 的
服务、账号或网络流量。项目非官方，仅供个人学习，请自行斟酌使用。
</details>

## 参与贡献

欢迎 Issue 与 PR：

- 翻译修正 — 直接编辑 `data/zh-CN.json`（key 是哈希值，
  可在 `data/template/app-en-US.json` 中按英文原文检索）
- 经过实测的 macOS 4.x 安装器是最受欢迎的贡献
- 提交翻译批次前请先运行 `python tools/translator.py check all`

## 许可证

本项目基于 [**CC BY-NC-SA 4.0**](https://creativecommons.org/licenses/by-nc-sa/4.0/)
协议发布——非商业、相同方式共享、需署名。详见 [LICENSE](LICENSE) 与 [NOTICE](NOTICE)。

> 非官方项目，与 Anthropic 无关，仅供个人学习。 Claude 是 Anthropic 的商标。

---

<div align="center">

**如果对你有帮助，欢迎 Star ⭐**

</div>
