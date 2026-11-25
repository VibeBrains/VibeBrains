#!/usr/bin/env python3
"""DeepSeek worker for Kimi: direct OpenAI-compatible API, no Claude Code runtime."""

import argparse
import base64
import json
import os
from pathlib import Path
import shutil
import signal
import subprocess
import sys
import time
import urllib.error
import urllib.request

MAX_TOOL_BYTES = 100_000
# Разведка по незнакомому репозиторию не укладывается в 40 ходов; настройка — переменная окружения
MAX_TURNS = int(os.environ.get("BRIGADIER_MAX_TURNS", "120"))
VIBEMEMORY_BIN = "vibememory"
# Заголовок коммита: первая строка брифа без служебной приставки, не длиннее 72 символов
TITLE_PREFIX = "Задача (write):"
TITLE_LIMIT = 72
# Каталог worktree по умолчанию — как у worker.sh: временный каталог системы
# Поле worktreesDir личного профиля сильнее, переменная BRIGADIER_WORKER_WORKTREES сильнее профиля
DEFAULT_WORKTREES_DIR = str(Path(os.environ.get("TMPDIR") or "/tmp") / "brigadier-worktrees")
DEFAULT_LOG_FILE = Path(os.environ.get("XDG_CACHE_HOME") or (Path.home() / ".cache")) / "brigadier-worker" / "runs.jsonl"
# Профиль: сначала пользовательский каталог, потом поставляемый с навыком — как в worker.sh
PROFILE_DIRS = [
    Path(os.environ.get("BRIGADIER_WORKER_PROVIDERS") or (Path.home() / ".config" / "brigadier-worker" / "providers")),
    Path(__file__).resolve().parent / "providers",
]
# Шумные каталоги: target/ у Rust — 154 ГБ, остальные тоже не код; в них не спускаемся
BLOCKED_PARTS = {".env", ".git", ".license", ".ssh", "node_modules", "target", "dist", "build", ".venv", "__pycache__"}
MAX_LISTED_FILES = 2000
TOOLS = [
    {"type": "function", "function": {"name": "list_files", "description": "List files below a relative directory", "parameters": {"type": "object", "properties": {"path": {"type": "string", "default": "."}}, "required": []}}},
    {"type": "function", "function": {"name": "read_file", "description": "Read a UTF-8 text file; large files page through offset/limit (1-based lines)", "parameters": {"type": "object", "properties": {"path": {"type": "string"}, "offset": {"type": "integer", "default": 1}, "limit": {"type": "integer", "default": 0}}, "required": ["path"]}}},
    {"type": "function", "function": {"name": "search_files", "description": "Search a literal string in text files below a relative directory", "parameters": {"type": "object", "properties": {"path": {"type": "string", "default": "."}, "query": {"type": "string"}}, "required": ["query"]}}},
    {"type": "function", "function": {"name": "write_file", "description": "Replace a text file; only in write mode. With old_string replaces the exactly-one occurrence of old_string with content, else writes content as the whole file", "parameters": {"type": "object", "properties": {"path": {"type": "string"}, "content": {"type": "string"}, "old_string": {"type": "string"}}, "required": ["path", "content"]}}},
]
SYSTEM = """Ты внешний исполнитель Kimi-бригадира. Работай сам, никому не делегируй.
Действуй инструментами, не выдумывай содержимое. Работай только в переданном каталоге.
Не читай секреты, .env, .git, .license и ключи. Не коммить и не пушь.
Большие файлы читай порциями read_file с offset/limit; точечные правки делай write_file с old_string (ровно одно вхождение).
Если тест падает дважды по одной причине — остановись и опиши, не перебирай вариации.
В конце дай короткий итог: сделано, проверено, не удалось."""


def engine_binary():
    """Путь движка: из PATH, иначе туда, куда его кладёт `vibememory install`."""
    return shutil.which(VIBEMEMORY_BIN) or str(Path.home() / ".vibememory" / "bin" / VIBEMEMORY_BIN)


