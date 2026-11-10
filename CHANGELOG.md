# Changelog

## 1.0.0 (2026-11-09)

First release.

### Highlights

- Full Simplified Chinese localization for Claude Desktop 4.x:
  **41,771 / 41,771** UI keys (100% coverage), AI-translated and QA-checked
- `tools/asar_tool.py`: pure standard-library asar tool (extract / header digest /
  patch / rebuild) with **per-file SHA-256 integrity block regeneration**,
  cross-checked against `@electron/asar` output (4820/4820 files byte-identical)
- Windows installer with automatic detection of the 4.x `ion-dist.asar` layout,
  end-to-end patching incl. in-place update of the `claude.exe` embedded header
  digest, automatic backup and rollback on failure
- Delta translation pipeline (`tools/translator.py`) for re-localizing new
  builds with any OpenAI-compatible API
