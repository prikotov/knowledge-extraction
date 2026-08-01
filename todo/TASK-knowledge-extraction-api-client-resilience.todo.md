---
type: fix
created: 2026-07-31
value: V2
complexity: C2
priority: P1
author: Архитектор (codex)
assignee:
branch: task/knowledge-extraction-api-client-resilience
pr:
status: done
---

# TASK-knowledge-extraction-api-client-resilience: Синхронизировать sources и показывать ошибки TasK API

## 0. Простое описание (Human Brief)

### Проблема простыми словами (Problem)

Скрипты knowledge-extraction не показывают sources, добавленные без локального JSON-кеша, а `chat.sh` скрывает ответ API с ошибкой — например, `422 Need to top up balance` выглядит как пустой ответ.

### Варианты или путь решения (Solution Sketch)

Получать полный список sources текущего project из TasK API, синхронизировать его с локальным JSON по UUID и централизованно обрабатывать HTTP-ответ до разбора SSE.

### Ожидаемый результат (Expected Result)

`ingest.sh --check` показывает все sources project, а `chat.sh` выводит безопасное сообщение с HTTP-кодом и `detail` вместо пустого результата.

## 1. Concept and Goal (Концепция и Цель)

### Story (User Story)

Как пользователь навыка, я хочу видеть актуальные sources и понятные ошибки TasK API, чтобы не принимать пустой вывод за отсутствие данных.

### Goal (Цель по SMART)

Исправить shell-клиент TasK API: получить все страницы sources, сделать UUID API источником истины для cache и печатать диагностируемую ошибку до SSE parsing. Измеримость — offline shell-тесты pagination, cache merge, `422 JSON`, `500 text/plain`, transport failure, valid/invalid SSE; срок определяет планирование.

## 2. Context and Scope (Контекст и границы)

- **Где делаем:** `scripts/ingest.sh`, `scripts/chat.sh`, `SKILL.md` этого repository.
- **Текущее поведение:** `--check` итерирует только `.task_project.json`; HTTP-wrapper печатает body до проверки статуса; `chat.sh` без проверки передаёт любой ответ в `parse_sse`.
- **Контракт API:** `GET /v1/projects/{projectUuid}/sources` может быть paginated; `POST /v1/chats/{chatUuid}/messages` при успехе отдаёт SSE.
- **Границы (Out of Scope):** изменения TasK API и его баланса, автоматическое пополнение, хранение token/Authorization header в Git или вывод секретов, исправление project-specific materialization documents в TasK.

## 3. Requirements (Требования, MoSCoW)

### 🔴 Must Have

- [x] Реализовать получение всех страниц `GET /projects/{projectUuid}/sources`: задавать `limit`, увеличивать `offset` и завершать цикл после `pagination.total`.
- [x] Синхронизировать `.task_project.json` по `sourceUuid`: импортировать sources, отсутствующие локально, и обновлять cache; не удалять локальную запись и не перезаписывать пользовательские поля без явно заданной policy.
- [x] При конфликте нормализованных URL хранить обе записи, если `sourceUuid` различается; не угадывать, что это один source.
- [x] Ввести единый HTTP-wrapper: успешный body — stdout, диагностика — stderr; network error и любой non-2xx возвращают non-zero.
- [x] Для JSON error вывести `HTTP <code>: <detail>`; для не-JSON/пустого body — безопасное общее сообщение без token и Authorization header.
- [x] Перед `parse_sse` проверить 2xx и `Content-Type`, совместимый с `text/event-stream`; иной ответ не разбирать как SSE.
- [x] Добавить offline shell-тесты без реального TasK token/API.

### 🟡 Should Have

- [x] Отмечать в выводе `--check` source, импортированный из API, отдельно от изменения статуса.
- [x] Обновить `SKILL.md` с синхронизацией cache и примером quota error.

### 🟢 Could Have

- [ ] Добавить `--verbose` с диагностическими HTTP-полями, исключая секреты.

### ⚫ Won't Have

- [x] Не использовать fallback, маскирующий ошибки, и не продолжать SSE parsing после неуспешного HTTP-ответа.
- [x] Не печатать token, Authorization header или исходный curl command с секретами.
- [x] Не менять API TasK в этой задаче.

## 4. Implementation Plan (План реализации)

1. [x] Выделить тестируемые функции HTTP response handling и pagination/cache merge.
2. [x] Реализовать получение всех pages и idempotent merge в `ingest.sh --check`.
3. [x] Реализовать HTTP/SSE guard в `chat.sh` и единый безопасный формат ошибок.
4. [x] Поднять local fixture HTTP server в shell-тестах и покрыть все обязательные сценарии.
5. [x] Обновить `SKILL.md`.

## 5. Definition of Done (Критерии приёмки)

- [x] Source, созданный веб-интерфейсом или другой сессией, появляется после `ingest.sh --check`.
- [x] Две страницы API дают полный и недублирующийся cache по UUID.
- [x] `422 {"detail":"Need to top up balance."}` печатает `HTTP 422: Need to top up balance.` в stderr и завершает `chat.sh` с non-zero code.
- [x] `500 text/plain`, пустое error body и network failure дают безопасную ошибку и не вызывают `parse_sse`.
- [x] Валидный SSE сохраняет текущее поведение вывода ответа.
- [x] Offline shell-тесты и `bash -n scripts/ingest.sh scripts/chat.sh` проходят.

## 6. Verification (Самопроверка)

```bash
bash -n scripts/ingest.sh scripts/chat.sh
# Запустить добавленные offline shell-тесты с fixture HTTP server.
```

## 7. Risks and Dependencies (Риски и зависимости)

- Формат pagination и SSE Content-Type нужно подтвердить фактическим API response; не подменять их guessed defaults.
- `.task_project.json` является пользовательским cache: merge не должен стирать данные при временной неполноте API response.
- Related: TasK task `TASK-source-reuse-project-documents` исправляет отсутствие documents в новом project, но не блокирует эту клиентскую задачу.

## 8. Sources (Источники)

- `scripts/ingest.sh`
- `scripts/chat.sh`
- `SKILL.md`
- TasK API production report от 2026-07-31.

## Change History (История изменений)

| Дата | Автор | Изменение |
|---|---|---|
| 2026-07-31 | Аналитик (codex) | Исходная постановка в TasK repository. |
| 2026-07-31 | Архитектор (codex) | Доработан HTTP/pagination контракт и перенесён в repository реализации. |
