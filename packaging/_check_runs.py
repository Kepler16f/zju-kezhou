import json, subprocess, urllib.request, time

token = subprocess.run(["gh", "auth", "token"], capture_output=True, text=True).stdout.strip()
def api(u):
    req = urllib.request.Request("https://api.github.com" + u, headers={"Authorization": "Bearer " + token, "Accept": "application/vnd.github+json"})
    return json.load(urllib.request.urlopen(req, timeout=30))

run_id = 39046382432
jobs = api(f"/repos/Kepler16f/zju-kezhou/actions/runs/{run_id}/jobs?per_page=50")["jobs"]
for j in jobs:
    print(j["name"][:44], "|", j["status"], "|", j["conclusion"])
