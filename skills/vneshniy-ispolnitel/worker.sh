#!/usr/bin/env bash
# Внешний исполнитель бригадира: отдельный неинтерактивный `claude -p`, у которого только в его процессе
# подменён сервер на Anthropic-совместимый API провайдера
# Главная сессия остаётся на своей подписке: переменные подмены живут только в дочернем процессе
#
# Команды:
#   worker.sh set-key <провайдер>
#   worker.sh import-key <провайдер> [--from-file <путь>]
#   worker.sh check [провайдер]
#   worker.sh run --provider <имя> --tier cheap|strong --effort <уровень> --mode read|write \
#                 --dir <путь> --budget <usd> --brief <файл или -> [--bash-allow "<шаблон>"]… [--allow-main-tree]
#
# Ключ в аргументы командной строки не попадает никогда: ни в свои, ни в чужие процессы

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
USER_PROVIDERS_DIR="${BRIGADIR_WORKER_PROVIDERS:-$HOME/.config/brigadir-worker/providers}"
LOG_FILE="${BRIGADIR_WORKER_LOG:-${XDG_CACHE_HOME:-$HOME/.cache}/brigadir-worker/runs.jsonl}"
CHECK_TIMEOUT_SEC=30
CHECK_MAX_TOKENS=64
PRICES_STALE_DAYS=30
CLAUDE_BIN="${BRIGADIR_WORKER_CLAUDE:-claude}"
DEFAULT_ENV_FILE="${BRIGADIR_WORKER_ENV_FILE:-$HOME/.vibe/.env}"

# Чтение и поиск, без записи и без сети
READ_ALLOWED='Read,Grep,Glob,Bash(ls *),Bash(pwd),Bash(wc *),Bash(rg *),Bash(grep *),Bash(git status*),Bash(git log*),Bash(git diff*),Bash(git show*),Bash(git ls-files*),Bash(git blame*)'
READ_DENIED='Edit,Write,NotebookEdit,WebFetch,WebSearch,Agent,Task'
# Запись только файловыми инструментами в каталоге запуска; коммитит и пушит бригадир
WRITE_ALLOWED="$READ_ALLOWED,Edit,Write"
WRITE_DENIED='NotebookEdit,WebFetch,WebSearch,Agent,Task,Bash(git commit*),Bash(git push*),Bash(git reset*),Bash(git checkout*),Bash(git clean*),Bash(git rebase*),Bash(git merge*),Bash(rm *)'

# Добавка к системному промпту: без CLAUDE.md исполнитель не знает, кто он
WORKER_PROMPT='Ты внешний исполнитель: делай задачу из брифа сам, никому её не передавай и субагентов не запускай. Не коммить и не пушь. В конце дай короткий итог: что сделано, что проверено, что не удалось.'

die() { printf 'ошибка: %s\n' "$*" >&2; exit 1; }

usage() {
  sed -n '2,14p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//' >&2
  exit 1
}

need_python() { command -v python3 >/dev/null 2>&1 || die "нужен python3 (разбор JSON)"; }

# Значение из профиля по пути через точку; список выводится через запятую
prof_get() {
  python3 -I -c '
import json, sys
node = json.load(open(sys.argv[1], encoding="utf-8"))
for part in sys.argv[2].split("."):
    if not isinstance(node, dict) or part not in node:
        sys.exit(3)
    node = node[part]
if isinstance(node, list):
    print(",".join(str(x) for x in node))
elif isinstance(node, dict):
    for k, v in node.items():
        print("%s=%s" % (k, v))
else:
    print(node)
' "$1" "$2"
}

valid_provider() { [[ "$1" =~ ^[a-z0-9][a-z0-9-]*$ ]]; }

