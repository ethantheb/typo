# Agent control

Programs running in typo's terminals (agents, scripts, the user) control the window
they run in with `typo ctl <command>`: list and arrange panes, start terminals, open
files and diffs, run commands, write commit messages, restart typo, and drive and
look at the UI for testing. The user's decisions (unsaved changes, running programs)
stay the user's. Committing and pushing aren't offered: an agent runs git itself.

## Rules

- **Only from inside.** A request is answered only if it comes from a process
  running under one of the window's own terminals (local or pinned). This keeps
  agents to their own window and stops accidents; it is not a security boundary
  against the user's own programs (any of them could start a child under a typo
  shell, or run git itself), so it isn't hardened past that.
- **Never starts typo.** With no window to answer, a command fails with a message and
  a non-zero exit. `typo ctl` is handled before the command line's paths and before
  `forward_to_window`, so it never falls back to opening a window. `typo ctl restart`
  relaunches the window it came from.
- **The user decides.** Closing a file with unsaved changes or a terminal running a
  program, and restarting, go through the user's own flow. `restart` waits for it
  (cancelling replies `declined`); `close` replies that it is asking.
- **Hands off the user's focus.** Agent actions never focus a pane or raise the
  window unless asked (`focus`, `--focus`), so the user's typing stays where it was.
- **One action layer.** A request runs the code the UI runs (`run_command`,
  `pane_move` with a `Drop`, `panes_open_file_beside`, `git_commit`, ...), on the UI
  thread at the start of a frame.

## Command line

`typo ctl` marks a control command (a file named `ctl` opens as `./ctl`): a word, as
PowerShell reads a lone `@` as splatting. Output is JSON on stdout; errors are one
line on stderr.

```
typo ctl --skill                     the manual for agents (CONTROL_SKILL)
typo ctl ls                          panes, layout, focus, the caller's pane
typo ctl do <command> [--pane P]     a Command by its settings.toml key (allowed ones)
typo ctl open <path>[:line[:col]] [--at P --side S] [--focus]
typo ctl terminal [--pinned | --local] [--name N] [--at P --side S]
                  [--hidden] [--focus] [-- <command line>]
typo ctl move P (--side S --of Q | --edge S | --shelf)
typo ctl focus P | close P | maximize P | maximize --off
typo ctl rename P <name>             a terminal's name
typo ctl diff <path> [--staged] [--focus]
typo ctl git open | git message (<text> | -)
typo ctl restart [--exe <path>]      saves, relaunches in this project
```

Testing (see Testing below):

```
typo ctl wait idle [--timeout S]     until nothing animates, loads or waits
typo ctl screenshot [P] --out <file.png>
typo ctl click (<element id> | <x>,<y>) [--right | --double]
typo ctl drag <from> <to>            press, move over frames, release
typo ctl hover <element id | x,y>    the pointer rests there (tooltips)
typo ctl keys <chord>...             key chords, as settings.toml writes them
typo ctl type <text>                 text input
typo ctl ui <element id>...          where the last layout put them
typo ctl log [--lines N]             SDL's log and the dialogs shown
```

