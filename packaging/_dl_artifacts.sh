#!/bin/bash
# packaging/_dl_artifacts.sh — 下载某次 Actions run 的全部产物到 Downloads/<目标名>/
# 用法：bash packaging/_dl_artifacts.sh <run_id> <目标目录名>
#   例：bash packaging/_dl_artifacts.sh 39061973906 kezhou-0.13.0
# 说明：GitHub 对 archive:false 产物会重定向回原始文件（exe/apk/ipa/zip/tar.gz 各自）；
#   curl -L 首跳带鉴权、重定向后自动匿名，正好符合该端点。偶发 DNS/连接重置时带重试。
set -e
RUN="${1:?需要 run_id}"
DESTNAME="${2:?需要目标目录名，如 kezhou-0.13.0}"
export DESTNAME
DEST="$USERPROFILE/Downloads/$DESTNAME"
mkdir -p "$DEST"
LIST=packaging/_arts.tsv
python - "$RUN" <<'PYEOF' > "$LIST"
import json, subprocess, sys, urllib.request, time
run = sys.argv[1]
token = subprocess.run(["gh", "auth", "token"], capture_output=True, text=True).stdout.strip()
url = f"https://api.github.com/repos/Kepler16f/zju-kezhou/actions/runs/{run}/artifacts"
data = None
for attempt in range(8):
    try:
        req = urllib.request.Request(url, headers={"Authorization": "Bearer " + token})
        data = json.load(urllib.request.urlopen(req, timeout=90))
        break
    except Exception:
        if attempt == 7:
            raise
        time.sleep(4)
for a in data["artifacts"]:
    print(str(a["id"]) + "\t" + a["name"])
PYEOF
TOKEN=$(gh auth token)
while IFS=$'\t' read -r id name; do
  echo "FETCH $name ($id)"
  curl -sSL --retry 6 --retry-delay 3 --retry-all-errors -H "Authorization: Bearer $TOKEN" -o packaging/_art.zip \
    "https://api.github.com/repos/Kepler16f/zju-kezhou/actions/artifacts/$id/zip"
  python - "$name" <<'PYEOF'
import sys, zipfile, io, os
name = sys.argv[1]
raw = open("packaging/_art.zip", "rb").read()
dest = os.path.join(os.path.expandvars(r"%USERPROFILE%\Downloads"), os.environ["DESTNAME"])
if raw[:2] == b"PK":
    zf = zipfile.ZipFile(io.BytesIO(raw))
    files = [n for n in zf.namelist() if not n.endswith("/")]
    if len(files) == 1:
        out = os.path.join(dest, os.path.basename(files[0]))
        open(out, "wb").write(zf.read(files[0]))
    else:
        out = os.path.join(dest, name); open(out, "wb").write(raw)
else:
    out = os.path.join(dest, name); open(out, "wb").write(raw)
print("  ->", os.path.basename(out), os.path.getsize(out))
PYEOF
done < "$LIST"
rm -f packaging/_art.zip "$LIST"
echo "---- final listing ----"
ls -la "$DEST"