def event(*args, cwd=None):
    """Событие состояния сессии в движке VibeMemory: тихо, необязательно, у самого исполнителя не срабатывает.

    Без KIMI_CODE_SESSION_ID движок берёт активную сессию по каталогу, поэтому событие идёт
    в каталоге проверяемого проекта (``cwd``), а не в том, откуда запустили воркер.
    """
    if os.environ.get("BRIGADIER_WORKER") == "1":
        return
    try:
        exe = engine_binary()
        if not Path(exe).is_file():
            return
        subprocess.run([exe, "brigadier", "event", *args], cwd=cwd, capture_output=True, timeout=5)
    except Exception:
        pass


def load_profile():
    """Профиль провайдера: цены и путь журнала; нет файла — пустой словарь."""
    for directory in PROFILE_DIRS:
        try:
            return json.loads((directory / "deepseek.json").read_text(encoding="utf-8"))
        except (OSError, ValueError):
            continue
    return {}


def log_file(profile):
    """Журнал запусков: переменная окружения, затем logFile профиля, затем общий путь."""
    configured = os.environ.get("BRIGADIER_WORKER_LOG") or profile.get("logFile")
    path = Path(os.path.expanduser(str(configured))) if configured else DEFAULT_LOG_FILE
    return path


def write_log(profile, path, line):
    """Одна JSON-строка на запуск, поля те же, что у worker.sh."""
    try:
        path.parent.mkdir(parents=True, exist_ok=True)
        with path.open("a", encoding="utf-8") as handle:
            handle.write(json.dumps(line, ensure_ascii=False) + "\n")
    except OSError as error:
        print(f"журнал не записан: {error}", file=sys.stderr)


RECEIPTS_NAME = "brigadier-receipts.jsonl"
# Номер сигнала, снявшего процесс: finally допишет его в причину квитанции
SIGNAL_STATE = {"number": None}


def receipts_path():
    """Файл квитанций запуска: независимый след рядом с состоянием движка."""
    base = os.environ.get("VIBEMEMORY_DIR") or str(Path.home() / ".vibememory")
    return Path(os.path.expanduser(base)) / RECEIPTS_NAME


def write_receipt(kind, verdict, reason, model, directory):
    """Квитанция попытки check/run по контракту; ошибка записи worker не валит."""
    try:
        path = receipts_path()
        path.parent.mkdir(parents=True, exist_ok=True)
        line = {
            "ts": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
            "cwd": str(canonical(directory or ".")),
            "kind": kind,
            "verdict": verdict,
            "reason": reason or None,
            "model": model or None,
            "pid": os.getpid(),
        }
        with path.open("a", encoding="utf-8") as handle:
            handle.write(json.dumps(line, ensure_ascii=False) + "\n")
    except Exception as error:
        print(f"квитанция не записана: {error}", file=sys.stderr)


def on_signal(signum, _frame):
    """SIGTERM: SystemExit, чтобы finally успел записать журнал и квитанцию."""
    SIGNAL_STATE["number"] = signum
    raise SystemExit(128 + signum)


def cost_of(profile, model, hit, miss, out):
    """Стоимость по usage и ценам профиля; нет цен — None."""
    price = (profile.get("prices") or {}).get(model)
    if not price:
        return None
    return (hit * price["inputHit"] + miss * price["inputMiss"] + out * price["output"]) / 1e6


def key_from_store():
    env = os.environ.get("BRIGADIER_WORKER_DEEPSEEK_KEY") or os.environ.get("DEEPSEEK_API_KEY")
    if env:
        return env
    if sys.platform == "darwin":
        user = os.environ.get("USER") or subprocess.check_output(["id", "-un"], text=True).strip()
        result = subprocess.run(["security", "find-generic-password", "-s", "brigadier-worker-deepseek", "-a", user, "-w"], capture_output=True, text=True)
        if result.returncode == 0:
            return result.stdout.strip()
    raise RuntimeError("ключ DeepSeek не найден: worker.sh set-key deepseek")


