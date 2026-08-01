---
type: feature
created: 2026-08-01
value: V2
complexity: C2
priority: P1
author: Аналитик (deepseek)
assignee:
branch: task/knowledge-extraction-local-file-upload
pr:
status: done
---

# TASK-knowledge-extraction-local-file-upload: Поддержка загрузки локальных файлов в TasK

## 0. Простое описание (Human Brief)

### Проблема простыми словами (Problem)

`ingest.sh` принимает только `--source-url` и постит `{"uri": ...}` в `/source-urls`. Локальные файлы (видео, аудио, PDF, DJVU, HTML) загрузить им нельзя, хотя README и SKILL.md обещают поддержку видео- и аудиофайлов через Whisper-транскрибацию. Для локального mp4 пришлось вручную: создать проект через API, загрузить файл curl'ом в `POST /v1/projects/{projectUuid}/source-files` (multipart) и вручную заполнить `.task_project.json` — скрипт не сделал ни шага. Также `ingest.sh` требует `--source-url` при первом запуске, поэтому `.task_project.json` не создаётся «автоматически при первом запуске», как заявлено в SKILL.md, если материал — файл.

### Варианты или путь решения (Solution Sketch)

Добавить в `ingest.sh` флаг `--source-file <path>`: определять существующий локальный путь, загружать multipart-запросом в `/source-files`, обрабатывать ответ `{sourceUuid, status}` и заполнять кеш тем же путём, что и URL-режим. Опционально — автоопределение: если `--source-url` указывает на существующий файл, трактовать его как файл.

### Ожидаемый результат (Expected Result)

`./scripts/ingest.sh --source-file /path/to/video.mp4` создаёт/переиспользует проект, загружает файл, ждёт готовности и выводит `project_uuid=...`, `source_uuid=...`, `documents=N` — без ручных curl-запросов.

## 1. Concept and Goal (Концепция и Цель)

### Story (User Story)

Как пользователь навыка, я хочу загружать локальные видео и документы в TasK одной командой, чтобы не писать curl-запросы к API и не заполнять кеш вручную.

### Goal (Цель по SMART)

Расширить shell-клиент TasK API: добавить файловый режим загрузки через существующий эндпоинт `source-files`, единый кеш с URL-режимом, документировать его в SKILL.md/README. Измеримость — успешная загрузка локального mp4 через `ingest.sh` с кешем и последующим `chat.sh` без ручных вызовов API.

## 2. Context and Scope (Контекст и границы)

- **Где делаем:** `scripts/ingest.sh`, опционально `scripts/chat.sh`, `README.md`, `SKILL.md` этого repository.
- **Текущее поведение:** `ingest.sh` принимает только `--source-url`, для файлов не предусмотрен; `.task_project.json` инициализируется только в URL-потоке; `chat.sh --source-url` резолвит кеш по `normalize_url`, что для локальных путей не документировано.
- **Контракт API:** `POST /v1/projects/{projectUuid}/source-files` — multipart/form-data, поле `file` (binary), ответ `CreateResponseDto` = `{sourceUuid, status}`; статусы `pending` / `processing` / `ready` / `failed` — те же, что у URL-загрузки.
- **Границы (Out of Scope):** изменения TasK API, загрузка каталогов/нескольких файлов одной командой, прогресс-бар загрузки, изменения транскрибации на стороне TasK.

## 3. Requirements (Требования, MoSCoW)

### 🔴 Must Have

- [x] Добавить `--source-file <path>` в `ingest.sh`: проверка существования файла, загрузка multipart в `/source-files`, разбор `{sourceUuid, status}`.
- [x] Заполнять `.task_project.json` в файловом режиме так же, как в URL-режиме: ключ кеша — нормализованный путь, запись `{uuid, url, title, status, last_used}`.
- [x] Не требовать `--source-url`, если передан `--source-file` (валидация аргументов учитывает оба режима).
- [x] После загрузки ждать готовности и обновлять статус в кеше — тем же циклом, что в URL-режиме.
- [x] Обновить usage-комментарий в шапке `ingest.sh` и README/SKILL.md: как грузить локальный файл.

### 🟡 Should Have

