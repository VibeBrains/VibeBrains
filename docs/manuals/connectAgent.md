# Подключить набор к своему агенту

Набор VibeBrains — это готовые навыки и правила для агента
Навык даёт агенту процедуру под задачу, правило задаёт постоянные рамки работы
Подключение — два независимых шага: положить навыки туда, где агент их ищет, и включить правила в его файле инструкций

## Что в наборе

| Что | Где лежит | Что даёт |
|---|---|---|
| Навыки | `skills/<имя>/SKILL.md` | Процедура под задачу: когда применять и как действовать |
| Правила | `rules/<id>.mdc` | Постоянные рамки: стиль, проверки, запреты, порядок работы |

Навыки соответствуют стандарту Agent Skills: папка с `SKILL.md`, поля `name` и `description` в шапке
Проверить свой навык можно валидатором `skills-ref validate ./skill` из спецификации
Правила написаны в формате Cursor: шапка `description`, `globs`, `alwaysApply` и текст правила
Навыки и правила независимы: можно подключить только навыки, только правила или оба

## Навыки: куда класть

Кладите папку навыка целиком, вместе с `SKILL.md` и вспомогательными файлами
Общий путь `.agents/skills/` в проекте и `~/.agents/skills/` глобально читают большинство агентов
Если агент есть в таблице ниже — используйте его пути; для остальных берите общий путь

| Агент | В проекте | Глобально |
|---|---|---|
| Claude Code | `.claude/skills/` | `~/.claude/skills/` |
| Codex CLI | `.agents/skills` | `~/.agents/skills` |
| Cursor | `.cursor/skills/`, `.agents/skills/` | `~/.cursor/skills/`, `~/.agents/skills/`; читает также `~/.claude/skills`, `~/.codex/skills` |
| Antigravity CLI | `.agents/skills/` | `~/.gemini/antigravity-cli/skills/` |
| Старый Gemini CLI | — | `~/.gemini/skills/` или `~/.agents/skills/` |
| Kimi Code | `.agents/skills/`, `.kimi/skills/`, `.claude/skills/` | `~/.config/agents/skills/` (рекомендуется), `~/.agents/skills/`, `~/.kimi/skills/`; читает также `~/.claude/skills`, `~/.codex/skills` |
| GitHub Copilot (VS Code) | `.github/skills/`, `.claude/skills/`, `.agents/skills/` | `~/.copilot/skills/`, `~/.claude/skills/`, `~/.agents/skills/` |
| Windsurf (Devin Desktop) | `.devin/skills/`, `.windsurf/skills/`, `.agents/skills/` | `~/.codeium/windsurf/skills/` или `~/.config/devin/skills/`, `~/.agents/skills/` |
| DeepSeek Harness | не проверено | не проверено |
| VibeIDE и VibeIDEA | `.vibe/skills/` | набор сеется при открытии проекта |

Antigravity CLI заменил Gemini CLI 18.06.2026; у старого Gemini CLI пути навыков и правил отличаются
У GitHub Copilot невалидный `name` — навык молча не загрузится, поэтому `bump.mjs` проверяет шапки навыков

## Правила: как включить

Правила лежат в `rules/<id>.mdc`; каждый файл отвечает за одну зону ответственности
Агент читает правила из своих файлов инструкций — таблица ниже показывает, куда их положить
Для агентов без `.mdc` соберите правила в один markdown переходником из следующего раздела

