/**
 * Пути в аргументах команды, которые лежат вне проекта
 *
 * Порт `commandPathsOutsideScope.ts` из VibeIDE: поведение один в один, только без TypeScript
 * WHY: проверки записи смотрели на путь инструмента правки, а у команды пути нет —
 * только строка, и абсолютный путь в аргументе (`--save /Volumes`) никто не читал
 *
 * Разбор намеренно грубый: аргументы любой программы, включая значение опции (`--opt=/path`, `-o/path`)
 * Что программа делает с путём, решает вызывающий: здесь только «путь вне проекта»
 *
 * Чистая: без файловой системы, окружения и платформы
 */

/** Каталоги, которые не являются данными: ссылка на них не выводит команду из проекта */
const NON_PATHS = new Set(['/dev/null', '/dev/stdout', '/dev/stderr']);

/** Системные каталоги: потеря самого каталога необратима, а вложенные пути — уже нет */
const SYSTEM_ROOTS = ['System', 'usr', 'etc', 'bin', 'var', 'Library', 'private'];

/** Временные каталоги, потеря содержимого которых потерей не считается */
export const TEMP_ROOTS = ['/tmp', '/private/tmp', '/var/tmp', '/private/var/tmp', '/var/folders', '/private/var/folders'];

/** Временные каталоги Windows: `C:\Users\<имя>\AppData\Local\Temp`, `C:\Windows\Temp` — путь уже с прямыми слэшами */
export const WINDOWS_TEMP = /^[a-z]:\/(?:users\/[^/]+\/appdata\/local|windows)\/temp\/(.*)$/i;

/**
 * Строка как её группирует оболочка: цепочки (`;`, `&&`, `||`, `&`, перевод строки),
 * в цепочке этапы конвейера (`|`, `|&`), в этапе слова
 *
 * Глубина намеренная: разделители, кавычки, обратная косая черта и `$( … )` / `<( … )` /
 * обратные кавычки целиком как одно слово, больше ничего
 * `2>&1` и `&>file` — перенаправления, а не разделители
 * `#` здесь НЕ комментарий: в cmd.exe его нет, и `echo # & format D:` там выполнит format
 */
export function parseShellLine(line) {
	const chains = [];
	let stages = [];
	let words = [];
	let word = '';
	let quote;
	let backtick = false;
	let nesting = 0;

	const endWord = () => { if (word) { words.push(word); word = ''; } };
	const endStage = () => { endWord(); if (words.length > 0) { stages.push(words); } words = []; };
	const endChain = () => { endStage(); if (stages.length > 0) { chains.push(stages); } stages = []; };

	for (let i = 0; i < line.length; i++) {
		const ch = line[i];
		const next = line[i + 1];
		if (nesting > 0) {
			// Внутри `$( … )` текст сохраняется дословно: это отдельная строка, её судят потом
			// Кавычки только мешают скобкам внутри них считаться
			word += ch;
			if (ch === '\\' && next !== undefined) {
				word += next;
				i++;
			} else if (quote) {
				if (ch === quote) { quote = undefined; }
			} else if (ch === '"' || ch === '\'') {
				quote = ch;
			} else if (ch === '(') {
				nesting++;
			} else if (ch === ')') {
				nesting--;
			}
		} else if (quote) {
			if (ch === quote) { quote = undefined; } else { word += ch; }
		} else if (ch === '`') {
			backtick = !backtick;
			word += ch;
		} else if (backtick) {
			word += ch;
		} else if (ch === '"' || ch === '\'') {
			quote = ch;
		} else if (ch === '\\' && next !== undefined) {
			word += next;
			i++;
		} else if ((ch === '$' || ch === '<' || ch === '>') && next === '(') {
			nesting = 1;
			word += ch + next;
			i++;
		} else if (ch === '|' && next === '|') {
			endChain();
			i++;
		} else if (ch === '|') {
			// `|&` ведёт stderr вместе с stdout: конвейер всё равно один
			endStage();
			if (next === '&') { i++; }
		} else if (ch === '&' && next === '&') {
			endChain();
			i++;
		} else if (ch === '&' && (next === '>' || word.endsWith('>') || word.endsWith('<'))) {
			// `2>&1`, `&>file`: перенаправление, а не разделитель
			word += ch;
		} else if (ch === ';' || ch === '\n' || ch === '\r' || ch === '&') {
			endChain();
		} else if (ch === ' ' || ch === '\t') {
			endWord();
		} else {
			word += ch;
		}
	}
	endChain();
	return chains;
}

