#!/usr/bin/env bash
# Проверка общего кэша сборки Cargo у worker.sh: worktree одного репозитория получают один CARGO_TARGET_DIR,
# чужие репозитории, workspace, выключатель, ручные пути и конфиг Cargo — разное или ничего
# Запуск: bash skills/brigadier/worker/test_cargo_cache.sh
# Реальный Rust не нужен: сборку изображает подставной cargo, который печатает доставшийся каталог
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
WORKER="$HERE/worker.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

fail() { echo "ПРОВАЛ: $*" >&2; exit 1; }

check_eq() { # описание, ожидаемое, фактическое
  [ "$2" = "$3" ] || fail "$1: ожидалось «$2», получено «$3»"
}

# Подставной cargo печатает каталог сборки, который ему достался от worker.sh
mkdir -p "$TMP/bin"
cat >"$TMP/bin/cargo" <<'SH'
#!/usr/bin/env bash
printf 'FAKE_CARGO_TARGET_DIR=%s\n' "${CARGO_TARGET_DIR:-}"
SH
chmod +x "$TMP/bin/cargo"
FAKE="$TMP/bin/cargo"

# Изоляция: чужое окружение, конфиг Cargo, личный git и квитанции движка не должны влиять на проверку
unset CARGO_TARGET_DIR BRIGADIER_WORKER_CARGO_TARGET BRIGADIER_WORKER_CARGO_TARGETS
export CARGO_HOME="$TMP/cargo-home"
mkdir -p "$CARGO_HOME"
export BRIGADIER_WORKER_WORKTREES="$TMP/worktrees"
mkdir -p "$TMP/worktrees"
export VIBEMEMORY_DIR="$TMP/vibememory"
export GIT_CONFIG_GLOBAL="$TMP/gitconfig"
export GIT_CONFIG_SYSTEM="$TMP/gitconfig-system"
: >"$GIT_CONFIG_GLOBAL"
: >"$GIT_CONFIG_SYSTEM"
export GIT_AUTHOR_NAME=probe GIT_AUTHOR_EMAIL=probe@example.com
export GIT_COMMITTER_NAME=probe GIT_COMMITTER_EMAIL=probe@example.com

make_repo() { # путь, нужен ли Cargo.toml
  local path="$1" with_cargo="${2:-1}"
  mkdir -p "$path"
  git -C "$path" init -q
  if [ "$with_cargo" = 1 ]; then
    printf '[package]\nname = "probe"\nversion = "0.1.0"\n' >"$path/Cargo.toml"
  fi
  printf 'probe\n' >"$path/README.probe"
  git -C "$path" add -A
  git -C "$path" commit -q -m base
}

# gates с подставным cargo: печатает доставшийся CARGO_TARGET_DIR, причина ошибки или пропуска — в err-файле
# Метка делает имена файлов уникальными: проверка параллельных запусков пишет в них одновременно
gates_cache() {
  local tag="$1" out rc=0
  shift
  out="$(bash "$WORKER" gates "$@" -- "$FAKE" build 2>"$TMP/gates-$tag.err")" || rc=$?
  if [ "$rc" -ne 0 ]; then
    printf 'ОШИБКА gates(%s): %s\n' "$tag" "$(cat "$TMP/gates-$tag.err")" >&2
    printf '%s\n' "__ERROR__"
    return 0
  fi
  printf '%s\n' "$out" | sed -n 's/^FAKE_CARGO_TARGET_DIR=//p' | tail -n 1
}

REPO_A="$TMP/repo-a"
make_repo "$REPO_A"
WT_A2="$TMP/wt-a2"
git -C "$REPO_A" worktree add -q -b probe-wt "$WT_A2" HEAD >/dev/null 2>&1 || fail "не создать worktree"

