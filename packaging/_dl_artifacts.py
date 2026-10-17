import json, subprocess, urllib.request, urllib.error, zipfile, io, os

token = subprocess.run(["gh", "auth", "token"], capture_output=True, text=True).stdout.strip()
dest = os.path.expandvars(r"%USERPROFILE%\Downloads\kezhou-0.12.1")
os.makedirs(dest, exist_ok=True)

def req(url, auth=True):
    h = {"Accept": "application/vnd.github+json"}
    if auth:
        h["Authorization"] = "Bearer " + token
    return urllib.request.Request(url, headers=h)

def no_redirect():
    class NR(urllib.request.HTTPRedirectHandler):
        def redirect_request(self, r, *a, **k):
            return None
    return urllib.request.build_opener(NR)

opener = no_redirect()

arts = json.load(urllib.request.urlopen(req(
    "https://api.github.com/repos/Kepler16f/zju-kezhou/actions/runs/39046382432/artifacts"), timeout=60))["artifacts"]
print("artifacts:", len(arts))
for a in arts:
    name, aid = a["name"], a["id"]
    url = f"https://api.github.com/repos/Kepler16f/zju-kezhou/actions/artifacts/{aid}/zip"
    try:
        resp = opener.open(req(url), timeout=300)
        # 未重定向：直接 body（少见）
        data = resp.read()
    except urllib.error.HTTPError as e:
        if e.code in (301, 302, 303, 307, 308):
            loc = e.headers.get("Location")
            data = urllib.request.urlopen(loc, timeout=300).read()  # 不带 auth
        else:
            raise
    zf = zipfile.ZipFile(io.BytesIO(data))
    files = [n for n in zf.namelist() if not n.endswith("/")]
    if len(files) == 1:
        out = os.path.join(dest, os.path.basename(files[0]))
        open(out, "wb").write(zf.read(files[0]))
        print("saved", os.path.basename(out), os.path.getsize(out))
    else:
        print("multi", name, files)

print("---- final listing ----")
for f in sorted(os.listdir(dest)):
    print(f, os.path.getsize(os.path.join(dest, f)))