/** Простые команды строки по порядку, без группировки — см. `parseShellLine` */
export function splitShellSegments(line) {
	return parseShellLine(line).flat().map(words => ({ command: words[0], args: words.slice(1) }));
}

/**
 * Найти пути вне области, в порядке появления в команде
 *
 * `roots` — то, что считается своим; временные каталоги свои по определению
 * `caseInsensitive` учитывает, что macOS сравнивает имена без регистра
 */
export function commandPathsOutsideScope(command, scope) {
	const outside = [];
	const seen = new Set();
	for (const segment of splitShellSegments(slashedWindowsPaths(command))) {
		const readOnly = isReadOnlySegment(segment.command, segment.args);
		for (const arg of segment.args) {
			const value = pathValueOf(arg);
			if (value === undefined) {
				continue;
			}
			const found = classify(value, scope);
			if (found === undefined || seen.has(found.key)) {
				continue;
			}
			seen.add(found.key);
			outside.push({ path: value, critical: found.critical, readOnly });
		}
	}
	return outside;
}

/** `C:\Users` и `\\server\share` — разделители Windows, а разбор строки считает `\` экранированием */
const WINDOWS_PATH_TOKEN = /(^|[\s=])((?:[A-Za-z]:|\\\\[^\\\s]+)[^\s]*)/g;

function slashedWindowsPaths(command) {
	return command.replace(WINDOWS_PATH_TOKEN, (match, lead, token) => {
		// Корень диска `D:\` разбор и так сохраняет: экранировать в нём нечего
		return /^[A-Za-z]:\\$/.test(token) ? match : `${lead}${token.replace(/\\/g, '/')}`;
	});
}

/**
 * Программы, которые только читают и ничего не пишут: внешний путь у них ничего не потеряет
 *
 * Не входят программы, которые пишут ключом или своим языком: `sed -i`, `awk`, `sort -o`, `tee`
 */
const READ_ONLY_PROGRAMS = new Set([
	'cat', 'head', 'tail', 'less', 'more', 'grep', 'egrep', 'fgrep', 'rg', 'wc', 'diff', 'cmp',
	'ls', 'stat', 'file', 'readlink', 'realpath', 'bat', 'fd', 'du', 'df', 'tree', 'nl', 'od',
	'hexdump', 'xxd', 'strings', 'zcat', 'bzcat', 'xzcat', 'tac', 'rev', 'cut', 'uniq', 'find',
	'echo', 'printf', 'test', 'which', 'pwd',
]);

/** Ключи `find`, с которыми он удаляет, запускает или пишет */
const FIND_WRITE_ACTIONS = /^-(?:delete|exec|execdir|ok|okdir|fprint|fprint0|fprintf|fls)$/;

/** Перенаправление вывода: `>`, `>>`, `2>`, `&>` — запись в файл */
const OUTPUT_REDIRECT = /^(?:\d*|&)>{1,2}/;

/** Сегмент только читает: программа из списка, без записи ключом и без перенаправления вывода */
function isReadOnlySegment(command, args) {
	if (!READ_ONLY_PROGRAMS.has(programName(command))) {
		return false;
	}
	if (args.some(arg => OUTPUT_REDIRECT.test(arg))) {
		return false;
	}
	return programName(command) !== 'find' || !args.some(arg => FIND_WRITE_ACTIONS.test(arg));
}

