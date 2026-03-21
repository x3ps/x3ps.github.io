---
title: "rns-over-email: туннелируем Reticulum через почту"
date: 2026-03-21
draft: false
toc: true
description: "Реализация email-транспорта для Reticulum: SMTP на выход, IMAP на приём, альфа-версия открыта для тестирования."
tags:
  - go
  - golang
  - reticulum
  - networking
  - email
  - open-source
categories:
  - Development
---

## Откуда это взялось

В [предыдущей статье о go-rns-pipe](/ru/posts/2026/03/writing-a-go-library-for-reticulum-go-rns-pipe/)
я рассказывал о Go-библиотеке для PipeInterface протокола Reticulum. В разделе «Планы» там был пункт:

> **Email-транспорт** — туннелирование пакетов Reticulum через SMTP/IMAP. Каждый пакет упаковывается
> в письмо, отправляется на почтовый сервер и считывается с другой стороны.

Вот он — [rns-over-email](https://github.com/x3ps/rns-over-email). Это rnsd PipeInterface-субпроцесс,
который пробрасывает RNS-пакеты через обычную электронную почту.

Проект в **альфа-статусе**. Базовый поток данных работает, но края протёрты неравномерно:
тестировался только **локальный почтовый сервер** (Docker-контейнер типа Mailpit) —
реальные рейтлимиты SMTP/IMAP у Gmail, Fastmail, Proton Mail и подобных **неизвестны**.
UID-чекпоинты не переживают перезапуск. Жду тестирования и фидбека.

## Зачем туннелировать Reticulum через почту

Email — один из немногих протоколов, которые работают почти везде. Там, где заблокированы VPN,
мессенджеры и нестандартные порты, SMTP/IMAP часто остаются доступны — провайдеры и корпоративные
сети вынуждены их пропускать.

Reticulum устроен так, что не важно, через что идут пакеты: LoRa, TCP, serial или электронная
почта. Транспорт полностью скрыт за PipeInterface. Всё, что нужно — доставить байты туда и
обратно. Email с этим справляется, пусть и медленно.

Медленно — это ключевое слово. Email-транспорт подходит для данных, которым не нужна
низкая задержка: синхронизация store-and-forward сообщений, репликация анонсов узлов,
передача файлов через Reticulum LXMF. Для голоса или real-time чата — нет.

## Архитектура

```text
                    stdin / stdout
                         │
            ┌────────────┴────────────┐
            │                         │
           rnsd              rns-over-email
            │                         │
            │                  SMTP (outbound)
            │                  IMAP (inbound)
            │                         │
            │                   mail server
            │                         │
            └──────── сеть ───── remote peer
                                (своя копия
                              rns-over-email)
```

Один процесс — один пир. Это **линейная модель**: каждый экземпляр `rns-over-email` знает ровно
об одном адресе назначения (`--peer-email`). Если нужно связаться с несколькими пирами — запускается
несколько экземпляров, каждый описывается своим блоком `[[PipeInterface]]` в конфиге rnsd.

Такой подход упрощает реализацию и изоляцию: проблема с одним пиром не аффектирует остальных.

## Поток данных

### Outbound: RNS → MIME → SMTP

1. rnsd записывает HDLC-фрейм в stdin процесса.
2. `go-rns-pipe` декодирует фрейм, достаёт сырой RNS-пакет.
3. Пакет сериализуется в MIME-письмо с уникальным `Message-ID` и отправляется через SMTP.
4. Письмо отправляется на SMTP-сервер с экспоненциальным бэкоффом: 1s → 2s → 4s.
5. После 5 подряд неудавшихся отправок логируется ошибка уровня `error`.

**MIME-структура письма:**

- `From:` / `To:` — адреса своего и пира
- `Message-ID:` — `<uuid@smtp-from-domain>`, UUID v4 гарантирует уникальность; MTA и IMAP-серверы
  могут дедуплицировать по нему — нам это на руку (RNS всё равно дедуплицирует сверху)
- `Content-Type: application/octet-stream` для attachment с бинарным телом RNS-пакета
  (base64 по стандарту MIME)

Письма собираются через `github.com/emersion/go-message` (v0.18.2) — та же экосистема, что
go-imap/v2, что упрощает работу с MIME.

Модель доставки — **best-effort, at-most-once**. Потеря пакета на этом уровне нормальна:
RNS Link и Resource слои имеют собственные ACK и ретрансмиссию. `rns-over-email` не пытается
восстановить потерянные пакеты — это работа Reticulum.

### Inbound: IMAP → decode → RNS

1. IMAP-воркер подключается к серверу и, если сервер поддерживает IMAP IDLE, ждёт push-уведомлений.
   Если нет — периодически опрашивает ящик (по умолчанию раз в 60 секунд).
2. Новые письма фильтруются по `From:` — принимаются только письма от `--peer-email`; остальные
   игнорируются.
3. Attachment декодируется обратно в байты RNS-пакета.
4. Пакет передаётся в rnsd через `Receive()` (stdout).
5. Обработанный UID сохраняется как чекпоинт — повторно не читается.

**Детали IMAP IDLE:**

- Клиент отправляет команду `IDLE`, сервер держит соединение открытым и присылает `* N EXISTS`
  при появлении нового письма — это настоящий push без опроса.
- Без IDLE (fallback): `SELECT INBOX` + `SEARCH UID > last_uid` + `FETCH` раз в poll-interval.
- Соединение IDLE требует периодического keep-alive: RFC 2177 рекомендует переподключаться
  не реже чем раз в 29 минут. go-imap/v2 обрабатывает это прозрачно.

Ошибка декодирования не удаляет письмо — оно остаётся в ящике для ручного разбора.

### IMAP UID чекпоинты

Каждое прочитанное письмо помечается по UID. При следующем опросе читаются только письма с UID
выше последнего обработанного. Чекпоинт хранится в памяти — **не переживает перезапуск процесса**.
Это известное ограничение альфа-версии: после перезапуска возможна повторная обработка писем,
что безопасно (RNS дедуплицирует на своём уровне), но расточительно.

## Модель доставки

| Сценарий | Поведение |
| --- | --- |
| SMTP-сервер недоступен | Экспоненциальный бэкофф: 1s, 2s, 4s; затем пакет теряется |
| 5+ последовательных ошибок отправки | `error`-уровень лога |
| IMAP decode failure | Письмо не удаляется, ошибка логируется |
| Дубликат пакета | RNS-уровень дедуплицирует |
| Перезапуск процесса | UID-чекпоинт сбрасывается; повторная обработка безопасна |

## Конфигурация

### CLI-флаги и переменные окружения

Каждый флаг имеет эквивалентную переменную окружения с префиксом `RNS_EMAIL_`.

**SMTP (исходящая почта):**

| Флаг | Переменная | По умолчанию |
| --- | --- | --- |
| `--smtp-host` | `RNS_EMAIL_SMTP_HOST` | — |
| `--smtp-port` | `RNS_EMAIL_SMTP_PORT` | `587` (STARTTLS) |
| `--smtp-username` | `RNS_EMAIL_SMTP_USERNAME` | — |
| `--smtp-password` | `RNS_EMAIL_SMTP_PASSWORD` | — |
| `--smtp-password-file` | `RNS_EMAIL_SMTP_PASSWORD_FILE` | — |
| `--smtp-from` | `RNS_EMAIL_SMTP_FROM` | — |

**IMAP (входящая почта):**

| Флаг | Переменная | По умолчанию |
| --- | --- | --- |
| `--imap-host` | `RNS_EMAIL_IMAP_HOST` | — |
| `--imap-port` | `RNS_EMAIL_IMAP_PORT` | `993` (TLS) |
| `--imap-username` | `RNS_EMAIL_IMAP_USERNAME` | — |
| `--imap-password` | `RNS_EMAIL_IMAP_PASSWORD` | — |
| `--imap-password-file` | `RNS_EMAIL_IMAP_PASSWORD_FILE` | — |
| `--imap-poll-interval` | `RNS_EMAIL_IMAP_POLL_INTERVAL` | `60s` |

**Пир и прочее:**

| Флаг | Переменная | По умолчанию |
| --- | --- | --- |
| `--peer-email` | `RNS_EMAIL_PEER` | — |
| `--mtu` | `RNS_EMAIL_MTU` | `500` |

Пароли через CLI-флаги отображаются в `ps aux`. Используйте `--*-password-file` или переменные
окружения в production.

### Конфиг rnsd

```ini
[interfaces]
  [[Email to Alice]]
    type = PipeInterface
    interface_enabled = Yes
    command = rns-over-email \
      --smtp-host smtp.example.com \
      --smtp-username bob@example.com \
      --smtp-password-file /run/secrets/smtp_pass \
      --smtp-from bob@example.com \
      --imap-host imap.example.com \
      --imap-username bob@example.com \
      --imap-password-file /run/secrets/imap_pass \
      --peer-email alice@example.com
    respawn_delay = 5
```

На стороне Alice — зеркальная конфигурация с `--peer-email bob@example.com`.

## Установка

### go install

```bash
go install github.com/x3ps/rns-iface-email/cmd/rns-over-email@latest
```

### Готовые бинари

На странице [Releases](https://github.com/x3ps/rns-over-email/releases) есть бинари для:

- Linux: amd64, arm64
- macOS: amd64, arm64
- Windows: amd64, arm64

### Сборка из исходников

```bash
git clone https://github.com/x3ps/rns-over-email
cd rns-over-email
go build ./cmd/rns-over-email
```

## Зависимости

Проект строится на трёх внешних пакетах:

- **[go-imap/v2](https://github.com/emersion/go-imap)** — IMAP-клиент с поддержкой IDLE
- **[go-smtp](https://github.com/emersion/go-smtp)** — SMTP-клиент с STARTTLS/TLS
- **[go-rns-pipe](https://github.com/x3ps/go-rns-pipe)** (v0.1.1) — HDLC-фреймирование и PipeInterface

`go-rns-pipe` — это та самая библиотека из [предыдущей статьи](/ru/posts/2026/03/writing-a-go-library-for-reticulum-go-rns-pipe/).
`rns-over-email` — первый production-пользователь библиотеки.

Плюс `github.com/google/uuid` для генерации `Message-ID`.

## Планы

### E2e тесты с Greenmail

Сейчас покрытие только юнит-тестами; интеграционных тестов (реальный SMTP/IMAP round-trip) нет.
[Greenmail](https://greenmail-mail-test.github.io/greenmail/) — встраиваемый SMTP/IMAP-сервер для
тестов — позволит гонять полный цикл outbound→inbound без внешней почты. Это следующий шаг
в сторону надёжности.

### POP3 (возможно)

Альтернатива IMAP для входящих — POP3 проще в реализации, но без IDLE и нормального UID.
Будет зависеть от фидбека: есть ли реальные серверы, где IMAP недоступен, а POP3 — есть.

### Multipeer — осознанное решение не делать

Мысли о мультипир-режиме (один процесс, несколько `--peer-email`) были, но отказался.
Причина: линейная модель проще и изолированнее — каждый пир живёт в отдельном процессе,
проблема с одним не аффектирует остальных.

Правильный путь: **запускать несколько экземпляров** бинарника с разными `--peer-email`,
каждый описывается своим блоком `[[PipeInterface]]` в конфиге rnsd (пример есть в разделе
[Конфиг rnsd](#конфиг-rnsd) выше).

## Альфа: жду тестирования и фидбека

Проект реален, работает, но молод. Что именно хотелось бы проверить:

- **Совместимость с почтовыми серверами** — тестировал только на локальном сервере в Docker
  (Mailpit). Fastmail, Gmail, Proton Mail (через bridge), корпоративные Exchange — интересно,
  как ведут себя там.
- **Рейтлимиты** — реальные ограничения SMTP/IMAP у публичных провайдеров неизвестны. При
  интенсивном трафике можно упереться в лимиты на количество подключений или писем в час.
- **IMAP IDLE** — есть серверы, которые формально объявляют IDLE, но реализуют его плохо.
  Если fallback-поллинг включается там, где не должен — это нужно знать.
- **Производительность** — какой реальный throughput при poll interval 60s? Какова задержка
  в сценарии «мессенджер поверх LXMF поверх rns-over-email»?
- **Граничные случаи конфигурации** — что происходит при смене пароля, истечении сессии,
  Full Inbox на IMAP.

Если попробуете — напишите, что получилось:

- **GitHub Issues**: [x3ps/rns-over-email/issues](https://github.com/x3ps/rns-over-email/issues)
- **Matrix**: `@x3ps:matrix.org`
- **Email**: смотри профиль на GitHub

Любой фидбек полезен: «работает на Fastmail» — уже хорошо. «Падает вот тут» — ещё лучше.
