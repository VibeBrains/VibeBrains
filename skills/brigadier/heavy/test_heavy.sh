#!/usr/bin/env bash
# Проверка heavy: вложенный запуск не ждёт слот, независимые запуски по-прежнему друг за другом
# Запуск: bash skills/brigadier/heavy/test_heavy.sh
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
HEAVY="$HERE/heavy"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# Очередь в песочнице: один слот, ждём без конца, опрос раз в секунду
export HEAVY_DIR="$TMP/heavy"
export HEAVY_SLOTS=1
export HEAVY_MAX_WAIT_MIN=0
export HEAVY_POLL=1
export HEAVY_WARN_MIN_GB=0
# Проверка памяти не должна влиять на время: на стенде давление может быть любым
export HEAVY_CRITICAL_PRESSURE=99
# Тест может сам идти внутри heavy: метка предка сломала бы проверку независимых запусков
unset HEAVY_HELD

fail() { echo "ПРОВАЛ: $*" >&2; exit 1; }
now() { date +%s; }

# 1. Вложенный heavy run завершается за секунды, а не ждёт слот предка
start=$(now)
out="$("$HEAVY" run -- "$HEAVY" run -- true 2>&1)" || fail "вложенный запуск упал: $out"
elapsed=$(( $(now) - start ))
[ "$elapsed" -le 10 ] || fail "вложенный запуск шёл ${elapsed}с вместо секунд"
case "$out" in *"без очереди"*) ;; *) fail "нет строки про вложенный запуск: $out" ;; esac
echo "ок: вложенный heavy run завершился за ${elapsed}с"

# 2. Пока вложенный работает, heavy status показывает только настоящего держателя слота
export TMP HEAVY_BIN="$HEAVY"
"$HEAVY" run --name "проверка: вложенный" -- bash -c '
  "$HEAVY_BIN" run -- bash -c "touch \"$TMP/inner.started\"; sleep 1" &
  inner=$!
  sleep 0.3
  "$HEAVY_BIN" status > "$TMP/status.txt"
  wait "$inner"
' >/dev/null 2>&1 || fail "запуск со status внутри упал"
[ -f "$TMP/inner.started" ] || fail "вложенный запуск не стартовал"
holders=$(grep -c 'pid [0-9]' "$TMP/status.txt" || true)
[ "$holders" = 1 ] || fail "heavy status показывает $holders держателей: $(cat "$TMP/status.txt")"
echo "ок: heavy status во время вложенного показывает 1 держателя"

# 3. Метка мёртвого pid — обычная очередь
out="$(HEAVY_HELD=999999 "$HEAVY" run -- true 2>&1)" || fail "мёртвая метка уронила запуск: $out"
case "$out" in *"слот взят"*) ;; *) fail "мёртвая метка не вернула в очередь: $out" ;; esac
echo "ок: мёртвая метка идёт обычной очередью"

# 4. Два независимых запуска по-прежнему последовательны: один слот
start=$(now)
"$HEAVY" run -- sleep 2 >/dev/null 2>&1 &
a=$!
"$HEAVY" run -- sleep 2 >/dev/null 2>&1 &
b=$!
wait "$a" || fail "первый независимый запуск упал"
wait "$b" || fail "второй независимый запуск упал"
elapsed=$(( $(now) - start ))
[ "$elapsed" -ge 3 ] || fail "независимые запуски шли параллельно: ${elapsed}с на двоих"
echo "ок: два независимых запуска шли последовательно за ${elapsed}с"

echo "всё прошло"
