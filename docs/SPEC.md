# VSCode Switcher — техническое задание

Нативное macOS-приложение (menu bar agent, без иконки в доке): всплывающая панель у левого
края экрана со списком открытых окон VSCode, их цветами, состоянием Claude-агентов в каждом
окне и списком неоткрытых проектов, которые можно открыть прямо из панели.

## 1. Пользовательский сценарий

1. Пользователь прижимает курсор к левому краю экрана и удерживает ~150 мс.
2. Слева выезжает панель со списком.
3. В списке видно: цвет окна, имя проекта, тему активного чата Claude, состояние агента
   (крутится / ждёт реакции / ждёт разрешения), число фоновых сабагентов, занятый контекст,
   модель.
4. Ниже — секция неоткрытых проектов из папки проектов.
5. Выбор строки: открытое окно → фокус на него; неоткрытый проект → открывается новое окно
   VSCode на его `.code-workspace` (или на папке, если воркспейс-файла нет).
6. Панель закрывается по Esc, клику вне, выбору или уходу курсора вправо.

## 2. Источники данных (проверены эмпирически на машине пользователя)

### 2.1 Окна VSCode — Accessibility API

- Приложение: bundle id `com.microsoft.VSCode`.
- `AXUIElementCreateApplication(pid)` → `kAXWindowsAttribute`.
- Фильтровать по `AXSubrole == AXStandardWindow` (отсекает диалоги).
- Порядок массива соответствует z-order: первое окно — самое переднее. Использовать как
  MRU-порядок в списке.
- Заголовок окна (`kAXTitleAttribute`) имеет вид:
  `<тема активного чата, обрезанная многоточием> — <rootName> (Workspace)`
  Разделитель — em dash `—` (U+2014), окружённый пробелами. Реальные примеры:
  - `Критические баги и оптим… — arcextension (Workspace)`
  - `остановись пока — glazy_solver (Workspace)`
  Если проект открыт как папка, а не как workspace, суффикс ` (Workspace)` отсутствует.
- Разбор: взять хвост после **последнего** ` — `, отрезать ` (Workspace)` → `rootName`.
- Фокус окна: `NSRunningApplication.activate()`, затем на AX-элементе окна снять
  `kAXMinimizedAttribute` (если свёрнуто) и выполнить `kAXRaiseAction`. macOS сам переключит
  Space, если окно на другом рабочем столе.
- Требуется разрешение Accessibility. Проверять `AXIsProcessTrustedWithOptions`.

### 2.2 Проекты и цвета

- Корни сканирования (конфиг, по умолчанию `~/Data/Projects`), глубина вложенности 2 —
  у пользователя есть подпапка `wirenboard/` с проектами внутри.
- Папка считается проектом, если содержит `*.code-workspace` или `.git`.
- `rootName` проекта = имя `.code-workspace` без расширения, иначе имя папки.
- Цвет ищется по цепочке:
  1. `<project>/*.code-workspace` → `settings["peacock.color"]`
  2. то же → `settings["workbench.colorCustomizations"]["titleBar.activeBackground"]`
  3. `<project>/.vscode/settings.json` → те же два ключа
  4. фолбэк — детерминированный цвет из хеша имени проекта
- **Важно:** `.code-workspace` и `settings.json` — это JSONC: допускаются комментарии `//`,
  `/* */` и висячие запятые. Нужен толерантный парсер (стриппер комментариев перед
  `JSONSerialization`).
- Реальные значения на машине: `home-network #1857a4`, `arcextension #d3a8e2`,
  `gitmost #d3ba41`, `research-mcp #58c045`, `glazy_solver #44a077`,
  `ukuetis_panel_fw #3ac976`, `ukuetis_controller_backend #64171d`, `wb-mge #a43683`.

### 2.3 Живые сессии Claude Code

`~/.claude/sessions/<pid>.json`, пример реального содержимого:

```json
{
  "pid": 37769,
  "sessionId": "d0ca6dae-8784-4a0b-a87a-6a7231152bfe",
  "cwd": "/Users/vvzvlad/Data/Projects/home-network",
  "startedAt": 1786402401054,
  "version": "2.1.226",
  "kind": "interactive",
  "entrypoint": "claude-vscode",
  "messagingSocketPath": "/tmp/cc-socks/37769.sock",
  "name": "home-network-ea",
  "nameSource": "derived"
}
```

- Живой считается сессия, чей `pid` существует (`kill(pid, 0)`), а `entrypoint` начинается
  с `claude-vscode`. Мёртвые файлы остаются на диске — их надо отфильтровывать.
