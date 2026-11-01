# Пакет ассетов

Все ассеты генерирует одна команда (`node brand/src/buildAssets.mjs --verify`) из генератора знака
Растеризация — resvg, sharp или Pillow, установленные в Caches, не в проект

## Состав

- `marks/` — варианты знака, компоновки, чертёж построения, чистые SVG с `viewBox` и `<title>`
- `app/ios/` — AppIcon 1024×1024 PNG без альфа-канала
- `app/android/` — адаптивная иконка: foreground (знак в безопасной зоне 66/108), background, monochrome для Android 13+, SVG и PNG 432; legacy mipmap mdpi…xxxhdpi
- `app/capacitor/` — исходники в раскладке `@capacitor/assets`: icon-only, icon-foreground, icon-background по 1024, splash и splash-dark по 2732
- `web/` — favicon.svg, favicon.ico, apple-touch-icon 180, PWA 192 и 512, maskable 512, OG 1200×630, фрагмент `site.webmanifest`
Размеры и раскладку брать из исходников пакетов и документации платформ, не по памяти

## Неочевидное

- `@capacitor/assets` (3.0.5) кладёт слои адаптивной иконки во внутренний отступ 16,7 %, поэтому знак в `icon-foreground.png` укладывается в круг 66/72, а не 66/108
- Сгенерированный им `ic_launcher.xml` слоя monochrome не содержит: монохромный слой добавляется своим образцом
- favicon.ico — на плашке основного цвета: знак без плашки на тёмной вкладке теряет контраст
- favicon.svg — без плашки, тема через `prefers-color-scheme` внутри SVG
- Chrome (проверено headless 25.10.2026) при `<link rel="icon" href="/favicon.svg" type="image/svg+xml">` и `<link rel="icon" href="/favicon.ico" sizes="48x48">` берёт svg на 1x и 2x
  Без `sizes="48x48"` у ico Chrome берёт ico вместо svg
- Слот вкладки — 16 CSS px: svg рисуется на 16 px при 1x и на 32 px при 2x, поэтому упрощённый знак строится на сетке 16 и масштабируется ровно вдвое
- Safari и Firefox выбирают иначе — проверять в них, а не переносить вывод из Chrome

## Проверка

`verifyAssets`: размеры и каналы PNG, чистота SVG, безопасные зоны на растре, каждый кадр ico и favicon.svg совпадают с перерисовкой
Листы просмотра (иконки под масками, компоновки, малые размеры с увеличением) — в Caches, смотреть глазами
