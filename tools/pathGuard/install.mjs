#!/usr/bin/env node
/**
 * Установка хука pathGuard в настройки Claude Code
 *
 * Копирует сам хук и разбор в `<CLAUDE_CONFIG_DIR или ~/.claude>/hooks/pathGuard/`
 * и вписывает запись `PreToolUse` с matcher `Bash` в `settings.json` того же каталога
 * Повторный запуск не плодит дубль: своя запись узнаётся по пути `hooks/pathGuard/pathGuard.mjs`
 * Чужие ключи и записи не трогаются; перед записью — резервная копия `settings.json.bak-pathGuard`
 *
 * Ключи: `--dry-run` — показать, что будет сделано, ничего не меняя; `--uninstall` — убрать запись и файлы
 * Против настоящего `~/.claude` не запускать в тестах: каталог задаётся через `CLAUDE_CONFIG_DIR`
 */
import { copyFileSync, existsSync, mkdirSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const SOURCE_DIR = path.dirname(fileURLToPath(import.meta.url));
const FILES = ['pathGuard.mjs', 'commandPaths.mjs'];

/** Отпечаток своей записи: установленный хук всегда лежит по этому пути внутри каталога настроек */
const MARKER = 'hooks/pathGuard/pathGuard.mjs';

const argv = process.argv.slice(2);
const dryRun = argv.includes('--dry-run');
const uninstall = argv.includes('--uninstall');

function configDir() {
	const fromEnv = process.env.CLAUDE_CONFIG_DIR;
	const base = typeof fromEnv === 'string' && fromEnv.trim().length > 0 ? fromEnv.trim() : path.join(os.homedir(), '.claude');
	return path.resolve(base);
}

/** Настройки читаются как есть; пустой файл — пустой объект, не объект — ошибка, чтобы не затереть чужое */
function readSettings(file) {
	if (!existsSync(file)) {
		return {};
	}
	const text = readFileSync(file, 'utf8');
	if (text.trim().length === 0) {
		return {};
	}
	const parsed = JSON.parse(text);
	if (typeof parsed !== 'object' || parsed === null || Array.isArray(parsed)) {
		throw new Error('settings.json — не объект');
	}
	return parsed;
}

/** Перед записью — копия: ручная правка настроек всегда должна быть возможна */
function writeSettings(file, settings) {
	if (existsSync(file)) {
		copyFileSync(file, `${file}.bak-pathGuard`);
	}
	writeFileSync(file, `${JSON.stringify(settings, null, 2)}\n`);
}

/** Своя запись — та, где один из хуков указывает на установленный `hooks/pathGuard/pathGuard.mjs` */
function isOwnEntry(entry) {
	return !!entry && Array.isArray(entry.hooks) && entry.hooks.some(hook =>
		!!hook && typeof hook.command === 'string'
			&& hook.command.replace(/\\/g, '/').includes(MARKER));
}

/** Объект `hooks` настроек: создаётся при отсутствии, чужой вид — ошибка */
function hooksOf(settings) {
	if (settings.hooks === undefined) {
		settings.hooks = {};
	}
	if (typeof settings.hooks !== 'object' || settings.hooks === null || Array.isArray(settings.hooks)) {
		throw new Error('ключ hooks в settings.json — не объект');
	}
	return settings.hooks;
}

/** Записи PreToolUse: создаются при отсутствии, чужой вид — ошибка */
function preToolUseOf(settings) {
	const hooks = hooksOf(settings);
	if (hooks.PreToolUse === undefined) {
		hooks.PreToolUse = [];
	}
	if (!Array.isArray(hooks.PreToolUse)) {
		throw new Error('hooks.PreToolUse в settings.json — не массив');
	}
	return hooks.PreToolUse;
}

function ownEntry(hookFile) {
	return {
		matcher: 'Bash',
		hooks: [{ type: 'command', command: `node "${hookFile}"`, timeout: 10 }],
	};
}

function install(config) {
	const hooksDir = path.join(config, 'hooks', 'pathGuard');
	const hookFile = path.join(hooksDir, 'pathGuard.mjs');
	const settingsFile = path.join(config, 'settings.json');
	const settings = readSettings(settingsFile);
	const pre = preToolUseOf(settings);
	const existing = pre.filter(isOwnEntry).length;
	const kept = pre.filter(entry => !isOwnEntry(entry));
	const verb = existing > 0 ? 'обновил' : 'добавил';

	if (dryRun) {
		console.log(`скопировал бы ${FILES.join(', ')} в ${hooksDir}`);
		console.log(`${verb} бы запись PreToolUse (matcher Bash) в ${settingsFile}`);
		return;
	}
	mkdirSync(hooksDir, { recursive: true });
	for (const file of FILES) {
		copyFileSync(path.join(SOURCE_DIR, file), path.join(hooksDir, file));
	}
	settings.hooks.PreToolUse = [...kept, ownEntry(hookFile)];
	writeSettings(settingsFile, settings);
	console.log(`файлы хука: ${hooksDir}`);
	console.log(`${verb} запись PreToolUse (matcher Bash) в ${settingsFile}`);
}

function uninstallHook(config) {
	const hooksDir = path.join(config, 'hooks', 'pathGuard');
	const settingsFile = path.join(config, 'settings.json');
	const settingsExists = existsSync(settingsFile);
	const settings = settingsExists ? readSettings(settingsFile) : {};
	let removed = 0;
	if (settings.hooks && Array.isArray(settings.hooks.PreToolUse)) {
		const pre = settings.hooks.PreToolUse;
		const kept = pre.filter(entry => !isOwnEntry(entry));
		removed = pre.length - kept.length;
		if (kept.length > 0) {
			settings.hooks.PreToolUse = kept;
		} else {
			delete settings.hooks.PreToolUse;
		}
		if (Object.keys(settings.hooks).length === 0) {
			delete settings.hooks;
		}
	}

	if (dryRun) {
		console.log(`убрал бы ${removed} записей PreToolUse из ${settingsFile}`);
		console.log(`удалил бы каталог ${hooksDir}`);
		return;
	}
	if (settingsExists && removed > 0) {
		writeSettings(settingsFile, settings);
	}
	rmSync(hooksDir, { recursive: true, force: true });
	console.log(`убрано записей PreToolUse: ${removed}`);
	console.log(`удалён каталог ${hooksDir}`);
}

/** Действие — только при прямом запуске: импорт файла (тестовый раннер, другой модуль) не должен ничего менять */
const isMain = process.argv[1] !== undefined && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url);

if (isMain) {
	try {
		const config = configDir();
		if (uninstall) {
			uninstallHook(config);
		} else {
			install(config);
		}
	} catch (error) {
		process.stderr.write(`pathGuard install: ${error.message}\n`);
		process.exitCode = 1;
	}
}
