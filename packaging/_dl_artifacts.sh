#!/bin/bash
# 下载 v0.12.1 全平台产物到 Downloads/kezhou-0.12.1/
set -e
DEST="$USERPROFILE/Downloads/kezhou-0.12.1"
mkdir -p "$DEST"
LIST=packaging/_arts.tsv
python - <<PYEOF > "$LIST"
import json, subprocess, urllib.request
token = subprocess.run(["gh","auth","token"],capture_output=True,text=True).stdout.strip()
req = urllib.request.Request("https://api.github.com/repos/Kepler16f/zju-kezhou/actions/runs/39046382432/artifacts",
  headers={"Authorization":"Bearer "+token})
for a in json.load(urllib.request.urlopen(req,timeout=60))["artifacts"]:
    print(str(a["id"]) + "\t" + a["name"])
PYEOF
TOKEN=$(gh auth token)
while IFS=$'\t' read -r id name; do
  echo "FETCH $name ($id)"
  curl -sSL -H "Authorization: Bearer $TOKEN" -o packaging/_art.zip \
    "https://api.github.com/repos/Kepler16f/zju-kezhou/actions/artifacts/$id/zip"
  python - "$name" <<PYEOF
import sys, zipfile, io, os
name = sys.argv[1]
raw = open("packaging/_art.zip","rb").read()
dest = os.path.expandvars(r"%USERPROFILE%\Downloads\kezhou-0.12.1")
if raw[:2] == b"PK":
    zf = zipfile.ZipFile(io.BytesIO(raw))
    files = [n for n in zf.namelist() if not n.endswith("/")]
    if len(files) == 1:
        out = os.path.join(dest, os.path.basename(files[0]))
        open(out,"wb").write(zf.read(files[0]))
    else:
        # 本身就是 zip 类产物（apk/ipa）：原始字节按名保存
        out = os.path.join(dest, name)
        open(out,"wb").write(raw)
else:
    # archive:false 产物直接重定向回原始文件（MZ 头等）
    out = os.path.join(dest, name)
    open(out,"wb").write(raw)
print("  ->", os.path.basename(out), os.path.getsize(out))
PYEOF
done < "$LIST"
echo "---- final listing ----"
ls -la "$DEST"
