# -*- coding: utf-8 -*-
# M4 拒答门 Code 节点（Dify「代码执行(Python3)」）
# 输入：chunks(str 知识检索结果拼接文本)  score(str 检索节点最高相关度, 可空)
# 输出：pass("true"/"false")  score(str)  reason(str)
# 逻辑：相关度阈值 + 命中数为0 双重判定；阈值可调（10/16 按评测集定稿）。
THRESHOLD = 0.50


def main(chunks="", score=""):
    text = (chunks or "").strip()
    try:
        s = float(score) if score else None
    except ValueError:
        s = None
    if not text or len(text) < 40:
        return {"pass": "false", "score": "0", "reason": "知识库无命中"}
    if s is not None:
        ok = s >= THRESHOLD
        return {"pass": "true" if ok else "false", "score": str(s),
                "reason": "" if ok else "最高相关度 %.2f 低于阈值" % s}
    return {"pass": "true", "score": "n/a", "reason": "无得分字段，按命中放行"}
