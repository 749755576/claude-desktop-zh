#!/usr/bin/env python3
"""
asar_tool.py — Electron asar extract / integrity / rebuild tool (stdlib only)

处理新版 Claude Desktop 的 ion-dist.asar 布局:
  1. extract   完整解包 asar
  2. header    输出 asar 头部 JSON 的 SHA-256 (Electron 完整性校验值)
  3. patch-js  解包 + 对 JS 分包打 zh-CN 语言列表补丁
  4. build     按原 asar 结构重建 (支持新增/替换文件)

asar 格式:
  [0:4]   uint32 = 4
  [4:8]   uint32 = header_pickle_size (8 + json_size, 4字节对齐)
  [8:12]  uint32 = 4
  [12:16] uint32 = header_json_size
  [16:16+json_size] UTF-8 JSON 文件索引
  其后为按 offset/size 排列的文件数据区
"""
import hashlib
import json
import os
import re
import shutil
import struct
import sys

RE_LANG_ARRAY = re.compile(r'((?:[\w$]+)=\["en-US"(?:,"[^"]+")+)\]')
RE_DISPLAY_MAP = re.compile(
    r'("en-US":\{name:"English \(United States\)",localName:"English \(United States\)"\},)'
)
ZH_DISPLAY_ENTRY = '"zh-CN":{name:"Chinese (Simplified)",localName:"简体中文"},'


def _align4(n):
    return (n + 3) & ~3


def read_header(path):
    """返回 (header_json_bytes, data_start_offset, files_dict)"""
    with open(path, "rb") as f:
        pre = f.read(16)
        if len(pre) < 16 or struct.unpack_from("<I", pre, 0)[0] != 4:
            raise SystemExit("错误: 不是有效的 asar 文件: %s" % path)
        header_pickle_size = struct.unpack_from("<I", pre, 4)[0]
        json_size = struct.unpack_from("<I", pre, 12)[0]
        header_json = f.read(json_size)
    if len(header_json) != json_size:
        raise SystemExit("错误: asar 头部不完整")
    return header_json, 8 + header_pickle_size, json.loads(header_json.decode("utf-8"))


def header_sha256(path):
    header_json, _, _ = read_header(path)
    return hashlib.sha256(header_json).hexdigest()


def _read_payload(asar_path, data_start, node):
    offset = int(node["offset"])
    size = int(node["size"])
    with open(asar_path, "rb") as f:
        f.seek(data_start + offset)
        data = f.read(size)
    if len(data) != size:
        raise SystemExit("错误: asar 数据区不完整")
    return data


def extract(asar_path, out_dir):
    _, data_start, files = read_header(asar_path)
    if os.path.exists(out_dir):
        shutil.rmtree(out_dir)
    os.makedirs(out_dir)
    count = 0
    skipped = []

    def walk(node, prefix):
        nonlocal count
        for name, child in node.items():
            rel = prefix + "/" + name if prefix else name
            target = os.path.join(out_dir, *rel.split("/"))
            if "files" in child:
                os.makedirs(target, exist_ok=True)
                walk(child["files"], rel)
            elif child.get("unpacked"):
                skipped.append(rel)
            else:
                data = _read_payload(asar_path, data_start, child)
                with open(target, "wb") as f:
                    f.write(data)
                count += 1
                if count % 500 == 0:
                    print(f"  已解包 {count} 个文件...", flush=True)

    walk(files["files"], "")
    print(f"已解包 {count} 个文件到 {out_dir}")
    if skipped:
        print(f"[提示] 跳过 {len(skipped)} 个 unpacked 文件")


def patch_js(out_dir):
    patched = 0
    assets = os.path.join(out_dir, "assets")
    if not os.path.isdir(assets):
        print("[警告] 未找到 assets 目录")
        return 0
    for root, _, names in os.walk(assets):
        for name in names:
            if not name.endswith(".js"):
                continue
            path = os.path.join(root, name)
            with open(path, "r", encoding="utf-8", errors="surrogateescape") as f:
                content = f.read()
            new = RE_LANG_ARRAY.sub(r'\1,"zh-CN"]', content)
            new = RE_DISPLAY_MAP.sub(lambda m: m.group(1) + ZH_DISPLAY_ENTRY, new, count=1)
            if new != content:
                with open(path, "w", encoding="utf-8", errors="surrogateescape", newline="") as f:
                    f.write(new)
                patched += 1
                print(f"  JS补丁: {os.path.relpath(path, out_dir)}")
    if patched == 0:
        print("[警告] 未匹配到语言列表 (Claude 可能又更新了)")
    return patched