def request(key, model, messages, effort):
    body = {"model": model, "messages": messages, "tools": TOOLS, "tool_choice": "auto", "reasoning_effort": effort}
    data = json.dumps(body).encode()
    req = urllib.request.Request("https://api.deepseek.com/chat/completions", data=data, headers={"Authorization": f"Bearer {key}", "Content-Type": "application/json"})
    try:
        with urllib.request.urlopen(req, timeout=180) as response:
            return json.load(response)
    except urllib.error.HTTPError as error:
        detail = error.read().decode(errors="replace")[:1000]
        raise RuntimeError(f"DeepSeek HTTP {error.code}: {detail}") from None


def canonical(value):
    """Единственная каноническая форма пути: симлинки раскрыты (/tmp → /private/tmp на macOS)."""
    return Path(value).resolve()


def safe_path(root, value):
    # Корень и запрошенный путь приводим к одной форме до сравнения: иначе /tmp/... и /private/tmp/...
    # никогда не совпадут и любая операция будет отклонена
    root = canonical(root)
    path = Path(value or ".")
    if path.is_absolute() or is_blocked(path.parts):
        raise ValueError("путь запрещён")
    resolved = canonical(root / path)
    try:
        resolved.relative_to(root)
    except ValueError:
        raise ValueError("путь вне каталога работы") from None
    return resolved


def in_tree(directory, path):
    """Путь после раскрытия симлинков остаётся внутри каталога."""
    try:
        canonical(path).relative_to(canonical(directory))
    except ValueError:
        return False
    return True


def is_blocked(parts):
    """Часть пути из закрытых каталогов, секретов и шумных сборок."""
    return any(part in BLOCKED_PARTS or part.startswith(".env") for part in parts)


def git_text_files(directory, limit):
    """Список файлов из git: --cached --others --exclude-standard учитывает .gitignore; вне git — None."""
    try:
        top = subprocess.run(
            ["git", "-C", str(directory), "rev-parse", "--show-toplevel"],
            capture_output=True, text=True, timeout=30,
        )
    except (OSError, subprocess.SubprocessError):
        return None
    if top.returncode != 0 or not top.stdout.strip():
        return None
    repo = canonical(top.stdout.strip())
    try:
        listing = subprocess.run(
            ["git", "-C", str(repo), "ls-files", "-z", "--cached", "--others", "--exclude-standard"],
            capture_output=True, timeout=30,
        )
    except (OSError, subprocess.SubprocessError):
        return None
    if listing.returncode != 0:
        return None
    directory = canonical(directory)
    found = []
    for raw in listing.stdout.split(b"\0"):
        if not raw:
            continue
        path = repo / os.fsdecode(raw)
        try:
            relative = path.relative_to(directory)
        except ValueError:
            continue
        if is_blocked(relative.parts):
            continue
        try:
            if in_tree(directory, path) and path.is_file():
                found.append(path)
        except OSError:
            continue
        if len(found) >= limit:
            break
    return sorted(found)


def text_files(directory, limit=MAX_LISTED_FILES):
    """Файлы каталога: в git — по ls-files с фильтром запрошенного подкаталога, иначе обход без шумных каталогов."""
    if not directory.exists():
        return []
    if directory.is_file():
        return [directory] if in_tree(directory.parent, directory) else []
    listed = git_text_files(directory, limit)
    if listed is not None:
        return listed
    found = []
    for current, dirnames, filenames in os.walk(directory):
        # Каталоги отсекаются до спуска: target/ не читается вообще
        dirnames[:] = [name for name in sorted(dirnames) if not is_blocked([name])]
        for name in sorted(filenames):
            path = Path(current) / name
            if is_blocked([name]):
                continue
            try:
                if in_tree(directory, path) and path.is_file():
                    found.append(path)
            except OSError:
                continue
            if len(found) >= limit:
                return sorted(found)
    return sorted(found)


