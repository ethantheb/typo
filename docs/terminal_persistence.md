# Terminal persistence through herdr-core

Terminals whose shells keep running after typo quits, shown again (screen and
history) when the project is reopened. typo keeps drawing them with its own
libghostty-vt; herdr-core (`hc`, 0.1.19) runs the programs and keeps their
screens. Local (ConPTY/pty) terminals stay the default; a setting picks the
backend of new terminals.

## What herdr-core is

A per-user daemon (the "core") with holder processes that own the programs'
pseudo consoles. It keeps each terminal's screen and scrollback in its own
Ghostty terminal, so a viewer can attach at any time and get a repaint.
Clients speak JSON-RPC 2.0 to it (`hc schema` is the OpenRPC document).

### Reaching the core

- The core listens on a named pipe, `\\.\pipe\herdr-core-<user>-<session>.sock`
  on Windows (a Unix socket elsewhere). The name depends on the user name, the
  session (`HC_SESSION`), `HC_SOCKET` and the config's `socket`: herdr's
  business, not typo's.
- `hc connect` speaks the protocol over its stdin/stdout, resolving all of
  that, and starts the core when it isn't running (verified: a stopped core is
  started by `hc connect`, and keeps running after `hc connect` exits or is
  killed). `hc server status` never starts one on Windows; `hc server start`
  does. Other commands (`hc ls`) start it too.
- **Decision: typo talks through one `hc connect` child process** (no console
  window), with every stream multiplexed on its framed connection. More robust
  than opening the pipe: typo doesn't depend on herdr's pipe naming, session or
  config rules, gets core start-up for free, and works the same on Unix. Cost:
  one small extra process per typo.
- **The child must not be in a kill-on-close job.** A core started by
  `hc connect` inherits its job object (verified: in a job with
  KILL_ON_JOB_CLOSE, closing the job killed the core). typo's language servers
  live in such a job; `hc connect` doesn't, and is started with
  CREATE_BREAKAWAY_FROM_JOB when typo itself runs in a job that allows it. If
  typo dies, the child sees its stdin close and exits.
- Finding `hc`: PATH (`hc`, `herdr-core`), then the installer's folder
  (`%LOCALAPPDATA%\Programs\herdr-core\hc.exe`; `~/.local/bin/hc` elsewhere),
  looked up on the herdr thread, never on the UI thread.

### Framing

`hello {"generation": 1, "framed": true}` is sent as one JSON line; the reply
is a JSON line, and after it the connection is framed both ways:

```
u32 channel (little endian) | u8 kind | u32 length (little endian) | payload
```

Channel 0 carries JSON-RPC (one message per frame). Kinds, worked out by
proxying `hc attach` and by experiment (the schema names them but doesn't give
numbers):

| kind | name            | payload                                          |
|------|-----------------|--------------------------------------------------|
| 0    | DATA            | bytes (JSON on channel 0 and on an events channel) |
| 1    | CREDIT          | u32: bytes of DATA the receiver has consumed     |
| 2    | CLOSE           | empty from a viewer; from the core, JSON: `{exit_code, finished_ms, reason, signal}` |
| 3    | RESIZE          | u16 cols, u16 rows                               |
| 4    | FOCUS           | u8: 1 focused, 0 not                             |
| 5    | FACTS           | (not seen; ignored)                              |
| 6    | AUTOMATIC_INPUT | bytes a viewer's terminal sends on its own (query replies) |

Streams are flow-controlled: the viewer returns CREDIT for each DATA frame it
consumed (`hc attach` does so per frame). The core sends DATA in frames of at
most 16 KiB.

### Attaching

`terminal.attach {terminal, cols, rows, history, display, resize_notifications}`
returns `{channel, terminal, automatic_input, resize_notifications}`. Then:

- **The first paint**: DATA beginning with CAN, a soft reset and mode resets,
  `ESC[H ESC[2J`, the tab stops, then `history` lines of scrollback (all 3000
  lines of a test came back) and the screen, cursor and modes. After it, the
  program's raw output (ConPTY's on Windows) is passed through.
- **Resizing**: RESIZE from the viewer resizes the terminal; no repaint
  follows. The core's own Ghostty reflows with stock semantics: growing pulls
  scrollback down (verified), no ConPTY-style trimming. With no viewer the
  terminal returns to the headless size (200x120 by default); `size` in
  `terminal.run` is only the initial size.
- **Several interactive viewers**: the terminal takes the size of the viewer
  that typed last; others get neither a RESIZE nor a repaint
  (`resize_notifications` is granted to observers only). Size changes do show
  up as `size` events.
- **Input**: DATA is typed input; FOCUS reports focus; AUTOMATIC_INPUT carries
  replies a viewer's own terminal makes to queries, so the core can tell them
  from typing (it answers display queries itself from `display`).
- **End**: when the program exits, the core sends its last output, then CLOSE
  with `{exit_code, reason: "exited" | "killed" | ...}`. A finished terminal
  can't be attached (`finished` error) but `terminal.read` still returns its
  screen and history as plain text until `terminal.rm`.
- **Loss** (holder died, signal, host shutdown): the stream ends; a kept
  terminal (`keep`) gets a new shell after a grace delay and a `restarted`
  event, then can be attached again.
- **Core restart/update** (`hc server restart`): the connection drops; the
  terminals keep running and the next core adopts them. Reconnect, attach again.

### Events

`events.subscribe {labels}` returns `{channel, seq, terminals}`: a snapshot,
then `{"method": "event", "params": {type, terminal, seq, data}}` lines as DATA
on that channel (with credit), types created, lost, restarted, keep, finished,
removed, status, turn, title, labels, size, doc, plus `heartbeat` and `missed`.

### Finding terminals again