/** Имя программы без пути и расширения Windows */
function programName(command) {
	const base = command.replace(/\\/g, '/').split('/').pop() ?? command;
	return base.replace(/\.(?:exe|com)$/i, '').toLowerCase();
}

/** Значение аргумента, если оно похоже на путь: сама опция путём не считается */
function pathValueOf(arg) {
	if (arg.includes('://')) {
		return undefined;
	}
	if (arg.startsWith('--')) {
		const equals = arg.indexOf('=');
		return equals < 0 ? undefined : asPath(arg.slice(equals + 1));
	}
	if (arg.startsWith('-')) {
		// `-o/path`, `-I/usr/include`: значение приклеено к короткой опции
		const starts = ['/', '~', '$'].map(marker => arg.indexOf(marker, 1)).filter(index => index > 0);
		return starts.length === 0 ? undefined : asPath(arg.slice(Math.min(...starts)));
	}
	const redirect = OUTPUT_REDIRECT.exec(arg);
	if (redirect !== null) {
		// `2>/path`, `>/path`: цель перенаправления приклеена к оператору
		return asPath(arg.slice(redirect[0].length));
	}
	const equals = arg.indexOf('=');
	// `NAME=/path`: присвоение переменной перед программой или значение без пробела
	return asPath(equals < 0 ? arg : arg.slice(equals + 1));
}

/** Путь-кандидат без разбора его вида; URL и служебные устройства отбрасываются */
function asPath(value) {
	if (!value || value.includes('://') || NON_PATHS.has(value)) {
		return undefined;
	}
	return isPathCandidate(value) ? value : undefined;
}

/** Абсолютный путь, домашний каталог или выход вверх — остальное аргумент, а не путь */
function isPathCandidate(value) {
	// Обратная косая — разделитель только в пути Windows; в остальном это экранирование
	// в шаблоне или тексте (`grep "\.venv"`, `printf '\n'`), а не путь от корня
	const slashed = isWindowsShaped(value) ? slashedPath(value) : value;
	return slashed.startsWith('/')
		|| /^[A-Za-z]:\//.test(slashed)
		|| /^\/\/[^/]+\/[^/]+/.test(slashed)
		|| slashed === '..' || slashed.startsWith('../')
		|| isHomePath(slashed);
}

/** Путь Windows: буква диска или общий каталог `\\server` */
function isWindowsShaped(value) {
	return /^(?:[A-Za-z]:[\\/]|\\\\)/.test(value);
}

/** `~`, `$HOME` и их продолжения: без раскрытия они всегда вне проекта */
function isHomePath(value) {
	return value === '~' || value.startsWith('~/')
		|| value === '$HOME' || value.startsWith('$HOME/')
		|| value === '${HOME}' || value.startsWith('${HOME}/');
}

/** Сама домашняя папка, а не путь внутри неё */
function isHomeRoot(value) {
	return /^(?:~|\$HOME|\$\{HOME\})\/?$/.test(value);
}

/** `~/x` и `$HOME/x` в абсолютный путь от известной домашней папки */
function expandHome(value, home) {
	return slashedPath(home).replace(/\/+$/, '') + value.replace(/^(?:~|\$HOME|\$\{HOME\})/, '');
}

/** Решение по одному пути: свой, внешний некритичный или критичный */
function classify(value, scope) {
	const slashed = slashedPath(value);
	if (isHomePath(slashed)) {
		// Без известной домашней папки путь не раскрыть: корнем считается только она сама,
		// а вложенный путь — внешний, но не корень
		if (scope.home === undefined) {
			return { key: `home:${fold(slashed, scope.caseInsensitive)}`, critical: isHomeRoot(slashed) };
		}
		// Раскрытый путь судится как любой абсолютный: свои каталоги в домашней папке разрешаются,
		// а корнем остаётся сама папка по правилам `/Users/<имя>` и `/home/<имя>`
		return classify(expandHome(slashed, scope.home), { ...scope, home: undefined });
	}
	if (slashed === '..' || slashed.startsWith('../')) {
		// Относительный путь читается от неизвестного каталога строки, поэтому он всегда внешний
		return { key: `up:${fold(normalizePath(slashed), scope.caseInsensitive)}`, critical: false };
	}
	const normalized = normalizePath(slashed);
	if (isInsideAny(normalized, scope.roots, scope.caseInsensitive) || isTemp(normalized, scope.caseInsensitive)) {
		return undefined;
	}
	return { key: `path:${fold(normalized, scope.caseInsensitive)}`, critical: isCritical(normalized, scope.caseInsensitive) };
}

