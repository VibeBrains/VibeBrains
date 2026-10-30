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
 * (тот же гейт прогоняют оба продукта на своих тестах)
 * Оба режима сначала проверяют шапки навыков и правил: ошибка в шапке — код 1, реестр не пишется
 * Версии правил и навыков (`vibeVersion` в шапке) скрипт читает и пишет в реестр; если содержимое
 * изменилось, а версия не поднята, патч поднимается сам; минор и мажор ставит человек
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
/** Каталоги про набор, а не его часть: мануалы и утилиты не сеются в проекты */
const NOT_SEEDED_DIRS = new Set(['docs', 'tools']);

/** sha256 от LF-нормализованного UTF-8 — CRLF-чекаут не должен выглядеть правкой. */
function sha256(text) {
	return createHash('sha256').update(text.replace(/\r\n/g, '\n'), 'utf8').digest('hex');
}

/** Версия правила или навыка: semver из трёх чисел; минор и мажор человек ставит руками, патч — скрипт */
const SEMVER = /^\d+\.\d+\.\d+$/;

/** Файл, в шапке которого живёт версия: правило — сам файл, любой файл навыка — его SKILL.md */
function versionFileOf(rel) {
	if (rel.endsWith('.mdc')) { return rel; }
	if (rel.startsWith('skills/')) { return `${rel.split('/').slice(0, 2).join('/')}/SKILL.md`; }
	return null;
}

/** Строки шапки без обрамляющих ---; null — шапки нет или она не закрыта */
function frontmatterLines(text) {
	if (!text.startsWith('---')) { return null; }
	const end = text.indexOf('\n---', 3);
	return end < 0 ? null : text.slice(3, end).split(/\r?\n/);
}

/** vibeVersion из шапки: у навыка вложенно под metadata, у правила — ключом верхнего уровня */
function rawVibeVersion(rel, text) {
	const lines = frontmatterLines(text);
	if (!lines) { return null; }
	if (rel.endsWith('SKILL.md')) {
		const at = lines.findIndex(line => /^metadata:\s*$/.test(line));
		if (at < 0) { return null; }
		for (let i = at + 1; i < lines.length; i++) {
			if (lines[i].trim() !== '' && !/^\s/.test(lines[i])) { break; }
			const kv = /^\s+vibeVersion:\s*(.*)$/.exec(lines[i]);
			if (kv) { return kv[1].trim(); }
		}
		return null;
	}
	const line = lines.find(l => /^vibeVersion:\s*/.test(l));
	return line ? line.replace(/^vibeVersion:\s*/, '').trim() : null;
}

/** Значение версии или текст ошибки: контракт требует semver в кавычках */
function parseVibeVersion(rel, raw) {
	if (raw === null || raw === '') { return { error: `${rel}: поле vibeVersion обязательно` }; }
	if (raw.length < 2 || (raw[0] !== '"' && raw[0] !== "'") || raw[raw.length - 1] !== raw[0]) {
		return { error: `${rel}: vibeVersion — значение в кавычках` };
	}
	const value = raw.slice(1, -1);
	if (!SEMVER.test(value)) { return { error: `${rel}: vibeVersion «${value}» — не semver` }; }
	return { value };
}

/** Переписать версию в шапке, сохранив отступ и кавычки */
function setVibeVersion(rel, text, value) {
	const end = text.indexOf('\n---', 3);
	const head = text.slice(0, end);
	const tail = text.slice(end);
	const line = rel.endsWith('SKILL.md') ? `  vibeVersion: "${value}"` : `vibeVersion: "${value}"`;
	const re = rel.endsWith('SKILL.md') ? /^\s+vibeVersion:.*$/m : /^vibeVersion:.*$/m;
	return head.replace(re, line) + tail;
}

/** Числа версии; prerelease контрактом не предусмотрен */
function semverParts(value) {
	return value.split('.').map(Number);
}

/** Сравнение версий: −1, 0 или 1 */
function compareSemver(a, b) {
	const left = semverParts(a);
	const right = semverParts(b);
	for (let i = 0; i < 3; i++) {
		if (left[i] !== right[i]) { return left[i] < right[i] ? -1 : 1; }
	}
	return 0;
}

