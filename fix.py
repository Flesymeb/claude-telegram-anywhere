#!/usr/bin/env python3
"""
额外修复脚本，在 apply-claude-code-channels-bypass-fix.sh 之后运行。
需要 sudo：sudo python3 fix-extra.py
"""

path = '/usr/local/lib/node_modules/@anthropic-ai/claude-code/cli.js'

with open(path, 'r') as f:
    code = f.read()

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

with open(path, 'w') as f:
    f.write(code)

print('Done.')