# 1. Два worktree одного репозитория — один общий каталог сборки
C_MAIN="$(gates_cache a1 --dir "$REPO_A")"
C_WT="$(gates_cache a2 --dir "$WT_A2")"
[ "$C_MAIN" != "__ERROR__" ] || fail "gates в основном дереве упали"
[ "$C_WT" != "__ERROR__" ] || fail "gates в worktree упали"
[ -n "$C_MAIN" ] || fail "автоматический кэш не выбран: $(cat "$TMP/gates-a1.err")"
check_eq "два worktree одного репозитория" "$C_MAIN" "$C_WT"
case "$C_MAIN" in
  "$TMP/targets/"*) ;;
  *) fail "кэш не в sibling targets у WORKTREES_ROOT: $C_MAIN" ;;
esac
NAME="$(basename "$C_MAIN")"
KEY="${NAME##*-}"
case "$NAME" in
  repo-a-*) ;;
  *) fail "имя каталога не <repo>-<key>: $NAME" ;;
esac
[ "${#KEY}" = 12 ] || fail "ключ не 12 hex: $NAME"
case "$KEY" in
  *[!0-9a-f]*) fail "ключ не hex: $KEY" ;;
esac
echo "ок: два worktree одного репозитория — общий кэш $C_MAIN"

# 2. Другой репозиторий и другой Cargo workspace того же репозитория — свои каталоги
REPO_B="$TMP/repo-b"
make_repo "$REPO_B"
C_B="$(gates_cache b --dir "$REPO_B")"
[ "$C_B" != "__ERROR__" ] || fail "gates в другом репозитории упали"
[ -n "$C_B" ] && [ "$C_B" != "$C_MAIN" ] || fail "другой репозиторий получил тот же кэш: $C_B"
mkdir -p "$REPO_A/sub"
printf '[package]\nname = "probe-sub"\nversion = "0.1.0"\n' >"$REPO_A/sub/Cargo.toml"
git -C "$REPO_A" add -A
git -C "$REPO_A" commit -q -m sub
C_SUB="$(gates_cache sub --dir "$REPO_A/sub")"
[ "$C_SUB" != "__ERROR__" ] || fail "gates во вложенном workspace упали"
[ -n "$C_SUB" ] && [ "$C_SUB" != "$C_MAIN" ] || fail "другой workspace получил тот же кэш: $C_SUB"
echo "ок: другой репозиторий и другой workspace изолированы"

# 3. Выключатель: off и none не задают каталог, причина печатается
C_OFF="$(
  export BRIGADIER_WORKER_CARGO_TARGET=off
  gates_cache off --dir "$REPO_A"
)"
check_eq "BRIGADIER_WORKER_CARGO_TARGET=off" "" "$C_OFF"
grep -q 'BRIGADIER_WORKER_CARGO_TARGET=off' "$TMP/gates-off.err" || fail "off: нет причины пропуска в выводе"
C_NONE="$(
  export BRIGADIER_WORKER_CARGO_TARGET=none
  gates_cache none --dir "$REPO_A"
)"
check_eq "BRIGADIER_WORKER_CARGO_TARGET=none" "" "$C_NONE"
echo "ок: выключатель off|none не задаёт кэш"

# 4. Значение-путь выключателя задаёт каталог
C_PATH="$(
  export BRIGADIER_WORKER_CARGO_TARGET="$TMP/manual-target"
  gates_cache path --dir "$REPO_A"
)"
check_eq "ручной путь" "$TMP/manual-target" "$C_PATH"
echo "ок: ручной путь из BRIGADIER_WORKER_CARGO_TARGET доставлен как есть"

# 5. Существующий CARGO_TARGET_DIR не меняется
C_ENV="$(
  export CARGO_TARGET_DIR="$TMP/env-target"
  gates_cache env --dir "$REPO_A"
)"
check_eq "существующий CARGO_TARGET_DIR" "$TMP/env-target" "$C_ENV"
echo "ок: существующий CARGO_TARGET_DIR не перекрыт"

