# -*- coding: utf-8 -*-
from html import escape

GREY = "#c4c4b9"; ARROW = "#9d9d94"; BLUE_F = "#e3edf8"; BLUE_S = "#3b7dc4"

DONE_F = "#f3f2ec"

def box(x, y, w, h, title, lines=(), hl=False, done=False):
    fill, stroke, sw = (BLUE_F, BLUE_S, 2) if hl else ((DONE_F, GREY, 1.3) if done else ("#fff", GREY, 1.3))
    out = [f'<rect x="{x}" y="{y}" width="{w}" height="{h}" rx="10" fill="{fill}" stroke="{stroke}" stroke-width="{sw}"/>']
    cx = x + w / 2
    out.append(f'<text x="{cx}" y="{y+23}" text-anchor="middle" class="bt">{escape(title)}</text>')
    for i, l in enumerate(lines):
        out.append(f'<text x="{cx}" y="{y+23+18*(i+1)}" text-anchor="middle" class="bs">{escape(l)}</text>')
    return "\n".join(out)

def arrow(x1, y1, x2, y2, both=False):
    s = ' marker-start="url(#ah)"' if both else ''
    return f'<line x1="{x1}" y1="{y1}" x2="{x2}" y2="{y2}" stroke="{ARROW}" stroke-width="1.2" marker-end="url(#ah)"{s}/>'

def label(x, y, t, anchor="start"):
    return f'<text x="{x}" y="{y}" text-anchor="{anchor}" class="lb">{escape(t)}</text>'

DEFS = f'''<defs><marker id="ah" viewBox="0 0 10 10" refX="9" refY="5" markerWidth="7" markerHeight="7" orient="auto-start-reverse">
<path d="M1 1 L9 5 L1 9" fill="none" stroke="{ARROW}" stroke-width="1.4" stroke-linecap="round" stroke-linejoin="round"/></marker></defs>'''

def svg(h, title, body):
    return (f'<svg viewBox="-3 0 706 {h}" xmlns="http://www.w3.org/2000/svg" role="img">{DEFS}'
            f'<text x="0" y="16" class="st">{escape(title)}</text>\n{body}</svg>')


# ---------- схема 1: архитектура ----------
a = []
a.append(box(0, 36, 145, 74, "Браузер", ["рабочее место, кабинет,", "интернет-магазин"]))
a.append(box(185, 36, 145, 74, "Агент оборудования", ["Rust, на рабочем месте:", "ККТ, терминалы, сканеры"]))
a.append(box(370, 36, 145, 74, "Программа", ["Tauri 2: Win, macOS,", "Linux, сервер внутри"]))
a.append(box(555, 36, 145, 74, "Мобильное", ["Tauri 2: Android, iOS", "ревизия, приёмка, касса"]))
a.append(arrow(145, 73, 185, 73, True)); a.append(label(165, 66, "WS", "middle"))
a.append(arrow(330, 73, 370, 73, True)); a.append(label(350, 66, "WS", "middle"))
for cx, anchor, lx in ((72, "start", 82), (442, "start", 452), (627, "end", 617)):
    a.append(arrow(cx, 110, cx, 168, True)); a.append(label(lx, 144, "HTTPS · WSS", anchor))
a.append(box(0, 168, 700, 66, "Сервер", ["Bun, TypeScript: REST API · WebSocket · витрина"], hl=True))
mods = [
    ("Учёт", ["документы, регистры,", "права, аудит"]),
    ("Прайс", ["адаптеры поставщиков,", "офлайн-прайсы"]),
    ("Роботы и очередь", ["pg-boss в PostgreSQL,", "без Redis"]),
    ("Интеграции", ["платежи, банки,", "ЭДО, маркетплейсы"]),
    ("Витрина", ["SSR, SEO, свои", "домены магазинов"]),
]
for i, (t, ls) in enumerate(mods):
    x = i * 142
    a.append(box(x, 290, 132, 70, t, ls))
    a.append(arrow(x + 66, 234, x + 66, 290, True))
    a.append(arrow(x + 66, 360, x + 66, 420, True))
a.append(box(0, 420, 700, 70, "PostgreSQL", ["реестр тенантов platform · база на каждого клиента tenant_<id>", "общая база shared: бренды, синонимы, кроссы, только чтение"]))
a.append(label(0, 520, "Рядом с сервером в облаке", "start"))
a.append(box(0, 530, 212, 70, "Кабинет облака", ["внутри server/:", "регистрация, тарифы, лимиты"]))
a.append(box(244, 530, 212, 70, "Caddy", ["TLS и домены", "интернет-магазинов"]))
a.append(box(488, 530, 212, 70, "Prometheus и Grafana", ["метрики и алерты", "прод-стенда облака"]))
SVG1 = svg(612, "Один сервер, база на каждого клиента", "\n".join(a))

