#!/usr/bin/env python3
"""
额外修复脚本，在 apply-claude-code-channels-bypass-fix.sh 之后运行。
需要 sudo：sudo python3 fix.py
"""

import os
import shutil
import subprocess
import sys
from datetime import datetime

RELATIVE_CLI = '@anthropic-ai/claude-code/cli.js'


def _npm_global_root():
    try:
        result = subprocess.run(
            ['npm', 'root', '-g'],
            check=True, capture_output=True, text=True,
        )
        return result.stdout.strip() or None
    except (FileNotFoundError, subprocess.CalledProcessError):
        return None


def _real_home():
    """sudo 场景下返回原用户的 home，而非 /root。"""
    sudo_user = os.environ.get('SUDO_USER')
    if sudo_user:
        import pwd
        try:
            return pwd.getpwnam(sudo_user).pw_dir
        except KeyError:
            pass
    return os.path.expanduser('~')


def _candidate_paths():
    """返回所有候选安装路径（已展开，去重保序）。"""
    home = _real_home()
    raw = [
        os.path.join(home, '.claude', 'local', 'node_modules', RELATIVE_CLI),
        '/usr/local/lib/node_modules/' + RELATIVE_CLI,
        '/usr/lib/node_modules/' + RELATIVE_CLI,
    ]
    npm_root = _npm_global_root()
    if npm_root:
        raw.append(os.path.join(npm_root, RELATIVE_CLI))

    seen, result = set(), []
    for p in raw:
        if p not in seen:
            seen.add(p)
            result.append(p)
    return result


def _find_cli_path(candidates):
    for p in candidates:
        if os.path.isfile(p):
            return p
    return None


def _check_access(path):
    if not os.access(path, os.R_OK):
        print(f'Error: no read permission: {path}', file=sys.stderr)
        sys.exit(1)
    if not os.access(path, os.W_OK):
        print(f'Error: no write permission: {path}', file=sys.stderr)
        print('Hint: try running with sudo.', file=sys.stderr)
        sys.exit(1)


def _backup(path):
    timestamp = datetime.now().strftime('%Y%m%d%H%M%S%f')
    backup_path = f'{path}.bak.{timestamp}'
    shutil.copy2(path, backup_path)
    print(f'Backup: {backup_path}')


def _apply_fixes(code):
    # Fix 1: BH() 可能返回 null，加 ||[] 兜底，防止 .length 报错
    old1 = 'let A=BH();let q=A.length'
    new1 = 'let A=BH()||[];let q=A.length'
    if old1 in code:
        code = code.replace(old1, new1, 1)
        print('Fix 1 applied: BH() null safety')
    elif new1 in code:
        print('Fix 1 already applied')
    else:
        print('Fix 1 pattern not found')

    # Fix 2: 返回对象缺少 unmatched 字段导致报错
    old2 = 'return{channels:A,disabled:!1,noAuth:!1,policyBlocked:!1,list:q}}'
    new2 = 'return{channels:A,disabled:!1,noAuth:!1,policyBlocked:!1,list:q,unmatched:[]}}'
    if old2 in code:
        code = code.replace(old2, new2, 1)
        print('Fix 2 applied: added unmatched:[]')
    elif new2 in code:
        print('Fix 2 already applied')
    else:
        print('Fix 2 pattern not found')

    return code


def main():
    candidates = _candidate_paths()
    path = _find_cli_path(candidates)
    if not path:
        print('Error: Claude Code cli.js not found. Checked:', file=sys.stderr)
        for c in candidates:
            print(f'  {c}', file=sys.stderr)
        sys.exit(1)

    print(f'Found: {path}')
    _check_access(path)

    with open(path, 'r', encoding='utf-8') as f:
        code = f.read()

    new_code = _apply_fixes(code)
    if new_code == code:
        print('No changes needed.')
        return

    _backup(path)
    with open(path, 'w', encoding='utf-8') as f:
        f.write(new_code)

    print('Done.')


if __name__ == '__main__':
    main()
