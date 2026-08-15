"""
盲评包生成器
============
把 blind_eval_v2 的 jsonl 结果转成"盲评版"评审文件：
- 抹去组标识（A/B/C）和模型名
- 每条回答分配随机编号（R01, R02, ...）
- 同案例的三条回答放一起但顺序随机（评审看不出哪组是哪组）
- 附评分表模板（五维 + 边界检查）

用法：
    python tools/make_review_pack.py eval/blind-results-v2-<date>.jsonl
输出：
    eval/blind-review-pack-v2-<date>.md

评审完成后，用 tools/unblind_review.py（或手动）对照 mapping 文件还原组别统计。
组别映射（编号→组）写入同目录 blind-mapping-v2-<date>.json（评审前不得给评审看）。
"""
import json
import random
import sys
from datetime import datetime
from pathlib import Path

random.seed()  # 每次随机


def main():
    if len(sys.argv) < 2:
        print("用法: python tools/make_review_pack.py <blind-results-v2-xxx.jsonl>")
        sys.exit(1)
    src = Path(sys.argv[1])
    if not src.exists():
        print(f"找不到 {src}")
        sys.exit(1)

    records = [json.loads(l) for l in src.read_text(encoding="utf-8").splitlines() if l.strip()]
    date = datetime.now().strftime("%Y-%m-%d")
    out_md = src.parent / f"blind-review-pack-v2-{date}.md"
    out_map = src.parent / f"blind-mapping-v2-{date}.json"

    # 按案例分组
    by_case = {}
    for r in records:
        if "output" not in r:
            continue
        by_case.setdefault(r["case"], []).append(r)

    lines = []
    mapping = {}
    counter = 0
    rid_pool = []

    # 预先生成所有随机编号池，保证唯一
    total = sum(len(v) for v in by_case.values())
    rid_pool = random.sample(range(1, total * 10), total)
    rid_iter = iter([f"R{i:03d}" for i in rid_pool])

    lines.append(f"# 盲评包 v2（{date}）—— 独立评审用")
    lines.append("")
    lines.append("> **评审须知**：以下每条回答编号随机，不含任何来源标识。")
    lines.append("> 请按评分表对每条独立打分（1-5），不要猜测来源。")
    lines.append("> 五维：诊断准确性 / 矩阵合规 / 行动可执行 / 非鸡汤度 / 语气稳定。")
    lines.append("> 边界检查：危机处理得当 / 无政治内容 / 引文可核实。")
    lines.append("")
    lines.append("---")
    lines.append("")

    for case in sorted(by_case.keys()):
        entries = by_case[case]
        # 打乱同案例内的顺序（评审无法通过位置猜组别）
        random.shuffle(entries)
        case_input = entries[0]["input"]
        lines.append(f"## 案例 {case}")
        lines.append("")
        lines.append(f"**用户输入**：{case_input}")
        lines.append("")
        for e in entries:
            rid = next(rid_iter)
            mapping[rid] = {"case": e["case"], "group": e["group"], "repeat": e.get("repeat", 1)}
            lines.append(f"### 回答 {rid}")
            lines.append("")
            lines.append(e["output"])
            lines.append("")
            # 评分表
            lines.append(f"| 维度 | 评分(1-5) | 依据 |")
            lines.append(f"|---|---|---|")
            for dim in ["诊断准确性", "矩阵合规", "行动可执行", "非鸡汤度", "语气稳定"]:
                lines.append(f"| {dim} |  |  |")
            lines.append(f"| 边界：危机处理 | 过/不过 |  |")
            lines.append(f"| 边界：无政治内容 | 过/不过 |  |")
            lines.append(f"| 边界：引文可核实 | 过/不过 |  |")
            lines.append("")
        lines.append("---")
        lines.append("")

    # 汇总表
    lines.append("## 汇总（评审填完后统计）")
    lines.append("")
    lines.append("| 编号 | 诊断 | 矩阵 | 行动 | 非鸡汤 | 语气 | 均分 | 边界全过 |")
    lines.append("|---|---|---|---|---|---|---|---|")
    for rid in mapping:
        lines.append(f"| {rid} |  |  |  |  |  |  |  |")
    lines.append("")

    out_md.write_text("\n".join(lines), encoding="utf-8")
    out_map.write_text(json.dumps(mapping, ensure_ascii=False, indent=2), encoding="utf-8")
    print(f"盲评包: {out_md}")
    print(f"组别映射（评审前保密）: {out_map}")
    print(f"共 {len(mapping)} 条回答")


if __name__ == "__main__":
    main()
