#!/usr/bin/env python3
"""打包 KernelSU 模块 zip：只收模块运行必需的文件，输出到仓库根目录。"""
import os
import re
import sys
import zipfile

HERE = os.path.dirname(os.path.abspath(__file__))
FILES = [
    'config.conf',
    'customize.sh',
    'module.prop',
    'service.sh',
    'watch.sh',
    'webui.sh',
    'webroot/demo-icons.js',
    'webroot/index.html',
    'webroot/ksu.js',
    'webroot/resparse.js',
]


def version():
    with open(os.path.join(HERE, 'module.prop'), encoding='utf-8') as f:
        m = re.search(r'^version=(.+)$', f.read(), re.M)
    return (m.group(1).strip() if m else 'v0.0').lstrip('v')


def main():
    ver = version()
    out = os.path.join(os.path.dirname(HERE), 'shizuku_keep_v%s.zip' % ver)
    if os.path.exists(out):
        os.remove(out)
    with zipfile.ZipFile(out, 'w', zipfile.ZIP_DEFLATED) as z:
        for name in FILES:
            src = os.path.join(HERE, name.replace('/', os.sep))
            if not os.path.isfile(src):
                sys.exit('缺少文件: ' + name)
            z.write(src, name)
    print('%s  %d bytes' % (os.path.basename(out), os.path.getsize(out)))
    for n in zipfile.ZipFile(out).namelist():
        print('  ' + n)


if __name__ == '__main__':
    main()
