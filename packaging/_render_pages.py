import fitz, os
pdf = r"D:\compass\docs\作品介绍.pdf"
outdir = r"D:\compass\docs\render"
os.makedirs(outdir, exist_ok=True)
doc = fitz.open(pdf)
print("pages:", doc.page_count)
for i, page in enumerate(doc):
    pix = page.get_pixmap(dpi=110)
    out = os.path.join(outdir, f"page{i+1}.png")
    pix.save(out)
    print("wrote", out, pix.width, "x", pix.height)