- Группировка по `cwd` → проект. У пользователя сейчас 19 живых сессий на 8 окон.

### 2.4 Транскрипт сессии

Путь: `~/.claude/projects/<slug>/<sessionId>.jsonl`, где `slug` — это `cwd` с заменой всех
`/` на `-` (например `/Users/vvzvlad/Data/Projects/home-network` →
`-Users-vvzvlad-Data-Projects-home-network`).

**Файлы достигают 24 МБ.** Читать только хвост (последние ~256–512 КБ) через
`FileHandle.seek(toOffset:)`, отбрасывая первую (возможно обрезанную) строку.

Типы записей, которые нужны:

| `type` | Что берём |
|---|---|
| `ai-title` | `aiTitle` — полная тема чата (в заголовке окна она обрезана) |
| `last-prompt` | `lastPrompt` — фолбэк темы, если `ai-title` ещё не сгенерирован |
| `assistant` | `message.model`, `message.usage`, `message.stop_reason` |

- **Модель**: `message.model` последней assistant-записи, у которой модель ≠ `<synthetic>`.
  Реальное значение: `claude-opus-5`.
- **Занятый контекст**: у той же записи
  `usage.input_tokens + usage.cache_read_input_tokens + usage.cache_creation_input_tokens`.
  Реальный пример: `2 + 456901 + 3593 ≈ 460k`.
  Лимит окна определять по модели; учесть, что бывают варианты с 1M контекста — если
  посчитанное значение превышает 200k, считать лимитом 1M.
- **Фолбэк-состояние** (когда нет данных от хуков): последняя assistant-запись,
  `stop_reason == "end_turn"` / `"stop_sequence"` → агент закончил и ждёт пользователя;
  `stop_reason == "tool_use"` → агент работает.
  Учитывать, что запись в jsonl отстаёт от реального времени на десятки секунд, поэтому это
  именно фолбэк, а не основной источник.

### 2.5 Фоновые сабагенты

Каталог `~/.claude/projects/<slug>/<sessionId>/subagents/`:

- `agent-<id>.jsonl` — транскрипт сабагента,
- `agent-<id>.meta.json` — метаданные, реальный пример:
  ```json
  {
    "agentType": "general-purpose",
    "description": "Round 6 residual gate fixes",
    "toolUseId": "toolu_01RVvsbZzZv4EX4cEu7VAN9c",
    "spawnDepth": 1
  }
  ```

Сабагент считается активным, если `mtime` его `.jsonl` моложе порога (по умолчанию 90 с)
и последняя запись не является финальным ответом. Показывать число активных сабагентов и
их `description` в подсказке.

### 2.6 Хуки Claude Code — основной источник состояния

`statusLine` у пользователя **не настроен** — его можно занять. `hooks` содержит два блока
`SessionStart`, которые нельзя затирать.

Ставим свои хуки, все `"async": true`, чтобы не блокировать агента:

- `UserPromptSubmit` → состояние `working`
- `Stop` → состояние `waiting` (агент ответил, ждёт реакции)
- `Notification` → `permission` либо `waiting` в зависимости от payload
- `SessionEnd` → удалить файл состояния

Хук пишет атомарно (`tmp` + `rename`) файл `~/.claude/window-status/<session_id>.json`:

```json
{
  "sessionId": "...",
  "cwd": "/Users/vvzvlad/Data/Projects/home-network",
  "state": "working|waiting|permission|ended",
  "event": "Stop",
  "ts": 1786402401
}
```

Дополнительно ставим `statusLine`-скрипт: он вызывается на каждое изменение состояния и
получает на stdin JSON с `model.display_name`, `context_window.used_percentage`, `cost` —
это самый свежий и дешёвый источник для контекста и модели. Скрипт печатает строку статуса
в stdout (её видит пользователь в VSCode) и попутно пишет те же данные в файл состояния.

**Схему payload'ов Notification нужно подтвердить эмпирически**, а не по документации:
хук должен уметь дампить сырой stdin в `~/.claude/window-status/_debug.jsonl` при
`VSCODE_SWITCHER_DEBUG=1`, и логика разбора должна быть устойчива к отсутствию полей.

## 3. Состояния агента и их отображение

| Состояние | Когда | Индикатор |
|---|---|---|
| `permission` | Claude ждёт разрешения на инструмент | оранжевая точка, пульсация |
| `waiting` | Claude ответил, ждёт реакции пользователя | зелёная точка |
| `working` | Claude выполняет ход | синяя точка с анимацией |
| `idle` | Сессия жива, но давно ничего не происходило | серая точка |

Приоритет при агрегации по окну: `permission` > `waiting` > `working` > `idle`.
Строка окна показывает бейдж с числом чатов в самом приоритетном состоянии.

