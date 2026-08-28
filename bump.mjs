#!/usr/bin/env node
/**
 * Пересчитывает versions.json — реестр ревизий набора.
 *
 * Зачем: продукты (VibeIDE, VibeIDEA) сеют этот набор в `.vibe/` проектов и потом должны
 * понимать про каждый файл: копия у пользователя — нетронутый старый сид (можно молча
 * обновить) или его правка (трогать нельзя, надо спросить). Отличить одно от другого можно
 * только зная sha256 ВСЕХ прошлых ревизий файла — их и накапливает `history`.
 *
 * Версия внутри самого jsonc (`"version": 1`) — это версия ФОРМАТА (контракт providers.json),
 * не ревизия сида: она есть не у всех файлов набора и путешествует вместе с копией
 * пользователя. Поэтому ревизии живут здесь, отдельным реестром.
 *
 * Запуск: `node bump.mjs` (после правки любых файлов набора, ДО коммита).
 * Проверка без записи: `node bump.mjs --check` — код возврата 1, если реестр устарел
 * (тот же гейт прогоняют оба продукта на своих тестах).
 */

import { execFileSync } from 'child_process';
import { createHash } from 'crypto';
import { promises as fs } from 'fs';
import path from 'path';
import { fileURLToPath } from 'url';

const ROOT = path.dirname(fileURLToPath(import.meta.url));
const REGISTRY = path.join(ROOT, 'versions.json');
/** Служебные файлы набора: описывают набор, но сами в проекты не сеются. */
const METADATA = new Set(['versions.json', 'deprecated.json']);

/** sha256 от LF-нормализованного UTF-8 — CRLF-чекаут не должен выглядеть правкой. */
function sha256(text) {
	return createHash('sha256').update(text.replace(/\r\n/g, '\n'), 'utf8').digest('hex');
}

async function collect(dir, rel = '') {
	const out = [];
	for (const entry of await fs.readdir(dir, { withFileTypes: true })) {
		if (entry.name === '.git' || entry.name === '.github') { continue; }
		const relPath = rel ? `${rel}/${entry.name}` : entry.name;
		if (entry.isDirectory()) {
			out.push(...await collect(path.join(dir, entry.name), relPath));
		} else if (entry.isFile() && !METADATA.has(relPath) && relPath !== 'bump.mjs') {
			out.push(relPath);
		}
	}
	return out;
}

/**
 * sha256 всех версий файла, что помнит git указанного репозитория.
 *
 * Нужно на инициализации и после переездов: копии, засеянные прошлыми релизами, лежат у людей
 * в проектах, и без их sha в `history` сеялка примет нетронутый старый сид за правку — и
 * никогда его не обновит. `--donor` добирает историю оттуда, откуда набор переехал
 * (`.vibe-defaults` репозитория VibeIDE), где у файлов был другой префикс пути.
 */
function gitHistoryHashes(repo, relPathInRepo) {
	let revisions;
	try {
		revisions = execFileSync('git', ['-C', repo, 'log', '--format=%H', '--', relPathInRepo], { encoding: 'utf8', stdio: ['ignore', 'pipe', 'ignore'] })
			.split('\n').filter(Boolean);
	} catch {
		return []; // не git-репозиторий или файла там не было
	}
	const hashes = [];
	for (const rev of revisions) {
		try {
			hashes.push(sha256(execFileSync('git', ['-C', repo, 'show', `${rev}:${relPathInRepo}`], { encoding: 'utf8', maxBuffer: 64 * 1024 * 1024, stdio: ['ignore', 'pipe', 'ignore'] })));
		} catch {
			// коммит-удаление: содержимого на этой ревизии нет
		}
	}
	return hashes;
}

/** `--donor <путь-к-репо>:<префикс>` — откуда добрать историю переехавших файлов. */
function parseDonors(argv) {
	return argv.filter(a => a.startsWith('--donor=')).map(a => {
		const value = a.slice('--donor='.length);
		const at = value.lastIndexOf(':');
		return { repo: value.slice(0, at), prefix: value.slice(at + 1) };
	});
}

async function readRegistry() {
	try {
		const parsed = JSON.parse(await fs.readFile(REGISTRY, 'utf8'));
		return parsed?.files ?? {};
	} catch {
		return {}; // первый запуск
	}
}

async function main() {
	const check = process.argv.includes('--check');
	const fromGit = process.argv.includes('--from-git');
	const donors = parseDonors(process.argv);
	const files = (await collect(ROOT)).sort();
	const previous = await readRegistry();
	const next = {};
	const bumped = [];
	const added = [];

	for (const rel of files) {
		const hash = sha256(await fs.readFile(path.join(ROOT, rel), 'utf8'));
		const prev = previous[rel];
		// Историю из git добираем всегда, когда просили: она пополняет запись, а не заменяет.
		const gitHashes = fromGit
			? [...gitHistoryHashes(ROOT, rel), ...donors.flatMap(d => gitHistoryHashes(d.repo, `${d.prefix}/${rel}`))]
				.filter(h => h !== hash)
			: [];
		if (!prev) {
			next[rel] = { version: 1 + gitHashes.length, sha256: hash, history: [...new Set(gitHashes)] };
			added.push(rel);
		} else if (prev.sha256 === hash) {
			if (gitHashes.length > 0) {
				const merged = [...new Set([...(prev.history ?? []), ...gitHashes])];
				next[rel] = merged.length === (prev.history ?? []).length ? prev : { ...prev, history: merged };
				continue;
			}
			next[rel] = prev; // не изменился — ревизия та же
		} else {
			const inherited = [...new Set([...(prev.history ?? []), prev.sha256, ...gitHashes])];
			// Содержимое поехало → новая ревизия, прошлая sha уходит в историю: по ней
			// продукты узнают нетронутую копию прошлого релиза в чужом проекте.
			next[rel] = { version: prev.version + 1, sha256: hash, history: inherited };
			bumped.push(rel);
		}
	}

	const dropped = Object.keys(previous).filter(p => !(p in next));
	const stale = check && (bumped.length > 0 || added.length > 0 || dropped.length > 0);
	if (check) {
		if (stale) {
			console.error('[bump] versions.json устарел:');
			for (const p of added) { console.error(`  + новый файл без записи: ${p}`); }
			for (const p of bumped) { console.error(`  ~ изменён без бампа ревизии: ${p}`); }
			for (const p of dropped) { console.error(`  - удалён, но остался в реестре (перенести в deprecated.json): ${p}`); }
			console.error('Запустите: node bump.mjs');
			process.exit(1);
		}
		console.log(`[bump] versions.json актуален (${files.length} файлов)`);
		return;
	}

	// Удалённый файл в реестре не оставляем: его место — deprecated.json (там история sha
	// нужна, чтобы сеялки удаляли только нетронутые копии).
	for (const p of dropped) {
		console.log(`[bump] удалён из набора: ${p} → перенесите запись в deprecated.json (history: ${[...(previous[p].history ?? []), previous[p].sha256].join(', ')})`);
	}

	const registry = { version: 1, comment: 'Ревизии файлов набора. Генерируется bump.mjs — руками не править. history хранит sha256 прошлых ревизий: по ним сеялка узнаёт нетронутую копию старого релиза.', files: next };
	await fs.writeFile(REGISTRY, `${JSON.stringify(registry, null, 2)}\n`, 'utf8');
	console.log(`[bump] записано ${files.length} файлов; новых ${added.length}, поднято ревизий ${bumped.length}`);
	for (const p of bumped) { console.log(`  ~ ${p} → v${next[p].version}`); }
}

main();