- [x] Автоопределение: если `--source-url` указывает на существующий локальный файл — трактовать как файл (или явная ошибка с подсказкой `--source-file`).
- [x] В SKILL.md — раздел про локальные файлы: пример `--source-file`, порядок (путь → multipart → ожидание готовности), заметка про время транскрибации.
- [x] В `chat.sh` документировать/поддержать резолв локального пути из кеша (или инструкцию использовать `--source <UUID>` из вывода ingest).

### 🟢 Could Have

- [ ] Выводить размер файла и/или имя в info-логах при загрузке.
- [ ] Поддержка нескольких `--source-file` за один вызов.

### ⚫ Won't Have

- [x] Не вводить новый формат кеша и не ломать обратную совместимость с существующим `.task_project.json`.
- [x] Не хранить пути/секреты за пределами `.task_project.json` и не печатать token.
- [x] Не менять TasK API и не добавлять fallback-эндпоинты.

## 4. Implementation Plan (План реализации)

1. [ ] Разобрать аргументы: разрешить `--source-file`, обновить валидацию «URL или файл обязателен».
2. [ ] Реализовать multipart-загрузку через `curl -F file=@...` в `/projects/{uuid}/source-files`, разобрать `sourceUuid`.
3. [ ] Переиспользовать существующие секции project/source/wait/out, параметризовав способ создания source.
4. [ ] Проверить повторный запуск с тем же путём: не дублировать source (поиск по кешу/API).
5. [ ] Обновить README.md и SKILL.md.

## 5. Definition of Done (Критерии приёмки)

- [x] `./scripts/ingest.sh --source-file "/path/to/video.mp4"` с пустым `.task_project.json` создаёт проект, загружает файл, дожидается `ready` и выводит `project_uuid=...`, `source_uuid=...`, `documents=N`.
- [x] В `.task_project.json` появляется запись source с ключом-путём, статус после ожидания — `ready`.
- [x] `--source-url` без `--source-file` и наоборот работают как раньше; без обоих — понятная ошибка.
- [x] Повторный `ingest.sh --source-file <тот же путь>` не создаёт дубликат source.
- [x] `./scripts/chat.sh --source <source_uuid>` отвечает по загруженному файлу.
- [x] `bash -n scripts/ingest.sh` проходит; README/SKILL.md описывают `--source-file`.

## 6. Verification (Самопроверка)

```bash
bash -n scripts/ingest.sh
# Загрузить небольшой локальный файл (например, mp3/mp4 или PDF) в тестовый проект,
# убедиться в готовности и ответе chat.sh по source_uuid.
```

## 7. Risks and Dependencies (Risks and dependencies)

- Ответ `CreateResponseDto` подтверждён по OpenAPI (`docs.ai-aid.pro/api.json`), но формат ошибок multipart-загрузки (413/415/422) нужно проверить фактическим ответом API.
- Локальные пути с пробелами и не-ASCII символами (например, «Рабочий стол») должны корректно передаваться в `curl -F`.
- Ключ кеша для локального файла — новый случай для `normalize_url`: нужна явная политика (путь как есть в lower-case), чтобы `--check` и повторный ingest находили source.
- Related: TasK task `TASK-knowledge-extraction-api-client-resilience` синхронизирует sources из API и централизует HTTP-ошибки; файловый режим должен быть совместим с ним по кешу.

## 8. Sources (Источники)

- `scripts/ingest.sh` — текущая реализация (только URL-режим).
- `README.md`, `SKILL.md` — заявленная поддержка видео/аудиофайлов без реализации в скриптах.
- TasK OpenAPI `docs.ai-aid.pro/api.json`: `POST /v1/projects/{projectUuid}/source-files`, `CreateResponseDto`.
- Наблюдение из реального использования 2026-08-01: загрузка локального mp4 потребовала ручного curl и ручного заполнения `.task_project.json`.

## Change History (История изменений)

| Дата | Автор | Изменение |
|---|---|---|
| 2026-08-01 | Аналитик (deepseek) | Исходная постановка: локальные файлы не поддерживаются ingest.sh, несмотря на заявленную поддержку; кеш и проект пришлось создавать вручную. |