## 4. UI

- `NSPanel`: `[.nonactivatingPanel, .borderless]`, `level = .floating`,
  `collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]`,
  `isOpaque = false`, `backgroundColor = .clear`, `hidesOnDeactivate = false`,
  переопределённый `canBecomeKey = true` (иначе не будет работать клавиатура).
- Подложка — `NSVisualEffectView` (`.sidebar` / `.hudWindow`, `blendingMode = .behindWindow`),
  скругление 12 pt по правым углам, тень.
- Содержимое — SwiftUI через `NSHostingView`.
- Анимация выезда слева ~0.14 с, ease-out.
- Строка списка: цветная полоса 4 pt слева (цвет проекта) → имя проекта (bold) →
  под ним тема активного чата (secondary, одна строка с усечением) → справа блок метрик:
  бейдж состояния с числом, число фоновых агентов, процент контекста, короткое имя модели.
- Секции: «Открытые окна» (в z-order) и «Проекты» (неоткрытые, по mtime, лимит ~30,
  поиск ищет по всем).
- Поле поиска сверху, фильтрация по имени проекта и теме чата.
- Клавиши: ↑/↓ — навигация, Enter — выбор, Esc — закрыть, Cmd+1…9 — быстрый выбор.
- Светлая и тёмная темы — системные, цвета не хардкодить.

## 5. Триггер левого края

- Таймер 30–60 Гц читает `NSEvent.mouseLocation` — это **не требует** разрешений
  (в отличие от глобального event tap).
- Экран определяется тот, на котором сейчас курсор (поддержка нескольких мониторов).
- Условие срабатывания: `x <= screen.frame.minX + 1.0`, удерживаемое `dwell` мс
  (по умолчанию 150, настраивается).
- Анти-дребезг: после закрытия панели не показывать её снова, пока курсор не отойдёт от
  края минимум на 100 pt.
- Автоскрытие: курсор ушёл правее правой границы панели + 60 pt и продержался там > 400 мс.
- У пользователя Dock расположен справа с автоскрытием, поэтому левый край свободен.

## 6. Производительность

- Всё чтение с диска — в фоновой очереди, UI обновляется только на главном потоке.
- Фоновое обновление модели: раз в 2 с в покое, раз в 1 с пока панель видна.
- Дополнительно `DispatchSource` на каталоги `~/.claude/window-status` и `~/.claude/sessions`.
- При показе панели немедленно рисуется кэш, обновление приходит следом.
- Индекс проектов кэшируется, инвалидация по mtime каталогов.
- Никогда не читать транскрипты целиком — только хвост.

## 7. Структура проекта

```
vscode-switcher/
├── Makefile                      # build / app / install / clean
├── README.md
├── docs/SPEC.md                  # этот файл
├── macos/
│   ├── Package.swift             # SPM, executableTarget, macOS 14
│   ├── Resources/Info.plist      # LSUIElement=true, bundle id xyz.vvzvlad.vscode-switcher
│   ├── scripts/build.sh          # сборка .app-бандла
│   └── Sources/VSCodeSwitcher/
│       ├── main.swift
│       ├── AppDelegate.swift     # жизненный цикл, menu bar, разрешения
│       ├── Config.swift          # настройки + чтение/запись конфига
│       ├── Model.swift           # типы строк списка и состояний
│       ├── EdgeTrigger.swift     # детект курсора у левого края
│       ├── VSCodeWindows.swift   # AX: перечисление и фокус окон
│       ├── WorkspaceIndex.swift  # скан проектов, цвета, JSONC-парсер
│       ├── ClaudeSessions.swift  # сессии, статусы, транскрипты, сабагенты
│       ├── DataSource.swift      # агрегация и фоновое обновление
│       ├── PanelController.swift # NSPanel
│       └── SwitcherView.swift    # SwiftUI
├── hooks/claude-window-status.sh # хук состояния
├── hooks/statusline.sh           # statusLine: контекст, модель
└── scripts/install-hooks.sh      # идемпотентная установка хуков через jq + бэкап
```

## 8. Ограничения, которые нужно задокументировать

- Если два окна VSCode открыты на один и тот же проект, сессии Claude распределяются между
  ними эвристически: активный чат окна определяется сравнением префикса заголовка окна
  (до многоточия) с `ai-title` сессий; остальные сессии проекта приписываются первому окну.
- Заголовок окна обрезается самим VSCode, поэтому полная тема чата берётся из `ai-title`.
- Состояние из транскрипта отстаёт от реального; актуальность обеспечивают хуки.