def call_tool(root, name, arguments, write):
    # Одна каноническая форма для разрешённого каталога и всех возвращаемых путей
    root = canonical(root)
    path = safe_path(root, arguments.get("path", "."))
    if name == "list_files":
        lines = [str(p.relative_to(root)) for p in text_files(path, MAX_LISTED_FILES)]
        return "\n".join(lines) or "(пусто)"
    if name == "read_file":
        text = path.read_bytes().decode(errors="replace")
        lines = text.splitlines(keepends=True)
        offset = max(int(arguments.get("offset") or 1), 1)
        limit = max(int(arguments.get("limit") or 0), 0)
        total = len(lines)
        if offset > 1 or limit:
            end = offset - 1 + limit if limit else total
            text = "".join(lines[offset - 1:end])
        encoded = text.encode()
        if len(encoded) > MAX_TOOL_BYTES:
            text = encoded[:MAX_TOOL_BYTES].decode(errors="replace") + "\n[обрезано]"
        if offset > 1 or limit:
            shown_end = min(offset - 1 + (limit or total), total)
            text = f"[строки {offset}-{shown_end} из {total}]\n" + text
        return text
    if name == "search_files":
        query = arguments["query"]
        matches = []
        for item in text_files(path, MAX_LISTED_FILES):
            try:
                for number, line in enumerate(item.read_text(errors="replace").splitlines(), 1):
                    if query in line:
                        matches.append(f"{item.relative_to(root)}:{number}:{line[:500]}")
                        if len(matches) >= 500:
                            return "\n".join(matches)
            except OSError:
                pass
        return "\n".join(matches) or "(не найдено)"
    if name == "write_file" and write:
        path.parent.mkdir(parents=True, exist_ok=True)
        old = arguments.get("old_string")
        if old is not None:
            current = path.read_text(errors="replace")
            count = current.count(old)
            if count != 1:
                raise ValueError(f"old_string встречается {count} раз, нужен ровно 1")
            path.write_text(current.replace(old, arguments["content"], 1))
            return f"патч применён: {path.relative_to(root)}"
        path.write_text(arguments["content"])
        return f"записано: {path.relative_to(root)}"
    raise ValueError("инструмент неизвестен или запись запрещена")


def base_commit(repo, base):
    """SHA базы до создания worktree: после коммита имя HEAD указывает уже на наш коммит."""
    return subprocess.check_output(["git", "-C", str(repo), "rev-parse", "--verify", f"{base}^{{commit}}"], text=True).strip()


def worktree_diff(worktree, base_sha):
    """Дифф от зафиксированной базы: `git diff <sha базы> HEAD`, а не `git diff HEAD HEAD`."""
    return subprocess.check_output(["git", "-C", str(worktree), "diff", base_sha, "HEAD"], text=True)


def worktrees_root(profile):
    """Каталог worktree: переменная, затем worktreesDir профиля, затем общий каталог владельца."""
    configured = os.environ.get("BRIGADIER_WORKER_WORKTREES") or (profile or {}).get("worktreesDir")
    path = Path(os.path.expanduser(str(configured))) if configured else Path(DEFAULT_WORKTREES_DIR)
    return canonical(path)


def prepare_worktree(source, base, profile=None):
    stamp = time.strftime("%Y%m%d-%H%M%S")
    base_dir = worktrees_root(profile)
    target = base_dir / f"kimi-{stamp}-{os.getpid()}"
    target.parent.mkdir(parents=True, exist_ok=True)
    branch = f"brigadier/kimi-{stamp}-{os.getpid()}"
    # База фиксируется до создания worktree и до коммита: иначе дифф считается как git diff HEAD HEAD
    base_sha = base_commit(source, base)
    subprocess.run(["git", "-C", str(source), "worktree", "add", "-b", branch, str(target), base_sha], check=True)
    # Возвращаем уже канонический путь: он же становится корнем инструментов и полем dir в журнале
    return canonical(target), branch, base_sha


def format_cost(cost):
    """Стоимость в форме worker.sh: $<costUsd>, а при costKnown=false — «неизвестна»."""
    return "неизвестна" if cost is None else f"${cost:.4f}"


