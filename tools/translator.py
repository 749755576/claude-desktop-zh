#!/usr/bin/env python3
"""translator.py — delta translation tool for the Claude Desktop zh-CN catalogs.

Datasets (template -> output):
  app      data/template/app-en-US.json     -> data/zh-CN.json
  dynamic  data/template/dynamic-en-US.json -> data/dynamic/zh-CN.json
  shell    data/template/shell-en-US.json   -> data/shell/zh-CN.json

Usage:
  python translator.py translate app     [--workers 4] [--batch-size 250]
  python translator.py translate dynamic
  python translator.py check app | dynamic | shell | all
  python translator.py clean  app | dynamic | shell | all

Configuration (.env at repo root, see .env.example):
  OPENAI_BASE_URL / OPENAI_API_KEY / OPENAI_MODEL   (any OpenAI-compatible endpoint)

Notes:
  - Only keys missing from the output file are submitted; existing work is kept.
  - Batches that fail after retries are skipped (never filled with source text);
    re-run the same command to fill the gaps.
  - The prompt enforces key parity, placeholder preservation and length proportion.
"""
from __future__ import annotations

import json
import os
import sys
import threading
import time
from concurrent.futures import ThreadPoolExecutor, as_completed
from pathlib import Path

try:
    from openai import OpenAI
except ImportError:
    sys.exit("missing dependency: pip install openai")

ROOT = Path(__file__).resolve().parent.parent
DATA = ROOT / "data"
TEMPLATE_DIR = DATA / "template"
BATCH_SIZE = 250
DEFAULT_WORKERS = 4
BLOCK_SIZE = 4_194_304

DATASETS = {
    "app": {
        "template": TEMPLATE_DIR / "app-en-US.json",
        "output": DATA / "zh-CN.json",
    },
    "dynamic": {
        "template": TEMPLATE_DIR / "dynamic-en-US.json",
        "output": DATA / "dynamic" / "zh-CN.json",
    },
    "shell": {
        "template": TEMPLATE_DIR / "shell-en-US.json",
        "output": DATA / "shell" / "zh-CN.json",
    },
}

SYSTEM_PROMPT = (
    "You are a professional software localization translator for the Claude Desktop "
    "application (Anthropic's AI desktop client). Translate UI strings from English "
    "to Simplified Chinese.\n\n"
    "Rules (violating any of these is a failure):\n"
    "1. Key parity: output JSON must contain exactly the same key set as the input; "
    "each value is the translation of that key's own source string only.\n"
    "2. Placeholders stay untouched, byte for byte: {name}, {count}, ICU plurals such "
    "as {n, plural, one {...} other {...}}, <tags>, URLs, and escaped sequences.\n"
    "3. Length proportion: single words stay short, sentences stay sentences.\n"
    "4. Faithful content; no additions, no key shifts.\n"
    "5. Use standard software terminology; keep brand names (Claude, MCP, API) as-is.\n"
    "6. Output strict JSON, nothing else."
)


def load_env() -> None:
    """Minimal .env loader (no external dependency)."""
    env_file = ROOT / ".env"
    if not env_file.exists():
        return
    for line in env_file.read_text(encoding="utf-8").splitlines():
        line = line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, _, value = line.partition("=")
        os.environ.setdefault(key.strip(), value.strip().strip('"'))


def say(msg: str) -> None:
    print(msg, flush=True)


def load_json(path: Path) -> dict:
    if not path.exists():
        return {}
    return json.loads(path.read_text(encoding="utf-8"))


def save_json(path: Path, data: dict) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("w", encoding="utf-8") as f:
        json.dump(data, f, ensure_ascii=False, indent=2, sort_keys=True)
        f.write("\n")


def make_client() -> tuple:
    base_url = os.environ.get("OPENAI_BASE_URL")
    api_key = os.environ.get("OPENAI_API_KEY")
    model = os.environ.get("OPENAI_MODEL", "glm-4-flash")
    if not base_url or not api_key:
        sys.exit("error: set OPENAI_BASE_URL / OPENAI_API_KEY in .env (see .env.example)")
    return OpenAI(base_url=base_url, api_key=api_key), model


