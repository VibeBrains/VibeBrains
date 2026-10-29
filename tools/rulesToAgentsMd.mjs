#!/usr/bin/env node
/**
 * Собирает правила набора в один markdown для агентов, которые не читают .mdc.
 *
 * Запуск: node tools/rulesToAgentsMd.mjs [--all | <id> ...] [--out AGENTS.md]
 * Без аргументов — только правила с alwaysApply: true, --all — все, <id> — выбранные
 * Вывод — в stdout или в файл из --out
 */

import { promises as fs } from 'fs';
import path from 'path';
import { fileURLToPath } from 'url';

const ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const RULES = path.join(ROOT, 'rules');

// Чтение через `| head` закрывает поток раньше — это не ошибка
process.stdout.on('error', (error) => {
	if (error.code === 'EPIPE') { process.exit(0); }
	throw error;
});

/** Поля шапки: key → значение; кавычки сняты, блок `>` или `|` собран до следующего ключа. */
function parseHeader(lines) {
	const fields = new Map();
	for (let i = 0; i < lines.length; i++) {
		const kv = /^([A-Za-z][\w-]*):\s*(.*)$/.exec(lines[i]);
		if (!kv) { continue; }
		const [, key, raw] = kv;
		if (/^[>|][+-]?\d?\s*$/.test(raw)) {
			const block = [];
			for (let j = i + 1; j < lines.length && !/^[A-Za-z][\w-]*:\s*/.test(lines[j]); j++) {
				block.push(lines[j].trim());
			}
			fields.set(key, block.filter(Boolean).join(' '));
			continue;
		}
		let value = raw.trim();
		if (value.length > 1 && (value[0] === '"' || value[0] === "'") && value.endsWith(value[0])) {
			value = value.slice(1, -1);
		}
		fields.set(key, value);
	}
	return fields;
}

/** Файл правила: id, поля шапки, тело без шапки. */
async function readRule(id) {
	const file = path.join(RULES, `${id}.mdc`);
	const text = await fs.readFile(file, 'utf8');
	const end = text.startsWith('---') ? text.indexOf('\n---', 3) : -1;
	const header = end < 0 ? [] : text.slice(3, end).split(/\r?\n/);
	const body = (end < 0 ? text : text.slice(end + 4)).replace(/^\s*\n/, '').trimEnd();
	return { id, fields: parseHeader(header), body };
}

function fail(message) {
	console.error(`[rules] ${message}`);
	process.exit(1);
}

async function main() {
	const argv = process.argv.slice(2);
	let all = false;
	let out = null;
	const ids = [];
	for (let i = 0; i < argv.length; i++) {
		const arg = argv[i];
		if (arg === '--all') { all = true; continue; }
		if (arg === '--out') {
			out = argv[++i];
			if (!out) { fail('после --out нужен путь к файлу'); }
			continue;
		}
		if (arg.startsWith('--out=')) { out = arg.slice('--out='.length); continue; }
		if (arg === '--help' || arg === '-h') {
			console.log('Собирает правила в один markdown для агентов без .mdc');
			console.log('Запуск: node tools/rulesToAgentsMd.mjs [--all | <id> ...] [--out AGENTS.md]');
			console.log('Без аргументов — только правила с alwaysApply: true');
			return;
		}
		if (arg.startsWith('-')) { fail(`неизвестный флаг ${arg}`); }
		ids.push(arg.endsWith('.mdc') ? arg.slice(0, -4) : arg);
	}
	if (all && ids.length > 0) { fail('--all не сочетается со списком id'); }

	const files = (await fs.readdir(RULES)).filter((f) => f.endsWith('.mdc')).sort();
	const rules = await Promise.all(files.map((f) => readRule(f.slice(0, -4))));
	let selected;
	if (all) {
		selected = rules;
	} else if (ids.length > 0) {
		const known = new Set(rules.map((r) => r.id));
		for (const id of ids) {
			if (!known.has(id)) { fail(`правило не найдено: rules/${id}.mdc`); }
		}
		selected = ids.map((id) => rules.find((r) => r.id === id));
	} else {
		selected = rules.filter((r) => r.fields.get('alwaysApply') === 'true');
	}

	const chunks = selected.map((rule) => {
		const description = rule.fields.get('description') ?? '';
		const lines = [`## ${rule.id}`];
		if (description) { lines.push('', description); }
		if (rule.body) { lines.push('', rule.body); }
		return lines.join('\n').trimEnd();
	});
	const text = chunks.length > 0 ? `${chunks.join('\n\n')}\n` : '';

	if (out) {
		const target = path.resolve(process.cwd(), out);
		await fs.mkdir(path.dirname(target), { recursive: true });
		await fs.writeFile(target, text, 'utf8');
		console.log(`[rules] записано правил: ${selected.length} → ${out}`);
	} else {
		process.stdout.write(text);
	}
}

main().catch((error) => fail(error.message));
