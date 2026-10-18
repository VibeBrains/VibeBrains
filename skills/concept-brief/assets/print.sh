#!/bin/bash
# Сборка и печать: template.html = head.part + body.part, build.py вставляет схемы, chrome-headless-shell печатает PDF
# Запуск: ./print.sh "<Имя итогового файла>.pdf"
cd "$(dirname "$0")" || exit 1
cat head.part body.part > template.html || exit 1
python3 build.py || exit 1
CH=$(ls -d "${PLAYWRIGHT_BROWSERS_PATH:-/nonexistent}"/chromium_headless_shell-*/chrome-headless-shell-*/chrome-headless-shell \
  ~/Library/Caches/ms-playwright/chromium_headless_shell-*/chrome-headless-shell-*/chrome-headless-shell \
  ~/.cache/ms-playwright/chromium_headless_shell-*/chrome-headless-shell-*/chrome-headless-shell 2>/dev/null | tail -1)
[ -x "$CH" ] || { echo "нет chrome-headless-shell: npx playwright install chromium-headless-shell"; exit 1; }
"$CH" --no-sandbox --disable-gpu --no-pdf-header-footer --print-to-pdf="out.pdf" "file://$PWD/index.html" 2>&1 | grep written
cp out.pdf "${1:-brief.pdf}"
python3 -c "import re;d=open('out.pdf','rb').read();print('pages',len(re.findall(rb'/Type\s*/Page[^s]',d)))"
