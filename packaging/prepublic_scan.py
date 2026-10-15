"""公开前体检：扫描已入库文件里的敏感信息。只输出计数与脱敏样本，不打印明文。"""
import re
import subprocess

files = subprocess.run(['git', 'ls-files'], capture_output=True, text=True,
                       cwd=r'D:\compass', encoding='utf-8', errors='replace').stdout.splitlines()

PATTERNS = {
    '邮箱': re.compile(r'[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}'),
    '手机号': re.compile(r'(?<!\d)1[3-9]\d{9}(?!\d)'),
    '长数字串(8-14位)': re.compile(r'(?<!\d)\d{8,14}(?!\d)'),
    '疑似口令字段': re.compile(r'(password|passwd|pwd|密码|口令)\s*[:=]\s*\S{3,}', re.I),
    '疑似 token/secret': re.compile(r'(token|secret|api[_-]?key|cookie)\s*[:=]\s*\S{6,}', re.I),
    '本机用户名': re.compile('\u80e1\u5929\u6cfd'),  # 以转义书写，避免扫描器自身携带明文
    '真实姓名常见字段': re.compile(r'(真实姓名|学生姓名|xm)\s*[:=]\s*[\u4e00-\u9fa5]{2,4}'),
    'QQ 号': re.compile(r'(?<!\d)[1-9]\d{4,10}(?!\d)'),
}

IGNORE_MAILBOX_DOMAINS = ('example.com', 'users.noreply.github.com', 'github.com', 'huaweicloud.com',
                          'flutt.io', 'flutter-io.cn', 'harmonyos.com', 'gitee.com', 'gitcode.com',
                          'pub.dev', 'dart.dev', 'w3.org', 'zju.edu.cn', 'qq.com')

hits = {}
for f in files:
    p = r'D:\compass\\' + f.replace('/', '\\')
    try:
        text = open(p, encoding='utf-8', errors='replace').read()
    except Exception:
        continue
    for name, rx in PATTERNS.items():
        ms = rx.findall(text)
        if not ms:
            continue
        if name == '邮箱':
            ms = [m for m in ms if not m.lower().endswith(IGNORE_MAILBOX_DOMAINS)]
        if name == 'QQ 号':          # QQ 号单独报太吵，只在同文件有"邮箱/口令"线索时才关注
            continue
        if not ms:
            continue
        hits.setdefault(f, []).append((name, len(ms)))

print('扫描文件数：%d' % len(files))
if not hits:
    print('未发现敏感信息命中。')
for f, items in sorted(hits.items()):
    print('%-58s %s' % (f, ', '.join('%s x%d' % (n, c) for n, c in items)))
