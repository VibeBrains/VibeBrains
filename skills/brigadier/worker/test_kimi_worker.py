#!/usr/bin/env python3
"""Регрессия путей worktree: /tmp в корне состояния и /private/tmp на диске — одна форма."""

import contextlib
import importlib.util
import io
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest
from unittest import mock

MODULE_PATH = Path(__file__).with_name("kimi_worker.py")
_SPEC = importlib.util.spec_from_file_location("kimi_worker_under_test", MODULE_PATH)
kimi_worker = importlib.util.module_from_spec(_SPEC)
_SPEC.loader.exec_module(kimi_worker)


class WorktreePathTest(unittest.TestCase):
    def setUp(self):
        # Каталог именно в /tmp: на macOS это симлинк на /private/tmp, как у рабочего worktree
        self.raw = Path(tempfile.mkdtemp(dir="/tmp", prefix="kimi-worker-test-"))
        if self.raw.resolve() == self.raw:
            shutil.rmtree(self.raw, ignore_errors=True)
            self.skipTest("/tmp не симлинк: сценарий /tmp → /private/tmp недоступен")
        self.addCleanup(shutil.rmtree, self.raw, True)
        (self.raw / "a.txt").write_text("alpha\nbeta\n", encoding="utf-8")
        (self.raw / "sub").mkdir()
        (self.raw / "sub" / "b.txt").write_text("gamma\n", encoding="utf-8")
        self.outside = Path(tempfile.mkdtemp(dir="/tmp", prefix="kimi-worker-outside-"))
        self.addCleanup(shutil.rmtree, self.outside, True)
        (self.outside / "secret.txt").write_text("секрет\n", encoding="utf-8")
        os.symlink(self.outside, self.raw / "escape")
        os.symlink(self.outside / "secret.txt", self.raw / "leak.txt")
        # Корень в том же виде, в каком его держит состояние воркера: нерезолвленный /tmp/...
        self.root = self.raw

    def test_root_is_canonical(self):
        resolved = kimi_worker.safe_path(self.root, ".")
        self.assertEqual(resolved, self.root.resolve())
        self.assertNotEqual(str(resolved), str(self.root))
        self.assertTrue(str(resolved).startswith(str(self.root.resolve())))

    def test_read_file_inside_worktree(self):
        text = kimi_worker.call_tool(self.root, "read_file", {"path": "a.txt"}, False)
        self.assertIn("alpha", text)
        self.assertIn("beta", text)

    def test_list_files_inside_worktree(self):
        listing = kimi_worker.call_tool(self.root, "list_files", {"path": "."}, False)
        self.assertEqual(sorted(listing.splitlines()), ["a.txt", "sub/b.txt"])

    def test_search_files_inside_worktree(self):
        found = kimi_worker.call_tool(self.root, "search_files", {"path": ".", "query": "gamma"}, False)
        self.assertEqual(found, "sub/b.txt:1:gamma")

    def test_write_file_inside_worktree(self):
        result = kimi_worker.call_tool(self.root, "write_file", {"path": "sub/new.txt", "content": "ok\n"}, True)
        self.assertIn("записано: sub/new.txt", result)
        self.assertEqual((self.raw / "sub" / "new.txt").read_text(encoding="utf-8"), "ok\n")
        patch = kimi_worker.call_tool(
            self.root, "write_file", {"path": "a.txt", "old_string": "beta", "content": "beta ok"}, True
        )
        self.assertIn("патч применён: a.txt", patch)
        self.assertEqual((self.raw / "a.txt").read_text(encoding="utf-8"), "alpha\nbeta ok\n")

    def test_parent_traversal_forbidden(self):
        with self.assertRaises(ValueError):
            kimi_worker.safe_path(self.root, "../outside.txt")
        with self.assertRaises(ValueError):
            kimi_worker.call_tool(self.root, "read_file", {"path": "../outside.txt"}, False)

    def test_absolute_external_path_forbidden(self):
        with self.assertRaises(ValueError):
            kimi_worker.safe_path(self.root, "/etc/hosts")
        with self.assertRaises(ValueError):
            kimi_worker.call_tool(self.root, "list_files", {"path": "/etc"}, False)

    def test_symlink_escape_forbidden(self):
        with self.assertRaises(ValueError):
            kimi_worker.safe_path(self.root, "escape/secret.txt")
        with self.assertRaises(ValueError):
            kimi_worker.call_tool(self.root, "read_file", {"path": "escape/secret.txt"}, False)
        with self.assertRaises(ValueError):
            kimi_worker.call_tool(self.root, "write_file", {"path": "escape/secret.txt", "content": "x"}, True)
        # Симлинк-файл наружу не должен попадать в список и в поиск
        self.assertNotIn("leak.txt", kimi_worker.call_tool(self.root, "list_files", {"path": "."}, False))
        self.assertNotIn("leak.txt", kimi_worker.call_tool(self.root, "search_files", {"path": ".", "query": "секрет"}, False))


