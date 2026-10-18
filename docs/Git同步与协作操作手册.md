# Git 同步与协作操作手册

适用仓库：`Kepler16f/zju-kezhou`（课舟 ClassArk）
分支模型：`main` 为稳定分支，`dev` 为日常开发分支。所有开发先提交到 `dev`，验证通过后再快进合并到 `main`。

## 1. 环境准备

本机使用免安装的 PortableGit（无需管理员权限）：

```text
C:\Users\61025\Documents\Codex\2026-10-14\new-chat\work\tools\PortableGit\cmd\git.exe
```

让 `git` 命令全局可用（在自己的 PowerShell 中执行一次，然后新开终端）：

```powershell
$bin = 'C:\Users\61025\Documents\Codex\2026-10-14\new-chat\work\tools\PortableGit\cmd'
$old = [Environment]::GetEnvironmentVariable('Path','User')
[Environment]::SetEnvironmentVariable('Path', "$bin;$old", 'User')
```

检查：

```powershell
git --version
git config --global user.name
git config --global user.email
```

未配置身份时：

```powershell
git config --global user.name "你的名字"
git config --global user.email "你的邮箱"
```

## 2. 获取仓库

首次克隆：

```powershell
cd C:\Users\61025\Documents\Codex\2026-10-14\new-chat\work
git clone https://github.com/Kepler16f/zju-kezhou.git
cd zju-kezhou
git checkout dev
```

已有仓库只需进入目录：

```powershell
cd C:\Users\61025\Documents\Codex\2026-10-14\new-chat\work\compass
```

## 3. 日常同步 main 最新代码

同步前先确认工作区干净，避免未提交改动被分支切换带走：

```powershell
git status
```

有未提交改动时，先提交或暂存：

```powershell
git add -A
git commit -m "wip: 本地改动"
# 或
git stash push -m "临时保存"
```

标准同步流程：

```powershell
git fetch origin --prune --tags

git checkout main
git merge --ff-only origin/main

git checkout dev
git merge main
```

说明：

- `fetch` 只更新远端跟踪分支，不改工作区。
- `merge --ff-only` 保证本地 `main` 不做多余合并提交；若提示无法快进，说明本地 `main` 有未推送提交，先人工核对，不要强推。
- `dev` 合并 `main` 后，把 `main` 上的修复带进开发分支。
- 若团队约定线性历史，可用 `git rebase main` 替代 `git merge main`；已推送的 `dev` 不要随意 rebase。

同步后检查：

```powershell
git log --oneline -5
git status -sb
```

## 4. 提交与推送

```powershell
git status
git add -A
git commit -m "fix: 简要说明改了什么"
git push -u origin dev
```

首次推送或凭据过期时会弹出 GitHub 登录窗口。也可使用 Personal Access Token（PAT）：

- Fine-grained token：仓库选 `Kepler16f/zju-kezhou`，权限 `Contents: Read and write`。
- Classic token：勾选 `repo`。
- 弹窗用户名填 GitHub 用户名，密码填 PAT。
- 凭据由 Git Credential Manager 缓存，后续无需重复输入。

## 5. dev 验证通过后合并到 main

```powershell
git checkout main
git merge --ff-only dev
git push origin main
git checkout dev
```

只有 `dev` 已完整验证（编译、测试通过）时才执行。`main` 禁止强推。

## 6. 冲突处理

合并时出现冲突：

```powershell
git status
```

1. 打开冲突文件，搜索 `<<<<<<<`、`=======`、`>>>>>>>`。
2. 保留正确内容并删除冲突标记。
3. 标记已解决并提交：

```powershell
git add <冲突文件>
git commit
```

放弃本次合并：

```powershell
git merge --abort
```

## 7. 常用排查

查看远端与分支：

```powershell
git remote -v
git branch -vv
git fetch origin --prune
```

推送被拒（non-fast-forward）：

```powershell
git fetch origin
git log --oneline HEAD..origin/dev
git merge origin/dev
```

不要用 `git push --force` 覆盖他人提交；确需强制时先确认分支只有自己使用。

网络/代理异常：

```powershell
git config --global --get http.proxy
git ls-remote origin
```

必要时设置或清除代理：

```powershell
git config --global http.proxy http://127.0.0.1:端口
git config --global --unset http.proxy
```

换行符警告（`LF will be replaced by CRLF`）是 Windows 下的正常提示，不影响提交内容。

## 8. 提交前检查清单

- `git status` 中没有意外文件（构建产物、日志、密钥）。
- `git diff` 已人工过目。
- 版本号 `pubspec.yaml` 与 `lib/data/app_version.dart` 保持同步。
- 编译通过：`powershell -NoProfile -ExecutionPolicy Bypass -File ..\build_check.ps1`。
- 测试通过：`python ..\run_tests.py`。
- 提交信息说明“改了什么、为什么改”，不要只写 `update`。

## 9. 一页速查

```powershell
# 同步 main 到本地与 dev
git fetch origin --prune --tags
git checkout main && git merge --ff-only origin/main
git checkout dev && git merge main

# 提交并推送开发分支
git add -A && git commit -m "feat: ..."
git push -u origin dev

# dev 验证通过后发布到 main
git checkout main && git merge --ff-only dev && git push origin main
git checkout dev
```