def build(orig_asar, out_dir, out_asar):
    """按原 asar 结构重建; out_dir 中的同名文件替换原内容, out_dir 独有的文件追加"""
    header_json, data_start, files = read_header(orig_asar)
    payloads = {}

    # 1. 结构内已有文件: 从 out_dir 读 (out_dir 缺失的回退到原 asar)
    def walk(node, prefix):
        for name, child in node.items():
            rel = prefix + "/" + name if prefix else name
            if "files" in child:
                walk(child["files"], rel)
            elif child.get("unpacked"):
                pass
            else:
                target = os.path.join(out_dir, *rel.split("/"))
                if os.path.isfile(target):
                    with open(target, "rb") as f:
                        payloads[rel] = f.read()
                else:
                    payloads[rel] = _read_payload(orig_asar, data_start, child)
                if len(payloads) % 500 == 0:
                    print(f"  已读取 {len(payloads)} 个文件...", flush=True)

    walk(files["files"], "")

    # 2. out_dir 独有的新文件: 自动补目录结构
    added = 0
    for root, _, names in os.walk(out_dir):
        for name in names:
            full = os.path.join(root, name)
            rel = os.path.relpath(full, out_dir).replace("\\", "/")
            if rel in payloads:
                continue
            with open(full, "rb") as f:
                payloads[rel] = f.read()
            parts = rel.split("/")
            children = files["files"]
            for p in parts[:-1]:
                children = children.setdefault(p, {"files": {}})["files"]
            children[parts[-1]] = {"size": 0, "offset": "0"}
            added += 1

    # 3. 统一重排 offset 并写盘
    entries = []

    def assign(node, prefix):
        for name, child in node.items():
            rel = prefix + "/" + name if prefix else name
            if "files" in child:
                assign(child["files"], rel)
            elif child.get("unpacked"):
                pass
            else:
                data = payloads[rel]
                child["size"] = len(data)
                whole = hashlib.sha256(data).hexdigest()
                blocks = []
                for i in range(0, len(data), 4194304):
                    blocks.append(hashlib.sha256(data[i:i + 4194304]).hexdigest())
                if not blocks:
                    blocks = [hashlib.sha256(b"").hexdigest()]
                child["integrity"] = {
                    "algorithm": "SHA256",
                    "hash": whole,
                    "blockSize": 4194304,
                    "blocks": blocks,
                }
                entries.append((rel, data))

    assign(files["files"], "")
    offset = 0
    for rel, data in entries:
        parts = rel.split("/")
        node = files["files"]
        for p in parts[:-1]:
            node = node[p]["files"]
        node[parts[-1]]["offset"] = str(offset)
        offset += len(data)

    header_out = json.dumps(files, ensure_ascii=False, separators=(",", ":")).encode("utf-8")
    json_size = len(header_out)
    # 观测 @electron/asar 实际布局:
    # [0:4]=4  [4:8]=H  [8:12]=payload_size=H-4  [12:16]=json_size
    # [16:16+json_size]=json  补零至 8+H, 文件数据从 8+H 开始
    payload_size = _align4(4 + json_size)
    H = 4 + payload_size

    with open(out_asar, "wb") as f:
        f.write(struct.pack("<I", 4))
        f.write(struct.pack("<I", H))
        f.write(struct.pack("<I", payload_size))
        f.write(struct.pack("<I", json_size))
        f.write(header_out)
        f.write(b"\x00" * (payload_size - 4 - json_size))
        written = 0
        for _, data in entries:
            f.write(data)
            written += 1
            if written % 500 == 0:
                print(f"  已写入 {written}/{len(entries)} 个文件...", flush=True)
    print(f"已写入 {out_asar} ({os.path.getsize(out_asar)} 字节, {len(entries)} 个文件, 新增 {added} 个)")


def main():
    args = sys.argv[1:]
    usage = __doc__
    if len(args) < 2:
        print(usage)
        sys.exit(1)
    cmd = args[0].lower()
    if cmd == "extract" and len(args) == 3:
        extract(args[1], args[2])
    elif cmd == "header" and len(args) == 2:
        print(header_sha256(args[1]))
    elif cmd == "patch-js" and len(args) == 3:
        extract(args[1], args[2])
        patch_js(args[2])
    elif cmd == "build" and len(args) == 4:
        build(args[1], args[2], args[3])  # build <原asar> <outdir> <输出asar>
    else:
        print(usage)
        sys.exit(1)


if __name__ == "__main__":
    main()