def brief_title(text):
    """Первая непустая строка брифа без «Задача (write):», обрезанная по символам и границе слова."""
    line = ""
    for raw in text.splitlines():
        if raw.strip():
            line = raw.strip()
            break
    if line.startswith(TITLE_PREFIX):
        line = line[len(TITLE_PREFIX):].strip()
    line = " ".join(line.split())
    if len(line) > TITLE_LIMIT:
        cut = line[:TITLE_LIMIT]
        space = cut.rfind(" ")
        if space > 0:
            cut = cut[:space]
        line = cut.rstrip(" ,;:—-")
    return line or "задача исполнителя"


def summary_line(model, effort, tokens_in, tokens_out, cost, seconds):
    """Итоговая строка stdout: токены числами вход/выход, стоимость как в worker.sh."""
    return (
        f"модель: {model}; уровень: {effort}; токены: вход={tokens_in} выход={tokens_out}; "
        f"стоимость: {format_cost(cost)}; секунд: {seconds:.1f}"
    )


def run(args):
    source = canonical(args.dir)
    worktree = branch = None
    profile = load_profile()
    root = source
    try:
        root, branch, base_sha = prepare_worktree(source, args.base, profile) if args.mode == "write" else (source, None, None)
        root = canonical(root)
        brief = sys.stdin.read() if args.brief == "-" else Path(args.brief).read_text()
        key = key_from_store()
    except BaseException as error:
        # До старта модели: state сессии не меняется, событие не шлём, но квитанция попытки остаётся
        reason = f"снят сигналом {SIGNAL_STATE['number']}" if SIGNAL_STATE["number"] else str(error)
        write_receipt("run", "failed", reason, args.model, source)
        raise
    messages = [{"role": "system", "content": SYSTEM}, {"role": "user", "content": f"Каталог работы: текущий корень.\nРежим: {args.mode}.\nБриф:\n{brief}"}]
    total = {"prompt_tokens": 0, "completion_tokens": 0, "prompt_cache_hit_tokens": 0, "prompt_cache_miss_tokens": 0}
    usage_seen = False
    started = time.monotonic()
    # Id запуска — время и pid, штамп того же вида, что у worker.sh
    run_id = time.strftime("%Y%m%d-%H%M%S") + f"-{os.getpid()}"
    event("run-started", "--run-id", run_id, "--mode", args.mode, "--model", args.model, "--effort", args.effort, cwd=source)
    verdict = "успех"
    failure = None
    try:
        for turn in range(1, MAX_TURNS + 1):
            answer = request(key, args.model, messages, args.effort)
            choice = answer["choices"][0]
            message = choice["message"]
            messages.append(message)
            usage = answer.get("usage") or {}
            if usage:
                usage_seen = True
            for field in total:
                total[field] += usage.get(field, 0)
            calls = message.get("tool_calls") or []
            # Одна строка на ход в stderr: вызывающий видит, что процесс жив; stdout не трогаем
            if calls:
                first = calls[0]["function"]
                try:
                    shown = json.loads(first.get("arguments") or "{}").get("path") or "."
                except ValueError:
                    shown = "?"
                print(f"ход {turn}: {first.get('name')} {shown}", file=sys.stderr, flush=True)
            else:
                print(f"ход {turn}: ответ", file=sys.stderr, flush=True)
            if not calls:
                print(message.get("content") or "(пустой ответ)")
                break
            for call in calls:
                name = call["function"]["name"]
                try:
                    arguments = json.loads(call["function"].get("arguments") or "{}")
                    result = call_tool(root, name, arguments, args.mode == "write")
                except Exception as error:
                    result = f"ошибка инструмента: {error}"
                messages.append({"role": "tool", "tool_call_id": call["id"], "content": result})
        else:
            raise RuntimeError(f"достигнут предел {MAX_TURNS} ходов")
        if worktree := (root if args.mode == "write" else None):
            subprocess.run(["git", "-C", str(worktree), "add", "-A"], check=True)
            diff = subprocess.run(["git", "-C", str(worktree), "diff", "--cached", "--quiet"])
            if diff.returncode != 0:
                subprocess.run(["git", "-C", str(worktree), "commit", "-m", f"brigadier: {brief_title(brief)}"], check=True)
            patch = worktree_diff(worktree, base_sha)
            patch_path = Path(str(worktree) + ".diff")
            patch_path.write_text(patch)
            print(f"worktree: {worktree}\nветка: {branch}\nдифф: {patch_path}")
    except Exception as error:
        verdict = "ошибка"
        failure = str(error)
        print(f"worktree сохранён для разбора: {root}", file=sys.stderr)
        event("run-failed", "--run-id", run_id, "--reason", failure or "запуск без итога", cwd=source)
        raise
    finally:
        # Снятие сигналом приходит SystemExit мимо except: итог и причину задаёт сигнал
        if SIGNAL_STATE["number"]:
            verdict = "ошибка"
            failure = failure or f"снят сигналом {SIGNAL_STATE['number']}"
        tokens_in = total["prompt_tokens"]
        tokens_out = total["completion_tokens"]
        hit = total["prompt_cache_hit_tokens"]
        miss = total["prompt_cache_miss_tokens"]
        if usage_seen and not miss and not hit:
            miss = tokens_in
        cost = cost_of(profile, args.model, hit, miss, tokens_out) if usage_seen else None
        cheap_model = ((profile.get("tiers") or {}).get("cheap") or {}).get("model")
        line = {
            "ts": time.strftime("%Y-%m-%dT%H:%M:%S%z"),
            "provider": "deepseek",
            "tier": "cheap" if args.model == cheap_model else "strong",
            "model": args.model, "effort": args.effort, "mode": args.mode,
            "dir": str(root), "tokensIn": tokens_in, "tokensOut": tokens_out,
            "costUsd": None if cost is None else round(cost, 6),
            "costKnown": cost is not None, "costExact": cost is not None, "capUsd": profile.get("maxRunUsd"),
            "claudeCounterUsd": None,
            "seconds": int(time.monotonic() - started), "verdict": verdict, "partial": verdict != "успех",
            "readLoop": False, "ownerApproved": False,
        }
        write_log(profile, log_file(profile), line)
        write_receipt("run", "ok" if verdict == "успех" else "failed", failure, args.model, source)
        if verdict == "успех":
            if line["costUsd"] is not None:
                event("run-finished", "--run-id", run_id, "--model", args.model, "--effort", args.effort, "--cost", str(line["costUsd"]), cwd=source)
            else:
                event("run-finished", "--run-id", run_id, "--model", args.model, "--effort", args.effort, cwd=source)
        # Итоговая строка: стоимость в форме worker.sh, токены числами вход/выход
        print(summary_line(args.model, args.effort, tokens_in, tokens_out, line["costUsd"], time.monotonic() - started))


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("command", choices=["check", "run"])
    parser.add_argument("--dir", default=".")
    parser.add_argument("--base", default="HEAD")
    parser.add_argument("--brief", default="-")
    parser.add_argument("--mode", choices=["read", "write"], default="read")
    parser.add_argument("--model", default="deepseek-flash")
    parser.add_argument("--effort", choices=["low", "high", "max"], default="high")
    args = parser.parse_args()
    SIGNAL_STATE["number"] = None
    try:
        signal.signal(signal.SIGTERM, on_signal)
    except (ValueError, OSError):
        # Не главный поток: штатный SIGTERM убьёт процесс без finally, квитанции не будет
        pass
    if args.command == "check":
        verdict, reason = "failed", None
        try:
            answer = request(key_from_store(), args.model, [{"role": "user", "content": "Ответь: ok"}], "low")
        except Exception as error:
            reason = str(error)
            event("check-failed", "--reason", reason, cwd=args.dir)
            raise
        else:
            verdict = "ok"
            event("check-ok", cwd=args.dir)
            print(f"DeepSeek Kimi worker: {answer['choices'][0]['message'].get('content', 'ok')}")
        finally:
            if SIGNAL_STATE["number"]:
                verdict = "failed"
                reason = reason or f"снят сигналом {SIGNAL_STATE['number']}"
            write_receipt("check", verdict, reason, args.model, args.dir)
    else:
        run(args)


if __name__ == "__main__":
    try:
        main()
    except Exception as error:
        print(f"ошибка: {error}", file=sys.stderr)
        sys.exit(1)