`terminal.run` returns an `address` (`t7`), stable for the life of the terminal
on that core. The core's identity (`core.id` in `hello`) is stable across
restarts. Labels are free-form `key=value` and filter `terminal.list` and
`events.subscribe`.

## Design in typo

### `herdr` package (src/herdr)

Standalone like `ipc` and `lsp` (imports only core):

- `frame.odin`: frame header encoding and an incremental frame reader.
- `protocol.odin`: requests' JSON and the decoded results typo uses
  (run, attach, read, close reasons, events).
- `client.odin`: the `Client`. Threads: a reader that starts `hc connect`,
  says hello, subscribes to typo's terminals' events and reads frames (and
  reconnects with a backoff when the connection drops), and a writer that
  drains a queue of frames, so the UI thread never blocks on a pipe. The UI
  thread only queues commands and takes finished results.
- A `Stream` per terminal: the bytes received for it (guarded by a mutex, read
  by the session's pump), whether the terminal must be reset before them (a new
  attach is a full repaint), and its state: starting, attached, lost, ended
  (exit code), gone. The client re-attaches streams after a reconnect, after a
  `restarted` event, and after another viewer resized the terminal and typo got
  it back (so typo's screen matches the core's again).
- `process_*.odin`: starting `hc connect` (pipes, no window, outside jobs) and
  finding `hc`.

### `term`: a session's backend

`term.Session` = libghostty-vt + a backend. The backend is where output comes
from and where input, resizes and focus go: `Local` (pty + reader thread, as
before) or `Herdr` (a `herdr.Stream`). Rendering, the row cache, find,
scrollback, selection and input encoding don't know which. The few places that
differ are in session.odin's backend procs (spawn/attach, write, resize, kill
or detach, pump's source).

Resize semantics are ConPTY's for both backends on Windows (no scrollback
pulled on grow, reflow trims trailing spaces, patches/ghostty.patch). The live
stream from herdr-core is its ConPTY's raw output, whose cursor positions refer
to ConPTY's screen, so typo's screen must resize as ConPTY's does: with
Ghostty's defaults the shell drew on the wrong row after a terminal was made
shorter, or narrower and wider again (test_remote_resize_keeps_rows). Only the
repaint sent on attach is herdr-core's own terminal, which reflows with
Ghostty's defaults: after resizes while typo wasn't attached, that repaint can
differ from ConPTY's screen until the shell redraws (worth raising with
herdr-core: its terminal on Windows would want the same semantics).
Replies typo's terminal makes to queries go back as AUTOMATIC_INPUT.

### The app

- Setting `terminal_backend`: "local" (default) or "herdr" (persistent). The
  settings row says when herdr-core isn't found. A new terminal with "herdr"
  while it isn't found starts locally and says so in its first line.
  Existing terminals keep their backend; Restart keeps it too.
- A herdr terminal is started with `outlive_parent`, `no_parent`, `no_notify`,
  `keep`, labels `typo=1`, `typo.project=<root>`, the shell and folder local
  terminals get, typo's shell environment, and `size`/`display` from the pane.
- Quitting typo detaches (the shells go on). Closing the pane kills and
  removes its herdr terminal, without a question, as closing a local terminal
  ends its shell. Restart kills it and starts another.
- The session's terminal entries keep the herdr address and core id; opening
  the project again attaches each with its history (`HISTORY_LINES`).
- A terminal that ended while typo was closed shows its last screen and
  history (plain text, from `terminal.read`) under an "ended" note with its
  exit code, and Enter starts a new shell, as when a local shell exits; the
  finished terminal is then removed from herdr. Chosen over a fresh shell
  because the output of what ran is usually why the terminal was kept. One
  that is gone (removed elsewhere, or another core) says so; Enter starts a
  new one.
- Lost attach: streams re-attach after a reconnect or a `restarted` event.

### `typo <file>` from a persistent shell

`TYPO_IPC` names one typo process's pipe, which is gone once typo restarts
while the shell lives on. Persistent shells get instead
`TYPO_IPC=project:<hash>`, a stable name for the project (a hash of its
folder). Each typo window registers its endpoint for the project it shows in a
per-user folder (`%LOCALAPPDATA%\typo\ipc\<hash>\<pid>` on Windows, the
user's 0700 runtime folder elsewhere): a file holding its endpoint. `typo
<file>` with a project name reads that folder, newest first, and sends to the
first endpoint that answers, through the same checks as before (a name typo
makes, served by the process the name gives, a DACL for the current user
only). The registry is only readable and writable by the user (it is inside
the user's profile, or a 0700 folder), so it adds no new way in; a stale entry
(typo crashed) fails the endpoint check and is skipped and cleaned up.

### Threads and limits

All networking, JSON and process work is on the herdr threads. The UI thread
takes finished results in `herdr_frame` and moves a stream's bytes into the
terminal within the pump's budget, as for local terminals. `herdr.timed`
marks the UI thread's share, which the perf suite limits per frame
(`herdr_limit`).

### Testing

Unit tests: frames, requests and results (herdr package). An integration test
and a perf phase run against a private herdr-core session (`HC_SESSION` and
scratch XDG paths) when `hc` is installed and skip, saying why, when it isn't:
a terminal is started, its output drawn, typo's side detached, the terminal
attached again, and the screen and history checked, then read back from a
real frame. They stop their session's core and remove its folder at the end.

## What herdr-core doesn't give us (yet)

- No repaint or notification for an interactive viewer when another viewer
  changes the size; typo re-attaches when it gets the terminal back.
- No per-terminal headless size: with typo closed a terminal is 200x120, so
  its history is rewrapped there and back.
- `terminal.read` of a finished terminal is plain text: an ended terminal's
  last screen comes back without colors.
- No way to ask whether another viewer is attached, so typo doesn't adopt
  labeled terminals missing from its session (another window may show them).
