# 课舟 Git 上手指南（学生版）

> 写给第一次碰 Git 的同学。不用背命令，照着敲就行。
>
> 如果只能记住一句话：**动手前先 `git status`，传代码前先同步。**

## 0. 先用一分钟搞明白

- **Git**：装在你电脑上的“存档器”。每 `commit` 一次就是存一个档，代码改坏了能翻旧账。
- **GitHub**：把存档放到云上，队友才能看到、才能一起改。
- **`main`**：能用的稳定版，别直接在上面乱改。
- **`dev`**：大家平时写代码的地方。改完、测完，再合回 `main`。

所以日常节奏就三步：**同步 → 写 → 提交推送**。

## 1. 打开终端，进到项目文件夹

在 Windows 搜索栏输入 `PowerShell`，打开后执行：

```powershell
cd C:\Users\61025\Documents\Codex\2026-10-14\new-chat\work\compass
```

以后每次开工都先走这一步，后面的命令都在这个文件夹里执行。

## 2. Git 已经装好了

这台电脑用的是免安装版 PortableGit，不用再下载：

```text
C:\Users\61025\Documents\Codex\2026-10-14\new-chat\work\tools\PortableGit\cmd\git.exe
```

想让 `git` 命令随处可用，在自己的 PowerShell 里执行一次，然后**重新开一个终端**：

```powershell
$bin = 'C:\Users\61025\Documents\Codex\2026-10-14\new-chat\work\tools\PortableGit\cmd'
$old = [Environment]::GetEnvironmentVariable('Path','User')
[Environment]::SetEnvironmentVariable('Path', "$bin;$old", 'User')
```

检查一下：

```powershell
git --version
```

能打印出版本号就说明好了。

## 3. 第一次用，先告诉 Git 你是谁

只做一次，以后不用再设：

```powershell
git config --global user.name "你的名字"
git config --global user.email "你的邮箱"
```

不设也能提交，但提交记录里会显示奇怪的名字，队友不知道是谁改的。

## 4. 把项目下载到电脑（只需一次）

如果文件夹里还没有代码：

```powershell
cd C:\Users\61025\Documents\Codex\2026-10-14\new-chat\work
git clone https://github.com/Kepler16f/zju-kezhou.git
cd zju-kezhou
git checkout dev
```

已经有文件夹了，就直接 `cd` 进去，跳到下一节。

## 5. 每天开工第一件事：同步 main

先看看自己有没有还没提交的改动：

```powershell
git status
```

如果显示 `working tree clean`，就可以放心同步。如果有改动，先提交（见第 7 节）或者临时存起来：

```powershell
git stash push -m "先存一下"
```

然后按顺序执行：

```powershell
git fetch origin --prune --tags

git checkout main
git merge --ff-only origin/main

git checkout dev
git merge main
```

每行在干嘛：

- `fetch`：去 GitHub 看看有没有新东西，先下载到本地，但不动你的代码。
- `checkout main`：切到稳定分支。
- `merge --ff-only`：把云端 main 的新提交“快进”到本地。不能快进就说明本地 main 有别人没有的提交，先停下来问人，别硬来。
- `checkout dev` + `merge main`：把刚同步到的东西带进开发分支。

同步完看一眼：

```powershell
git log --oneline -5
git status -sb
```

`git status -sb` 显示 `## dev...origin/dev` 就说明你在 dev 上，而且和云端对上了。

## 6. 确认自己在 dev 上，再开始写

```powershell
git branch --show-current
```

输出 `dev` 就对了。如果输出 `main`，先切回来：

```powershell
git checkout dev
```

**别在 main 上直接改代码。** main 是给大家用的稳定版，改坏了很麻烦。

## 7. 写完了：提交并推送

先看看自己改了哪些文件：

```powershell
git status
git diff
```

确认没有把密码、token、日志、构建产物一起带进去，然后：

```powershell
git add -A
git commit -m "fix: 修复军体类被算进思政类的问题"
git push -u origin dev
```

提交信息写人话，让队友一眼看懂：

- 好：`fix: 修复培养方案军体类被算进思政类`
- 好：`feat: 成绩页新增工具选项卡`
- 不好：`update`、`修改`、`111`、`最终版`

第一次推送会弹 GitHub 登录窗口。登录后凭据会被记住，以后不用反复输。

### 用 PAT 登录（弹窗要求输入密码时）

- 用户名：你的 GitHub 用户名
- 密码：Personal Access Token（不是账号密码）
- Fine-grained token 权限选 `Contents: Read and write`
- Classic token 勾选 `repo`

## 8. 测完没问题，再把 dev 合进 main

这一步一般是负责人做，或者确认整包编译、测试都过了再做：

```powershell
git checkout main
git merge --ff-only dev
git push origin main
git checkout dev
```

`main` 永远不要强推，也不要在上面直接改。

## 9. 合并冲突了怎么办

别慌，Git 会告诉你哪些文件冲突：

```powershell
git status
```

打开冲突文件，会看到这种标记：

```text
<<<<<<< HEAD
你的代码
=======
别人的代码
>>>>>>> main
```

留下正确的内容，把 `<<<<<<<`、`=======`、`>>>>>>>` 这三行删掉，然后：

```powershell
git add 冲突文件
git commit
```

如果彻底乱了，想放弃这次合并：

```powershell
git merge --abort
```

代码会回到合并前的样子。

## 10. 常见报错翻译器

| 报错 | 什么意思 | 怎么办 |
|---|---|---|
| `could not read Username` / `Authentication failed` | 没登录 GitHub | 重新 `git push`，按弹窗登录；或用 PAT |
| `non-fast-forward` / `rejected` | 云端有你本地没有的提交 | 先 `git fetch origin`，再 `git merge origin/dev` |
| `Your local changes would be overwritten` | 你有没提交的改动，切分支会覆盖 | 先 `git add` + `git commit`，或 `git stash` |
| `fatal: not a git repository` | 当前文件夹不是项目目录 | `cd` 到 `compass` 再执行 |
| `LF will be replaced by CRLF` | Windows 换行符提示 | 正常现象，不用管 |
| `failed to connect` / `Could not connect` | 网络或代理问题 | 换网络；检查 `git config --global --get http.proxy` |

## 11. 新手最容易踩的坑

- 在 `main` 上直接改代码。
- 把 `.env`、密码、PAT、学号姓名等敏感信息提交上去。
- 提交信息只写“修改”，过两天自己都不知道改了啥。
- 看到冲突就 `git push --force`，把队友的提交覆盖掉。
- 不先 `git status` 就切分支，未提交的改动被带走或覆盖。

## 12. 一页速查

```powershell
# 每天开工：同步 main 到本地和 dev
git fetch origin --prune --tags
git checkout main && git merge --ff-only origin/main
git checkout dev && git merge main

# 写完：提交并推送
git status
git add -A && git commit -m "feat: 一句话说明改了什么"
git push -u origin dev

# 验证通过：dev 合进 main
git checkout main && git merge --ff-only dev && git push origin main
git checkout dev

# 不知道自己在哪 / 改了啥
git branch --show-current
git status
```

---

有搞不定的报错，把终端里完整的报错复制下来再问，不要只说“跑不起来”。完整的报错里通常已经写了原因。