# Профиль: сначала пользовательский каталог, потом поставляемый с навыком
find_profile() {
  valid_provider "$1" || die "имя провайдера: строчные латинские буквы, цифры и дефис"
  if [ -f "$USER_PROVIDERS_DIR/$1.json" ]; then
    printf '%s\n' "$USER_PROVIDERS_DIR/$1.json"
  elif [ -f "$SCRIPT_DIR/providers/$1.json" ]; then
    printf '%s\n' "$SCRIPT_DIR/providers/$1.json"
  else
    die "нет профиля провайдера «$1» (искал в $USER_PROVIDERS_DIR и $SCRIPT_DIR/providers)"
  fi
}

# Ключ: переменная окружения, затем хранилище секретов ОС
# Значение печатается только в stdout подстановки, в аргументы оно не попадает
read_key() {
  local profile="$1" service env_name key
  service="$(prof_get "$profile" secret.service)" || die "в профиле нет secret.service"
  env_name="$(prof_get "$profile" secret.env)" || die "в профиле нет secret.env"
  key="${!env_name:-}"
  if [ -z "$key" ]; then
    case "$(uname -s)" in
      Darwin) key="$(security find-generic-password -s "$service" -a "$USER" -w 2>/dev/null || true)" ;;
      Linux)
        if command -v secret-tool >/dev/null 2>&1; then
          key="$(secret-tool lookup service "$service" account "$USER" 2>/dev/null || true)"
        fi
        ;;
    esac
  fi
  printf '%s' "$key"
}

# Запись ключа в хранилище ОС: значение приходит со stdin, в аргументы процессов не попадает
store_secret() {
  local service="$1" env_name="$2" value out
  IFS= read -r value || true
  [ -n "$value" ] || die "пустой ключ"
  case "$(uname -s)" in
    Darwin)
      # `security -i` читает команды со stdin; printf — встроенная команда, значения в argv нет
      local esc="${value//\\/\\\\}"
      esc="${esc//\"/\\\"}"
      out="$(printf 'add-generic-password -U -s "%s" -a "%s" -w "%s"\n' "$service" "$USER" "$esc" | security -i 2>&1)" ||
        die "связка macOS не приняла ключ"
      case "$out" in *rror*) die "связка macOS не приняла ключ" ;; esac
      ;;
    Linux)
      command -v secret-tool >/dev/null 2>&1 || die "нет secret-tool (пакет libsecret-tools); запасной путь — переменная $env_name"
      printf '%s' "$value" | secret-tool store --label="$service" service "$service" account "$USER" ||
        die "secret-tool не принял ключ"
      ;;
    *) die "для этой системы — переменная $env_name" ;;
  esac
}

# Название хранилища для сообщений
store_label() {
  case "$(uname -s)" in
    Darwin) printf 'связку macOS (%s)' "$1" ;;
    Linux) printf 'secret-tool (%s)' "$1" ;;
    *) printf '%s' "$1" ;;
  esac
}

cmd_set_key() {
  local provider="${1:-}" profile service env_name key
  [ -n "$provider" ] || usage
  profile="$(find_profile "$provider")" || exit 1
  service="$(prof_get "$profile" secret.service)" || die "в профиле нет secret.service"
  env_name="$(prof_get "$profile" secret.env)" || die "в профиле нет secret.env"
  # Ключ вводится в приглашении, не в аргументе
  printf 'Вставьте ключ и нажмите Enter (ввод не отображается): '
  IFS= read -rs key
  echo
  printf '%s\n' "$key" | store_secret "$service" "$env_name"
  echo "ключ положен в $(store_label "$service")"
}

# Перенос уже имеющегося ключа в хранилище: из переменной окружения keyEnv и файлов .env
cmd_import_key() {
  local provider="" from_file=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --from-file) from_file="${2:-}"; [ -n "$from_file" ] || die "--from-file: нужен путь"; shift 2 ;;
      -*) die "неизвестный аргумент: $1" ;;
      *) [ -z "$provider" ] || die "лишний аргумент: $1"; provider="$1"; shift ;;
    esac
  done
  [ -n "$provider" ] || usage
  need_python
  local profile service env_name key_env
  profile="$(find_profile "$provider")" || exit 1
  service="$(prof_get "$profile" secret.service)" || die "в профиле нет secret.service"
  env_name="$(prof_get "$profile" secret.env)" || die "в профиле нет secret.env"
  key_env="$(prof_get "$profile" keyEnv)" || die "в профиле нет keyEnv (имя переменной, под которой ключ обычно лежит)"
  if [ -n "$from_file" ] && [ ! -f "$from_file" ]; then die "нет файла $from_file"; fi

  # Вывод: число разных значений, затем источники без значений; при одном значении — строка V: со значением
  local found
  found="$(python3 -I -c '
