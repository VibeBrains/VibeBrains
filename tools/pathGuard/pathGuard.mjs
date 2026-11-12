#!/usr/bin/env node
/**
 * Хук Claude Code `PreToolUse` для Bash: путь вне проекта останавливает команду
 *
 * WHY: субагент выполнил `npm run compare:brandbook -- --save /VolumES`
 * macOS сравнивает имена без регистра, `/VolumES` = `/Volumes`, и внешний диск был стёрт
 * Правило `Bash(npm run:*)` разрешило команду молча, а хук срабатывает до любой команды
 * PreToolUse, в том числе разрешённой правилом и запущенной субагентом
 *
 * Вход: JSON Claude Code в stdin, выход: одна строка JSON с решением в stdout и код 0
 * Сломанный хук не должен останавливать работу: любая ошибка разбора — код 0 без вывода, причина в stderr
 *
 * Логика разбора — в `commandPaths.mjs`, здесь только вход, корни и печать решения
 */
import { readFileSync } from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { commandPathsOutsideScope } from './commandPaths.mjs';

/** Строка о причине в stderr: stdout остаётся чистым, хук ничего не решает */
function warn(reason) {
	process.stderr.write(`pathGuard: ${reason}\n`);
}

/** Свои каталоги: проект, каталог строки, разрешённые вручную и временные */
function rootsOf(input) {
	const roots = [];
	const push = (value) => {
		if (typeof value === 'string' && value.trim().length > 0) {
			roots.push(value.trim());
		}
	};
	push(process.env.CLAUDE_PROJECT_DIR);
	push(typeof input.cwd === 'string' ? input.cwd : undefined);
	const allow = process.env.PATH_GUARD_ALLOW;
	if (typeof allow === 'string') {
		for (const part of allow.split(path.delimiter)) {
			push(part);
		}
	}
	push(os.tmpdir());
	return roots;
}

/** Текст для человека и модели: что не так и как сделать правильно */
function reasonOf(paths, critical) {
	const listed = paths.map(item => item.critical
		? `«${item.path}» — корень диска, тома или домашней папки`
		: `«${item.path}»`);
	const head = critical
		? 'Путь вне папок проекта, среди них корень диска, тома или домашней папки'
		: 'Путь вне папок проекта';
	return `${head}: ${listed.join('; ')}. Адресуй путь внутри проекта; разрешённые каталоги задаются PATH_GUARD_ALLOW.`;
}

function decide(input) {
	if (!input || input.tool_name !== 'Bash') {
		return undefined;
	}
	const command = input.tool_input && typeof input.tool_input.command === 'string' ? input.tool_input.command : undefined;
	if (command === undefined) {
		return undefined;
	}
	const caseInsensitive = process.platform === 'darwin' || process.platform === 'win32';
	const found = commandPathsOutsideScope(command, {
		roots: rootsOf(input),
		caseInsensitive,
		home: os.homedir(),
		cwd: typeof input.cwd === 'string' && path.isAbsolute(input.cwd) ? input.cwd : undefined,
	});
	// Чтение ничего не теряет, даже у корня тома (`ls /Volumes`), поэтому не спрашивается
	const paths = found.filter(item => !item.readOnly);
	if (paths.length === 0) {
		return undefined;
	}
	const critical = paths.some(item => item.critical);
	return {
		hookSpecificOutput: {
			hookEventName: 'PreToolUse',
			permissionDecision: critical ? 'deny' : 'ask',
			permissionDecisionReason: reasonOf(paths, critical),
		},
	};
}

function main() {
	let input;
	try {
		const raw = readFileSync(0, 'utf8');
		input = JSON.parse(raw);
	} catch (error) {
		warn(`вход не разобран: ${error.message}`);
		return;
	}
	const decision = decide(input);
	if (decision !== undefined) {
		process.stdout.write(`${JSON.stringify(decision)}\n`);
	}
}

/** Действие — только при прямом запуске: импорт файла (тестовый раннер, другой модуль) не должен ничего менять */
const isMain = process.argv[1] !== undefined && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url);

if (isMain) {
	try {
		main();
	} catch (error) {
		// Непредвиденное — та же политика: не мешать работе, но сказать в stderr
		warn(`решение не принято: ${error.message}`);
	}
}
