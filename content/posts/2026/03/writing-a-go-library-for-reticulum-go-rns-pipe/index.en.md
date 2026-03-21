---
title: "Writing a Go Library for Reticulum: go-rns-pipe"
date: 2026-03-19
draft: false
toc: true
description: "How I implemented the Reticulum Network Stack's PipeInterface protocol in Go: HDLC framing, reconnection logic, and zero external dependencies."
tags:
  - go
  - golang
  - reticulum
  - networking
  - open-source
categories:
  - Development
---

## What is Reticulum and why I needed Go

[Reticulum Network Stack](https://reticulum.network/) is a cryptographic network stack designed
to work under conditions of low bandwidth and unreliable links. The key idea: abstraction over
physical transport. Reticulum can operate over LoRa, TCP, UDP, serial ports — and through
PipeInterface, which is the subject of this article.

PipeInterface lets you launch an arbitrary process and communicate with rnsd via stdin/stdout. The
rnsd daemon acts as the "server", and your process acts as the transport. Data flows in both
directions as HDLC frames. The reference implementation is written in Python (`PipeInterface.py`),
but I needed Go.

The reason goes deeper than "I don't want to pull in a Python runtime" (though that's part of it
too). The goal was to make a library **independent of the implementation**: not tied to Python,
usable as a building block for any Reticulum implementation.

Right now Reticulum exists only as the reference Python implementation, but Go and Rust
implementations are actively being developed. PipeInterface is a natural seam: any language that
can speak HDLC over stdin/stdout can connect to rnsd without changes to the daemon itself. It was
with that future in mind that [go-rns-pipe](https://github.com/x3ps/go-rns-pipe) was designed.

## The task

rnsd launches a child process using a command from the config:

```ini
[interfaces]
  [[My Go Transport]]
    type = PipeInterface
    interface_enabled = Yes
    command = /usr/local/bin/my-transport
    respawn_delay = 5
```

The child process communicates with rnsd via stdin/stdout:

- **stdin** — incoming stream of HDLC frames from rnsd (packets to be sent outbound)
- **stdout** — outgoing stream of HDLC frames to rnsd (received packets)

The protocol is simple, but you need to reproduce the HDLC framing from Python exactly — otherwise
rnsd won't understand a single packet.

## Architecture

The library consists of six components:

```
         stdin
           │
           ▼
      ┌─────────┐   packets   ┌──────────────────┐
      │ Decoder │ ──────────► │                  │
      └─────────┘             │    Interface     │ ◄── OnSend callback
                              │                  │
      ┌─────────┐   frame     │  pipeOnline      │ ◄── Start()/readLoop()
      │ Encoder │ ◄────────── │  transportOnline │ ◄── SetOnline(bool)
      └─────────┘             └──────────────────┘
           │                          │
           ▼                     Reconnector
         stdout                        │
                                  Config / slog
```

- **`Interface`** — the central type. Orchestrates reading/writing, manages the two-bit `online`
  state, invokes callbacks.
- **`Encoder`** — wraps an arbitrary byte slice in an HDLC frame.
- **`Decoder`** — a streaming state machine. Implements `io.Writer`, internally holds a channel of
  ready packets.
- **`Reconnector`** — manages reconnection logic: fixed delay or exponential backoff.
- **`Config`** — configuration with sensible defaults matching `PipeInterface.py`.
- **`SetOnline(bool)`** — external signal about the state of the network side of the transport.

Data flow when receiving a packet from rnsd:

1. `io.Copy` in a goroutine reads bytes from `config.Stdin` and writes them into `Decoder`.
2. `Decoder.Write` runs each byte through the state machine.
3. The finished packet is placed in a buffered channel `packets`.
4. The main `select` loop in `readLoop` reads from the channel and invokes the `OnSend` callback.

Sending a packet to rnsd — `iface.Receive(pkt)` — encodes it via `Encoder` and writes it to
`config.Stdout`.

### SetOnline: two-bit state

`Interface` manages two independent online flags:

- **`pipeOnline`** — the rnsd side is alive. Set to `true` on successful `Start()`, to `false`
  on EOF or `readLoop` error.
- **`transportOnline`** — the network side is alive. Controlled by calling `SetOnline(bool)` from
  the transport.

Effective state: `pipeOnline && transportOnline`. The `onStatus` callback fires only on real
transitions, so rnsd doesn't receive spurious notifications.

Typical scenario for a TCP transport:

```go
// TCP connection lost — signal that the network side is unavailable
func (t *TCPTransport) onDisconnect() {
    t.iface.SetOnline(false)
    // ...reconnection logic...
}

// TCP connection restored
func (t *TCPTransport) onConnect() {
    t.iface.SetOnline(true)
}
```

This lets rnsd correctly display the interface state even when the pipe to rnsd is alive but the
network side is temporarily unavailable.

## HDLC framing

### Frame structure

HDLC (High-Level Data Link Control) in a simplified form, similar to PPP:

```
0x7E | escaped_data | 0x7E
```

The byte `0x7E` is the start/end frame flag. If the payload contains `0x7E` or `0x7D`
(the escape character), they must be escaped:

| Original byte | Replacement       |
|---------------|-------------------|
| `0x7D`        | `0x7D 0x5D`       |
| `0x7E`        | `0x7D 0x5E`       |

Rule: escape `0x7D` first, then `0x7E`. Order matters — otherwise you'd double-escape.

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
These are exactly the values expected by `PipeInterface.py`.

### Decoder: state machine

The decoder is streaming. It implements `io.Writer` so it can be passed directly to `io.Copy`:

```go
func (d *Decoder) Write(b []byte) (int, error) {
    d.mu.Lock()
    defer d.mu.Unlock()

    for _, byte_ := range b {
        if d.inFrame && byte_ == HDLCFlag {
            // End of frame — deliver the packet
            pkt := make([]byte, len(d.buf))
            copy(pkt, d.buf)
            select {
            case d.packets <- pkt:
            default:
                d.dropped.Add(1) // channel full — increment drop counter
            }
            d.buf = d.buf[:0]
            d.inFrame = false
        } else if byte_ == HDLCFlag {
            // Start of frame
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

Three states: outside a frame, inside a frame, waiting for escape. The logic exactly reproduces
`readLoop` from `PipeInterface.py` — including the fact that an empty frame `0x7E 0x7E` delivers
an empty packet (Python does the same, calling `process_incoming(b"")` without a length check).

The maximum buffer size is bounded by `hwMTU` (default 1064 bytes, as in `PipeInterface.py#L72`).
Packets that don't fit in the buffered channel are counted as dropped — the `DroppedPackets()`
counter helps monitor load.

## Reconnection

### Two modes

The default mode is **fixed delay** — exactly like `respawn_delay` in Python:

```go
func (r *reconnector) backoff(attempt int) time.Duration {
    if attempt == 0 {
        return 0 // first attempt without delay
    }
    if !r.exponentialBackoff {
        return r.baseDelay // fixed delay
    }
    // exponential backoff with ±25% jitter, 60s ceiling
    exp := math.Pow(2, float64(attempt-1))
    delayF := float64(r.baseDelay) * exp
    if delayF > float64(60*time.Second) {
        delayF = float64(60 * time.Second)
    }
    return time.Duration(delayF * (0.75 + rand.Float64()*0.5))
}
```

For long-running services that manage reconnection themselves, there's `ExponentialBackoff: true`.

### ErrPipeClosed

There's a nuance: if the Go process is launched as a child of rnsd, then upon receiving EOF on
stdin it should exit rather than reconnect — rnsd will restart the process itself after
`respawn_delay`.

For this there's `ExitOnEOF: true`:

```go
iface := rnspipe.New(rnspipe.Config{
    ExitOnEOF: true, // return ErrPipeClosed instead of reconnecting
})
```

With `ExitOnEOF=true` and a clean EOF, `Start` returns `ErrPipeClosed` immediately, without
waiting for `ReconnectDelay`. This lets the process exit quickly and signal rnsd to restart.

## Concurrency

### sync.RWMutex for state

State flags and callbacks are protected by `sync.RWMutex`:

```go
type Interface struct {
    mu              sync.RWMutex // protects: pipeOnline, transportOnline, started, onSend, onStatus, cancelFn
    writeMu         sync.Mutex   // serializes writes to Stdout in Receive()
    pipeOnline      bool         // pipe to rnsd is alive (Start/readLoop)
    transportOnline bool         // network side is alive (SetOnline)
    // ...
}
```

`writeMu` is separate — so multiple goroutines can concurrently call `Receive()` without conflicts
on writing to stdout.

### Atomic metric counters

Traffic is counted without locks:

```go
packetsSent     atomic.Uint64
packetsReceived atomic.Uint64
bytesSent       atomic.Uint64
bytesReceived   atomic.Uint64
```

`atomic.Uint64` from the standard library — safe to read from any number of goroutines
without `sync.Mutex`.

### Goroutine lifecycle

`readLoop` launches one goroutine for `io.Copy`. On context cancellation, we need to unblock
it — if `Stdin` implements `io.Closer`, we close it and wait for completion:

```go
case <-ctx.Done():
    if iface.config.Stdin != os.Stdin {
        if closer, ok := iface.config.Stdin.(io.Closer); ok {
            _ = closer.Close()
            <-readErr // wait for goroutine
        }
    }
    return nil
```

`os.Stdin` is intentionally excluded from this path — closing it would affect the entire process.
If `Stdin` doesn't implement `io.Closer`, a warning about a potential goroutine leak is logged.

## Zero dependencies

The core library uses only the Go standard library — `go.sum` is empty for the main module. This
is a deliberate decision:

**Pros:**
- No diamond-dependency problems when embedded in another project
- Builds in any environment without `go get`
- Smaller supply-chain attack surface

**Cons:**
- No `zerolog` or `zap` — logging via the standard `log/slog`
- No ready-made `backoff` package — implemented manually (it's small)

Parity tests require only `python3` in PATH — the script is embedded directly in the test as a
constant, without any third-party Python packages.

## Testing

### Unit tests

Basic scenarios in `pipe_test.go`: encode/decode, byte stuffing, empty packets, metrics,
goroutine races. Tests with `sync.Mutex`/`atomic` are run with the race detector:

```bash
make test
# equivalent to: go test -race ./...
```

### Parity tests with Python

The most important part — verifying that our HDLC encoding is compatible with the reference
implementation. In `parity_test.go` (build tag `integration`) the Go encoder sends frames to a
Python script that decodes them:

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

There's also the reverse test: Python encodes a frame, Go decodes it. And a full round-trip:
Go → Python → Go with binary payloads (`0x7E`, `0x7D`, and their combinations).

## Plans

The PipeInterface abstraction makes adding new transports an almost mechanical task: implement
reading/writing packets through the chosen channel, call `SetOnline` based on connection state —
and that's it.

Several transports are planned:

**Email transport** — tunneling Reticulum packets over SMTP/IMAP. Each packet is wrapped in an
email message, sent to a mail server, and read from the other side. This enables circumventing
censorship in regions where mainstream internet traffic is filtered but email still works.

**S3 transport** — object storage (AWS S3, MinIO, and similar) as an asynchronous packet relay.
Packets are written as objects with a known naming scheme; the receiver periodically reads and
deletes them. Suitable for store-and-forward over heavily filtered connections or asymmetric links.

The broader idea: PipeInterface is not just a convenient way to write a transport for rnsd, but
also a tool for implementing non-standard channels that would never make it into the official
Python code.

## Summary

**What was built:**

- A Python-compatible implementation of the PipeInterface protocol in pure Go
- Two reconnection modes (fixed delay and exponential backoff with jitter)
- A streaming HDLC decoder as an `io.Writer` — connects directly to `io.Copy`
- Metrics via atomic counters
- Two-bit online state: `pipeOnline` (rnsd side) + `transportOnline` (network side)

**What I learned:**

Exactly reproducing the behaviour of another implementation is its own challenge. The protocol
seems simple: flag byte, escape sequences. But details like "an empty frame is also delivered" or
"escape ESC before FLAG" only surface through careful code reading and parity tests.

The `ExitOnEOF`/`ErrPipeClosed` isolation for child-process mode is also non-obvious at first —
you need to understand the rnsd lifecycle before you can design the right interface.

**Project status:**

The library is stable, well-tested, and used in my own projects. Source code on GitHub:
[x3ps/go-rns-pipe](https://github.com/x3ps/go-rns-pipe). Version — v0.1.1. License — MIT.

```bash
go get github.com/x3ps/go-rns-pipe@v0.1.1
```
