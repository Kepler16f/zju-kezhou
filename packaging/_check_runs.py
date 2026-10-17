import json, subprocess, urllib.request, time

token = subprocess.run(["gh", "auth", "token"], capture_output=True, text=True).stdout.strip()
def api(u):
    req = urllib.request.Request("https://api.github.com" + u, headers={"Authorization": "Bearer " + token, "Accept": "application/vnd.github+json"})
    return json.load(urllib.request.urlopen(req, timeout=60))

full = subprocess.run(["git", "rev-parse", "75c7fb6"], capture_output=True, text=True).stdout.strip()
deadline = time.time() + 600
while time.time() < deadline:
    runs = api(f"/repos/Kepler16f/zju-kezhou/actions/runs?head_sha={full}")["workflow_runs"]
    hap = [r for r in runs if "HarmonyOS" in r["name"]]
    if hap and all(r["status"] == "completed" for r in hap):
        for r in hap:
            print(r["id"], r["name"], r["status"], r.get("conclusion"))
        break
    print("in progress:", [(r["id"], r["status"]) for r in hap])
    time.sleep(25)