# ---------- схема 2: жизнь документа ----------
c = []
W, G = 154, 28
xs = [i * (W + G) for i in range(4)]
data = [
    ("1. Черновик", ["правка, нумерация", "остаток не уменьшает"], False),
    ("2. Проведение", ["одна транзакция:", "проверки → движения", "→ статус"], True),
    ("3. Регистры", ["остаток — сумма", "движений, партии, FIFO"], False),
    ("4. Отмена проведения", ["движения удаляются,", "снимок уходит в аудит"], False),
]
for x, (t, ls, hl) in zip(xs, data):
    c.append(box(x, 36, W, 100, t, ls, hl))
for i in range(3):
    c.append(arrow(xs[i] + W, 86, xs[i + 1], 86))
c.append(f'<path d="M{xs[3]+W/2} 136 V170 H{xs[0]+W/2} V140" fill="none" stroke="{ARROW}" stroke-width="1.2" marker-end="url(#ah)"/>')
c.append(label(350, 192, "Отмена возвращает документ в черновик; закрытый период править нельзя", "middle"))
SVG2 = svg(204, "Каждое изменение учёта — документ, остатки — сумма его движений", "\n".join(c))

# ---------- схема 3: дорожная карта ----------
STAGES = [
    ("0 · Старт", ["структура, ТЗ, ADR", "ГЕЙТ 0 пройден"], "done"),
    ("1 · Разведка", ["исследования", "ГЕЙТ 1 пройден"], "done"),
    ("2 · Дизайн", ["62 экрана-прототипа", "ГЕЙТ 2 пройден"], "done"),
    ("3 · Платформа", ["ядро, вход, каркас UI", "14 из 18 пунктов"], "now"),
    ("4 · Склад", ["справочники, приход,", "ревизия"], ""),
    ("5 · Деньги", ["кассы, авансы,", "акт сверки"], ""),
    ("6 · Продажи", ["клиенты, цены,", "быстрая продажа"], ""),
    ("7 · Оборудование", ["агент и ККТ,", "ГЕЙТ 7.1 и ГЕЙТ 7"], ""),
    ("8 · Прайс", ["поставщики, заказы", "ГЕЙТ 8 · MVP-1"], ""),
    ("9 · Автосервис", ["заказ-наряд, запись,", "хранение шин"], ""),
    ("10 · Сотрудники", ["зарплата, планы,", "премии"], ""),
    ("11 · Печать", ["печатные формы,", "ГЕЙТ 11.1"], ""),
    ("12 · Связь", ["почта, SMS, чаты,", "телефония"], ""),
    ("13 · Площадки", ["крупные торговые", "площадки"], ""),
    ("14 · Магазин", ["витрина, домены,", "ГЕЙТ 14.1"], ""),
    ("15 · API и сеть", ["API партнёров,", "вебхуки, сеть"], ""),
    ("16 · Редакции", ["кабинет, лицензии,", "ГЕЙТ 16"], ""),
    ("17 · Мобильное", ["ревизия, продажа,", "ГЕЙТ 17.1"], ""),
    ("18 · Запуск", ["прод-стенд, перенос", "ГЕЙТ 18 · старт"], ""),
]
d = []
BW, BG, BH, RG = 127, 16, 76, 34
def pos(i):
    r, k = divmod(i, 5)
    return k * (BW + BG), 36 + r * (BH + RG)
for i, (t, ls, st) in enumerate(STAGES):
    x, y = pos(i)
    d.append(box(x, y, BW, BH, t, ls, hl=(st == "now"), done=(st == "done")))
    if i + 1 < len(STAGES):
        x2, y2 = pos(i + 1)
        if y2 == y:
            d.append(arrow(x + BW, y + BH / 2, x2, y2 + BH / 2))
        else:
            cx, cx2 = x + BW / 2, x2 + BW / 2
            d.append(f'<path d="M{cx} {y+BH} V{y+BH+RG/2} H{cx2} V{y2-2}" fill="none" stroke="{ARROW}" stroke-width="1.2" marker-end="url(#ah)"/>')
lx, ly = 4 * (BW + BG), 36 + 3 * (BH + RG)
for k, (fill, stroke, sw, txt) in enumerate(((DONE_F, GREY, 1.3, "пройдено"), (BLUE_F, BLUE_S, 2, "идёт сейчас"), ("#fff", GREY, 1.3, "впереди"))):
    yy = ly + 6 + k * 24
    d.append(f'<rect x="{lx+8}" y="{yy}" width="22" height="14" rx="4" fill="{fill}" stroke="{stroke}" stroke-width="{sw}"/>')
    d.append(label(lx + 40, yy + 11, txt))
H3 = 36 + 4 * (BH + RG) - RG + 12
SVG3 = svg(H3, "Девятнадцать этапов; ГЕЙТ — остановка до решения оператора", "\n".join(d))

HTML = open("template.html", encoding="utf-8").read()
HTML = HTML.replace("{{SVG1}}", SVG1).replace("{{SVG2}}", SVG2).replace("{{SVG3}}", SVG3)
open("index.html", "w", encoding="utf-8").write(HTML)
print("ok", len(HTML))