/** Путь лежит в одном из корней: сам корень и всё под ним */
function isInsideAny(path, roots, caseInsensitive) {
	const folded = fold(path, caseInsensitive);
	return roots.some(root => {
		const foldedRoot = fold(normalizePath(slashedPath(root)), caseInsensitive);
		return foldedRoot === '/' ? folded.startsWith('/') : folded === foldedRoot || folded.startsWith(`${foldedRoot}/`);
	});
}

/** Временный каталог — не потеря: там промежуточные файлы, а не работа пользователя */
function isTemp(path, caseInsensitive) {
	const folded = fold(path, caseInsensitive);
	if (TEMP_ROOTS.some(root => folded === fold(root, caseInsensitive) || folded.startsWith(`${fold(root, caseInsensitive)}/`))) {
		return true;
	}
	return WINDOWS_TEMP.test(`${folded}/`);
}

/** Корень диска, тома, домашней папки или системного каталога */
function isCritical(path, caseInsensitive) {
	const folded = fold(path, caseInsensitive);
	const name = (canonical) => fold(canonical, caseInsensitive);
	if (folded === '/') {
		return true;
	}
	if (/^[a-z]:\/$/.test(folded)) {
		return true;
	}
	// Корень общего каталога Windows: `//server/share` без вложенных папок
	if (/^\/\/[^/]+\/[^/]+$/.test(folded)) {
		return true;
	}
	const parts = folded.split('/').filter(part => part.length > 0);
	if (parts[0] === name('Volumes') && parts.length <= 2) {
		return true;
	}
	if (parts[0] === name('Users') && parts.length <= 2) {
		return true;
	}
	if (parts[0] === name('home') && parts.length <= 2) {
		return true;
	}
	if (parts[0] === name('mnt') && parts.length <= 2) {
		return true;
	}
	if (parts[0] === name('media') && parts.length <= 3) {
		return true;
	}
	if (parts.length === 1 && (parts[0] === name('root') || SYSTEM_ROOTS.some(root => parts[0] === name(root)))) {
		return true;
	}
	return false;
}

/**
 * Приведение к одному виду: прямые слэши, без `.`, `..` и повторных слэшей
 *
 * Ведущие `//` сохраняются: это не повтор слэша, а имя общего каталога Windows
 */
function normalizePath(path) {
	const slashed = slashedPath(path);
	const drive = /^([A-Za-z]):(?=\/|$)/.exec(slashed);
	const unc = !drive && slashed.startsWith('//');
	const prefix = drive ? `${drive[1].toLowerCase()}:` : unc ? '//' : slashed.startsWith('/') ? '/' : '';
	const parts = [];
	for (const part of slashed.slice(prefix.length).split('/')) {
		if (part === '' || part === '.') {
			continue;
		}
		if (part === '..') {
			// Выше корня абсолютного пути выйти нельзя; у относительного `..` остаётся как есть
			if (parts.length > 0 && parts[parts.length - 1] !== '..') {
				parts.pop();
			} else if (prefix === '') {
				parts.push(part);
			}
		} else {
			parts.push(part);
		}
	}
	if (prefix === '//') {
		return `//${parts.join('/')}`;
	}
	if (prefix.endsWith(':')) {
		return `${prefix}/${parts.join('/')}`;
	}
	return `/${parts.join('/')}`;
}

function slashedPath(path) {
	return path.replace(/\\/g, '/');
}

function fold(path, caseInsensitive) {
	return caseInsensitive ? path.toLowerCase() : path;
}