class GitIgnoreListTest(unittest.TestCase):
    """В git список файлов — из ls-files с .gitignore: target/ не виден ни списку, ни поиску."""

    def setUp(self):
        self.repo = Path(tempfile.mkdtemp(prefix="kimi-worker-ignore-"))
        self.addCleanup(shutil.rmtree, self.repo, True)
        self.git("init", "-q")
        self.git("config", "user.email", "worker@example.invalid")
        self.git("config", "user.name", "worker test")
        self.git("config", "commit.gpgsign", "false")
        (self.repo / ".gitignore").write_text("target/\n", encoding="utf-8")
        (self.repo / "kept.txt").write_text("kept\n", encoding="utf-8")
        (self.repo / "untracked.txt").write_text("fresh\n", encoding="utf-8")
        (self.repo / "sub").mkdir()
        (self.repo / "sub" / "inner.txt").write_text("inner\n", encoding="utf-8")
        generated = self.repo / "target" / "debug"
        generated.mkdir(parents=True)
        (generated / "generated.txt").write_text("target-only\n", encoding="utf-8")
        self.git("add", "-A")
        self.git("commit", "-qm", "base")

    def git(self, *args):
        result = subprocess.run(["git", "-C", str(self.repo), *args], capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        return result.stdout

    def test_list_files_skips_ignored_target(self):
        listing = kimi_worker.call_tool(self.repo, "list_files", {"path": "."}, False).splitlines()
        self.assertIn("kept.txt", listing)
        self.assertIn("untracked.txt", listing)
        self.assertIn("sub/inner.txt", listing)
        self.assertNotIn("target/debug/generated.txt", listing)
        self.assertFalse(any(line.startswith("target/") for line in listing))

    def test_search_files_skips_ignored_target(self):
        found = kimi_worker.call_tool(self.repo, "search_files", {"path": ".", "query": "target-only"}, False)
        self.assertEqual(found, "(не найдено)")

    def test_list_files_filters_requested_subdirectory(self):
        listing = kimi_worker.call_tool(self.repo, "list_files", {"path": "sub"}, False).splitlines()
        self.assertEqual(listing, ["sub/inner.txt"])

    def test_limit_applied_while_collecting(self):
        self.assertEqual(len(kimi_worker.text_files(self.repo, limit=2)), 2)


class BlockedDirsWalkTest(unittest.TestCase):
    """Вне git обход пропускает шумные каталоги до спуска в них."""

    def setUp(self):
        self.root = Path(tempfile.mkdtemp(prefix="kimi-worker-blocked-"))
        self.addCleanup(shutil.rmtree, self.root, True)
        probe = subprocess.run(["git", "-C", str(self.root), "rev-parse", "--show-toplevel"], capture_output=True)
        if probe.returncode == 0:
            self.skipTest("временный каталог внутри git-репозитория")
        (self.root / "a.txt").write_text("alpha\n", encoding="utf-8")
        for name in ("target", "dist", "build", ".venv", "__pycache__"):
            noise = self.root / name
            noise.mkdir()
            (noise / "noise.txt").write_text(f"noise {name}\n", encoding="utf-8")

    def test_list_and_search_skip_noise(self):
        self.assertEqual(kimi_worker.call_tool(self.root, "list_files", {"path": "."}, False), "a.txt")
        found = kimi_worker.call_tool(self.root, "search_files", {"path": ".", "query": "noise"}, False)
        self.assertEqual(found, "(не найдено)")

    def test_walk_does_not_descend_into_noise(self):
        visited = []
        real_walk = os.walk

        def recording_walk(top, *args, **kwargs):
            for entry in real_walk(top, *args, **kwargs):
                visited.append(Path(entry[0]))
                yield entry

        with mock.patch.object(kimi_worker.os, "walk", recording_walk):
            kimi_worker.call_tool(self.root, "list_files", {"path": "."}, False)
        # Корень на диске канонический (/var → /private/var), поэтому сверяем имена частей пути
        entered = {part for path in visited for part in path.parts}
        self.assertFalse(entered & {"target", "dist", "build", ".venv", "__pycache__"})

    def test_unreadable_noise_dir_does_not_raise(self):
        noise = self.root / "target"
        noise.chmod(0o000)
        self.addCleanup(noise.chmod, 0o755)
        self.assertEqual(kimi_worker.call_tool(self.root, "list_files", {"path": "."}, False), "a.txt")


class BriefTitleTest(unittest.TestCase):
    """Заголовок коммита: первая строка брифа без приставки, 72 символа по границе слова."""

    def test_first_line_without_task_prefix(self):
        text = "\n\nЗадача (write): починить экспорт отчёта\nвторая строка\n"
        self.assertEqual(kimi_worker.brief_title(text), "починить экспорт отчёта")

    def test_short_line_unchanged(self):
        text = "Задача (write): три доработки worker и evals в VibeBrains.\n"
        self.assertEqual(kimi_worker.brief_title(text), "три доработки worker и evals в VibeBrains.")

    def test_empty_brief_fallback(self):
        self.assertEqual(kimi_worker.brief_title("\n  \n"), "задача исполнителя")

    def test_truncates_by_characters_on_word_boundary(self):
        body = "оченьдлинноеслово " * 10
        title = kimi_worker.brief_title("Задача (write): " + body)
        self.assertLessEqual(len(title), 72)
        self.assertNotIn("�", title)
        # Обрезка не посреди слова: в исходнике дальше идёт пробел
        self.assertTrue(body.startswith(title + " "))

    def test_long_word_is_not_cut_mid_character(self):
        # Байтовая обрезка дала бы «нов�»: здесь символов ровно 72, замена не появляется
        title = kimi_worker.brief_title("Задача (write): " + "нов" * 60)
        self.assertEqual(len(title), 72)
        self.assertNotIn("�", title)
        self.assertTrue(all(character in "нов" for character in title))


class SummaryLineTest(unittest.TestCase):
    """Итоговая строка: токены числами вход/выход, стоимость в форме worker.sh."""

    def test_cost_known(self):
        line = kimi_worker.summary_line("deepseek-chat", "high", 1200, 340, 0.0025, 1.5)
        self.assertIn("токены: вход=1200 выход=340", line)
        self.assertIn("стоимость: $0.0025", line)
        self.assertNotIn("{", line)

    def test_cost_unknown(self):
        line = kimi_worker.summary_line("deepseek-chat", "high", 7, 0, None, 2.0)
        self.assertIn("стоимость: неизвестна", line)
        self.assertNotIn("$", line)
        self.assertNotIn("{", line)

    def test_cost_rounded_like_log(self):
        self.assertEqual(kimi_worker.format_cost(round(0.0012345678, 6)), "$0.0012")


class DiffBaseTest(unittest.TestCase):
    """Дифф считается от базы, зафиксированной до коммита, — не `git diff HEAD HEAD`."""

    def setUp(self):
        self.repo = Path(tempfile.mkdtemp(prefix="kimi-worker-git-"))
        self.addCleanup(shutil.rmtree, self.repo, True)
        self.git("init", "-q")
        self.git("config", "user.email", "worker@example.invalid")
        self.git("config", "user.name", "worker test")
        self.git("config", "commit.gpgsign", "false")
        (self.repo / "a.txt").write_text("alpha\n", encoding="utf-8")
        self.git("add", "-A")
        self.git("commit", "-qm", "base")

    def git(self, *args):
        result = subprocess.run(["git", "-C", str(self.repo), *args], capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        return result.stdout

    def test_base_sha_pins_commit_before_change(self):
        base_sha = kimi_worker.base_commit(self.repo, "HEAD")
        self.assertEqual(base_sha, self.git("rev-parse", "HEAD").strip())
        (self.repo / "a.txt").write_text("alpha\nbeta\n", encoding="utf-8")
        self.git("add", "-A")
        self.git("commit", "-qm", "change")
        # Воспроизведение дефекта: после коммита свежий HEAD уже наш, дифф HEAD..HEAD пуст
        self.assertEqual(self.git("diff", "HEAD", "HEAD"), "")
        patch = kimi_worker.worktree_diff(self.repo, base_sha)
        self.assertIn("+beta", patch)
        self.assertEqual(patch, self.git("diff", base_sha, "HEAD"))

    def test_worktree_diff_after_commit_is_not_empty(self):
        worktrees = Path(tempfile.mkdtemp(prefix="kimi-worker-wt-"))
        self.addCleanup(shutil.rmtree, worktrees, True)
        env = mock.patch.dict(os.environ, {"BRIGADIER_WORKER_WORKTREES": str(worktrees)})
        env.start()
        self.addCleanup(env.stop)
        worktree, branch, base_sha = kimi_worker.prepare_worktree(self.repo, "HEAD")
        self.assertTrue(branch.startswith("brigadier/kimi-"))
        self.assertEqual(base_sha, self.git("rev-parse", "HEAD").strip())
        self.addCleanup(
            subprocess.run,
            ["git", "-C", str(self.repo), "worktree", "remove", "--force", str(worktree)],
            capture_output=True,
        )
        (worktree / "a.txt").write_text("alpha\nbeta\n", encoding="utf-8")
        subprocess.run(["git", "-C", str(worktree), "add", "-A"], check=True, capture_output=True)
        subprocess.run(["git", "-C", str(worktree), "commit", "-qm", "brigadier"], check=True, capture_output=True)
        patch = kimi_worker.worktree_diff(worktree, base_sha)
        self.assertIn("+beta", patch)
        self.assertNotEqual(patch.strip(), "")

    def test_profile_worktrees_dir_is_default_source(self):
        worktrees = Path(tempfile.mkdtemp(prefix="kimi-worker-profile-"))
        self.addCleanup(shutil.rmtree, worktrees, True)
        with mock.patch.dict(os.environ, {}, clear=False):
            os.environ.pop("BRIGADIER_WORKER_WORKTREES", None)
            worktree, _branch, _base = kimi_worker.prepare_worktree(
                self.repo, "HEAD", {"worktreesDir": str(worktrees)}
            )
        self.addCleanup(
            subprocess.run,
            ["git", "-C", str(self.repo), "worktree", "remove", "--force", str(worktree)],
            capture_output=True,
        )
        self.assertEqual(worktree.parent, worktrees.resolve())


class ReceiptTest(unittest.TestCase):
    """Квитанция check по контракту: независимый след при успехе и при провале."""

    def setUp(self):
        self.base = Path(tempfile.mkdtemp(prefix="kimi-worker-receipts-"))
        self.addCleanup(shutil.rmtree, self.base, True)
        self.work = self.base / "work"
        self.work.mkdir()
        self.receipts = self.base / "state" / "brigadier-receipts.jsonl"

    def receipt_lines(self):
        return [json.loads(line) for line in self.receipts.read_text(encoding="utf-8").splitlines()]

    def run_check(self, request_effect):
        with (
            mock.patch.dict(os.environ, {"VIBEMEMORY_DIR": str(self.base / "state")}),
            mock.patch.object(kimi_worker, "key_from_store", return_value="test-key"),
            mock.patch.object(kimi_worker, "request", side_effect=request_effect),
            mock.patch.object(kimi_worker, "event"),
            mock.patch.object(sys, "argv", ["kimi_worker.py", "check", "--dir", str(self.work)]),
            contextlib.redirect_stdout(io.StringIO()),
        ):
            kimi_worker.main()

    def assert_contract_line(self, line):
        self.assertEqual(set(line), {"ts", "cwd", "kind", "verdict", "reason", "model", "pid"})
        self.assertRegex(line["ts"], r"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$")
        self.assertEqual(line["cwd"], str(self.work.resolve()))
        self.assertEqual(line["kind"], "check")
        self.assertEqual(line["model"], "deepseek-flash")
        self.assertEqual(line["pid"], os.getpid())

    def test_successful_check_writes_ok_receipt(self):
        self.run_check(lambda *args, **kwargs: {"choices": [{"message": {"content": "ок"}}]})
        self.assertEqual(len(self.receipt_lines()), 1)
        line = self.receipt_lines()[0]
        self.assert_contract_line(line)
        self.assertEqual(line["verdict"], "ok")
        self.assertIsNone(line["reason"])

    def test_failed_check_writes_failed_receipt(self):
        def boom(*args, **kwargs):
            raise RuntimeError("сервер не ответил")

        with self.assertRaises(RuntimeError):
            self.run_check(boom)
        self.assertEqual(len(self.receipt_lines()), 1)
        line = self.receipt_lines()[0]
        self.assert_contract_line(line)
        self.assertEqual(line["verdict"], "failed")
        self.assertIn("сервер не ответил", line["reason"])

    def test_unwritable_receipt_does_not_raise(self):
        blocker = self.base / "blocker"
        blocker.write_text("not a directory\n", encoding="utf-8")
        with (
            mock.patch.dict(os.environ, {"VIBEMEMORY_DIR": str(blocker)}),
            contextlib.redirect_stderr(io.StringIO()),
        ):
            kimi_worker.write_receipt("check", "failed", "проверка", None, str(self.work))
        self.assertFalse(self.receipts.exists())


class EnginePathTest(unittest.TestCase):
    """Движок ищется в PATH, а без него — по абсолютному пути установки."""

    def test_path_binary_wins(self):
        with mock.patch.object(kimi_worker.shutil, "which", return_value="/opt/bin/vibememory"):
            self.assertEqual(kimi_worker.engine_binary(), "/opt/bin/vibememory")

    def test_install_path_is_the_fallback(self):
        home = Path(tempfile.mkdtemp(prefix="kimi-worker-home-"))
        self.addCleanup(shutil.rmtree, home, True)
        with (
            mock.patch.object(kimi_worker.shutil, "which", return_value=None),
            mock.patch.object(kimi_worker.Path, "home", return_value=home),
        ):
            expected = home / ".vibememory" / "bin" / "vibememory"
            self.assertEqual(kimi_worker.engine_binary(), str(expected))


if __name__ == "__main__":
    unittest.main()
