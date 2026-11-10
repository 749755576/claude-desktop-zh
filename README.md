# claude-desktop-zh

**Full Simplified Chinese localization for Claude Desktop — 100% UI coverage**

[![Version](https://img.shields.io/badge/version-1.0.0-blue)](CHANGELOG.md)
[![Claude Desktop](https://img.shields.io/badge/Claude%20Desktop-4.x-7C3AED)](https://claude.ai/download)
[![UI Translation](https://img.shields.io/badge/UI%20translation-100%25%20(41771%20keys)-brightgreen)](#features)
[![Platform](https://img.shields.io/badge/platform-Windows%20%7C%20macOS-lightgrey)](#platform-support)
[![Runtime](https://img.shields.io/badge/runtime-Python%203.8%2B-informational)](#requirements)
[![License](https://img.shields.io/badge/license-CC%20BY--NC--SA%204.0-orange)](#license)

[简体中文](README.zh-CN.md) | **English**

*Unofficial localization · Not affiliated with Anthropic*

---

> [!IMPORTANT]
> Claude Desktop 4.x ships its UI and i18n resources inside `ion-dist.asar` and enforces
> an embedded SHA-256 integrity check in `claude.exe`. This project ships a patcher that
> handles both correctly — a naive "copy JSON files" approach will silently fail or
> produce a blank window on current builds.

## Features

- 🎯 **100% UI coverage** — all **41,771** interface strings translated to Simplified
  Chinese (verified against `i18n/en-US.json` of Claude Desktop 4.x)
- 🧩 **New-architecture ready** — unpacks `ion-dist.asar`, registers `zh-CN` in the
  renderer locale tables and the language picker, injects translation JSON, and repacks
  the archive with **regenerated per-file integrity blocks**
- 🔐 **Integrity-safe** — updates the SHA-256 header digest embedded in `claude.exe`
  so the app starts normally instead of silently refusing to launch
- 💾 **Non-destructive** — every original file is backed up to
  `%TEMP%\claude-zh-cn-backup` before patching; the uninstaller restores it
- 🤖 **Built-in AI translation pipeline** — regenerate the string template after any
  Claude update and re-translate the delta with any OpenAI-compatible API
- 🧰 **Zero heavy dependencies** — the asar tool uses only the Python standard library

## Requirements

| | |
|---|---|
| OS | Windows 10 / 11 (macOS: see [Platform support](#platform-support)) |
| Claude Desktop | installed, any recent 4.x build |
| Python | 3.8+ ([python.org](https://www.python.org/downloads/)) — standard library only |
| Privileges | Administrator (the installer will elevate via UAC) |

> Optional: an OpenAI-compatible API key, **only** if you want to re-translate strings
> after a Claude update. Installing the shipped translations requires no API at all.

## Quick start (Windows)

1. **Fully quit Claude Desktop** (including the tray icon).
2. Run **installer/install.bat** and click **Yes** on the UAC prompt.
3. Launch Claude, open **Settings → Language**, pick **简体中文**.

That's it. To roll back at any time, run **installer/uninstall.bat**.

### Command line

```powershell
powershell -ExecutionPolicy Bypass -File .\installer\install.ps1            # install
powershell -ExecutionPolicy Bypass -File .\installer\install.ps1 -Uninstall # restore backup
```

## Layout

```
installer/     install.ps1 + launchers (backup, patch, digest update, rollback)
tools/         asar_tool.py (asar extract/rebuild/integrity)
               translator.py (AI delta-translation pipeline + QA)
data/          zh-CN.json — the 41,771-key catalog (installer input)
               dynamic/ shell/ overrides/ — auxiliary catalogs
               template/ — English sources for the translation pipeline
```

## How it works

Modern Claude Desktop (4.x) no longer keeps web assets on disk as plain files — the
renderer, i18n JSON catalog and the locale tables all live inside `ion-dist.asar`, and
`claude.exe` refuses to start when the archive header does not match an embedded
SHA-256 digest.

The installer therefore performs, in order:

1. **Backup** — `ion-dist.asar` and `claude.exe` are copied to a temp backup folder.
2. **Extract** — `tools/asar_tool.py` unpacks the archive (pure pickle-format reader,
   standard library only).
3. **Patch** — `"zh-CN"` is registered in the renderer locale arrays and the language
   display map; `i18n/zh-CN.json` and `i18n/dynamic/zh-CN.json` are injected.
4. **Repack** — the archive is rebuilt with **fresh per-file SHA-256 integrity blocks**
   (`hash` + 4 MiB `blocks`), matching what `@electron/asar` would produce.
5. **Re-sign the digest** — the 64-character header hash embedded in `claude.exe` is
   replaced in place with the new archive's digest, so the embedded asar-integrity
   fuse passes and the app launches.
6. **Configure** — `config.json` locale is set to `zh-CN`; Claude restarts.

## After a Claude update

An update overwrites `claude.exe` and `ion-dist.asar`, so the patch disappears. To
regain 100% coverage on the new build:

```bash
# 1. Extract the new string template
python tools/asar_tool.py extract "<Claude>\app\resources\ion-dist.asar" work\extracted
#    → replace data/template/app-en-US.json with work\extracted\i18n\en-US.json
#    → replace data/template/dynamic-en-US.json with work\extracted\i18n\dynamic\en-US.json

# 2. Re-run the installer — it now patches the new layout end-to-end
```

Translations for keys that still exist are reused automatically; only the delta gets
translated.

### AI translation pipeline

```bash
copy .env.example .env          # then edit: base URL, API key, model
python tools/translator.py translate app --workers 4
python tools/translator.py check app       # QA: fallbacks, missing, placeholder balance
python tools/translator.py clean app       # drop keys removed by the new build
```

Works with any OpenAI-compatible endpoint (tested with Zhipu `glm-5.3-flash`).
The system prompt enforces one-to-one key mapping, placeholder preservation
(`{count}`, ICU plurals), and length proportionality.

> [!TIP]
> Mind your provider's rate limits. The retry logic skips failed batches instead of
> writing raw English into the catalog — just re-run to fill the gaps.

## Platform support

| Platform | Status | Notes |
|---|---|---|
| **Windows** 10/11 | ✅ Full support | asar patch + `claude.exe` digest update, tested end-to-end |
| **macOS** | ⚠️ Planned | `tools/asar_tool.py` is cross-platform; on macOS the asar digest lives in `Info.plist` (`ElectronAsarIntegrity`) and the bundle must be ad-hoc re-signed (`codesign --force --deep -s -`). Patches welcome. |

## FAQ

<details>
<summary><b>Claude shows a blank/white window after patching</b></summary>

The asar header digest or a per-file integrity block does not match. Always rebuild
with this repo's `tools/asar_tool.py` (it regenerates integrity for every file) and let the
installer update `claude.exe`. To recover immediately, run `installer/uninstall.bat` to
restore the backup.
</details>

<details>
<summary><b>Some parts of the UI are still English</b></summary>

Claude ships new strings with every release, and strings served from the server side
(experiment gates) can't be translated locally. Re-run the template + translation
pipeline after major updates.
</details>

<details>
<summary><b>Antivirus / SmartScreen flags the installer</b></summary>

Expected — the script takes ownership of files inside `C:\Program Files\WindowsApps`
and writes back patched binaries. It only touches Claude's own resources and restores
backups on failure. Review `installer/install.ps1` before running if in doubt.
</details>

<details>
<summary><b>Is this safe? Is it against Anthropic's ToS?</b></summary>

The patch modifies files on your own machine for personal accessibility use. It does
not touch Anthropic's services, accounts or network traffic. It is unofficial and
provided for personal study — use at your own discretion.
</details>

## Contributing

Issues and PRs are welcome:

- translation fixes — edit `data/zh-CN.json` (keys are opaque hashes; search by the
  English source in `data/template/app-en-US.json`)
- a tested macOS 4.x installer would be a highly appreciated contribution
- please run `python tools/translator.py check all` before submitting translation batches

## License

Distributed under [**CC BY-NC-SA 4.0**](https://creativecommons.org/licenses/by-nc-sa/4.0/)
— non-commercial, share-alike, with attribution. See [LICENSE](LICENSE) and [NOTICE](NOTICE).

> Unofficial project, not affiliated with Anthropic. For personal study only.
> Claude is a trademark of Anthropic.

---

<div align="center">

**如果对你有帮助，欢迎 Star ⭐**

</div>
