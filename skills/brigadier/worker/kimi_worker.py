#!/usr/bin/env python3
"""DeepSeek worker for Kimi: direct OpenAI-compatible API, no Claude Code runtime."""

import argparse
import base64
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import time
import urllib.error
import urllib.request

MAX_TOOL_BYTES = 100_000
# Разведка по незнакомому репозиторию не укладывается в 40 ходов; настройка — переменная окружения
MAX_TURNS = int(os.environ.get("BRIGADIER_MAX_TURNS", "120"))
DELEGATED_BIN = "vibememory"
BLOCKED_PARTS = {".env", ".git", ".license", ".ssh", "node_modules"}
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


def delegated_note(*args):
    """Отметить запуск в движке VibeMemory: тихо, необязательно, у самого исполнителя не срабатывает."""
    if os.environ.get("BRIGADIER_WORKER") == "1":
        return
    try:
        exe = shutil.which(DELEGATED_BIN)
        if not exe:
            return
        subprocess.run([exe, "delegated", *args], capture_output=True, timeout=5)
    except Exception:
        pass


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


def safe_path(root, value):
    path = Path(value or ".")
    if path.is_absolute() or any(part in BLOCKED_PARTS or part.startswith(".env") for part in path.parts):
        raise ValueError("путь запрещён")
    resolved = (root / path).resolve()
    resolved.relative_to(root)
    return resolved


def text_files(directory):
    if not directory.exists():
        return []
    if directory.is_file():
        return [directory]
    found = []
    for path in directory.rglob("*"):
        try:
            relative = path.relative_to(directory)
            if path.is_file() and not any(part in BLOCKED_PARTS or part.startswith(".env") for part in relative.parts):
                found.append(path)
        except OSError:
            pass
    return sorted(found)


def call_tool(root, name, arguments, write):
    path = safe_path(root, arguments.get("path", "."))
    if name == "list_files":
        lines = [str(p.relative_to(root)) for p in text_files(path)[:2000]]
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
        for item in text_files(path):
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


def prepare_worktree(source, base):
    stamp = time.strftime("%Y%m%d-%H%M%S")
    base_dir = Path(os.environ.get("BRIGADIER_WORKER_WORKTREES", "/tmp/brigadier-worktrees")).resolve()
    target = base_dir / f"kimi-{stamp}-{os.getpid()}"
    target.parent.mkdir(parents=True, exist_ok=True)
    branch = f"brigadier/kimi-{stamp}-{os.getpid()}"
    subprocess.run(["git", "-C", str(source), "worktree", "add", "-b", branch, str(target), base], check=True)
    return target, branch


def run(args):
    source = Path(args.dir).resolve()
    worktree = branch = None
    try:
        root = prepare_worktree(source, args.base) if args.mode == "write" else (source, None)
        root, branch = root
        brief = sys.stdin.read() if args.brief == "-" else Path(args.brief).read_text()
        key = key_from_store()
    except Exception as error:
        delegated_note("--failed", str(error))
        raise
    messages = [{"role": "system", "content": SYSTEM}, {"role": "user", "content": f"Каталог работы: текущий корень.\nРежим: {args.mode}.\nБриф:\n{brief}"}]
    total = {"prompt_tokens": 0, "completion_tokens": 0}
    started = time.monotonic()
    try:
        for _ in range(MAX_TURNS):
            answer = request(key, args.model, messages, args.effort)
            choice = answer["choices"][0]
            message = choice["message"]
            messages.append(message)
            usage = answer.get("usage", {})
            for field in total:
                total[field] += usage.get(field, 0)
            calls = message.get("tool_calls") or []
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
        print(f"модель: {args.model}; уровень: {args.effort}; токены: {total}; секунд: {time.monotonic()-started:.1f}")
        if worktree := (root if args.mode == "write" else None):
            subprocess.run(["git", "-C", str(worktree), "add", "-A"], check=True)
            diff = subprocess.run(["git", "-C", str(worktree), "diff", "--cached", "--quiet"])
            if diff.returncode != 0:
                subprocess.run(["git", "-C", str(worktree), "commit", "-m", "brigadier: выполнил бриф Kimi"], check=True)
            patch = subprocess.check_output(["git", "-C", str(worktree), "diff", args.base, "HEAD"], text=True)
            patch_path = Path(str(worktree) + ".diff")
            patch_path.write_text(patch)
            print(f"worktree: {worktree}\nветка: {branch}\nдифф: {patch_path}")
    except Exception:
        print(f"worktree сохранён для разбора: {root}", file=sys.stderr)
        raise


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
    if args.command == "check":
        try:
            answer = request(key_from_store(), args.model, [{"role": "user", "content": "Ответь: ok"}], "low")
        except Exception as error:
            delegated_note("--failed", str(error))
            raise
        print(f"DeepSeek Kimi worker: {answer['choices'][0]['message'].get('content', 'ok')}")
    else:
        delegated_note("--ok")
        run(args)


if __name__ == "__main__":
    try:
        main()
    except Exception as error:
        print(f"ошибка: {error}", file=sys.stderr)
        sys.exit(1)
