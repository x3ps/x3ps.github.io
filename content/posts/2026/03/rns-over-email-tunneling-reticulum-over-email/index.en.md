---
title: "rns-over-email: Tunneling Reticulum over Email"
date: 2026-03-21
draft: false
toc: true
description: "An email transport for Reticulum: SMTP for outbound, IMAP for inbound, alpha release open for testing."
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

## Where this came from

In the [previous article about go-rns-pipe](/posts/2026/03/writing-a-go-library-for-reticulum-go-rns-pipe/)
I wrote about a Go library for Reticulum's PipeInterface protocol. The "Plans" section there included:

> **Email transport** — tunneling Reticulum packets over SMTP/IMAP. Each packet is wrapped in an
> email, sent to a mail server, and read out on the other side.

Here it is — [rns-over-email](https://github.com/x3ps/rns-over-email). It's an rnsd PipeInterface
subprocess that forwards RNS packets over ordinary email.

The project is in **alpha status**. The basic data flow works, but the edges are unevenly worn:
only a **local mail server** (a Docker container like Mailpit) has been tested —
real SMTP/IMAP rate limits at Gmail, Fastmail, Proton Mail and similar services are **unknown**.
UID checkpoints don't survive restarts. Looking for testing and feedback.

## Why tunnel Reticulum over email

Email is one of the few protocols that works almost everywhere. Where VPNs, messengers, and
non-standard ports are blocked, SMTP/IMAP often remain accessible — ISPs and corporate networks
are forced to allow them.

Reticulum is designed so it doesn't matter what carries the packets: LoRa, TCP, serial, or email.
The transport is fully hidden behind PipeInterface. All that's needed is to deliver bytes back and
forth. Email handles that, albeit slowly.

Slowly is the key word. An email transport suits data that doesn't need low latency:
store-and-forward message sync, node announcement replication, file transfers over Reticulum LXMF.
Not for voice or real-time chat.

## Architecture

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
            └───── network ───── remote peer
                                (your copy of
                              rns-over-email)
```

One process — one peer. This is a **linear model**: each `rns-over-email` instance knows exactly
one destination address (`--peer-email`). To connect to multiple peers, run multiple instances,
each described by its own `[[PipeInterface]]` block in the rnsd config.

This approach keeps the implementation simple and isolated: a problem with one peer doesn't affect
the others.

## Data flow

### Outbound: RNS → MIME → SMTP

1. rnsd writes an HDLC frame to the process's stdin.
2. `go-rns-pipe` decodes the frame and extracts the raw RNS packet.
3. The packet is serialized into a MIME email with a unique `Message-ID` and sent over SMTP.
4. The email is delivered to the SMTP server with exponential backoff: 1s → 2s → 4s.
5. After 5 consecutive failed sends, an `error`-level log entry is written.

**MIME email structure:**

- `From:` / `To:` — own and peer addresses
- `Message-ID:` — `<uuid@smtp-from-domain>`, UUID v4 guarantees uniqueness; MTAs and IMAP servers
  may deduplicate by it — which works in our favor (RNS deduplicates on top of that anyway)
- `Content-Type: application/octet-stream` for an attachment carrying the binary RNS packet body
  (base64 per the MIME standard)

Emails are assembled using `github.com/emersion/go-message` (v0.18.2) — the same ecosystem as
go-imap/v2, which simplifies MIME handling.

The delivery model is **best-effort, at-most-once**. Losing a packet at this layer is normal:
the RNS Link and Resource layers have their own ACKs and retransmission. `rns-over-email` makes
no attempt to recover lost packets — that's Reticulum's job.

### Inbound: IMAP → decode → RNS

1. The IMAP worker connects to the server and, if the server supports IMAP IDLE, waits for push
   notifications. Otherwise it polls the mailbox periodically (default: every 60 seconds).
2. New emails are filtered by `From:` — only emails from `--peer-email` are accepted; the rest
   are ignored.
3. The attachment is decoded back into the raw RNS packet bytes.
4. The packet is passed to rnsd via `Receive()` (stdout).
5. The processed UID is saved as a checkpoint and won't be read again.

**IMAP IDLE details:**

- The client sends the `IDLE` command; the server keeps the connection open and sends `* N EXISTS`
  when a new email arrives — true push with no polling.
- Without IDLE (fallback): `SELECT INBOX` + `SEARCH UID > last_uid` + `FETCH` every poll interval.
- An IDLE connection needs periodic keep-alives: RFC 2177 recommends reconnecting at least every
  29 minutes. go-imap/v2 handles this transparently.

A decoding error does not delete the email — it stays in the mailbox for manual inspection.

### IMAP UID checkpoints

Each read email is tracked by UID. On the next poll, only emails with a UID above the last
processed one are fetched. The checkpoint is stored in memory — **it does not survive process
restarts**. This is a known alpha limitation: after a restart some emails may be processed again,
which is safe (RNS deduplicates at its layer) but wasteful.

## Delivery model

| Scenario | Behavior |
| --- | --- |
| SMTP server unreachable | Exponential backoff: 1s, 2s, 4s; then the packet is dropped |
| 5+ consecutive send failures | `error`-level log entry |
| IMAP decode failure | Email is not deleted; error is logged |
| Duplicate packet | RNS layer deduplicates |
| Process restart | UID checkpoint is reset; reprocessing is safe |

## Configuration

### CLI flags and environment variables

Every flag has an equivalent environment variable with the `RNS_EMAIL_` prefix.

**SMTP (outbound):**

| Flag | Variable | Default |
| --- | --- | --- |
| `--smtp-host` | `RNS_EMAIL_SMTP_HOST` | — |
| `--smtp-port` | `RNS_EMAIL_SMTP_PORT` | `587` (STARTTLS) |
| `--smtp-username` | `RNS_EMAIL_SMTP_USERNAME` | — |
| `--smtp-password` | `RNS_EMAIL_SMTP_PASSWORD` | — |
| `--smtp-password-file` | `RNS_EMAIL_SMTP_PASSWORD_FILE` | — |
| `--smtp-from` | `RNS_EMAIL_SMTP_FROM` | — |

**IMAP (inbound):**

| Flag | Variable | Default |
| --- | --- | --- |
| `--imap-host` | `RNS_EMAIL_IMAP_HOST` | — |
| `--imap-port` | `RNS_EMAIL_IMAP_PORT` | `993` (TLS) |
| `--imap-username` | `RNS_EMAIL_IMAP_USERNAME` | — |
| `--imap-password` | `RNS_EMAIL_IMAP_PASSWORD` | — |
| `--imap-password-file` | `RNS_EMAIL_IMAP_PASSWORD_FILE` | — |
| `--imap-poll-interval` | `RNS_EMAIL_IMAP_POLL_INTERVAL` | `60s` |

**Peer and misc:**

| Flag | Variable | Default |
| --- | --- | --- |
| `--peer-email` | `RNS_EMAIL_PEER` | — |
| `--mtu` | `RNS_EMAIL_MTU` | `500` |

Passwords passed via CLI flags will show up in `ps aux`. Use `--*-password-file` or environment
variables in production.

### rnsd config

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

On Alice's side — the mirror configuration with `--peer-email bob@example.com`.

## Installation

### go install

```bash
go install github.com/x3ps/rns-iface-email/cmd/rns-over-email@latest
```

### Prebuilt binaries

The [Releases](https://github.com/x3ps/rns-over-email/releases) page has binaries for:

- Linux: amd64, arm64
- macOS: amd64, arm64
- Windows: amd64, arm64

### Build from source

```bash
git clone https://github.com/x3ps/rns-over-email
cd rns-over-email
go build ./cmd/rns-over-email
```

## Dependencies

The project is built on three external packages:

- **[go-imap/v2](https://github.com/emersion/go-imap)** — IMAP client with IDLE support
- **[go-smtp](https://github.com/emersion/go-smtp)** — SMTP client with STARTTLS/TLS
- **[go-rns-pipe](https://github.com/x3ps/go-rns-pipe)** (v0.1.1) — HDLC framing and PipeInterface

`go-rns-pipe` is the library from the [previous article](/posts/2026/03/writing-a-go-library-for-reticulum-go-rns-pipe/).
`rns-over-email` is the library's first production user.

Plus `github.com/google/uuid` for `Message-ID` generation.

## Plans

### E2E tests with Greenmail

Currently only unit tests exist; there are no integration tests (real SMTP/IMAP round-trip).
[Greenmail](https://greenmail-mail-test.github.io/greenmail/) — an embeddable SMTP/IMAP server for
tests — will allow running the full outbound→inbound cycle without external mail. This is the next
step toward reliability.

### POP3 (maybe)

An alternative to IMAP for inbound — POP3 is simpler to implement, but has no IDLE and no proper
UID support. Will depend on feedback: are there real servers where IMAP is unavailable but POP3 is
not?

### Multipeer — a deliberate non-feature

Multipeer mode (one process, multiple `--peer-email`) was considered and rejected.
The reason: the linear model is simpler and more isolated — each peer lives in its own process,
and a problem with one doesn't affect the others.

The right approach: **run multiple instances** of the binary with different `--peer-email` values,
each described by its own `[[PipeInterface]]` block in the rnsd config (see the
[rnsd config](#rnsd-config) section above).

## Alpha: looking for testing and feedback

The project is real and working, but young. What I'd particularly like to verify:

- **Mail server compatibility** — only tested against a local Docker server (Mailpit).
  Fastmail, Gmail, Proton Mail (via bridge), corporate Exchange — curious how they behave.
- **Rate limits** — real SMTP/IMAP rate limits at public providers are unknown. Under heavy
  traffic you might hit limits on connection counts or emails per hour.
- **IMAP IDLE** — some servers formally advertise IDLE but implement it poorly.
  If the fallback polling kicks in where it shouldn't — that's worth knowing.
- **Performance** — what's the real throughput at a 60s poll interval? What's the latency in a
  "messenger over LXMF over rns-over-email" scenario?
- **Edge cases in configuration** — what happens on password change, session expiry,
  or a full IMAP inbox.

If you try it — let me know how it went:

- **GitHub Issues**: [x3ps/rns-over-email/issues](https://github.com/x3ps/rns-over-email/issues)
- **Matrix**: `@x3ps:matrix.org`
- **Email**: see the profile on GitHub

Any feedback is useful: "works on Fastmail" is already good. "Crashes here" is even better.