import os, sys

key_env, from_file, default_file = sys.argv[1:4]

def parse_env(path):
    value = None
    with open(path, encoding="utf-8", errors="replace") as f:
        for raw in f:
            line = raw.strip()
            if not line or line.startswith("#"):
                continue
            if line.startswith("export ") or line.startswith("export\t"):
                line = line[7:].lstrip()
            name, sep, val = line.partition("=")
            if not sep or name.strip() != key_env:
                continue
            val = val.strip()
            if len(val) >= 2 and val[0] == val[-1] and val[0] in (chr(34), chr(39)):
                val = val[1:-1]
            else:
                cut = val.find(" #")
                if cut >= 0:
                    val = val[:cut].rstrip()
            value = val
    return value

sources = []
if from_file:
    v = parse_env(from_file)
    if v:
        sources.append(("%s (%s)" % (from_file, key_env), v))
else:
    v = os.environ.get(key_env)
    if v:
        sources.append(("переменная окружения %s" % key_env, v))
    if os.path.isfile(default_file):
        v = parse_env(default_file)
        if v:
            sources.append(("%s (%s)" % (default_file, key_env), v))
distinct = {v for _, v in sources}
print(len(distinct))
for label, _ in sources:
    print("S:" + label)
if len(distinct) == 1:
    print("V:" + next(iter(distinct)))
' "$key_env" "$from_file" "$DEFAULT_ENV_FILE")" || die "не удалось разобрать источники"

  local count
  count="$(printf '%s\n' "$found" | sed -n '1p')"
  case "$count" in
    0)
      if [ -n "$from_file" ]; then
        echo "import-key: в $from_file нет $key_env" >&2
      else
        echo "import-key: ключ $key_env не найден ни в переменной окружения, ни в $DEFAULT_ENV_FILE" >&2
      fi
      echo "Положите ключ вручную: worker.sh set-key $provider" >&2
      return 1
      ;;
    1)
      local label value
      label="$(printf '%s\n' "$found" | sed -n 's/^S://p' | sed -n '1p')"
      value="$(printf '%s\n' "$found" | sed -n 's/^V://p')"
      printf '%s\n' "$value" | store_secret "$service" "$env_name"
      echo "import-key: ключ из $label положен в $(store_label "$service")"
      cmd_check "$provider"
      ;;
    *)
      echo "import-key: найдено несколько разных значений ключа, источники:" >&2
      printf '%s\n' "$found" | sed -n 's/^S:/  /p' >&2
      echo "Укажите нужный файл: worker.sh import-key $provider --from-file <путь>" >&2
      return 1
      ;;
  esac
}

# Предупреждение, если цены в профиле не проверялись дольше PRICES_STALE_DAYS
prices_age_warning() {
  python3 -I -c '
import datetime, json, sys
d = json.load(open(sys.argv[1], encoding="utf-8"))
if "prices" not in d:
    print("check: %s — в профиле нет prices, стоимость будет неизвестна" % sys.argv[2])
    sys.exit(0)
try:
    age = (datetime.date.today() - datetime.date.fromisoformat(d["pricesCheckedAt"])).days
except (KeyError, ValueError):
    print("check: %s — нет корректной pricesCheckedAt — обнови цены" % sys.argv[2])
    sys.exit(0)
if age > int(sys.argv[3]):
    print("check: %s — цены проверены %d дней назад — обнови" % (sys.argv[2], age))
' "$1" "$2" "$PRICES_STALE_DAYS"
}

