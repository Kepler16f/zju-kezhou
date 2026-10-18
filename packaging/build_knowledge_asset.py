# -*- coding: utf-8 -*-
"""把知识库 knowledge.json 转成 assets/knowledge/zju_course_selection_2026.json：
- entries -> documents（兼容 InMemoryAiKnowledgeBase.fromJson 的 {"documents":[...]} 形状）
- 从 title/section 生成轻量 keywords（2 字滑窗 + 全串），提高零依赖检索命中
- 原文 text 保留
"""
import json, io, re

SRC = r"C:\Users\胡天泽\Desktop\浙大选课知识库-2026\knowledge.json"
DST = r"D:\compass\compass_app\assets\knowledge\zju_course_selection_2026.json"

d = json.load(io.open(SRC, encoding="utf-8"))
out = []
for e in d["entries"]:
    title = e["title"]
    section = e.get("section", "")
    kw = set()
    base = "%s %s" % (title, section)
    for tok in re.findall(r"[一-鿿]+|[A-Za-z0-9_]{2,}", base):
        if len(tok) == 1:
            kw.add(tok)
            continue
        kw.add(tok)
        if re.match(r"[一-鿿]", tok):
            for i in range(len(tok) - 1):
                kw.add(tok[i:i + 2])
    # 标题整串 + 小节名权重最高：keywords 全匹配 +3
    docs_entry = {
        "id": e["id"],
        "title": title,
        "section": section,
        "text": e["text"],
        "keywords": sorted(kw),
        "source": e.get("source", ""),
    }
    out.append(docs_entry)

meta = {
    "name": d.get("name", "浙大选课知识库"),
    "version": d.get("version", ""),
    "updated": d.get("updated", ""),
    "documents": out,
}
io.open(DST, "w", encoding="utf-8").write(json.dumps(meta, ensure_ascii=False))
print("wrote", DST, len(out), "docs")