Panes (`P`, `Q`): `self` (the terminal the command runs in), `focused`, `p<id>` (from
`ls`, `Pane.id`: a window's own, so after a restart `ls` again) or the path of an
open file. Sides: `left`, `right`, `top`, `bottom` (right when none is given).

Exit codes: 0 done, 1 refused or failed (the message says why), 2 bad arguments,
3 no window to answer (none runs, or none has the caller's terminal), 4 the user
declined.

`ls`: each pane's id, kind (`editor`, `terminal`, `git`, `diff`), title, rect, and
whether it is shown, focused or maximized; an editor's path and unsaved state; a
terminal's pinned state and herdr address; a diff's path; the Git pane's message.
Also the split tree (axis, ratio, children), the shelf and the project's folder.

Pane commands run the UI's own procs: `open` is `pane_for_file` placed by
`place_beside` (or `--at`), at a line through `editor_when_ready`; `terminal` is
`panes_add_terminal` placed by `place_for` (a hidden one's shell starts once shown);
`diff` is `git_open_diff`, which opens in place of the editor in use as the Git
pane does; `close` is `pane_close`, which may start the unsaved-changes flow (the
reply says it's asking, without waiting).

`do` takes only commands that make sense without a person at the keys
(`DO_REFUSED`): not Copy, Paste or Cut (Paste into `self` would type the clipboard
into the agent), and not those that open something waiting for typing (Find,
Rename, Go_To_Line, Find_File, Open_Project, the symbol finders, Find_References).
`keys` isn't held to that list: it is for testing. With `--pane` the pane is
focused for it (with `pane_focus`'s side effects), and the focus put back unless
the command moved it or a pane is maximized. `focus` and `maximize` move the focus.

Requests and replies are at most `ipc.MAX_MESSAGE` (64 KB): a longer `type` is
refused by the command line, a longer reply (a big `log`) is an error.

## Console

typo.exe is a GUI program, and cmd and PowerShell don't wait for one: output comes
after the prompt and the exit code is lost, unless the output is piped (`| Out-String`
in PowerShell) or the shell is bash. Not built yet: typo also building as `typo.com`,
a console program from the same source, which cmd and PowerShell pick before
typo.exe (PATHEXT); it would handle `typo ctl` and forwarding `typo <file>` itself,
and start typo.exe for anything else.

## Protocol

Frames as in ipc/message.odin (a u32 length, then NUL-ended fields). Version 2's
fields are `"typo-ipc/2"` and one JSON object (`Control_Args`); the reply's are
`"typo-ipc/2"`, `"ok" | "error" | "declined" | "not_mine"` and a JSON object
(`message` for errors, the result otherwise). `typo <file>` keeps version 1. A
client that gets a version 1 reply (`Too_Old`) says that window's typo is older and
needs a restart. JSON strings are built with `json.marshal` or concatenated: Odin's
`fmt` reads `{` as a placeholder.

Version 2 clients wait for their reply without a limit (a restart waits for the
user's answer to the unsaved-changes flow); the send and the connect keep their
timeouts.

## Who is calling

The connection's thread takes the client's process id (`GetNamedPipeClientProcessId`)
and walks up its parents (a Toolhelp snapshot) until it reaches the shell of one of
the window's terminals. Each step needs the parent to have started before its child
(`GetProcessTimes`), since process ids are reused; a broken chain or a walk past
`CONTROL_MAX_ANCESTORS` refuses the request. The terminal found is `self`. Unix
has no walk yet (`conn_client_pid` and `process_ancestors` return nothing), so every
request there is `not_mine` (exit 3); it needs `SO_PEERCRED` or `LOCAL_PEERPID` and
parents from `/proc` or `sysctl`.

- Shell process ids come from `term.session_pid`: a local shell's from its pty, a
  pinned one's from herdr-core, known once attached and changing on a `restarted`
  event. A pinned terminal not attached yet (a restored one still on the shelf)
  can't control the window until it is.
- The list (pane id, shell pid) of terminals whose shell is alive is published
  under a mutex by the UI thread when it changes; the connection's thread does all
  the process lookups.
- A program that fully detaches from its shell has no chain back and is refused.
- Everything started from a window's local terminal runs under its shell, another
  typo window too (`typo -n`), whose own terminals then pass this window's check if
  they reach its endpoint. Fine for what the check is for.
- A pinned shell's `TYPO_IPC` names the project; each window showing it is tried
  newest first, and one without the caller's terminal answers `not_mine`, so the
  client tries the next. All `not_mine` is exit 3.

## Server

- A thread per connection (at most `MAX_CLIENTS`; over that, turned away).
- The connection's thread checks the caller, decodes the request (`job_prepare`:
  checks, and work off the UI thread such as restart's copy), queues it with an
  `ipc.Slot` and waits on the slot together with a pending 1-byte read on the
  connection, so a client that goes away is noticed (`slot_abandoned`) and the UI
  thread drops its request.
- `control_frame` (from `ipc_frame`, before `apply_pending_action`) applies one
  queued request a frame and fills its slot. Requests wait while the project loads
  or an action is pending; while the user is asked something (`user_asked`: a
  dialog or the unsaved-changes flow) queued ones are turned away at once
  (`turn_away_queued`), so none answers it for them and no client holds a
  connection waiting (`MAX_CLIENTS` is shared with `typo <file>`). `keys` stops
  pressing once one opens such a question. `click`, `wait` and `screenshot` take
  frames (`jobs.active`) and hold up the rest; `wait --timeout` counts from when the
  request arrived.
- `restart` carries its job in the unsaved-changes flow (`Restarting`); the flow's
  end answers it, and `unsaved_reset` declines it when dropped.
- `server_stop` ends waiting connections (their slots are abandoned) before joining.
- The UI thread only gathers what a reply needs (`control_ui` times its share,
  `control_limit` in the perf suite); a slot hands it over (`slot_data`: `ls`'s
  values, a screenshot's pixels) and the connection's thread encodes it (JSON, PNG).
  `log` doesn't reach the UI thread at all.

## Restart

`typo ctl restart` (from a pinned terminal only: a local shell, and the agent in it,
would end with the window; refused in a folder that isn't a project, which has no
session):

1. The window runs the unsaved-changes flow, with its own wording; cancelling replies
   `declined`.
2. It saves the session, detaches its pinned terminals and starts the new typo with
   `--after <pid> <project>` (it waits up to `AFTER_WAIT_MS` for this one), replies,
   and quits once the reply was sent (`Control_Call.after`: quitting would cut off
   an unsent reply). The executable is `--exe`, else the
   typo the client ran (the one installed, not the one the window runs from, which
   an install moves aside); it is first copied to `%LOCALAPPDATA%\typo\run\` and the
   copy runs, so neither the build folder's nor the installed typo.exe is held. The
   copy is made on the connection's thread before the window has checked the
   request, so a refused restart still makes it (the next one removes it).
3. The new typo waits for the old process to exit, opens the project and restores its
   session whatever `restore_session` says; pinned terminals reattach, the caller's
   among them.
4. The client waits (up to `RESTART_WAIT`) until a new window under the project
   answers for its terminal (it lists itself before it has reattached), so the
   agent's next command finds it.

## Testing

What a test needs from a running typo without a person: to act as the user does and
to see the result.

- `screenshot` reads the frame being drawn just before it is presented
  (`control_capture`, `sdl.RenderReadPixels`), all of it or a pane's rect (layout
  units times `gfx.scale`), whatever covers the window.
- `keys`, `type` and `click` feed input the way the perf suite does
  (`handle_key_event`, `g.mouse_pos` and the press flags), so they reach typo as a
  person's would and don't depend on the window having focus. A click takes frames:
  the pointer moves there first (Clay's pointer state is set before requests apply),
  then the button goes down, then up. Element ids are Clay's: "Name" or "Name:index".
- `wait idle` is answered at the end of a frame after it (`control_frame_end`) that
  would let the loop sleep (`g.sleeping`) with nothing animating; until then it
  wakes the loop for another frame, up to its timeout.
- `ui` gives where the last layout put the elements named (`element_rect`).
- `log` returns the last `LOG_LINES` of SDL's log (Clay errors and renderer problems
  go there; `control_log_init` keeps SDL's own output too) and the dialogs shown.

None of them change settings: a test that needs other settings starts a test
instance on a scratch `TYPO_SETTINGS`. The perf phase "typo ctl in the terminal"
(perf_control.odin) checks a terminal's request is answered as `self` and one from
outside is refused; `TYPO_PERF_PHASES=<text>` runs only the phases whose names
contain it.

## Agents finding it

Every shell typo starts has `TYPO_IPC`. `typo ctl --skill` prints a short manual for
agents (`CONTROL_SKILL`, control_cli.odin): the commands, pane references, exit
codes, the rules as they affect an agent, and the test loop (rebuild,
`restart --exe`, act, `wait idle`, `screenshot`). Keep it in step with the commands.
Not built yet: telling agents about it without being asked (a skill file installed
for them, asking first).
