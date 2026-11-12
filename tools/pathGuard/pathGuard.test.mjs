/**
 * Тесты pathGuard: общие векторы разбора, сквозные прогоны хука и установщик
 * Запуск: node --test tools/pathGuard/
 */
import test from 'node:test';
import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { existsSync, mkdtempSync, readFileSync, writeFileSync } from 'node:fs';
import { homedir, tmpdir } from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { commandPathsOutsideScope } from './commandPaths.mjs';

const HERE = path.dirname(fileURLToPath(import.meta.url));
const ROOT = path.dirname(path.dirname(HERE));
const HOOK = path.join(HERE, 'pathGuard.mjs');
const INSTALL = path.join(HERE, 'install.mjs');
const VECTORS = JSON.parse(readFileSync(path.join(ROOT, 'testVectors', 'commandPathsOutside.json'), 'utf8'));

/** Прогон хука как его запускает Claude Code: JSON в stdin, решение в stdout */
function runHook(input, env = {}) {
	return spawnSync(process.execPath, [HOOK], {
		input: typeof input === 'string' ? input : JSON.stringify(input),
		encoding: 'utf8',
		env: { ...process.env, ...env },
	});
}

/** Каталог проекта для сквозных тестов: вне временных каталогов, иначе проверка корней ничего не значит */
const PROJECT = path.join(homedir(), 'pathguard-fixture-project');

test('векторы разбора из testVectors/commandPathsOutside.json', async (t) => {
	for (const vector of VECTORS) {
		await t.test(vector.name, () => {
			const found = commandPathsOutsideScope(vector.command, {
				roots: vector.roots,
				caseInsensitive: vector.caseInsensitive,
				home: vector.home,
				cwd: vector.cwd,
			});
			assert.deepStrictEqual(found, vector.expected);
		});
	}
});

test('хук: инструмент не Bash — молчит', () => {
	const result = runHook({
		hook_event_name: 'PreToolUse',
		tool_name: 'Read',
		tool_input: { file_path: '/etc/passwd' },
		cwd: PROJECT,
	});
	assert.equal(result.status, 0);
	assert.equal(result.stdout, '');
});

test('хук: путь внутри проекта — молчит', () => {
	const result = runHook({
		hook_event_name: 'PreToolUse',
		tool_name: 'Bash',
		tool_input: { command: `cat ${path.join(PROJECT, 'src', 'a.ts')}` },
		cwd: PROJECT,
	}, { CLAUDE_PROJECT_DIR: PROJECT });
	assert.equal(result.status, 0);
	assert.equal(result.stdout, '');
});

test('хук: --save на корень тома — deny', () => {
	// macOS сравнивает имена без регистра: /VolumES и есть /Volumes
	const target = process.platform === 'darwin' ? '/VolumES' : '/Volumes';
	const result = runHook({
		hook_event_name: 'PreToolUse',
		tool_name: 'Bash',
		tool_input: { command: `npm run compare:brandbook -- --save ${target}` },
		cwd: PROJECT,
	}, { CLAUDE_PROJECT_DIR: PROJECT });
	assert.equal(result.status, 0);
	assert.equal(result.stdout.trim().split('\n').length, 1);
	const decision = JSON.parse(result.stdout);
	assert.equal(decision.hookSpecificOutput.hookEventName, 'PreToolUse');
	assert.equal(decision.hookSpecificOutput.permissionDecision, 'deny');
	assert.ok(decision.hookSpecificOutput.permissionDecisionReason.includes(target));
});

test('хук: чтение вне проекта и шаблон с обратной косой — пусто', () => {
	for (const command of ['cat /opt/x', 'ls /Volumes', 'grep -v "\\.venv\\|test" a']) {
		const result = runHook({ hook_event_name: 'PreToolUse', tool_name: 'Bash', tool_input: { command }, cwd: PROJECT }, { CLAUDE_PROJECT_DIR: PROJECT });
		assert.equal(result.status, 0);
		assert.equal(result.stdout, '', command);
	}
});

