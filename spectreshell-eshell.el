;;; spectreshell-eshell.el --- eshell integration for spectreshell -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Shinnosuke Sawada-Dazai

;; Author: Shinnosuke Sawada-Dazai <shin@warashi.dev>
;; Keywords: terminals, processes
;; Version: 0.0.1
;; URL: https://github.com/Warashi/emacs-spectreshell
;; Package-Requires: ((emacs "31.1"))

;; This file is part of emacs-spectreshell, and is distributed under
;; the MIT License; see LICENSE for details.

;;; Commentary:

;; `spectreshell-eshell-mode' wires eshell's own external-process machinery
;; (esh-proc.el's `eshell-gather-process-output') into the
;; eshell-independent rendering core in spectreshell.el, the same way
;; `eat-eshell-mode' wires eat's terminal into eshell.  See docs/design.org's
;; "eshell 統合 (spectreshell-eshell.el)" section for the rationale.
;;
;; Only the pipeline stage whose output eshell would otherwise write
;; straight to the buffer for interactive display -- the last stage of a
;; pipeline, or the whole command when it isn't piped at all
;; (`eshell-interactive-output-p') -- gets attached to a terminal.  Earlier
;; pipeline stages keep talking to the next stage the way eshell always
;; has (a plain pipe, relayed through `process-send-string'); they have no
;; screen of their own to render.

;;; Code:

(require 'esh-proc)
(require 'esh-mode)
;; Only to reach `eshell-visual-command-p' below, so it is guaranteed to
;; exist by the time `spectreshell-eshell-mode' first runs regardless of
;; when the first eshell buffer (which is what normally loads eshell's
;; optional modules, `eshell-term' included) gets created; loading the
;; file does not by itself turn the module on for any buffer (that also
;; needs `eshell-term' in `eshell-modules-list', per em-term.el), so this
;; is harmless even for users who have disabled it.
(require 'em-term)
(require 'spectreshell)

(defgroup spectreshell-eshell nil
  "Integration of spectreshell with eshell."
  :group 'spectreshell
  :prefix "spectreshell-")

;; ---------------------------------------------------------------------
;; Bundled terminfo detection
;; ---------------------------------------------------------------------

(defconst spectreshell--terminfo-candidate-subdirs
  '(;; A local `zig build'/`just build' checkout: `spectreshell.el' loads
    ;; from the repository root, and `build.zig' installs terminfo next
    ;; to the module under `zig-out'.
    "zig-out/share/terminfo"
    ;; The nix package layout: `spectreshell.el' loads from
    ;; "$out/share/emacs/site-lisp", two levels up from which is
    ;; "$out/share", the sibling of "$out/share/terminfo".
    "../../terminfo")
  "Directories to probe for a bundled terminfo database.
Each is relative to the directory `spectreshell.el' (this library) was
loaded from; see `spectreshell--detect-terminfo-directory'.")

(defun spectreshell--detect-terminfo-directory ()
  "Return a directory holding spectreshell's bundled terminfo database, or nil.
Probes `spectreshell--terminfo-candidate-subdirs' relative to wherever
`locate-library' says `spectreshell.el' itself was loaded from, and
returns the first one that exists as a directory.  Returns nil if
`spectreshell.el' cannot be located (should not normally happen, since
this file requires it) or none of the candidates exist -- e.g. a `zig
build' that has not installed anything yet, or a manual/non-nix install
that only copied the .el files and the module."
  (when-let* ((lib (locate-library "spectreshell"))
              (dir (file-name-directory lib)))
    (seq-find #'file-directory-p
              (mapcar (lambda (rel) (expand-file-name rel dir))
                      spectreshell--terminfo-candidate-subdirs))))

(defcustom spectreshell-term-name "xterm-ghostty"
  "TERM value spectreshell exports for eshell's external processes.
Defaults to \"xterm-ghostty\", the name of spectreshell's own bundled
terminfo entry (ghostty-vt's actual capabilities, since the entry is
ghostty's own -- see `spectreshell-terminfo-directory'), so that child
processes see an accurate capability set instead of settling for
whatever a generic xterm entry happens to also cover.

If, at load time, no bundled terminfo database could be found
\(`spectreshell-terminfo-directory' is nil) *and* this variable still has
its default value, spectreshell exports \"xterm-256color\" instead --
a value practically every system already has terminfo for -- so that
child processes do not fail to look up an unknown TERM.  Customize this
variable to any other value (including \"xterm-ghostty\" itself, set
explicitly) to opt out of that fallback, e.g. because a matching
terminfo entry is installed system-wide even though spectreshell could
not find its own copy."
  :type 'string)

(defcustom spectreshell-terminfo-directory (spectreshell--detect-terminfo-directory)
  "Directory added to TERMINFO for eshell's external processes, or nil.
Auto-detected when this library loads by
`spectreshell--detect-terminfo-directory', which recognizes both a
local `zig build' checkout's `zig-out/share/terminfo' and the nix
package's `$out/share/terminfo' layout.  Nil means no bundled terminfo
database was found (see `spectreshell-term-name' for the TERM value
fallback this implies); set this explicitly if you installed one
somewhere spectreshell cannot guess, or to nil to force that fallback
even when a database was in fact auto-detected."
  :type '(choice (const :tag "Do not set TERMINFO" nil) directory))

;; ---------------------------------------------------------------------
;; Per-buffer terminal/process bookkeeping
;; ---------------------------------------------------------------------

(defvar-local spectreshell-eshell--terminals nil
  "Alist of (PROCESS . TERMINAL) for every job rendering into this buffer.
A buffer can host several at once: a job started with an `&' leaves a
background job drawing into a terminal region of its own while eshell
goes back to reading the command line, and the next foreground job then
gets a second region below it.  Each entry is added by
`spectreshell-eshell--attach' and removed by
`spectreshell-eshell--detach'; the pairing is what
`spectreshell-eshell--window-size-change' needs, since
`spectreshell-resize' takes the `spectreshell' struct while
`set-process-window-size' takes the process object and neither one
holds a reference to the other.")

(defvar-local spectreshell-eshell--process nil
  "The process `spectreshell--current' (if any) in this buffer is attached to.
That is the *foreground* job's process: `spectreshell--current' names
the terminal keys go to, and only a foreground job has a claim on the
keyboard.  Kept in lockstep with `spectreshell--current' by
`spectreshell-eshell--attach'/`spectreshell-eshell--detach'.")

;; ---------------------------------------------------------------------
;; Terminal geometry
;; ---------------------------------------------------------------------

(defun spectreshell-eshell--window (buffer)
  "Return the window whose size BUFFER\='s spectreshell terminals follow, or nil.
A buffer can be on screen more than once, in windows of different
sizes, but a terminal has exactly one size; this function is the single
rule that picks which window wins, applied both when a terminal is
created (`spectreshell-eshell--terminal-size') and whenever the layout
changes afterwards (`spectreshell-eshell--window-size-change'), so that
the two can never disagree.

The rule is `get-buffer-window-list\='s first entry across all frames,
which its docstring defines as the selected window whenever that window
shows BUFFER at all.  So the terminal fits whichever window the user is
actually typing into, and only falls back to an arbitrary-but-stable
choice when they are elsewhere entirely -- rather than following
whichever window redisplay happened to notify about last, which is what
the size ends up being when each notification is honored on its own."
  (car (get-buffer-window-list buffer nil t)))

(defun spectreshell-eshell--terminal-size (buffer)
  "Return (ROWS . COLS) for a new spectreshell terminal in BUFFER.
Prefers `spectreshell-eshell--window\='s window for BUFFER:
`window-body-height' and `window-max-chars-per-line' are exactly the
visible terminal cell counts a real terminal would report via
TIOCGWINSZ.  Falls back to the selected frame's size when BUFFER has no
window yet (e.g. a job started into a buffer that isn't displayed
anywhere), and to a plain 80x24 under `noninteractive' (batch Emacs, as
ERT runs under), where frame dimensions do not correspond to anything a
user could see."
  (if-let* ((window (spectreshell-eshell--window buffer)))
      (cons (window-body-height window) (window-max-chars-per-line window))
    (if noninteractive
        (cons 24 80)
      (cons (frame-height) (frame-width)))))

(defun spectreshell-eshell--window-size-change (_window)
  "Resize every spectreshell terminal in this buffer to its window.
Every terminal in the buffer follows the same window, the one
`spectreshell-eshell--window' picks, so a background job left at the
old size would keep wrapping its output at a width nothing on screen
has.  The notified WINDOW is deliberately ignored in favor of that
rule: redisplay calls this once per window showing the buffer, so
honoring each notification on its own would leave the terminal at
whichever window came last.
Buffer-local member of `window-size-change-functions' and
`window-buffer-change-functions' (the latter covers a buffer being
\(re)displayed in an existing window without any size change -- e.g. a
job attached while the buffer was buried, then brought back with
`switch-to-buffer'), both added by `spectreshell-eshell--attach'.  Left
in place after the last terminal it was added for finalizes
\(`spectreshell-eshell--detach' does not remove it): an empty
`spectreshell-eshell--terminals' then makes every subsequent call of
this a no-op, which is cheaper than tracking add/remove state across
however many jobs run in this buffer over its lifetime.

A window with no body at all (either measurement 0, which is what a
window narrowed down to a single column reports for its width) is
skipped and the terminals keep the size they had.  There is no
terminal to resize *to* -- `spectreshell-start' rejects a zero
dimension -- and signaling from here is worse than doing nothing:
`window-size-change-functions' runs inside redisplay, which mutes the
error, so the terminal would silently stay at its old size while the
pty had already been told the new one."
  (when-let* ((window (spectreshell-eshell--window (current-buffer)))
              (rows (window-body-height window))
              ((> rows 0))
              (cols (window-max-chars-per-line window))
              ((> cols 0)))
    (pcase-dolist (`(,proc . ,obj) spectreshell-eshell--terminals)
      (unless (and (= rows (spectreshell-rows obj)) (= cols (spectreshell-cols obj)))
        (spectreshell-resize obj rows cols)
        (set-process-window-size proc rows cols)))))

;; ---------------------------------------------------------------------
;; Attach / detach
;; ---------------------------------------------------------------------

(defun spectreshell-eshell--attach (proc size background)
  "Start a spectreshell terminal for PROC and take over its buffer I/O.
Called right after `eshell-gather-process-output' creates PROC, when
`eshell-interactive-output-p' said PROC is the pipeline stage whose
output is headed for interactive display.  Replaces PROC's filter and
sentinel (installed for the plain, non-terminal-emulating case by
`eshell-gather-process-output' itself).

BACKGROUND is `eshell-current-subjob-p' as it stood at that call, i.e.
non-nil for a job started with `&'.  Such a job gets a terminal region
and a redraw of its own but nothing else: it does not become
`spectreshell--current' and does not turn on
`spectreshell-semi-char-mode', so eshell keeps the keyboard and the
command line stays usable while it runs.  Its terminal is also started
COMPACT, so that its region does not push eshell's prompt a screenful
down the moment it prints its first line.  (Interactive input to a
background job is out of scope; a real shell would stop it on SIGTTIN
instead.)  A foreground job takes both, for as long as it runs.

SIZE is the
\(ROWS . COLS) `spectreshell-eshell--gather-process-output-advice' already
computed and had `spectreshell-eshell--wrap-command-for-pty' give PROC's
pty via `stty' before exec'ing the real command, reused here (rather
than measured again) so the terminal spectreshell creates always
matches the size the child's very first ioctl already saw."
  (when-let* ((buffer (process-buffer proc))
              ((buffer-live-p buffer)))
    (with-current-buffer buffer
      ;; `spectreshell-start' anchors the terminal region at point, which
      ;; must therefore be exactly where PROC's first output byte belongs;
      ;; `eshell-gather-process-output' always leaves the buffer's point at
      ;; that position right after creating PROC, but pin it explicitly
      ;; rather than relying on that undocumented ordering.
      (goto-char (point-max))
      (pcase-let* ((`(,rows . ,cols) size)
                   (obj (spectreshell-start
                         buffer rows cols
                         ;; The final feed can still carry :responses
                         ;; (e.g. a DSR reply) after PROC already died;
                         ;; writing to a dead process would signal from
                         ;; inside the process filter.
                         (lambda (bytes)
                           (when (process-live-p proc)
                             (process-send-string proc bytes)))
                         background)))
        (process-put proc 'spectreshell-eshell-terminal obj)
        ;; PROC's output must reach `spectreshell-feed' as exact raw bytes
        ;; (docs/module-api.org) and PROC's input (encode-key/encode-paste/
        ;; response bytes, all already-encoded unibyte strings) must reach
        ;; PROC unchanged; only `no-conversion' guarantees both directions
        ;; skip Emacs's usual coding-system decode/encode step entirely.
        (set-process-coding-system proc 'no-conversion 'no-conversion)
        (set-process-filter proc #'spectreshell-eshell--filter)
        (set-process-sentinel proc #'spectreshell-eshell--sentinel)
        (set-process-window-size proc rows cols)
        (push (cons proc obj) spectreshell-eshell--terminals)
        (add-hook 'window-size-change-functions
                   #'spectreshell-eshell--window-size-change nil t)
        (add-hook 'window-buffer-change-functions
                   #'spectreshell-eshell--window-size-change nil t)
        (unless background
          (setq spectreshell--current obj
                spectreshell-eshell--process proc)
          (spectreshell-semi-char-mode 1))))))

(defun spectreshell-eshell--detach (proc)
  "Finalize PROC's spectreshell terminal and, for a foreground job, leave semi-char.
Called from `spectreshell-eshell--sentinel' once PROC is no longer
live.  Idempotent (PROC's `spectreshell-eshell-terminal' property is
cleared on first use) because a process sentinel can run more than
once for the same process.

A background job's exit touches neither `spectreshell--current' nor
`spectreshell-semi-char-mode' nor `eshell-last-output-end': all three
belong to whatever eshell is doing in the foreground, which is either a
running job whose keyboard must not be taken away mid-command, or a
command line whose half-typed input the next `eshell-send-input' still
has to read back.

`spectreshell-mode' itself goes away only once the *last* terminal in
this buffer has, whichever kind of job owned it: its keymap\'s sole
binding re-enters `spectreshell-semi-char-mode', which is meaningless
-- and silently swallows every key, since `spectreshell-send-key' has
no terminal to send to -- with nothing left running.  Turning it off
per foreground job instead would take that entry point away from a
background job still drawing into the buffer."
  (when-let* ((obj (process-get proc 'spectreshell-eshell-terminal)))
    (process-put proc 'spectreshell-eshell-terminal nil)
    (if (buffer-live-p (spectreshell-buffer obj))
        (with-current-buffer (spectreshell-buffer obj)
          (setq spectreshell-eshell--terminals
                (assq-delete-all proc spectreshell-eshell--terminals))
          (let ((foreground (eq spectreshell--current obj))
                (end (spectreshell-finalize obj)))
            (when foreground
              ;; `spectreshell-eshell--filter' bypasses eshell's own
              ;; output path entirely (`eshell-insertion-filter'/
              ;; `eshell-interactive-process-filter'), the only code that
              ;; normally advances `eshell-last-output-end'; without this,
              ;; `eshell-sentinel''s prompt (run right after this function
              ;; returns) would land wherever that marker was last left --
              ;; i.e. right before the terminal region, not after it.
              ;; Repinned right here, while END is still current: a
              ;; background job writing into its own region above would
              ;; otherwise shift the text END names out from under it.
              (set-marker eshell-last-output-end end)
              (setq spectreshell--current nil
                    spectreshell-eshell--process nil)
              (spectreshell-semi-char-mode -1)))
          (unless spectreshell-eshell--terminals
            (spectreshell-mode -1)))
      ;; The buffer was killed while PROC was still running: there is
      ;; nothing left to finalize *into*, so just release the module
      ;; terminal directly instead of leaving it for the GC finalizer.
      (spectreshell--release (spectreshell-term obj)))))

;; ---------------------------------------------------------------------
;; Filter / sentinel
;; ---------------------------------------------------------------------

(defun spectreshell-eshell--filter (proc bytes)
  "Feed BYTES from PROC into its spectreshell terminal.
Installed as PROC's process filter in place of eshell's own
`eshell-interactive-process-filter': BYTES is already the raw byte
stream (`spectreshell-eshell--attach' forced `no-conversion'), and
`spectreshell-feed' writes the decoded, decorated result straight into
PROC's buffer itself, so there is nothing left for eshell's own output
machinery to do with it."
  ;; The terminal property check also covers the (rare) case of output
  ;; delivered after `spectreshell-eshell--detach' already cleared it;
  ;; feeding a nil terminal would signal from inside the filter.
  (when-let* (((buffer-live-p (process-buffer proc)))
              (obj (process-get proc 'spectreshell-eshell-terminal)))
    (spectreshell-feed obj bytes)))

(defun spectreshell-eshell--sentinel (proc string)
  "Finalize PROC's spectreshell terminal, then run `eshell-sentinel'.
Installed as PROC's process sentinel in place of plain `eshell-sentinel'
by `spectreshell-eshell--attach', so that the terminal region is frozen
into ordinary buffer text (and semi-char mode turned off) before
`eshell-sentinel' prints eshell's next prompt below it.  STRING is
passed through unchanged; PROC's actual bookkeeping (removing it from
`eshell-process-list', closing handles, recording the exit status
`eshell-cmd.el' reads back, ...) is still entirely `eshell-sentinel''s
job."
  (unwind-protect
      (unless (process-live-p proc)
        (spectreshell-eshell--detach proc))
    ;; `eshell-sentinel' must run even if detach signals: skipping it would
    ;; leave PROC in `eshell-process-list' forever and eshell stuck
    ;; believing the command is still running.
    (eshell-sentinel proc string)))

;; ---------------------------------------------------------------------
;; `eshell-gather-process-output' / `make-process' advice
;; ---------------------------------------------------------------------

(defvar spectreshell-eshell--want-pty nil
  "Non-nil while the `make-process' advice should force a pty connection.
Let-bound around the one `eshell-gather-process-output' call that will
own the terminal (docs/design.org's \"only the pipeline stage with a
screen of its own\" simplification); left nil for every other
concurrent pipeline stage, which keeps talking to the next stage over
whatever plain pipe eshell itself set up.")

(defvar spectreshell-eshell--pty-size nil
  "The (ROWS . COLS) to give the child's pty via `stty'.
Only consulted while `spectreshell-eshell--want-pty' is non-nil.
Let-bound alongside it by
`spectreshell-eshell--gather-process-output-advice', from the same
measurement `spectreshell-eshell--attach' goes on to use for the
terminal itself.")

(defun spectreshell-eshell--force-pty-output (connection-type)
  "Return CONNECTION-TYPE with its output side forced to `pty'.
CONNECTION-TYPE is a `make-process' :connection-type value (nil, `pipe',
`pty', or an (INPUT . OUTPUT) cons, per its docstring).  The input side
is left exactly as eshell chose it: spectreshell only ever needs its
own writes, via `process-send-string', to reach the child, never real
terminal typing on that side."
  (cons (if (consp connection-type) (car connection-type) connection-type)
        'pty))

(defun spectreshell-eshell--wrap-command-for-pty (command rows cols)
  "Return a `make-process' :command list that sanitizes PROC\'s pty first.
COMMAND is the original (PROGRAM . ARGS) list.  A pty Emacs itself just
opened for a subprocess defaults to `-echo -onlcr' (checked directly
with `stty -a' against one), unlike a real terminal\'s; under correct
VT100 semantics that turns even completely ordinary newline-terminated
output -- i.e. most Unix programs, which rely on the tty driver\'s
ONLCR to turn a bare LF into a proper new line -- into a staircase.
So exec through a tiny `/bin/sh -c' wrapper that runs `stty' first:
`sane' restores the full standard mode set (ONLCR included), and
ROWS/COLS are set in the same call so the child\'s very first ioctl
already sees the right size.  (cf. `term-exec-1' in `term.el', which
works around the same default the same way.)

The `stty' is given a duplicate of file descriptor 1 as its standard
input.  Only the *output* side is forced to a pty here
\(`spectreshell-eshell--force-pty-output\'), so fd 1 is the one descriptor
that is a pty by construction wherever this wrapper runs at all.  Not
standard input: on a pipeline\'s last stage that is eshell\'s plain pipe
from the previous stage, and an `stty' on it fails with ENOTTY, leaving
the staircase above unfixed for every piped command.  Not `/dev/tty'
either, even though it names the pty on GNU/Linux: a child gets that pty
as its *controlling* terminal only via the TIOCSCTTY that Emacs\'s
`emacs_spawn' issues when the *input* side is a pty too, or via the
reopen that Emacs skips on Darwin and the BSDs (its DONT_REOPEN_PTY,
whose stated premise -- TIOCSCTTY already ran -- does not hold for the
\(pipe . pty) connection type used here); on macOS the open therefore
fails with ENXIO.

The redirection of standard error to the null device comes first in the
list, because POSIX evaluates redirections left to right and a
redirection that fails to open reports it on whatever standard error is
at that point: putting it last is what let the ENXIO above reach the pty
and land in the user\'s buffer.  (`stty\'s own diagnostics -- ENOTTY if
Emacs quietly downgraded the pty to a pipe, or not-found if there is no
`stty' at all -- go to the null device whatever the order, since both
redirections are in place before it runs.  Both merely leave the
staircase unfixed, silently, which is what a shell wrapper can do about
them.)

COMMAND is appended after the script so that `sh' binds PROGRAM to $0
and ARGS to $@; `exec \"$0\" \"$@\"' then reassembles them exactly.  Passing
PROGRAM as $0 rather than as $1 is what lets the wrapper stay free of a
placeholder argument, so an ARG that happens to look like one is just an
ordinary argument."
  (append
   (list "/bin/sh" "-c"
         (format "stty 2>%s <&1 sane rows %d columns %d; exec \"$0\" \"$@\""
                 null-device rows cols))
   command))

(defun spectreshell-eshell--make-process-advice (orig &rest args)
  "Force a pty and pre-sanitize it while `spectreshell-eshell--want-pty' holds.
Around-advice for `make-process' (ORIG ARGS); rewriting the actual
`:connection-type'/`:command' keyword arguments is the only way to
guarantee both, regardless of eshell's own pipeline connection-type
choice or the user's `process-connection-type' setting, since a
process's pty-vs-pipe-ness and what actually gets exec'd into it are
both fixed at OS-level creation time and cannot be changed afterwards."
  (if spectreshell-eshell--want-pty
      (apply orig (plist-put
                   (plist-put args :connection-type
                              (spectreshell-eshell--force-pty-output
                               (plist-get args :connection-type)))
                   :command
                   (spectreshell-eshell--wrap-command-for-pty
                    (plist-get args :command)
                    (car spectreshell-eshell--pty-size)
                    (cdr spectreshell-eshell--pty-size))))
    (apply orig args)))

(defun spectreshell-eshell--effective-term-name ()
  "Return the TERM value to export for eshell's external processes.
Applies `spectreshell-term-name''s documented xterm-ghostty ->
xterm-256color fallback: only when the user has not customized TERM
away from the default *and* no bundled terminfo database was found for
it to describe."
  (if (and (equal spectreshell-term-name "xterm-ghostty")
           (null spectreshell-terminfo-directory))
      "xterm-256color"
    spectreshell-term-name))

(defconst spectreshell-eshell--pty-unset-variables '("COLUMNS" "LINES")
  "Environment variables removed from a child spectreshell gives a pty.
Both are entries without a \"=VALUE\" part, which is how
`process-environment' spells \"unset this for the subprocess\".")

(defun spectreshell-eshell--process-environment (attach)
  "Return `process-environment' plus spectreshell's TERM/TERMINFO exports.
`eshell-gather-process-output' rebuilds `process-environment' for the
child from whatever `process-environment' *dynamically* is at the
moment it calls `eshell-environment-variables' (which copies the
special variable's then-current value), so let-binding this function's
result around a call to it is enough to reach the child even though
eshell never asks anyone else for extra variables directly.  Prepended
\(rather than appended) so these values win over any same-named
variable already inherited from Emacs's own environment.

When ATTACH is non-nil the child gets a pty, and
`spectreshell-eshell--pty-unset-variables' are unset on top of that, so
that the pty\'s TIOCGWINSZ is the child\'s single source of truth for
its size (docs/design.org).  Unsetting rather than correcting the
values is what keeps them from going stale: a resize updates the pty
but can never update an already-exec\'d child\'s environment."
  (append (list (concat "TERM=" (spectreshell-eshell--effective-term-name)))
          (when spectreshell-terminfo-directory
            (list (concat "TERMINFO=" spectreshell-terminfo-directory)))
          (when attach spectreshell-eshell--pty-unset-variables)
          process-environment))

(defun spectreshell-eshell--variable-aliases-list ()
  "Return `eshell-variable-aliases-list' with COLUMNS/LINES not exported.
Clearing only each entry\'s COPY-TO-ENVIRONMENT flag (its third element)
keeps `$COLUMNS'/`$LINES' working as eshell variables while stopping
`eshell-environment-variables' from `setenv'-ing them over the unset
entries `spectreshell-eshell--process-environment' put in
`process-environment' -- which it would otherwise do, since it rebuilds
the child\'s environment from this list after copying that one."
  (mapcar (lambda (alias)
            (if (member (car alias) spectreshell-eshell--pty-unset-variables)
                (append (list (car alias) (cadr alias) nil) (nthcdr 3 alias))
              alias))
          eshell-variable-aliases-list))

(defun spectreshell-eshell--gather-process-output-advice (orig command args)
  "Run ORIG (`eshell-gather-process-output' COMMAND ARGS) under spectreshell.
Always exports `spectreshell-term-name'/`spectreshell-terminfo-directory'
into the child's environment (real shells export TERM unconditionally,
not only for the foreground job).  When attaching, COLUMNS/LINES are
additionally unset for the child (see
`spectreshell-eshell--process-environment'); the `let' of
`eshell-variable-aliases-list' takes effect even though `em-dirs.el'
makes that variable buffer-local, because ORIG runs with this same
eshell buffer current.

Additionally attaches spectreshell when both of these hold: (1)
`eshell-interactive-output-p' says this call's output is headed for
interactive display -- COMMAND is the pipeline's last (or only) stage,
docs/design.org's simplification -- and (2) `default-directory' is
local; TRAMP's own remote `make-process' replacement does not
necessarily route through the `make-process' advice below, so a remote
pty built on that assumption could well be wrong, and is not attempted
at all.  When attaching, ORIG's own `make-process' call is arranged to
get a pty sized and sanitized for `spectreshell-eshell--terminal-size''s
ROWS/COLS (via `spectreshell-eshell--want-pty'/`spectreshell-eshell--pty-size'),
and the resulting process is attached to a new spectreshell terminal of
that same size (`spectreshell-eshell--attach').

`eshell-current-subjob-p' is read here rather than left for
`spectreshell-eshell--attach' to read itself: `eshell-do-subjob' binds
it around evaluating a `&'-terminated command, and that binding is only
in effect for as long as ORIG is on the stack."
  (let* ((attach (and (eshell-interactive-output-p)
                       (not (file-remote-p default-directory))))
         (background eshell-current-subjob-p)
         (size (and attach (spectreshell-eshell--terminal-size (current-buffer))))
         (spectreshell-eshell--want-pty attach)
         (spectreshell-eshell--pty-size size)
         (process-environment (spectreshell-eshell--process-environment attach))
         (eshell-variable-aliases-list
          (if attach
              (spectreshell-eshell--variable-aliases-list)
            eshell-variable-aliases-list))
         (proc (funcall orig command args)))
    (when (and attach (processp proc))
      (spectreshell-eshell--attach proc size background))
    proc))

;; ---------------------------------------------------------------------
;; Minor mode
;; ---------------------------------------------------------------------

;;;###autoload
(define-minor-mode spectreshell-eshell-mode
  "Route eshell's external-process output through spectreshell's terminal.
A global minor mode: while on, `eshell-gather-process-output' (and
therefore every eshell buffer's external commands, present and future)
is advised to attach spectreshell to whichever pipeline stage would
otherwise write straight to the buffer (docs/design.org).  That process
gets a pty, TERM/TERMINFO in its environment (and COLUMNS/LINES
unset, so the pty\'s size is the only size it sees), and drives the buffer
through spectreshell's VT emulation instead of eshell's own plain-text
output filter for as long as it runs."
  :global t
  :group 'spectreshell-eshell
  (if spectreshell-eshell-mode
      (progn
        (advice-add 'eshell-gather-process-output :around
                    #'spectreshell-eshell--gather-process-output-advice)
        (advice-add 'make-process :around
                    #'spectreshell-eshell--make-process-advice)
        (advice-add 'eshell-visual-command-p :around
                    #'spectreshell-eshell--visual-command-p-advice))
    (advice-remove 'eshell-gather-process-output
                    #'spectreshell-eshell--gather-process-output-advice)
    (advice-remove 'make-process
                    #'spectreshell-eshell--make-process-advice)
    (advice-remove 'eshell-visual-command-p
                    #'spectreshell-eshell--visual-command-p-advice)))

;; Defined after `spectreshell-eshell-mode' itself (rather than up with the
;; other advice functions) purely so this can refer to that variable
;; without a forward `defvar' declaration.
(defun spectreshell-eshell--visual-command-p-advice (orig command args)
  "Disable `em-term.el''s visual-command redirection while spectreshell runs.
Around-advice for `eshell-visual-command-p' (ORIG COMMAND ARGS).  When
the optional `eshell-term' module is enabled, eshell normally routes
commands like `less'/`vim'/`top' (`eshell-visual-commands') to a
separate `term-mode' buffer instead of `eshell-gather-process-output',
specifically because plain eshell cannot render their escape codes --
exactly the problem spectreshell solves, and docs/design.org picks
\"run every external command's output through spectreshell\" over
\"only visual commands, in a separate buffer\" for that reason.  Without
this advice those commands would never reach the advice above at all."
  (and (not spectreshell-eshell-mode) (funcall orig command args)))

(provide 'spectreshell-eshell)
;;; spectreshell-eshell.el ends here