# 6. Собственный build.target-dir проекта не перекрывается автоматическим кэшем
REPO_C="$TMP/repo-c"
make_repo "$REPO_C"
mkdir -p "$REPO_C/.cargo"
printf '[build]\ntarget-dir = "own-target"\n' >"$REPO_C/.cargo/config.toml"
git -C "$REPO_C" add -A
git -C "$REPO_C" commit -q -m cargo-config
C_CFG="$(gates_cache cfg --dir "$REPO_C")"
check_eq "build.target-dir проекта" "" "$C_CFG"
grep -q 'target-dir' "$TMP/gates-cfg.err" || fail "нет причины пропуска про конфиг Cargo: $(cat "$TMP/gates-cfg.err")"
echo "ок: build.target-dir из .cargo/config.toml не перекрыт"

# 7. --target-dir сильнее выключателя и уже заданного окружения
C_CLI="$(
  export BRIGADIER_WORKER_CARGO_TARGET=off
  export CARGO_TARGET_DIR="$TMP/env-target"
  gates_cache cli --dir "$REPO_A" --target-dir "$TMP/cli-target"
)"
check_eq "--target-dir сильнее off и env" "$TMP/cli-target" "$C_CLI"
echo "ок: --target-dir сильнее остальных источников"

# 8. Нет Cargo.toml — прежнее поведение: каталог не задаётся, gates работают
REPO_D="$TMP/repo-d"
make_repo "$REPO_D" 0
C_NO="$(gates_cache nocargo --dir "$REPO_D")"
[ "$C_NO" != "__ERROR__" ] || fail "gates в репозитории без Cargo.toml упали"
check_eq "без Cargo.toml" "" "$C_NO"
grep -q 'Cargo workspace' "$TMP/gates-nocargo.err" || fail "нет причины пропуска про отсутствие Cargo"
echo "ок: без Cargo.toml поведение прежнее"

# 9. Квитанция гейтов несёт cache=, merge по ней по-прежнему вливает
REPO_E="$TMP/repo-e"
make_repo "$REPO_E"
WT_E="$TMP/wt-e"
git -C "$REPO_E" worktree add -q -b probe-merge "$WT_E" HEAD >/dev/null 2>&1 || fail "не создать worktree для merge"
C_E="$(gates_cache e --dir "$WT_E")"
RECEIPT="$(git -C "$WT_E" rev-parse --absolute-git-dir)/brigadier-gates"
[ -f "$RECEIPT" ] || fail "квитанция гейтов не написана: $RECEIPT"
for key in tree= head= at= cmd= cache=; do
  grep -q "^$key" "$RECEIPT" || fail "в квитанции нет $key: $(cat "$RECEIPT")"
done
[ "$(sed -n 's/^cache=//p' "$RECEIPT")" = "$C_E" ] || fail "cache= в квитанции не совпал с выбранным путём: $(cat "$RECEIPT")"
bash "$WORKER" merge --dir "$REPO_E" --branch probe-merge >/dev/null 2>&1 || fail "merge после гейтов отказал"
echo "ок: квитанция с cache=, merge вливает"

# 10. Два параллельных gates: оба зелёные и видят один каталог
gates_cache p1 --dir "$REPO_A" >"$TMP/p1.txt" &
P1_PID=$!
gates_cache p2 --dir "$WT_A2" >"$TMP/p2.txt" &
P2_PID=$!
wait "$P1_PID"
wait "$P2_PID"
P1="$(cat "$TMP/p1.txt")"
P2="$(cat "$TMP/p2.txt")"
[ -n "$P1" ] && [ "$P1" != "__ERROR__" ] || fail "первый параллельный gates: $P1"
[ -n "$P2" ] && [ "$P2" != "__ERROR__" ] || fail "второй параллельный gates: $P2"
check_eq "два параллельных gates" "$P1" "$P2"
echo "ок: два параллельных gates видят один каталог"

echo "всё прошло"