# Короткий запрос напрямую к API: проверяет и ключ, и адрес, и модель
cmd_check() {
  local provider="${1:-deepseek}" profile base model key code body_file
  need_python
  profile="$(find_profile "$provider")" || exit 1
  base="$(prof_get "$profile" baseUrl)" || die "в профиле нет baseUrl"
  model="$(prof_get "$profile" tiers.cheap.model)" || die "в профиле нет tiers.cheap.model"
  key="$(read_key "$profile")"
  if [ -z "$key" ]; then
    echo "check: $provider — ключ не найден (хранилище секретов или переменная окружения)" >&2
    return 1
  fi
  body_file="$(mktemp)"
  # Заголовок с ключом идёт конфигом через stdin: в списке процессов его нет
  code="$(
    printf 'header = "x-api-key: %s"\n' "$key" |
      curl -sS -K - --max-time "$CHECK_TIMEOUT_SEC" -o "$body_file" -w '%{http_code}' \
        -H 'content-type: application/json' -H 'anthropic-version: 2023-06-01' \
        -d "{\"model\":\"$model\",\"max_tokens\":$CHECK_MAX_TOKENS,\"messages\":[{\"role\":\"user\",\"content\":\"ответь одним словом: ок\"}]}" \
        "$base/v1/messages" 2>/dev/null
  )"
  if [ "$code" = "200" ]; then
    echo "check: $provider — ключ найден, сервер отвечает (модель $model)"
    rm -f "$body_file"
    prices_age_warning "$profile" "$provider"
    return 0
  fi
  # Тело ответа сервера ключа не содержит; печатаем только тип ошибки
  local reason
  reason="$(python3 -I -c '
import json, sys
try:
    d = json.load(open(sys.argv[1], encoding="utf-8"))
    e = d.get("error", {})
    print(e.get("type") or e.get("message") or "без описания")
except Exception:
    print("ответ не JSON")
' "$body_file" 2>/dev/null)"
  rm -f "$body_file"
  echo "check: $provider — сервер ответил HTTP ${code:-000} ($reason)" >&2
  return 1
}