test('хук: запись вне проекта без критичности — ask', () => {
	const result = runHook({
		hook_event_name: 'PreToolUse',
		tool_name: 'Bash',
		tool_input: { command: 'cp a /opt/x' },
		cwd: PROJECT,
	}, { CLAUDE_PROJECT_DIR: PROJECT });
	assert.equal(result.status, 0);
	const decision = JSON.parse(result.stdout);
	assert.equal(decision.hookSpecificOutput.permissionDecision, 'ask');
});

test('хук: мусор на входе — код 0 и пустой stdout', () => {
	const result = runHook('это не JSON');
	assert.equal(result.status, 0);
	assert.equal(result.stdout, '');
	assert.ok(result.stderr.includes('pathGuard'));
});

test('установщик: установка, повтор без дубля, удаление', () => {
	const config = mkdtempSync(path.join(tmpdir(), 'pathguard-config-'));
	const settingsFile = path.join(config, 'settings.json');
	const hooksDir = path.join(config, 'hooks', 'pathGuard');
	const hookFile = path.join(hooksDir, 'pathGuard.mjs');
	const foreign = { matcher: 'Edit', hooks: [{ type: 'command', command: 'echo чужой' }] };
	writeFileSync(settingsFile, JSON.stringify({ model: 'opus', hooks: { PreToolUse: [foreign] }, permissions: { allow: [] } }, null, 2));

	const run = (args) => spawnSync(process.execPath, [INSTALL, ...args], {
		encoding: 'utf8',
		env: { ...process.env, CLAUDE_CONFIG_DIR: config },
	});
	const settings = () => JSON.parse(readFileSync(settingsFile, 'utf8'));
	const own = (value) => value.hooks.PreToolUse.filter(entry =>
		entry.hooks.some(hook => hook.command.includes('hooks/pathGuard/pathGuard.mjs')));

	const first = run([]);
	assert.equal(first.status, 0, first.stderr);
	assert.ok(existsSync(hookFile));
	assert.ok(existsSync(path.join(hooksDir, 'commandPaths.mjs')));
	assert.ok(existsSync(`${settingsFile}.bak-pathGuard`));
	assert.equal(settings().model, 'opus');
	assert.deepEqual(settings().permissions, { allow: [] });
	assert.equal(settings().hooks.PreToolUse.length, 2);
	assert.equal(settings().hooks.PreToolUse[0].matcher, 'Edit');
	assert.equal(own(settings()).length, 1);
	assert.equal(own(settings())[0].matcher, 'Bash');
	assert.equal(own(settings())[0].hooks[0].timeout, 10);
	assert.ok(own(settings())[0].hooks[0].command.includes(hookFile));

	const second = run([]);
	assert.equal(second.status, 0, second.stderr);
	assert.equal(settings().hooks.PreToolUse.length, 2);
	assert.equal(own(settings()).length, 1);
	assert.equal(settings().model, 'opus');

	const removed = run(['--uninstall']);
	assert.equal(removed.status, 0, removed.stderr);
	assert.equal(own(settings()).length, 0);
	assert.equal(settings().hooks.PreToolUse.length, 1);
	assert.deepEqual(settings().hooks.PreToolUse[0], foreign);
	assert.equal(settings().model, 'opus');
	assert.ok(!existsSync(hooksDir));
});

test('установщик: --dry-run ничего не меняет', () => {
	const config = mkdtempSync(path.join(tmpdir(), 'pathguard-dry-'));
	const settingsFile = path.join(config, 'settings.json');
	writeFileSync(settingsFile, JSON.stringify({ model: 'opus' }, null, 2));
	const before = readFileSync(settingsFile, 'utf8');
	const result = spawnSync(process.execPath, [INSTALL, '--dry-run'], {
		encoding: 'utf8',
		env: { ...process.env, CLAUDE_CONFIG_DIR: config },
	});
	assert.equal(result.status, 0, result.stderr);
	assert.ok(result.stdout.includes('matcher Bash'));
	assert.equal(readFileSync(settingsFile, 'utf8'), before);
	assert.ok(!existsSync(path.join(config, 'hooks')));
	assert.ok(!existsSync(`${settingsFile}.bak-pathGuard`));
});
