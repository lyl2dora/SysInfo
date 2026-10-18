#!/bin/bash
# 公开仓库防泄漏检查（D77）：扫描所有已跟踪和已暂存的文件，发现以下内容就失败。
#   - 私网 IPv4（10/8、172.16/12、192.168/16）：内网机器地址不进库
#   - 家目录路径（/Users/<名字>、Claude 临时目录里的 -Users-<名字>-）
#   - UUID 与 MAC 地址（scripts/leak-allowlist.txt 里列出的编造值除外）
#   - /Volumes/<卷名>（/System/Volumes/* 与 allowlist 里的通用卷名除外）
#   - 带真名的签名身份「Developer ID Application: <名字>」
#   - 可选的本地黑名单 Config/leak-denylist.local（不进库，每行一个词，例如个人软件名）
# 用法：scripts/check-leaks.sh            检查整个仓库
#       scripts/check-leaks.sh <文件…>     只检查给定文件（测试用）
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root"
allow_file="scripts/leak-allowlist.txt"
deny_file="Config/leak-denylist.local"

if [ $# -gt 0 ]; then
    files=("$@")
else
    files=()
    while IFS= read -r -d '' f; do
        [ -f "$f" ] && files+=("$f")
    done < <(git ls-files -z --cached)
fi

python3 -I - "$allow_file" "$deny_file" "${files[@]}" <<'EOF'
import re, sys, os

allow_file, deny_file, *files = sys.argv[1:]
allow = set()
if os.path.exists(allow_file):
    for line in open(allow_file, encoding='utf-8'):
        line = line.split('#', 1)[0].strip()
        if line:
            allow.add(line.lower())

checks = [
    ('私网 IPv4', re.compile(r'(?<![\d.])(?:10\.\d{1,3}|172\.(?:1[6-9]|2\d|3[01])|192\.168)\.\d{1,3}\.\d{1,3}(?![\d.])')),
    ('家目录路径', re.compile(r'/Users/(?!Shared\b)[A-Za-z0-9._-]+|-Users-[A-Za-z0-9._]+-')),
    ('UUID', re.compile(r'\b[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}\b')),
    ('MAC 地址', re.compile(r'(?<![0-9A-Fa-f:])(?:[0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}(?![0-9A-Fa-f:])')),
    ('卷名', re.compile(r'(?<!/System)/Volumes/[^\s"\'`)/\]]+')),
    ('签名身份里的名字', re.compile(r'Developer ID Application: [^"\'`(\n]*[A-Za-z]')),
]
if os.path.exists(deny_file):
    words = [w.strip() for w in open(deny_file, encoding='utf-8') if w.strip() and not w.startswith('#')]
    if words:
        checks.append(('本地黑名单', re.compile('|'.join(re.escape(w) for w in words), re.I)))

# 本脚本和 allowlist 自身含有模式说明，跳过
skip = {'scripts/check-leaks.sh', allow_file}
bad = 0
for f in files:
    if f in skip:
        continue
    try:
        text = open(f, encoding='utf-8').read()
    except (UnicodeDecodeError, IsADirectoryError, FileNotFoundError):
        continue
    for no, line in enumerate(text.splitlines(), 1):
        for name, rx in checks:
            for m in rx.finditer(line):
                hit = m.group(0)
                if hit.lower() in allow:
                    continue
                print(f'{f}:{no}: {name}: {hit}')
                bad += 1
if bad:
    print(f'check-leaks: 发现 {bad} 处可能泄漏的内容（D77）。确属编造的测试值时加进 scripts/leak-allowlist.txt。', file=sys.stderr)
    sys.exit(1)
print(f'check-leaks: OK（{len(files)} 个文件）')
EOF