cmd_run() {
  local provider="" tier="" effort="" mode="" dir="" budget="" brief=""
  local allow_main=0
  local -a bash_allow=()
  while [ $# -gt 0 ]; do
    case "$1" in
      --provider) provider="${2:-}"; shift 2 ;;
      --tier) tier="${2:-}"; shift 2 ;;
      --effort) effort="${2:-}"; shift 2 ;;
      --mode) mode="${2:-}"; shift 2 ;;
      --dir) dir="${2:-}"; shift 2 ;;
      --budget) budget="${2:-}"; shift 2 ;;
      --brief) brief="${2:-}"; shift 2 ;;
      --bash-allow) bash_allow+=("Bash(${2:-})"); shift 2 ;;
      --allow-main-tree) allow_main=1; shift ;;
      *) die "неизвестный аргумент: $1" ;;
    esac
  done
  [ -n "$provider" ] && [ -n "$tier" ] && [ -n "$mode" ] && [ -n "$dir" ] && [ -n "$budget" ] && [ -n "$brief" ] ||
    die "обязательны --provider --tier --mode --dir --budget --brief"
  need_python
  command -v "$CLAUDE_BIN" >/dev/null 2>&1 || die "нет команды $CLAUDE_BIN"

  local profile model efforts cheap_model
  profile="$(find_profile "$provider")" || exit 1
  model="$(prof_get "$profile" "tiers.$tier.model")" || die "в профиле нет ступени «$tier»"
  cheap_model="$(prof_get "$profile" tiers.cheap.model)" || die "в профиле нет tiers.cheap.model"
  efforts="$(prof_get "$profile" efforts)" || die "в профиле нет списка efforts"
  [ -n "$effort" ] || effort="$(prof_get "$profile" defaultEffort)" || die "не задан --effort и нет defaultEffort"
  case ",$efforts," in *",$effort,"*) ;; *) die "уровень «$effort» не из списка провайдера: $efforts" ;; esac
  [[ "$budget" =~ ^[0-9]+(\.[0-9]+)?$ ]] || die "--budget — число в долларах, например 0.30"
  case "$mode" in read | write) ;; *) die "--mode: read или write" ;; esac
  [ -d "$dir" ] || die "нет каталога $dir"
  dir="$(cd "$dir" && pwd)"
  if [ "$brief" != "-" ] && [ ! -f "$brief" ]; then die "нет файла брифа $brief"; fi

  if [ "$mode" = "write" ] && [ "$allow_main" -eq 0 ]; then
    local gd cd_
    gd="$(git -C "$dir" rev-parse --absolute-git-dir 2>/dev/null)" || die "режим write: $dir не в git-репозитории"
    cd_="$(git -C "$dir" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)"
    [ "$gd" != "$cd_" ] || die "режим write только в отдельном git worktree (git worktree add …); основное дерево — с --allow-main-tree"
  fi

  local key base
  key="$(read_key "$profile")"
  [ -n "$key" ] || die "ключ провайдера «$provider» не найден: worker.sh set-key $provider"
  base="$(prof_get "$profile" baseUrl)" || die "в профиле нет baseUrl"

  local allowed denied
  if [ "$mode" = "read" ]; then allowed="$READ_ALLOWED"; denied="$READ_DENIED"; else allowed="$WRITE_ALLOWED"; denied="$WRITE_DENIED"; fi
  local extra
  for extra in ${bash_allow[@]+"${bash_allow[@]}"}; do allowed="$allowed,$extra"; done

  local out_file err_file brief_file
  out_file="$(mktemp)"; err_file="$(mktemp)"
  if [ "$brief" = "-" ]; then brief_file="$(mktemp)"; cat >"$brief_file"; else brief_file="$brief"; fi

  local started
  started="$(date +%s)"
  # Подмена сервера — только внутри этой подоболочки; ключ идёт через окружение, не через аргументы
  (
    cd "$dir" || exit 1
    unset CLAUDE_CODE_OAUTH_TOKEN ANTHROPIC_API_KEY ANTHROPIC_AUTH_TOKEN ANTHROPIC_MODEL \
      ANTHROPIC_DEFAULT_OPUS_MODEL ANTHROPIC_DEFAULT_SONNET_MODEL ANTHROPIC_DEFAULT_HAIKU_MODEL \
      CLAUDE_CODE_USE_BEDROCK CLAUDE_CODE_USE_VERTEX CLAUDE_CODE_USE_FOUNDRY
    export ANTHROPIC_BASE_URL="$base"
    export ANTHROPIC_AUTH_TOKEN="$key"
    export ANTHROPIC_MODEL="$model"
    export ANTHROPIC_DEFAULT_OPUS_MODEL="$model"
    export ANTHROPIC_DEFAULT_SONNET_MODEL="$model"
    export ANTHROPIC_DEFAULT_HAIKU_MODEL="$cheap_model"
    export CLAUDE_CODE_SUBAGENT_MODEL="$model"
    export CLAUDE_CODE_EFFORT_LEVEL="$effort"
    export CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1
    export BRIGADIR_WORKER=1
    while IFS='=' read -r name value; do
      [ -n "$name" ] && export "$name=$value"
    done < <(prof_get "$profile" extraEnv 2>/dev/null || true)
    "$CLAUDE_BIN" -p --bare --no-session-persistence --output-format json \
      --max-budget-usd "$budget" --model "$model" \
      --permission-mode dontAsk \
      --allowedTools "$allowed" --disallowedTools "$denied" \
      --append-system-prompt "$WORKER_PROMPT" <"$brief_file" >"$out_file" 2>"$err_file"
  )
  local claude_rc=$?
  if [ "$brief" = "-" ]; then rm -f "$brief_file"; fi

  # Отчёт и строка журнала; текста брифа в журнале нет
  python3 -I - "$out_file" "$err_file" "$LOG_FILE" "$provider" "$tier" "$effort" "$mode" "$dir" "$model" "$claude_rc" "$started" "$profile" <<'PY'
