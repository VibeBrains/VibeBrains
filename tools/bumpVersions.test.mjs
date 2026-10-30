/**
 * Тесты bump.mjs: версии в шапках, автоподъём патча, ручные минор и мажор.
 * Запуск: node --test tools/ (на Node 24 каталог не подхватывается — node --test tools/*.test.mjs)
 */
import test from 'node:test';
import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { copyFileSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const ROOT = path.dirname(path.dirname(fileURLToPath(import.meta.url)));
const BUMP = path.join(ROOT, 'bump.mjs');

const RULE = [
	'---',
	'description: Тестовое правило',
	'alwaysApply: false',
	'vibeVersion: "1.0.0"',
	'---',
	'',
	'Тело правила',
	'',
].join('\n');

const SKILL = [
	'---',
	'name: demo',
	'description: Тестовый навык',
	'metadata:',
	'  vibeVersion: "1.0.0"',
	'---',
	'',
	'# demo',
	'',
].join('\n');

/** Минимальный набор во временной папке: одно правило, один навык и файл без версии */
function fixture() {
	const dir = mkdtempSync(path.join(tmpdir(), 'bump-versions-'));
	copyFileSync(BUMP, path.join(dir, 'bump.mjs'));
	writeFileSync(path.join(dir, 'README.md'), '# набор\n');
	mkdirSync(path.join(dir, 'rules'));
	writeFileSync(path.join(dir, 'rules', 'a.mdc'), RULE);
	mkdirSync(path.join(dir, 'skills', 'demo'), { recursive: true });
	writeFileSync(path.join(dir, 'skills', 'demo', 'SKILL.md'), SKILL);
	writeFileSync(path.join(dir, 'skills', 'demo', 'worker.sh'), 'echo 1\n');
	return dir;
}

function read(dir, rel) {
	return readFileSync(path.join(dir, rel), 'utf8');
}

function write(dir, rel, text) {
	writeFileSync(path.join(dir, rel), text);
}

function bump(dir, ...args) {
	return spawnSync(process.execPath, ['bump.mjs', ...args], { cwd: dir, encoding: 'utf8' });
}

function registry(dir) {
	return JSON.parse(read(dir, 'versions.json')).files;
}

function withFixture(fn) {
	const dir = fixture();
	try {
		fn(dir);
	} finally {
		rmSync(dir, { recursive: true, force: true });
	}
}

test('базовый прогон пишет vibeVersion только навыкам и правилам', () => withFixture(dir => {
	const result = bump(dir);
	assert.equal(result.status, 0, result.stderr);
	const files = registry(dir);
	assert.equal(files['rules/a.mdc'].vibeVersion, '1.0.0');
	assert.equal(files['skills/demo/SKILL.md'].vibeVersion, '1.0.0');
	assert.equal('vibeVersion' in files['skills/demo/worker.sh'], false);
	assert.equal('vibeVersion' in files['README.md'], false);
}));

test('изменённое правило получает патч автоматически', () => withFixture(dir => {
	assert.equal(bump(dir).status, 0);
	write(dir, 'rules/a.mdc', read(dir, 'rules/a.mdc').replace('Тело правила', 'Тело правила 2'));
	const result = bump(dir);
	assert.equal(result.status, 0, result.stderr);
	assert.match(result.stdout, /rules\/a\.mdc.*1\.0\.0 → 1\.0\.1/);
	assert.match(read(dir, 'rules/a.mdc'), /vibeVersion: "1\.0\.1"/);
	assert.equal(registry(dir)['rules/a.mdc'].vibeVersion, '1.0.1');
	assert.equal(registry(dir)['rules/a.mdc'].version, 2);
}));

test('изменение любого файла навыка поднимает версию в его SKILL.md', () => withFixture(dir => {
	assert.equal(bump(dir).status, 0);
	write(dir, 'skills/demo/worker.sh', 'echo 2\n');
	const result = bump(dir);
	assert.equal(result.status, 0, result.stderr);
	assert.match(result.stdout, /skills\/demo\/SKILL\.md.*1\.0\.0 → 1\.0\.1/);
	assert.match(read(dir, 'skills/demo/SKILL.md'), /vibeVersion: "1\.0\.1"/);
	assert.equal(registry(dir)['skills/demo/SKILL.md'].vibeVersion, '1.0.1');
	assert.equal(registry(dir)['skills/demo/worker.sh'].version, 2);
}));

test('ручной минор скрипт уважает и не перебивает патчем', () => withFixture(dir => {
	assert.equal(bump(dir).status, 0);
	write(dir, 'skills/demo/worker.sh', 'echo 2\n');
	write(dir, 'skills/demo/SKILL.md', read(dir, 'skills/demo/SKILL.md').replace('"1.0.0"', '"1.1.0"'));
	const result = bump(dir);
	assert.equal(result.status, 0, result.stderr);
	assert.doesNotMatch(result.stdout, /версия поднята автоматически/);
	assert.match(read(dir, 'skills/demo/SKILL.md'), /vibeVersion: "1\.1\.0"/);
	assert.equal(registry(dir)['skills/demo/SKILL.md'].vibeVersion, '1.1.0');
}));

test('понижение версии — ошибка в обоих режимах', () => withFixture(dir => {
	assert.equal(bump(dir).status, 0);
	write(dir, 'rules/a.mdc', read(dir, 'rules/a.mdc')
		.replace('Тело правила', 'Тело правила 2')
		.replace('"1.0.0"', '"0.9.0"'));
	const writeRun = bump(dir);
	assert.equal(writeRun.status, 1);
	assert.match(writeRun.stderr, /ниже записанной/);
	const checkRun = bump(dir, '--check');
	assert.equal(checkRun.status, 1);
	assert.match(checkRun.stderr, /ниже записанной/);
	assert.equal(registry(dir)['rules/a.mdc'].vibeVersion, '1.0.0');
}));

test('отсутствие версии — ошибка шапки', () => withFixture(dir => {
	assert.equal(bump(dir).status, 0);
	write(dir, 'skills/demo/SKILL.md', read(dir, 'skills/demo/SKILL.md').replace('  vibeVersion: "1.0.0"\n', ''));
	for (const args of [[], ['--check']]) {
		const result = bump(dir, ...args);
		assert.equal(result.status, 1);
		assert.match(result.stderr, /vibeVersion/);
	}
}));

test('--check краснеет, когда содержимое изменилось без подъёма версии', () => withFixture(dir => {
	assert.equal(bump(dir).status, 0);
	write(dir, 'rules/a.mdc', read(dir, 'rules/a.mdc').replace('Тело правила', 'Тело правила 2'));
	const result = bump(dir, '--check');
	assert.equal(result.status, 1);
	assert.match(result.stderr, /версия не поднята/);
}));
