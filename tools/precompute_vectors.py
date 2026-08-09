#!/usr/bin/env python3
"""明镜 CLI —— 语料向量预计算脚本（可选增强，非 MVP 必需）。

MVP 的检索默认走 Dart 端零依赖实现（困境分类 + 字符 n-gram + 声部加成，
见 cli/lib/rag/vector_search.dart），不需要本脚本。

本脚本为"向量检索"预留：把 corpus/*.json 的"白话解析"embedding 成
data/corpus_vectors.bin（float32 顺序存储）+ data/corpus_index.json（id→偏移）。
当未来在 Dart 端接入与预计算同模型（bge-small-zh-v1.5）同维度的 query
embedding 来源后，可切换检索实现为 cosine。

用法:
  pip install sentence-transformers
  python tools/precompute_vectors.py            # 默认输出到 data/
  python tools/precompute_vectors.py --out D:/tmp/vec   # 自定义输出

产物（已被 .gitignore 忽略，可重新生成）:
  data/corpus_vectors.bin    # N×512 float32，小端
  data/corpus_index.json     # {"<corpus-id>": <offset(条)>}
"""

import argparse
import json
import struct
from pathlib import Path

MODEL_NAME = "BAAI/bge-small-zh-v1.5"  # 512 维


def load_corpus(corpus_dir: Path) -> list[dict]:
    entries = []
    for f in sorted(corpus_dir.glob("*.json")):
        try:
            arr = json.loads(f.read_text(encoding="utf-8"))
        except json.JSONDecodeError:
            print(f"警告: 跳过无法解析的 {f.name}")
            continue
        for e in arr:
            if e.get("id") and e.get("白话解析"):
                entries.append(e)
    return entries


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--corpus", type=Path, default=Path("corpus"))
    ap.add_argument("--out", type=Path, default=Path("data"))
    args = ap.parse_args()

    entries = load_corpus(args.corpus)
    print(f"加载 {len(entries)} 条语料")

    from sentence_transformers import SentenceTransformer

    model = SentenceTransformer(MODEL_NAME)
    texts = [f"{e['白话解析']} {e['原文']}" for e in entries]
    vecs = model.encode(texts, normalize_embeddings=True, show_progress_bar=True)
    print(f"向量维度: {vecs.shape[1]}")

    args.out.mkdir(parents=True, exist_ok=True)
    bin_path = args.out / "corpus_vectors.bin"
    idx_path = args.out / "corpus_index.json"

    with bin_path.open("wb") as f:
        for v in vecs:
            f.write(struct.pack(f"<{v.shape[0]}f", *v.tolist()))
    idx = {e["id"]: i for i, e in enumerate(entries)}
    idx_path.write_text(json.dumps(idx, ensure_ascii=False, indent=1), encoding="utf-8")

    size_mb = bin_path.stat().st_size / 1024 / 1024
    print(f"完成: {bin_path} ({size_mb:.1f}MB) + {idx_path} ({len(idx)} 条)")


if __name__ == "__main__":
    main()
