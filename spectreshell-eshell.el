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

(defvar-local spectreshell-eshell--process nil
  "The process `spectreshell--current' (if any) in this buffer is attached to.
Kept in lockstep with `spectreshell--current' by
`spectreshell-eshell--attach'/`spectreshell-eshell--detach':
`spectreshell-resize' needs the `spectreshell' struct but
`set-process-window-size' needs the process object, and neither one
holds a reference to the other.")

;; ---------------------------------------------------------------------
;; Terminal geometry
;; ---------------------------------------------------------------------

(defun spectreshell-eshell--terminal-size (buffer)
  "Return (ROWS . COLS) for a new spectreshell terminal in BUFFER.
Prefers a window currently showing BUFFER: `window-body-height' and
`window-max-chars-per-line' are exactly the visible terminal cell
counts a real terminal would report via TIOCGWINSZ.  Falls back to the
selected frame's size when BUFFER has no window yet (e.g. a job
started into a buffer that isn't displayed anywhere), and to a plain
80x24 under `noninteractive' (batch Emacs, as ERT runs under), where
frame dimensions do not correspond to anything a user could see."
  (if-let* ((window (get-buffer-window buffer t)))
      (cons (window-body-height window) (window-max-chars-per-line window))
    (if noninteractive
        (cons 24 80)
      (cons (frame-height) (frame-width)))))

(defun spectreshell-eshell--window-size-change (window)
  "Resize this buffer's running spectreshell terminal to fit WINDOW.
Buffer-local member of `window-size-change-functions' and
`window-buffer-change-functions' (the latter covers a buffer being
\(re)displayed in an existing window without any size change -- e.g. a
job attached while the buffer was buried, then brought back with
`switch-to-buffer'), both added by `spectreshell-eshell--attach'.  Left
in place after the terminal it was added for finalizes
\(`spectreshell-eshell--detach' does not remove it):
`spectreshell--current' being nil then makes every subsequent call of
this a no-op, which is cheaper than tracking add/remove state across
however many jobs run in this buffer over its lifetime."
  (when-let* ((obj spectreshell--current)
              (proc spectreshell-eshell--process)
              (rows (window-body-height window))
              (cols (window-max-chars-per-line window)))
    (unless (and (= rows (spectreshell-rows obj)) (= cols (spectreshell-cols obj)))
      (spectreshell-resize obj rows cols)
      (set-process-window-size proc rows cols))))

;; ---------------------------------------------------------------------
;; Attach / detach
;; ---------------------------------------------------------------------

(defun spectreshell-eshell--attach (proc size)
  "Start a spectreshell terminal for PROC and take over its buffer I/O.
Called right after `eshell-gather-process-output' creates PROC, when
`eshell-interactive-output-p' said PROC is the pipeline stage whose
output is headed for interactive display.  Replaces PROC's filter and
sentinel (installed for the plain, non-terminal-emulating case by
`eshell-gather-process-output' itself) and switches PROC's buffer into
`spectreshell-semi-char-mode' for the job's duration.  SIZE is the
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
                             (process-send-string proc bytes))))))
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
        (setq spectreshell--current obj
              spectreshell-eshell--process proc)
        (add-hook 'window-size-change-functions
                   #'spectreshell-eshell--window-size-change nil t)
        (add-hook 'window-buffer-change-functions
                   #'spectreshell-eshell--window-size-change nil t)
        (spectreshell-semi-char-mode 1)))))

(defun spectreshell-eshell--detach (proc)
  "Finalize PROC's spectreshell terminal and leave semi-char mode.
Called from `spectreshell-eshell--sentinel' once PROC is no longer
live.  Idempotent (PROC's `spectreshell-eshell-terminal' property is
cleared on first use) because a process sentinel can run more than
once for the same process."
  (when-let* ((obj (process-get proc 'spectreshell-eshell-terminal)))
    (process-put proc 'spectreshell-eshell-terminal nil)
    (if (buffer-live-p (spectreshell-buffer obj))
        (with-current-buffer (spectreshell-buffer obj)
          (spectreshell-finalize obj)
          ;; `spectreshell-eshell--filter' bypasses eshell's own output
          ;; path entirely (`eshell-insertion-filter'/
          ;; `eshell-interactive-process-filter'), the only code that
          ;; normally advances `eshell-last-output-end'; without this,
          ;; `eshell-sentinel''s prompt (run right after this function
          ;; returns) would land wherever that marker was last left --
          ;; i.e. right before the terminal region, not after it.
          (set-marker eshell-last-output-end (point-max))
          (when (eq spectreshell--current obj)
            (setq spectreshell--current nil
                  spectreshell-eshell--process nil))
          (spectreshell-semi-char-mode -1))
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
  "Return a `make-process' :command list that sanitizes PROC's pty first.
COMMAND is the original (PROGRAM . ARGS) list.  A pty Emacs itself just
opened for a subprocess defaults to `-echo -onlcr' (checked directly
with `stty -a' against one), unlike a real terminal's; under correct
VT100 semantics that turns even completely ordinary newline-terminated
output -- i.e. most Unix programs, which rely on the tty driver's
ONLCR to turn a bare LF into a proper new line -- into a staircase.
`term.el' (`term-exec-1') works around exactly this the same way: exec
through a tiny `/bin/sh -c' wrapper that runs `stty ... sane' first,
copied here (ROWS/COLS included so the child's very first ioctl
already sees the right size, same as `term-exec-1')."
  (append
   (list "/bin/sh" "-c"
         (format "stty -nl echo rows %d columns %d sane 2>%s;\
if [ $1 = .. ]; then shift; fi; exec \"$@\""
                 rows cols null-device)
         "..")
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

(defun spectreshell-eshell--process-environment ()
  "Return `process-environment' plus spectreshell's TERM/TERMINFO exports.
`eshell-gather-process-output' rebuilds `process-environment' for the
child from whatever `process-environment' *dynamically* is at the
moment it calls `eshell-environment-variables' (which copies the
special variable's then-current value), so let-binding this function's
result around a call to it is enough to reach the child even though
eshell never asks anyone else for extra variables directly.  Prepended
\(rather than appended) so these two values win over any same-named
variable already inherited from Emacs's own environment."
  (append (list (concat "TERM=" (spectreshell-eshell--effective-term-name)))
          (when spectreshell-terminfo-directory
            (list (concat "TERMINFO=" spectreshell-terminfo-directory)))
          process-environment))

(defun spectreshell-eshell--gather-process-output-advice (orig command args)
  "Run ORIG (`eshell-gather-process-output' COMMAND ARGS) under spectreshell.
Always exports `spectreshell-term-name'/`spectreshell-terminfo-directory'
into the child's environment (real shells export TERM unconditionally,
not only for the foreground job).

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
that same size (`spectreshell-eshell--attach')."
  (let* ((attach (and (eshell-interactive-output-p)
                       (not (file-remote-p default-directory))))
         (size (and attach (spectreshell-eshell--terminal-size (current-buffer))))
         (spectreshell-eshell--want-pty attach)
         (spectreshell-eshell--pty-size size)
         (process-environment (spectreshell-eshell--process-environment))
         (proc (funcall orig command args)))
    (when (and attach (processp proc))
      (spectreshell-eshell--attach proc size))
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
gets a pty, TERM/TERMINFO in its environment, and drives the buffer
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