/** Патч вперёд: 1.0.0 → 1.0.1; минор и мажор остаются человеку */
function patchBump(value) {
	const [major, minor, patch] = semverParts(value);
	return `${major}.${minor}.${patch + 1}`;
}

async function collect(dir, rel = '') {
	const out = [];
	for (const entry of await fs.readdir(dir, { withFileTypes: true })) {
		if (entry.name === '.git' || entry.name === '.github') { continue; }
		if (!rel && entry.isDirectory() && NOT_SEEDED_DIRS.has(entry.name)) { continue; }
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

/**
 * Однострочные поля шапки, которые читают и строгий YAML (GitHub, Claude Code), и ручные разборщики продуктов
 * Значение в кавычках или блоком (`>`, `|`) — валидный YAML, проверяется только закрытие кавычки
 * Без кавычек YAML ломается на «: » и « #» внутри значения и на служебном знаке в начале
 * globs и triggers не проверяются: это формат Cursor и VibeIDE, а не YAML
 */
const PLAIN_KEYS = new Set(['name', 'title', 'description']);
const YAML_INDICATOR_START = /^[-?:,\[\]{}#&*!|>'"%@`]/;

/**
 * Поля шапки: key → значение или строки блока
 * Значение в двойных или одинарных кавычках отдаётся без кавычек
 * Блок `>` или `|` собирается до следующего ключа верхнего уровня
 */
function headerFields(lines) {
	const fields = new Map();
	for (let i = 0; i < lines.length; i++) {
		const kv = /^([A-Za-z][\w-]*):\s*(.*)$/.exec(lines[i]);
		if (!kv) { continue; }
		const [, key, raw] = kv;
		if (/^[>|][+-]?\d?\s*$/.test(raw)) {
			const block = [];
			for (let j = i + 1; j < lines.length && !/^[A-Za-z][\w-]*:\s*/.test(lines[j]); j++) {
				block.push(lines[j]);
			}
			fields.set(key, { value: '', block });
			continue;
		}
		let value = raw.replace(/\s+$/, '');
		if (value.length > 1 && (value[0] === '"' || value[0] === "'") && value.endsWith(value[0])) {
			value = value.slice(1, -1);
		}
		fields.set(key, { value, block: null });
	}
	return fields;
}

/** Проверки стандарта Agent Skills для SKILL.md: name и description */
function agentSkillErrors(rel, fields) {
	const errors = [];
	const folder = rel.split('/').slice(-2)[0] ?? '';
	const name = fields.get('name');
	if (!name || name.value === '') {
		errors.push(`${rel}: поле name обязательно`);
	} else {
		const value = name.value;
		if (value.length > 64) { errors.push(`${rel}: name длиннее 64 символов`); }
		if (!/^[a-z0-9-]+$/.test(value)) { errors.push(`${rel}: name — только строчные латинские буквы, цифры и дефис`); }
		if (value.startsWith('-') || value.endsWith('-')) { errors.push(`${rel}: name не начинается и не кончается дефисом`); }
		if (value.includes('--')) { errors.push(`${rel}: name без двойного дефиса`); }
		if (value !== folder) { errors.push(`${rel}: name «${value}» не совпадает с именем папки «${folder}»`); }
	}
	const description = fields.get('description');
	if (!description) {
		errors.push(`${rel}: поле description обязательно`);
	} else {
		// Блок считаем по сумме длин его строк без отступа
		const length = description.block
			? description.block.reduce((sum, line) => sum + line.trim().length, 0)
			: description.value.trim().length;
		if (length === 0) { errors.push(`${rel}: поле description обязательно`); }
		else if (length > 1024) { errors.push(`${rel}: description длиннее 1024 символов (${length})`); }
	}
	return errors;
}

/** Ошибки шапки файла набора: строка на ошибку, пустой список — шапка в порядке */
function frontmatterErrors(rel, text) {
	const isSkill = rel.endsWith('SKILL.md');
	const isRule = rel.endsWith('.mdc');
	if (!isSkill && !isRule) { return []; }
	if (!text.startsWith('---')) {
		return isSkill ? [`${rel}: шапка не найдена — поле name обязательно`] : [];
	}
	const end = text.indexOf('\n---', 3);
	if (end < 0) { return [`${rel}: шапка не закрыта строкой ---`]; }
	const lines = text.slice(3, end).split(/\r?\n/);
	const errors = [];
	for (const line of lines) {
		const kv = /^([A-Za-z][\w-]*):\s*(.*)$/.exec(line);
		if (!kv || !PLAIN_KEYS.has(kv[1]) || kv[2] === '') { continue; }
		const value = kv[2];
		if (/^[>|][+-]?\d?\s*$/.test(value)) { continue; }
		if (value[0] === '"' || value[0] === "'") {
			const closed = value.length > 1 && value.endsWith(value[0]) && !(value[0] === '"' && /(^|[^\\])(\\\\)*\\"$/.test(value.slice(1)));
			if (!closed) { errors.push(`${rel}: поле ${kv[1]} — кавычка не закрыта в той же строке`); }
			continue;
		}
		if (value.includes(': ')) { errors.push(`${rel}: в поле ${kv[1]} двоеточие с пробелом — заменить на « — » или взять значение в кавычки`); }
		if (value.includes(' #')) { errors.push(`${rel}: в поле ${kv[1]} « #» — YAML читает остаток как комментарий`); }
		if (YAML_INDICATOR_START.test(value)) { errors.push(`${rel}: поле ${kv[1]} начинается со служебного знака YAML «${value[0]}»`); }
	}
	if (isSkill) { errors.push(...agentSkillErrors(rel, headerFields(lines))); }
	return errors;
}

async function main() {
	const check = process.argv.includes('--check');
	const fromGit = process.argv.includes('--from-git');
	const donors = parseDonors(process.argv);
	const files = (await collect(ROOT)).sort();
	const texts = new Map();
	for (const rel of files) { texts.set(rel, await fs.readFile(path.join(ROOT, rel), 'utf8')); }

	const headerErrors = [];
	for (const rel of files) { headerErrors.push(...frontmatterErrors(rel, texts.get(rel))); }

	// Версия сущности живёт в шапке: правило — верхним уровнем, навык — в metadata своего SKILL.md
	const versions = new Map();
	for (const rel of files) {
		if (versionFileOf(rel) !== rel) { continue; }
		const parsed = parseVibeVersion(rel, rawVibeVersion(rel, texts.get(rel)));
		if (parsed.error) { headerErrors.push(parsed.error); } else { versions.set(rel, parsed.value); }
	}
	if (headerErrors.length > 0) {
		console.error('[bump] ошибки шапок навыков и правил:');
		for (const e of headerErrors) { console.error(`  ! ${e}`); }
		process.exit(1);
	}

	const previous = await readRegistry();
	const versionErrors = [];
	const notRaised = [];
	const autoBumped = [];
	const pendingBumps = [];
	const entityFiles = new Map();
	for (const rel of files) {
		const versionFile = versionFileOf(rel);
		if (!versionFile) { continue; }
		if (!entityFiles.has(versionFile)) { entityFiles.set(versionFile, []); }
		entityFiles.get(versionFile).push(rel);
	}
	for (const [versionFile, members] of entityFiles) {
		const current = versions.get(versionFile);
		if (!current) { continue; }
		const recorded = previous[versionFile]?.vibeVersion;
		if (!recorded) { continue; } // новая сущность: сравнивать не с чем
		const order = compareSemver(current, recorded);
		if (order < 0) {
			versionErrors.push(`${versionFile}: в шапке ${current}, в реестре ${recorded}`);
			continue;
		}
		const present = new Set(members);
		const removed = Object.keys(previous).filter(p => versionFileOf(p) === versionFile && !present.has(p));
		const changed = removed.length > 0 || members.some(rel => previous[rel]?.sha256 !== sha256(texts.get(rel)));
		if (!changed || order > 0) { continue; } // версию подняли руками — её уважаем
		if (check) {
			notRaised.push(versionFile);
			continue;
		}
		pendingBumps.push({ versionFile, from: current, to: patchBump(current) });
	}
	// Ошибку понижения показываем до записи: при ней не меняем ни файлы, ни реестр
	if (versionErrors.length > 0) {
		console.error('[bump] версия ниже записанной в реестре:');
		for (const e of versionErrors) { console.error(`  ! ${e}`); }
		process.exit(1);
	}
	for (const { versionFile, from, to } of pendingBumps) {
		const bumpedText = setVibeVersion(versionFile, texts.get(versionFile), to);
		texts.set(versionFile, bumpedText);
		// Патч пишем в сам файл: реестр должен описывать то, что лежит на диске
		await fs.writeFile(path.join(ROOT, versionFile), bumpedText, 'utf8');
		versions.set(versionFile, to);
		autoBumped.push(`${versionFile} ${from} → ${to}`);
	}

	const next = {};
	const bumped = [];
	const added = [];
	const restamped = [];

	for (const rel of files) {
		const hash = sha256(texts.get(rel));
		const vibeVersion = versions.get(rel);
		const prev = previous[rel];
		// Историю из git добираем всегда, когда просили: она пополняет запись, а не заменяет.
		const gitHashes = fromGit
			? [...gitHistoryHashes(ROOT, rel), ...donors.flatMap(d => gitHistoryHashes(d.repo, `${d.prefix}/${rel}`))]
				.filter(h => h !== hash)
			: [];
		if (!prev) {
			next[rel] = { version: 1 + gitHashes.length, sha256: hash, history: [...new Set(gitHashes)] };
			if (vibeVersion) { next[rel].vibeVersion = vibeVersion; }
			added.push(rel);
		} else if (prev.sha256 === hash) {
			let record = prev;
			if (gitHashes.length > 0) {
				const merged = [...new Set([...(prev.history ?? []), ...gitHashes])];
				record = merged.length === (prev.history ?? []).length ? prev : { ...prev, history: merged };
			}
			if (vibeVersion && record.vibeVersion !== vibeVersion) {
				record = { ...record, vibeVersion };
				restamped.push(rel);
			}
			next[rel] = record; // не изменился — ревизия та же
		} else {
			const inherited = [...new Set([...(prev.history ?? []), prev.sha256, ...gitHashes])];
			// Содержимое поехало → новая ревизия, прошлая sha уходит в историю: по ней
			// продукты узнают нетронутую копию прошлого релиза в чужом проекте.
			next[rel] = { version: prev.version + 1, sha256: hash, history: inherited };
			if (vibeVersion) { next[rel].vibeVersion = vibeVersion; }
			bumped.push(rel);
		}
	}

	const dropped = Object.keys(previous).filter(p => !(p in next));
	const stale = check && (bumped.length > 0 || added.length > 0 || dropped.length > 0
		|| restamped.length > 0 || notRaised.length > 0);
	if (check) {
		if (stale) {
			console.error('[bump] versions.json устарел:');
			for (const p of added) { console.error(`  + новый файл без записи: ${p}`); }
			for (const p of bumped) { console.error(`  ~ изменён без бампа ревизии: ${p}`); }
			for (const p of restamped) { console.error(`  ~ не записана версия в реестре: ${p}`); }
			for (const p of dropped) { console.error(`  - удалён, но остался в реестре (перенести в deprecated.json): ${p}`); }
			if (notRaised.length > 0) {
				console.error('[bump] версия не поднята при изменённом содержимом:');
				for (const p of notRaised) { console.error(`  ! ${p}: поднимите vibeVersion или запустите node bump.mjs`); }
			}
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

	const registry = { version: 1, comment: 'Ревизии файлов набора. Генерируется bump.mjs — руками не править. history хранит sha256 прошлых ревизий: по ним сеялка узнаёт нетронутую копию старого релиза. vibeVersion — версия правила или навыка из шапки.', files: next };
	await fs.writeFile(REGISTRY, `${JSON.stringify(registry, null, 2)}\n`, 'utf8');
	console.log(`[bump] записано ${files.length} файлов; новых ${added.length}, поднято ревизий ${bumped.length}`);
	for (const p of bumped) { console.log(`  ~ ${p} → v${next[p].version}`); }
	for (const line of autoBumped) { console.log(`[bump] версия поднята автоматически: ${line}`); }
}

main();
