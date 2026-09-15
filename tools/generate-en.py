"""Regenerate English application sources from tracked Russian sources.

Run with Python 3 from any directory. English documentation is maintained separately.
"""
from pathlib import Path
import shutil
import subprocess

root = Path(__file__).resolve().parents[1]
pairs = [line.split('\t', 1) for line in
         (root / 'tools/en-translations.tsv').read_text(encoding='utf-8').splitlines()]
tracked = subprocess.check_output(['git', '-C', str(root), 'ls-files'], text=True).splitlines()
for name in tracked:
    if not name.startswith(('windows/', 'macos/')) or name.endswith('.md'):
        continue
    src, dest = root / name, root / 'en' / name
    dest.parent.mkdir(parents=True, exist_ok=True)
    if src.suffix in {'.cs', '.swift', '.xaml', '.ps1', '.command', '.plist'}:
        content = src.read_text(encoding='utf-8-sig')
        for ru, en in sorted(pairs, key=lambda pair: -len(pair[0])):
            content = content.replace(ru, en)
        content = content.replace('%D0%94%D0%B0', 'Yes')
        dest.write_text(content, encoding='utf-8')
    else:
        shutil.copy2(src, dest)