| Агент | Где включает правила |
|---|---|
| Claude Code | Глобально `~/.claude/CLAUDE.md`, `~/.claude/rules/`; проект `CLAUDE.md`, `.claude/rules/` (шапка paths); `AGENTS.md` — только если нет `CLAUDE.md`; `.mdc` — не проверено |
| Codex CLI | Глобально `~/.codex/AGENTS.md` (или `AGENTS.override.md`); проект `AGENTS.md` (лимит 32 КиБ); `.mdc` — не проверено |
| Cursor | Глобально User Rules в настройках; проект `.cursor/rules/*.mdc` (только `.mdc`, шапка description/globs/alwaysApply) и `AGENTS.md` |
| Antigravity CLI | Глобально `~/.gemini/AGENTS.md` или `GEMINI.md`, `~/.gemini/config/rules/*.md`; проект `AGENTS.md`, `GEMINI.md`, `.agents/rules/*.md`; `.mdc` нет — у `rules/*.md` своя шапка trigger (always_on, model_decision, glob, manual), description, globs; без шапки файл отбрасывается |
| Старый Gemini CLI | `GEMINI.md` |
| Kimi Code | Проект `AGENTS.md` и `.kimi/AGENTS.md`; глобальный — не проверено; `.mdc` — не проверено |
| GitHub Copilot (VS Code) | Глобально `~/.copilot/copilot-instructions.md`; проект `.github/copilot-instructions.md`, `.github/instructions/*.instructions.md` (шапка applyTo), `AGENTS.md`, `CLAUDE.md`; `.mdc` нет |
| Windsurf (Devin Desktop) | Глобально `~/.codeium/windsurf/memories/global_rules.md`; проект `.devin/rules/*.md` или `.windsurf/rules/*.md` (шапка trigger, description, globs), `AGENTS.md`; `.mdc` нет |
| DeepSeek Harness | не проверено |
| VibeIDE и VibeIDEA | `.vibe/rules/*.mdc` — читают сами, набор сеется при открытии проекта |

Cursor принимает в `.cursor/rules/` только `.mdc`; наши файлы подходят как есть
Antigravity и Windsurf читают `.md` со своей шапкой; без неё файл отбрасывается

## Собрать правила в один файл

`tools/rulesToAgentsMd.mjs` — переходник для агентов, которые не читают `.mdc`
Он срезает шапку правила и добавляет перед каждым правилом заголовок `## <id>` и строку `description`

```
node tools/rulesToAgentsMd.mjs --out AGENTS.md
```

Без аргументов в файл попадут только правила с `alwaysApply: true` — тот же набор, что агент применяет постоянно
Все правила:

```
node tools/rulesToAgentsMd.mjs --all --out AGENTS.md
```

Выбранные правила:

```
node tools/rulesToAgentsMd.mjs brigadier verification --out AGENTS.md
```

Вывод без `--out` идёт в stdout — удобно вставить в `CLAUDE.md`, `GEMINI.md` или `copilot-instructions.md`
Для Antigravity и Windsurf добавьте к файлу их шапку `trigger`, иначе файл в `.agents/rules/` или `.devin/rules/` будет отброшен

## Источники

- Спецификация Agent Skills — https://agentskills.io/specification
- Claude Code, навыки — https://code.claude.com/docs/en/skills
- Claude Code, память и правила — https://code.claude.com/docs/en/memory
- Codex CLI, навыки — https://learn.chatgpt.com/docs/build-skills
- Codex CLI, AGENTS.md — https://learn.chatgpt.com/docs/agent-configuration/agents-md
- Cursor, навыки — https://cursor.com/docs/context/skills
- Cursor, правила — https://cursor.com/docs/context/rules
- Antigravity, навыки — https://antigravity.google/docs/skills
- Antigravity, правила — https://antigravity.google/docs/rules
- Старый Gemini CLI, навыки — https://geminicli.com/docs/cli/skills/
- Kimi Code, навыки — https://moonshotai.github.io/kimi-cli/en/customization/skills.html
- Kimi Code, AGENTS.md — https://moonshotai.github.io/kimi-cli/en/customization/agents.html
- GitHub Copilot, навыки — https://code.visualstudio.com/docs/copilot/customization/agent-skills
- GitHub Copilot, инструкции — https://code.visualstudio.com/docs/copilot/customization/custom-instructions
- Windsurf, навыки — https://docs.devin.ai/desktop/cascade/skills
- Windsurf, правила — https://docs.devin.ai/desktop/cascade/memories
- DeepSeek Harness — публичной документации нет, не проверено

Пути и правила сверены с документацией вендоров 29.10.2026