import json, os, sys, time

out_file, err_file, log_file, provider, tier, effort, mode, workdir, model, rc, started, profile_file = sys.argv[1:13]
raw = open(out_file, encoding="utf-8", errors="replace").read().strip()
err = open(err_file, encoding="utf-8", errors="replace").read().strip()
data = None
try:
    data = json.loads(raw) if raw else None
except ValueError:
    data = None
if isinstance(data, list):
    data = next((x for x in reversed(data) if isinstance(x, dict) and x.get("type") == "result"), None)

result = ""
counter = 0.0
real_cost = None  # None — цены модели в профиле нет
tokens_in = tokens_out = 0
verdict = "ошибка"
if isinstance(data, dict):
    result = str(data.get("result") or "")
    counter = float(data.get("total_cost_usd") or 0.0)
    usage = data.get("usage") or {}
    tok_hit = int(usage.get("cache_read_input_tokens") or 0)
    # Записи в кэш у DeepSeek отдельной цены нет: считаем как промах
    tok_miss = int(usage.get("input_tokens") or 0) + int(usage.get("cache_creation_input_tokens") or 0)
    tokens_in = tok_miss + tok_hit
    tokens_out = int(usage.get("output_tokens") or 0)
    try:
        price = json.load(open(profile_file, encoding="utf-8"))["prices"][model]
        real_cost = (tok_miss * price["inputMiss"] + tok_hit * price["inputHit"] + tokens_out * price["output"]) / 1e6
    except (OSError, ValueError, KeyError, TypeError):
        real_cost = None
    subtype = str(data.get("subtype") or "")
    if "budget" in subtype:
        verdict = "упёрся в бюджет"
    elif data.get("is_error"):
        verdict = "ошибка"
    else:
        verdict = "успех"
if verdict == "ошибка" and not result:
    result = "(пустой ответ; stderr: %s)" % (err[:500] if err else "пусто")

elapsed = int(time.time()) - int(started)
line = {
    "ts": time.strftime("%Y-%m-%dT%H:%M:%S%z"),
    "provider": provider, "tier": tier, "model": model, "effort": effort, "mode": mode,
    "dir": workdir, "tokensIn": tokens_in, "tokensOut": tokens_out,
    "costUsd": None if real_cost is None else round(real_cost, 6),
    "claudeCounterUsd": round(counter, 6), "seconds": elapsed, "verdict": verdict,
}
try:
    os.makedirs(os.path.dirname(log_file), exist_ok=True)
    with open(log_file, "a", encoding="utf-8") as f:
        f.write(json.dumps(line, ensure_ascii=False) + "\n")
except OSError as e:
    sys.stderr.write("журнал не записан: %s\n" % e)

print(result)
print("---")
print("исполнитель: провайдер=%s ступень=%s модель=%s уровень=%s режим=%s" % (provider, tier, model, effort, mode))
cost_text = "неизвестна (нет prices в профиле)" if real_cost is None else "$%.4f" % real_cost
print("токены: вход=%d выход=%d; время: %dс" % (tokens_in, tokens_out, elapsed))
print("стоимость: %s; счётчик claude (для --budget): $%.4f" % (cost_text, counter))
print("итог: %s" % verdict)
sys.exit({"успех": 0, "упёрся в бюджет": 2}.get(verdict, 1))
PY
  local rc=$?
  rm -f "$out_file" "$err_file"
  return $rc
}

main() {
  [ $# -ge 1 ] || usage
  local sub="$1"
  shift
  case "$sub" in
    set-key) cmd_set_key "$@" ;;
    import-key) cmd_import_key "$@" ;;
    check) cmd_check "$@" ;;
    run) cmd_run "$@" ;;
    *) usage ;;
  esac
}

main "$@"