def translate_batch(client, model: str, batch: dict, label: str) -> dict:
    payload = json.dumps(batch, ensure_ascii=False)
    for attempt in range(3):
        t0 = time.time()
        try:
            resp = client.chat.completions.create(
                model=model,
                messages=[
                    {"role": "system", "content": SYSTEM_PROMPT},
                    {"role": "user", "content": payload},
                ],
                temperature=0.2,
                response_format={"type": "json_object"},
            )
            result = json.loads(resp.choices[0].message.content or "")
            return {k: result[k] for k in batch if k in result and isinstance(result[k], str)}
        except Exception as exc:  # noqa: BLE001
            elapsed = time.time() - t0
            if attempt == 2:
                say(f"  [{label}] batch failed, skipped for retry later: {exc}")
                return {}
            wait = 10 * (attempt + 1)
            say(f"  [{label}] retry {attempt + 1}/3 after {wait}s ({elapsed:.1f}s): {str(exc)[:120]}")
            time.sleep(wait)
    return {}


def run(client, model: str, dataset: str, workers: int, batch_size: int) -> None:
    cfg = DATASETS[dataset]
    template = load_json(cfg["template"])
    output = load_json(cfg["output"])
    pending = {k: v for k, v in template.items()
               if k not in output or not isinstance(output.get(k), str) or not output[k].strip()}
    if not pending:
        say(f"[{dataset}] nothing to translate ({len(template)} keys)")
        return

    keys = list(pending)
    batches = [keys[i:i + batch_size] for i in range(0, len(keys), batch_size)]
    say(f"[{dataset}] pending {len(pending)}/{len(template)} keys -> {len(batches)} batches, {workers} workers")
    lock = threading.Lock()
    done = 0

    def submit(batch_keys):
        nonlocal done
        batch = {k: pending[k] for k in batch_keys}
        translated = translate_batch(client, model, batch, f"{dataset}")
        if translated:
            with lock:
                current = load_json(cfg["output"])
                current.update(translated)
                save_json(cfg["output"], current)
                done += len(translated)
                say(f"  [{dataset}] progress {done}/{len(pending)}")

    with ThreadPoolExecutor(max_workers=workers) as pool:
        futures = [pool.submit(submit, b) for b in batches]
        for f in as_completed(futures):
            f.result()
    say(f"[{dataset}] done")


def check(dataset: str) -> None:
    cfg = DATASETS[dataset]
    template = load_json(cfg["template"])
    output = load_json(cfg["output"])
    missing = [k for k in template if k not in output]
    fallback = [k for k in template if k in output and output[k] == template[k]]
    empty = [k for k in template if k in output and not str(output[k]).strip()]
    bad_ph = []
    for k, src in template.items():
        if k not in output:
            continue
        if src.count("{") != str(output[k]).count("{") or src.count("}") != str(output[k]).count("}"):
            bad_ph.append(k)
    print(f"[{dataset}] template={len(template)} output={len(output)} "
          f"missing={len(missing)} fallback={len(fallback)} empty={len(empty)} placeholder={len(bad_ph)}")
    if missing:
        print(f"  -> run: python translator.py translate {dataset}")


def clean(dataset: str) -> None:
    cfg = DATASETS[dataset]
    template = load_json(cfg["template"])
    output = load_json(cfg["output"])
    kept = {k: v for k, v in output.items() if k in template}
    removed = len(output) - len(kept)
    save_json(cfg["output"], kept)
    print(f"[{dataset}] kept {len(kept)}, removed {removed} stale keys")


def main() -> None:
    load_env()
    args = sys.argv[1:]
    if not args:
        print(__doc__)
        sys.exit(1)

    workers = DEFAULT_WORKERS
    batch_size = BATCH_SIZE
    if "--workers" in args:
        i = args.index("--workers"); workers = int(args[i + 1]); del args[i:i + 2]
    if "--batch-size" in args:
        i = args.index("--batch-size"); batch_size = int(args[i + 1]); del args[i:i + 2]

    cmd = args[0].lower()
    if cmd == "translate":
        if len(args) < 2 or args[1] not in DATASETS:
            sys.exit(f"usage: translate <{'|'.join(DATASETS)}>")
        client, model = make_client()
        run(client, model, args[1], workers, batch_size)
    elif cmd == "check":
        targets = list(DATASETS) if (len(args) < 2 or args[1] == "all") else [args[1]]
        for t in targets:
            if t in DATASETS:
                check(t)
    elif cmd == "clean":
        targets = list(DATASETS) if (len(args) < 2 or args[1] == "all") else [args[1]]
        for t in targets:
            if t in DATASETS:
                clean(t)
    else:
        print(__doc__)
        sys.exit(1)


if __name__ == "__main__":
    main()
