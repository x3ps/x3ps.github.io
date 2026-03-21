---
title: "Пишем Go-библиотеку для Reticulum: go-rns-pipe"
date: 2026-03-19
draft: false
toc: true
description: "Как я реализовал PipeInterface протокол Reticulum Network Stack на Go: HDLC-фреймирование, логика переподключения и нулевые внешние зависимости."
tags:
  - go
  - golang
  - reticulum
  - networking
  - open-source
categories:
  - Development
---

## Что такое Reticulum и зачем мне понадобился Go

[Reticulum Network Stack](https://reticulum.network/) — это криптографический сетевой стек, спроектированный
для работы в условиях низкой пропускной способности и ненадёжных каналов. Ключевая идея: абстракция над
физическим транспортом. Reticulum умеет работать поверх LoRa, TCP, UDP, последовательных портов — и через
PipeInterface, которому посвящена эта статья.

PipeInterface позволяет запустить произвольный процесс и общаться с rnsd через stdin/stdout. Демон rnsd
выступает как «сервер», а ваш процесс — как транспорт. Данные передаются в обе стороны HDLC-фреймами.
Эталонная реализация написана на Python (`PipeInterface.py`), но мне понадобился Go.

Причина глубже, чем просто «не хочу тащить Python-рантайм» (хотя и это тоже). Задача была сделать
библиотеку **независимой от реализации**: не привязанной к Python, пригодной как строительный блок
для любой реализации Reticulum.

Сейчас Reticulum существует только как эталонная Python-реализация, но активно разрабатываются
реализации на Go и Rust. PipeInterface — это естественный шов: любой язык, умеющий говорить
HDLC поверх stdin/stdout, может подключиться к rnsd без изменений в самом демоне. Именно с этим
будущим в голове проектировался [go-rns-pipe](https://github.com/x3ps/go-rns-pipe).

## Задача

rnsd запускает дочерний процесс командой из конфига:

```ini
[interfaces]
  [[My Go Transport]]
    type = PipeInterface
    interface_enabled = Yes
    command = /usr/local/bin/my-transport
    respawn_delay = 5
```

Дочерний процесс общается с rnsd через stdin/stdout:

- **stdin** — поток входящих HDLC-фреймов от rnsd (пакеты, которые нужно передать наружу)
- **stdout** — поток исходящих HDLC-фреймов к rnsd (принятые пакеты)

Протокол простой, но нужно точно воспроизвести HDLC-фреймирование из Python — иначе rnsd не поймёт
ни одного пакета.

## Архитектура

Библиотека состоит из шести компонентов:

```
         stdin
           │
           ▼
      ┌─────────┐    пакеты    ┌──────────────────┐
      │ Decoder │ ──────────►  │                  │
      └─────────┘              │    Interface     │ ◄── OnSend callback
                               │                  │
      ┌─────────┐   фрейм      │  pipeOnline      │ ◄── Start()/readLoop()
      │ Encoder │ ◄──────────  │  transportOnline │ ◄── SetOnline(bool)
      └─────────┘              └──────────────────┘
           │                          │
           ▼                     Reconnector
         stdout                        │
                                  Config / slog
```

- **`Interface`** — центральный тип. Оркестрирует чтение/запись, управляет двухбитным состоянием
  `online`, вызывает коллбэки.
- **`Encoder`** — оборачивает произвольный байтовый срез в HDLC-фрейм.
- **`Decoder`** — потоковый автомат состояний. Реализует `io.Writer`, внутри хранит канал готовых пакетов.
- **`Reconnector`** — управляет логикой повторных подключений: фиксированная задержка или экспоненциальный
  бэкофф.
- **`Config`** — конфигурация с разумными дефолтами, совпадающими с `PipeInterface.py`.
- **`SetOnline(bool)`** — внешний сигнал о состоянии сетевой стороны транспорта.

Поток данных при получении пакета от rnsd:

1. `io.Copy` в горутине читает байты из `config.Stdin` и пишет их в `Decoder`.
2. `Decoder.Write` прогоняет каждый байт через автомат состояний.
3. Готовый пакет кладётся в буферизованный канал `packets`.
4. Основной `select`-цикл в `readLoop` читает из канала и вызывает `OnSend`-коллбэк.

Отправка пакета к rnsd — `iface.Receive(pkt)` — кодирует его через `Encoder` и пишет в `config.Stdout`.

### SetOnline: двухбитное состояние

`Interface` управляет двумя независимыми флагами online:

- **`pipeOnline`** — rnsd-сторона жива. Выставляется в `true` при успешном `Start()`, в `false`
  при EOF или ошибке `readLoop`.
- **`transportOnline`** — сетевая сторона жива. Управляется вызовом `SetOnline(bool)` из транспорта.

Эффективное состояние: `pipeOnline && transportOnline`. Коллбэк `onStatus` срабатывает только при
реальных переходах, чтобы rnsd не получал лишних уведомлений.

Типичный сценарий для TCP-транспорта:

```go
// TCP-соединение потеряно — сообщаем, что сетевая сторона недоступна
func (t *TCPTransport) onDisconnect() {
    t.iface.SetOnline(false)
    // ...логика переподключения...
}

// TCP-соединение восстановлено
func (t *TCPTransport) onConnect() {
    t.iface.SetOnline(true)
}
```

Это позволяет rnsd корректно отображать состояние интерфейса даже если pipe к rnsd жив, но
сетевая сторона временно недоступна.

## HDLC-фреймирование

### Как устроен фрейм

HDLC (High-Level Data Link Control) в упрощённом виде, похожем на PPP:

```
0x7E | escaped_data | 0x7E
```

Байт `0x7E` — флаг начала/конца фрейма. Если в полезной нагрузке встречается `0x7E` или `0x7D`
(escape-символ), их нужно экранировать:

| Исходный байт | Замена            |
|---------------|-------------------|
| `0x7D`        | `0x7D 0x5D`       |
| `0x7E`        | `0x7D 0x5E`       |

Правило: сначала экранируем `0x7D`, потом `0x7E`. Порядок важен — иначе дважды заэкранируем.

### Encoder

```go
const (
    HDLCFlag    = 0x7E
    HDLCEscape  = 0x7D
    HDLCEscMask = 0x20
)

func (e *Encoder) Encode(packet []byte) []byte {
    out := make([]byte, 0, len(packet)+len(packet)/4+2)
    out = append(out, HDLCFlag)

    for _, b := range packet {
        switch b {
        case HDLCEscape:
            out = append(out, HDLCEscape, HDLCEscape^HDLCEscMask)
        case HDLCFlag:
            out = append(out, HDLCEscape, HDLCFlag^HDLCEscMask)
        default:
            out = append(out, b)
        }
    }

    out = append(out, HDLCFlag)
    return out
}
```

`HDLCEscape ^ HDLCEscMask` = `0x7D ^ 0x20` = `0x5D`. `HDLCFlag ^ HDLCEscMask` = `0x7E ^ 0x20` = `0x5E`.
Именно эти значения ожидает `PipeInterface.py`.

### Decoder: автомат состояний

Декодер — потоковый. Он реализует `io.Writer`, чтобы его можно было передать прямо в `io.Copy`:

```go
func (d *Decoder) Write(b []byte) (int, error) {
    d.mu.Lock()
    defer d.mu.Unlock()

    for _, byte_ := range b {
        if d.inFrame && byte_ == HDLCFlag {
            // Конец фрейма — отдаём пакет
            pkt := make([]byte, len(d.buf))
            copy(pkt, d.buf)
            select {
            case d.packets <- pkt:
            default:
                d.dropped.Add(1) // канал переполнен — счётчик дропов
            }
            d.buf = d.buf[:0]
            d.inFrame = false
        } else if byte_ == HDLCFlag {
            // Начало фрейма
            d.inFrame = true
            d.buf = d.buf[:0]
        } else if d.inFrame && len(d.buf) < d.hwMTU {
            if byte_ == HDLCEscape {
                d.escape = true
            } else {
                if d.escape {
                    switch byte_ {
                    case HDLCFlag ^ HDLCEscMask:
                        byte_ = HDLCFlag
                    case HDLCEscape ^ HDLCEscMask:
                        byte_ = HDLCEscape
                    }
                    d.escape = false
                }
                d.buf = append(d.buf, byte_)
            }
        }
    }
    return len(b), nil
}
```

Три состояния: вне фрейма, внутри фрейма, ожидание escape. Логика точно воспроизводит
`readLoop` из `PipeInterface.py` — вплоть до того, что пустой фрейм `0x7E 0x7E` доставляет
пустой пакет (Python делает то же самое, вызывая `process_incoming(b"")` без проверки длины).

Максимальный размер буфера ограничен `hwMTU` (по умолчанию 1064 байта, как в `PipeInterface.py#L72`).
Пакеты, которые не влезают в буферизованный канал, считаются дропнутыми — счётчик `DroppedPackets()`
помогает мониторить нагрузку.

## Переподключение

### Два режима

По умолчанию режим **fixed delay** — точно как `respawn_delay` в Python:

```go
func (r *reconnector) backoff(attempt int) time.Duration {
    if attempt == 0 {
        return 0 // первая попытка без задержки
    }
    if !r.exponentialBackoff {
        return r.baseDelay // фиксированная задержка
    }
    // экспоненциальный бэкофф с джиттером ±25%, потолок 60s
    exp := math.Pow(2, float64(attempt-1))
    delayF := float64(r.baseDelay) * exp
    if delayF > float64(60*time.Second) {
        delayF = float64(60 * time.Second)
    }
    return time.Duration(delayF * (0.75 + rand.Float64()*0.5))
}
```

Для долгоживущих сервисов, которые сами управляют переподключением, есть `ExponentialBackoff: true`.

### ErrPipeClosed

Есть нюанс: если Go-процесс запущен как дочерний rnsd, то при получении EOF на stdin он должен
завершиться, а не переподключаться — rnsd сам перезапустит процесс через `respawn_delay`.

Для этого есть `ExitOnEOF: true`:

```go
iface := rnspipe.New(rnspipe.Config{
    ExitOnEOF: true, // вернуть ErrPipeClosed вместо переподключения
})
```

При `ExitOnEOF=true` и получении чистого EOF `Start` возвращает `ErrPipeClosed` немедленно, без
ожидания `ReconnectDelay`. Это позволяет процессу быстро завершиться и дать rnsd сигнал к
перезапуску.

## Конкурентность

### sync.RWMutex для состояния

Флаги состояния и коллбэки защищены `sync.RWMutex`:

```go
type Interface struct {
    mu              sync.RWMutex // защищает: pipeOnline, transportOnline, started, onSend, onStatus, cancelFn
    writeMu         sync.Mutex   // сериализует запись в Stdout в Receive()
    pipeOnline      bool         // pipe к rnsd жив (Start/readLoop)
    transportOnline bool         // сетевая сторона жива (SetOnline)
    // ...
}
```

`writeMu` отдельный — чтобы несколько горутин могли одновременно вызывать `Receive()` без
конфликтов на записи в stdout.

### Атомарные счётчики метрик

Трафик считается без локов:

```go
packetsSent     atomic.Uint64
packetsReceived atomic.Uint64
bytesSent       atomic.Uint64
bytesReceived   atomic.Uint64
```

`atomic.Uint64` из стандартной библиотеки — безопасно читать из любого числа горутин
без `sync.Mutex`.

### Жизненный цикл горутины

`readLoop` запускает одну горутину для `io.Copy`. При отмене контекста нужно разблокировать
её — если `Stdin` реализует `io.Closer`, закрываем его и ждём завершения:

```go
case <-ctx.Done():
    if iface.config.Stdin != os.Stdin {
        if closer, ok := iface.config.Stdin.(io.Closer); ok {
            _ = closer.Close()
            <-readErr // ждём горутину
        }
    }
    return nil
```

`os.Stdin` намеренно исключён из этого пути — его закрытие аффектирует весь процесс.
Если `Stdin` не реализует `io.Closer`, логируется предупреждение о возможной утечке горутины.

## Нулевые зависимости

Основная библиотека использует только стандартную библиотеку Go — `go.sum` пуст для основного
модуля. Это сознательное решение:

**Плюсы:**
- Нет diamond-dependency проблем при вложении в другой проект
- Сборка работает в любом окружении без `go get`
- Меньше поверхность для supply-chain атак

**Минусы:**
- Нет `zerolog` или `zap` — логирование через стандартный `log/slog`
- Нет готового `backoff`-пакета — реализован вручную (невелик)

Для parity-тестов нужен только `python3` в PATH — скрипт встроен прямо в тест как константа,
без сторонних Python-пакетов.

## Тестирование

### Юнит-тесты

Базовые сценарии в `pipe_test.go`: encode/decode, byte stuffing, пустые пакеты, метрики,
горутинные гонки. Тесты с `sync.Mutex`/`atomic` прогоняются с детектором гонок:

```bash
make test
# эквивалентно: go test -race ./...
```

### Parity-тесты с Python

Самый важный момент — убедиться, что наша HDLC-кодировка совместима с эталонной реализацией.
В `parity_test.go` (тег сборки `integration`) Go-кодировщик отправляет фреймы Python-скрипту,
который их декодирует:

```go
func TestHDLCParityPython(t *testing.T) {
    payload := []byte("hello-parity-test")
    enc := &rnspipe.Encoder{}
    frame := enc.Encode(payload)

    cmd := exec.Command(python, tmp.Name())
    cmd.Stdin = bytes.NewReader(frame)
    out, _ := cmd.Output()

    if !bytes.Equal(out, payload) {
        t.Errorf("Python decoded %q, want %q", out, payload)
    }
}
```

Есть и обратный тест: Python кодирует фрейм, Go декодирует. И полный round-trip:
Go → Python → Go с бинарными нагрузками (`0x7E`, `0x7D`, их комбинациями).

## Планы

Абстракция PipeInterface делает добавление новых транспортов почти механической задачей: реализуй
чтение/запись пакетов через выбранный канал, вызывай `SetOnline` по состоянию соединения — и всё.

Несколько транспортов в планах:

**Email-транспорт** — туннелирование пакетов Reticulum через SMTP/IMAP. Каждый пакет упаковывается
в письмо, отправляется на почтовый сервер и считывается с другой стороны. Это позволяет обходить
цензуру в регионах, где основной интернет-трафик фильтруется, но email ещё работает.

**S3-транспорт** — объектное хранилище (AWS S3, MinIO и аналоги) как асинхронное реле пакетов.
Пакеты записываются как объекты с известным именованием; получатель периодически читает их и удаляет.
Подходит для store-and-forward поверх сильно фильтруемых соединений или при асимметричном канале.

Общая идея: PipeInterface — это не только удобный способ написать транспорт для rnsd, но и
инструмент для реализации нестандартных каналов, которые никогда не войдут в официальный Python-код.

## Итоги

**Что получилось:**

- Совместимая с Python реализация PipeInterface протокола на чистом Go
- Два режима переподключения (fixed delay и exponential backoff с jitter)
- Потоковый HDLC-декодер как `io.Writer` — подключается к `io.Copy` напрямую
- Метрики через атомарные счётчики
- Двухбитное состояние online: `pipeOnline` (rnsd-сторона) + `transportOnline` (сетевая сторона)

**Что узнал:**

Точное воспроизведение behaviour другой реализации — это отдельная задача. Казалось бы, простой
протокол: флаговый байт, escape-последовательности. Но детали вроде «пустой фрейм тоже доставляется»
или «порядок escape ESC до FLAG» обнаруживаются только при внимательном чтении кода и parity-тестах.

Изоляция через `ExitOnEOF`/`ErrPipeClosed` для режима дочернего процесса тоже не очевидна сразу —
нужно понять жизненный цикл rnsd, прежде чем сделать правильный интерфейс.

**Состояние проекта:**

Библиотека стабильна, покрыта тестами, используется в моих проектах. Исходный код на GitHub:
[x3ps/go-rns-pipe](https://github.com/x3ps/go-rns-pipe). Версия — v0.1.1. Лицензия — MIT.

```bash
go get github.com/x3ps/go-rns-pipe@v0.1.1
```
