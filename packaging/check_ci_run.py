# packaging/check_ci_run.py — 轮询指定 workflow run 到完成
# 用法：python packaging/check_ci_run.py <run_id> [workflow名过滤，如 HarmonyOS]
import json, sys, time, urllib.request

run_id = sys.argv[1]
flt = sys.argv[2] if len(sys.argv) > 2 else ""
token = None
import subprocess
token = subprocess.run(["gh", "auth", "token"], capture_output=True, text=True).stdout.strip()

def api(u):
    req = urllib.request.Request("https://api.github.com" + u,
        headers={"Authorization": "Bearer " + token, "Accept": "application/vnd.github+json"})
    return json.load(urllib.request.urlopen(req, timeout=60))

deadline = time.time() + 2400
while time.time() < deadline:
    try:
        run = api(f"/repos/Kepler16f/zju-kezhou/actions/runs/{run_id}")
        jobs = api(f"/repos/Kepler16f/zju-kezhou/actions/runs/{run_id}/jobs?per_page=100")["jobs"]
    except Exception as e:
        print("poll retry:", repr(e)[:70])
        time.sleep(20)
        continue
    jobs = [j for j in jobs if not flt or flt.lower() in (j["name"] or "").lower()]
    rows = [(j["name"][:40], j["status"], j["conclusion"]) for j in jobs]
    print("run status", run["status"], run.get("conclusion"))
    for x in rows:
        print("   ", x)
    if run["status"] == "completed":
        break
    if rows and all(x[1] == "completed" for x in rows):
        break
    time.sleep(25)
