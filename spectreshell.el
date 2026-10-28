;;; spectreshell.el --- Terminal emulation rendering engine for eshell -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Shinnosuke Sawada-Dazai

;; Author: Shinnosuke Sawada-Dazai <shin@warashi.dev>
;; Keywords: terminals, processes
;; Version: 0.0.1
;; URL: https://github.com/Warashi/emacs-spectreshell
;; Package-Requires: ((emacs "31.1"))

;; This file is part of emacs-spectreshell, and is distributed under
;; the MIT License; see LICENSE for details.

;;; Commentary:

;; `spectreshell.el' is the eshell-independent rendering core described in
;; docs/design.org.  It owns the mapping between a `libspectreshell.so'
;; terminal object (see docs/module-api.org) and a region of an Emacs
;; buffer: feeding bytes to the terminal, applying the returned dirty-row
;; diff to the buffer, converting SGR style spans to text properties, and
;; confirming scrolled-off lines as permanent scrollback text.
;;
;; Callers (eventually spectreshell-eshell.el) are responsible for owning
;; the PTY and process; this file only turns "bytes in" into "buffer
;; updated" and "response bytes out".

;;; Code:

(require 'cl-lib)
(require 'pcase)
(require 'subr-x)
(require 'ansi-color)
(require 'button)
(require 'mwheel)

;; Defined by `libspectreshell.so' (module-load'ed at runtime, not a
;; regular Elisp library); declared to keep the byte-compiler quiet.
(declare-function spectreshell--create "libspectreshell" (rows cols))
(declare-function spectreshell--feed "libspectreshell" (term bytes))
(declare-function spectreshell--resize "libspectreshell" (term rows cols))
(declare-function spectreshell--flush "libspectreshell" (term))
(declare-function spectreshell--release "libspectreshell" (term))
(declare-function spectreshell--encode-key "libspectreshell" (term key modifiers))
(declare-function spectreshell--encode-paste "libspectreshell" (term text))
(declare-function spectreshell--encode-mouse "libspectreshell" (term button action row col modifiers))
(declare-function spectreshell--clipboard-reply "libspectreshell" (term id result &optional remember))
(declare-function spectreshell--clipboard-pending-p "libspectreshell" (term id))
(declare-function spectreshell--set-clipboard-write "libspectreshell" (term policy))
(declare-function spectreshell--encode-paste-event "libspectreshell" (term))

;; ---------------------------------------------------------------------
;; Module loading
;; ---------------------------------------------------------------------

(defconst spectreshell--module-candidate-subpaths
  '(;; A local `zig build'/`just build' checkout: `spectreshell.el' loads
    ;; from the repository root, and `build.zig' installs the module next
    ;; to the terminfo database under `zig-out'.  Zig names the shared
    ;; library after the target platform's convention (`.so' on Linux,
    ;; `.dylib' on darwin), so probe both suffixes for each layout.
    "zig-out/lib/libspectreshell.so"
    "zig-out/lib/libspectreshell.dylib"
    ;; The nix package layout: `spectreshell.el' loads from
    ;; "$out/share/emacs/site-lisp", three levels up from which is
    ;; "$out", the parent of "$out/lib".
    "../../../lib/libspectreshell.so"
    "../../../lib/libspectreshell.dylib")
  "Paths to probe for the libspectreshell dynamic module.
Each is relative to the directory `spectreshell.el' (this library) was
loaded from; see `spectreshell--detect-module-path'.")

(defun spectreshell--detect-module-path ()
  "Return a path to the libspectreshell module found near this library, or nil.
Probes `spectreshell--module-candidate-subpaths' relative to wherever
`locate-library' says `spectreshell.el' itself was loaded from, and
returns the first one that exists as a file."
  (when-let* ((lib (locate-library "spectreshell"))
              (dir (file-name-directory lib)))
    (seq-find #'file-exists-p
              (mapcar (lambda (rel) (expand-file-name rel dir))
                      spectreshell--module-candidate-subpaths))))

(defun spectreshell-ensure-module-loaded ()
  "Load the libspectreshell module via `module-load' unless already loaded.
Called lazily by `spectreshell-start' -- the first entry point that
needs a module function -- rather than at library load time, so that
merely loading this file (a plain `require', possibly triggered by an
autoload) never fails on a machine where the module has not been built
yet.  Checks `fboundp' on `spectreshell--create' first both to make
this idempotent (module-load'ing the same file twice is unnecessary
work at best) and to let a caller -- e.g. a test harness that wants a
fresh terminal-less module state -- `module-load' a specific copy ahead
of time and have this become a no-op.  Signals an error naming the
paths it tried when `spectreshell--detect-module-path' cannot find one,
since \"module functions are simply undefined\" would otherwise surface
as a much more confusing error far from its cause."
  (unless (fboundp 'spectreshell--create)
    (if-let* ((path (spectreshell--detect-module-path)))
        (module-load path)
      (error "Spectreshell: libspectreshell module not found near %s (tried: %s); run `zig build' or `nix build' first"
             (or (locate-library "spectreshell") "spectreshell.el")
             (mapconcat #'identity spectreshell--module-candidate-subpaths ", ")))))

(defgroup spectreshell nil
  "Terminal emulation rendering engine for eshell."
  :group 'terminals
  :prefix "spectreshell-")

;; ---------------------------------------------------------------------
;; Faces
;; ---------------------------------------------------------------------

;; SGR 30-37/90-97 map onto palette indices 0-15 in this fixed order
;; (docs/module-api.org :fg/:bg); inheriting from the existing
;; `ansi-color-*' faces (rather than hardcoding colors) lets the user's
;; color theme drive spectreshell's palette too.
(defface spectreshell-color-0 '((t :inherit ansi-color-black))
  "Face for palette color 0 (black)." :group 'spectreshell)
(defface spectreshell-color-1 '((t :inherit ansi-color-red))
  "Face for palette color 1 (red)." :group 'spectreshell)
(defface spectreshell-color-2 '((t :inherit ansi-color-green))
  "Face for palette color 2 (green)." :group 'spectreshell)
(defface spectreshell-color-3 '((t :inherit ansi-color-yellow))
  "Face for palette color 3 (yellow)." :group 'spectreshell)
(defface spectreshell-color-4 '((t :inherit ansi-color-blue))
  "Face for palette color 4 (blue)." :group 'spectreshell)
(defface spectreshell-color-5 '((t :inherit ansi-color-magenta))
  "Face for palette color 5 (magenta)." :group 'spectreshell)
(defface spectreshell-color-6 '((t :inherit ansi-color-cyan))
  "Face for palette color 6 (cyan)." :group 'spectreshell)
(defface spectreshell-color-7 '((t :inherit ansi-color-white))
  "Face for palette color 7 (white)." :group 'spectreshell)
(defface spectreshell-color-8 '((t :inherit ansi-color-bright-black))
  "Face for palette color 8 (bright black)." :group 'spectreshell)
(defface spectreshell-color-9 '((t :inherit ansi-color-bright-red))
  "Face for palette color 9 (bright red)." :group 'spectreshell)
(defface spectreshell-color-10 '((t :inherit ansi-color-bright-green))
  "Face for palette color 10 (bright green)." :group 'spectreshell)
(defface spectreshell-color-11 '((t :inherit ansi-color-bright-yellow))
  "Face for palette color 11 (bright yellow)." :group 'spectreshell)
(defface spectreshell-color-12 '((t :inherit ansi-color-bright-blue))
  "Face for palette color 12 (bright blue)." :group 'spectreshell)
(defface spectreshell-color-13 '((t :inherit ansi-color-bright-magenta))
  "Face for palette color 13 (bright magenta)." :group 'spectreshell)
(defface spectreshell-color-14 '((t :inherit ansi-color-bright-cyan))
  "Face for palette color 14 (bright cyan)." :group 'spectreshell)
(defface spectreshell-color-15 '((t :inherit ansi-color-bright-white))
  "Face for palette color 15 (bright white)." :group 'spectreshell)

;; `ansi-color' has no strikethrough face to borrow, unlike
;; bold/italic/faint/underline/inverse (see `spectreshell--span-face').
(defface spectreshell-strikethrough '((t :strike-through t))
  "Face used for SGR strikethrough (9) text." :group 'spectreshell)

(define-button-type 'spectreshell-hyperlink
  'action #'spectreshell--follow-hyperlink
  'follow-link t)

(defun spectreshell--follow-hyperlink (button)
  "Open the URI recorded on BUTTON with `browse-url'."
  (browse-url (button-get button 'spectreshell-hyperlink-uri)))

;; ---------------------------------------------------------------------
;; Terminal object
;; ---------------------------------------------------------------------

(cl-defstruct (spectreshell
               (:constructor spectreshell--make)
               (:copier nil))
  "A spectreshell terminal bound to a region of a buffer.
Construct with `spectreshell-start'; do not call the `spectreshell--make'
constructor directly outside this file."
  term
  buffer
  marker
  ;; End of the terminal region, as a marker so that text inserted
  ;; before it (this terminal's own output, or another terminal's in the
  ;; same buffer) keeps it pinned to the region's end.  Its insertion
  ;; type is the default nil, and every helper that grows the region
  ;; repins it explicitly (`spectreshell--set-region-end'): type t would
  ;; make an insertion *at* the end position pull the marker along, and
  ;; that is exactly what eshell does when it writes the prompt and the
  ;; next command line right after a background job's still-empty
  ;; region -- which would swallow them into the region.
  end-marker
  rows
  cols
  send-fn
  alt-saved
  ;; Non-nil while the child is on the alternate screen; see
  ;; `spectreshell--align-windows'.  Not derived from `alt-saved': a
  ;; terminal that entered the alt screen with an empty region saves the
  ;; empty string, which is non-nil, so the two are only accidentally
  ;; equivalent.
  alt-screen
  title
  styles
  face-generation
  row-cache
  ;; Non-nil to keep the region only as tall as its output; see
  ;; `spectreshell--trim-blank-tail'.
  compact
  ;; Buffer position where the last update left the terminal cursor; see
  ;; `spectreshell--cursor-followed-p'.
  cursor-pos
  ;; The same cursor as a terminal (ROW . COL) cons, which is what says
  ;; how far down the terminal has been used (`spectreshell--used-rows').
  ;; The buffer position cannot answer that: a row the terminal never
  ;; dirtied has no line in the region, so the position clamps to the
  ;; region's end and the row number is lost.
  cursor-rowcol
  ;; Non-nil while drawing is held back for synchronized output; see
  ;; `spectreshell--hold-synchronized'.
  sync-timer)

(defvar spectreshell--face-generation 0
  "Counter bumped whenever cached `face' values may have gone stale.
Terminals cache the `face' value they built for each style ID; those
values embed colors resolved against the frame and theme current at the
time (see `spectreshell--resolve-color'), so a new theme or a new frame
\(a daemon's first real frame in particular, since the startup terminal
resolves colors differently) invalidates them.  A counter rather than a
registry of live terminals: each terminal compares it against its own
`spectreshell-face-generation' on the next update and refreshes then.")

(defun spectreshell--invalidate-faces (&rest _)
  "Mark every terminal's cached `face' values as stale."
  (setq spectreshell--face-generation (1+ spectreshell--face-generation)))

(add-hook 'enable-theme-functions #'spectreshell--invalidate-faces)
(add-hook 'disable-theme-functions #'spectreshell--invalidate-faces)
(add-hook 'after-make-frame-functions #'spectreshell--invalidate-faces)

(defvar spectreshell-title-functions nil
  "Abnormal hook run when a terminal's title changes (OSC 0/2).
Each function is called with two arguments, the `spectreshell' object
and the new title string, with the terminal's buffer current.  The
latest title is also always readable from `spectreshell-title'.
spectreshell itself deliberately renames nothing (a buffer rename would
break eshell's buffer bookkeeping, a frame title is not this layer's
to own); displaying the title anywhere is entirely up to these hooks.
`spectreshell-relay-title' is one that sends it to the outer terminal.")

(defun spectreshell--check-size (rows cols)
  "Signal unless ROWS and COLS are both positive integers.
The dimensions are checked here, with a message naming both, rather
than left to `spectreshell--create'/`spectreshell--resize': the module
signals a bare `args-out-of-range' with just the offending number,
which says nothing about which of the two it was nor that a window
measurement (`window-body-height' and `window-max-chars-per-line' both
return 0 for a window too small to show anything) is the usual way a
caller ends up here.  Not clamped to 1 either: a 1x1 terminal would
render an unreadable screen for as long as the job runs, rather than
fail where the size came from."
  (unless (and (integerp rows) (> rows 0) (integerp cols) (> cols 0))
    (error "Spectreshell: terminal size must be positive, got %S rows x %S cols"
           rows cols)))

;;;###autoload
(defun spectreshell-start (buffer rows cols send-fn &optional compact)
  "Start a ROWS x COLS spectreshell terminal rendering into BUFFER.

The terminal region begins at BUFFER's point at call time and ends at a
marker that grows with the terminal's own output; callers must therefore
invoke this right after a newline (mid-line start positions are not
supported).  Text written after that end marker -- eshell's next prompt
and command line, or another concurrently running job's region -- is
left alone, so one buffer can host several terminals at once.  SEND-FN is called with a single unibyte string argument
whenever `spectreshell-feed' or `spectreshell-resize' produces PTY
response bytes (e.g. a DSR cursor-position reply) that must be written
back to the child process.

With COMPACT non-nil the region is kept only as tall as the output
drawn into it so far, instead of the full ROWS
\(`spectreshell--trim-blank-tail').

ROWS and COLS must both be at least 1
\(`spectreshell--check-size').

Return a new `spectreshell' object to pass to the other
`spectreshell-*' functions."
  (spectreshell-ensure-module-loaded)
  (spectreshell--check-size rows cols)
  (with-current-buffer buffer
    (spectreshell--make
     :term (spectreshell--create rows cols)
     :buffer buffer
     :marker (point-marker)
     :end-marker (point-marker)
     :rows rows
     :cols cols
     :send-fn send-fn
     :alt-saved nil
     ;; Style IDs are small consecutive integers assigned by the module,
     ;; so `eq' hashing is exact and cheap here.
     :styles (make-hash-table :test 'eq)
     :face-generation spectreshell--face-generation
     :row-cache (make-hash-table :test 'eq)
     :compact compact
     :cursor-pos (point)
     :cursor-rowcol (cons 0 0))))

(defvar spectreshell--before-feed-functions nil
  "Abnormal hook run with OBJ before each `spectreshell-feed' to it.
For state the module needs current to answer the child's queries.")

(defun spectreshell-feed (obj bytes)
  "Feed BYTES (a unibyte string) to OBJ's terminal and update its buffer.
Return the raw update plist from `spectreshell--feed' (docs/module-api.org)."
  (run-hook-with-args 'spectreshell--before-feed-functions obj)
  (let ((update (spectreshell--feed (spectreshell-term obj) bytes)))
    (if (plist-get update :synchronized)
        (spectreshell--hold-synchronized obj update)
      (spectreshell--cancel-sync-timer obj)
      (spectreshell--apply-update obj update))))

;; ---------------------------------------------------------------------
;; Synchronized output (mode 2026)
;; ---------------------------------------------------------------------

(defvar spectreshell-synchronized-timeout 1.0
  "Seconds to hold back drawing for a frame left open in synchronized output.
The same limit as ghostty's own (`sync_reset_ms' in termio/Thread.zig).")

(defvar spectreshell--update-functions nil
  "Abnormal hook run with OBJ and each module update plist for it.
Run for held synchronized feeds too, after the responses and relayed
events are acted on.")

(defun spectreshell--hold-synchronized (obj update)
  "Leave OBJ's buffer as it is while the child is inside a synchronized frame.
UPDATE is the `(:synchronized t ...)' plist from `spectreshell--feed';
only its responses and relayed events are acted on.  The timer is armed once per hold and
not pushed back by later held feeds: when every read ends inside some
frame, no feed ever closes one, and drawing would otherwise stall for as
long as the output keeps coming."
  (unless (spectreshell-sync-timer obj)
    (setf (spectreshell-sync-timer obj)
          (run-at-time spectreshell-synchronized-timeout nil
                       #'spectreshell--flush-synchronized obj)))
  (when-let* ((response (plist-get update :responses)))
    (funcall (spectreshell-send-fn obj) response))
  (spectreshell--apply-relay obj update)
  (run-hook-with-args 'spectreshell--update-functions obj update)
  update)

(defun spectreshell--cancel-sync-timer (obj)
  "Stop OBJ's synchronized-output timeout, if one is armed."
  (when-let* ((timer (spectreshell-sync-timer obj)))
    (cancel-timer timer)
    (setf (spectreshell-sync-timer obj) nil)))

(defun spectreshell--flush-synchronized (obj)
  "Draw what OBJ held back, ending the child's synchronized output."
  (setf (spectreshell-sync-timer obj) nil)
  (when (buffer-live-p (spectreshell-buffer obj))
    (spectreshell--apply-update obj (spectreshell--flush (spectreshell-term obj)))))

(defun spectreshell-resize (obj rows cols)
  "Resize OBJ's terminal to ROWS x COLS and update its buffer accordingly.
ROWS and COLS must both be at least 1
\(`spectreshell--check-size'); OBJ is left untouched otherwise, so a
caller that traps the error still has a terminal matching the size its
pty was last told.
Return the raw update plist from `spectreshell--resize'."
  (spectreshell--check-size rows cols)
  (let ((update (spectreshell--resize (spectreshell-term obj) rows cols)))
    (spectreshell--cancel-sync-timer obj)
    (setf (spectreshell-rows obj) rows
          (spectreshell-cols obj) cols)
    ;; Reflow moves content between rows, and shrinking drops rows
    ;; outright, so row numbers no longer mean what the cache recorded.
    (clrhash (spectreshell-row-cache obj))
    (spectreshell--apply-update obj update)))

(defun spectreshell-finalize (obj)
  "Freeze OBJ's terminal region as ordinary buffer text and release it.
Call this once when the backing process has exited; OBJ (and the
module terminal it wraps) must not be used again afterwards.  The
terminal region is already rendered as real buffer text throughout, so
there is nothing left to convert here beyond detaching the markers and
releasing the module's terminal object.

Return the buffer position just past the frozen region, which callers
need in order to place whatever they write next (eshell's prompt) right
below the output; the markers are gone by the time this returns, so it
is the only way left to name that position.

Point is moved there only if it was inside the region: a background job
finishing while the user edits the command line further down must not
drag point away from what is being typed.

If the process died while the alternate screen was still active (a
clean exit would have sent ?1049l first), the saved primary screen is
restored just as leaving the alt screen would have, so the user's
pre-TUI screen content is not silently lost.

A frame still held back for synchronized output is drawn first: it may
already have pushed lines into the scrollback.

State OBJ left on the outer terminal (a progress bar) is cleared
\(`spectreshell--relay-release')."
  (when (spectreshell-sync-timer obj)
    (spectreshell--cancel-sync-timer obj)
    (spectreshell--flush-synchronized obj))
  (let (end)
    (with-current-buffer (spectreshell-buffer obj)
      (save-restriction
        (widen)
        (let ((inhibit-read-only t)
              (buffer-undo-list t)
              (inside (and (>= (point) (spectreshell-marker obj))
                           (<= (point) (spectreshell--region-end obj))))
              (saved-point (point-marker)))
          (when (spectreshell-alt-saved obj)
            (spectreshell--leave-alt-screen obj))
          (remove-list-of-text-properties
           (spectreshell-marker obj) (spectreshell--region-end obj)
           '(spectreshell-cells))
          (spectreshell--trim-frozen-region obj)
          (setq end (spectreshell--region-end obj))
          (goto-char (if inside end saved-point))
          (set-marker saved-point nil))))
    (set-marker (spectreshell-marker obj) nil)
    (set-marker (spectreshell-end-marker obj) nil)
    (spectreshell--relay-release obj)
    (spectreshell--release (spectreshell-term obj))
    end))

(defun spectreshell--trim-frozen-region (obj)
  "Strip OBJ's terminal-region padding before it freezes into plain text.
Removes each line's trailing run of property-less spaces (the module
pads rows to the full terminal width; see
`spectreshell--trim-trailing-blanks' for why styled spaces survive),
then the rows below the last one the terminal used, so eshell's next
prompt lands right under the output instead of a screenful of blank
lines further down.

The used rows are the last row holding output *and* every row above the
cursor (`spectreshell--used-rows'): a command ending in
\"printf \\n\\n\\n\" draws nothing but leaves the cursor on row 3, and
those three blank rows are its output just as much as text would be."
  (let ((marker (spectreshell-marker obj)))
    (goto-char marker)
    (while (< (point) (spectreshell--region-end obj))
      (end-of-line)
      (while (and (> (point) (line-beginning-position))
                  (eq (char-before) ?\s)
                  (null (text-properties-at (1- (point)))))
        (delete-char -1))
      (forward-line 1))
    (goto-char (spectreshell--region-end obj))
    (skip-chars-backward "\n" marker)
    (delete-region (point) (spectreshell--region-end obj))
    ;; Nothing was ever drawn (a job that printed no output at all): the
    ;; region freezes into no text rather than into an empty line, which
    ;; would push eshell's prompt -- and whatever is being typed at it --
    ;; a row down as the job exits.
    (when (> (point) marker)
      (insert "\n")
      (spectreshell--set-region-end obj))
    (spectreshell--restore-used-rows obj)))

(defun spectreshell--used-rows (obj)
  "Return how many rows of OBJ the terminal had used when it last drew.
Every row above the cursor's has been passed through, and the cursor's
own row counts as used once the cursor has left column 0.  Zero when no
cursor is on record (`spectreshell--leave-alt-screen')."
  (pcase (spectreshell-cursor-rowcol obj)
    (`(,row . ,col) (if (> col 0) (1+ row) row))
    (_ 0)))

(defun spectreshell--restore-used-rows (obj)
  "Give OBJ's frozen region back the blank rows its cursor had passed.
Called after the all-blank tail rows were cut: the rows a command left
blank on purpose are indistinguishable from the never-drawn padding
below them by their content alone, and the cut takes both."
  (let ((missing (- (spectreshell--used-rows obj) (spectreshell--row-count obj))))
    (when (> missing 0)
      (goto-char (spectreshell--region-end obj))
      (insert (make-string missing ?\n))
      (spectreshell--set-region-end obj))))

;; ---------------------------------------------------------------------
;; Update plist application
;; ---------------------------------------------------------------------

(defun spectreshell--apply-update (obj update)
  "Apply the module UPDATE plist for OBJ to its buffer and send-fn.
Return UPDATE unchanged, for callers that want to inspect it further."
  (with-current-buffer (spectreshell-buffer obj)
    ;; This runs from a process filter at arbitrary times, so the user may
    ;; have narrowed the buffer meanwhile; the terminal region (its end
    ;; marker above all) can well sit outside the accessible portion,
    ;; and every helper below edits it by buffer position.
    (save-restriction
      (widen)
      ;; `buffer-undo-list' is bound to t because terminal redraw churn
      ;; would otherwise accumulate unbounded undo entries (eshell buffers
      ;; have undo enabled), and undoing a redraw after the job exits
      ;; would corrupt confirmed scrollback text.
      ;; Who follows the cursor is decided here, before any helper below
      ;; touches the buffer: the redraw moves point around (and rewrites
      ;; the very rows the comparison is about), so after it there is no
      ;; way left to tell "was sitting at the cursor" from "was reading
      ;; the scrollback".
      (let* ((inhibit-read-only t)
             (buffer-undo-list t)
             (follow-point (spectreshell--cursor-followed-p obj (point)))
             (follow-windows (spectreshell--following-windows obj))
             (saved-point (spectreshell--save-line obj (point)))
             (saved-views (spectreshell--save-window-views obj follow-windows)))
        ;; Styles first: the rows below are drawn from style IDs that this
        ;; call is what teaches OBJ about.
        (spectreshell--apply-styles obj update)
        (spectreshell--handle-alt-screen obj (plist-get update :alt-screen))
        (spectreshell--apply-scrolled-off obj (plist-get update :scrolled-off))
        (spectreshell--apply-dirty obj (plist-get update :dirty))
        (spectreshell--trim-rows obj)
        (when (spectreshell-compact obj)
          (spectreshell--trim-blank-tail obj))
        (spectreshell--move-point obj (plist-get update :cursor)
                                  (plist-get update :cursor-index)
                                  follow-point follow-windows saved-point)
        (spectreshell--restore-window-views obj saved-views)
        (spectreshell--align-windows obj)
        (when-let* ((title (plist-get update :title)))
          (setf (spectreshell-title obj) title)
          (run-hook-with-args 'spectreshell-title-functions obj title)))))
  (when-let* ((response (plist-get update :responses)))
    (funcall (spectreshell-send-fn obj) response))
  (spectreshell--apply-relay obj update)
  (run-hook-with-args 'spectreshell--update-functions obj update)
  update)

;; ---------------------------------------------------------------------
;; Relay to the outer terminal
;; ---------------------------------------------------------------------

(defun spectreshell--relay-terminal (frame)
  "Return FRAME's terminal if things the child sends outward belong there.
Only tty frames qualify: a GUI frame has no terminal to write escape
sequences to.  A daemon's initial frame is a non-graphic frame too, but
its terminal is the daemon's own stdout, not anything the user sees."
  (unless (or (display-graphic-p frame) (frame-initial-p frame))
    (frame-terminal frame)))

(defun spectreshell--relay-terminals (buffer)
  "Return the terminals of the tty frames showing BUFFER, each once."
  (let (terminals)
    (dolist (window (get-buffer-window-list buffer nil t))
      (when-let* ((terminal (spectreshell--relay-terminal (window-frame window))))
        (cl-pushnew terminal terminals)))
    (nreverse terminals)))

(defun spectreshell--relay (obj string &optional predicate)
  "Send STRING to the outer terminals showing OBJ's buffer.
With PREDICATE, send only to the terminals it returns non-nil for.
Nothing is sent when no tty frame shows the buffer, and nothing is
queued for later either: the child is talking to whoever is looking,
and with nobody looking there is no one to tell."
  (dolist (terminal (spectreshell--relay-terminals (spectreshell-buffer obj)))
    (when (or (null predicate) (funcall predicate terminal))
      (send-string-to-terminal string terminal))))

(defvar spectreshell--relay-handlers nil
  "Alist of (SYMBOL . FUNCTION) handling the module's `:relay' events.
FUNCTION is called with the `spectreshell' object followed by the
event's arguments.  Events without a handler are dropped.")

(defun spectreshell--apply-relay (obj update)
  "Hand each `:relay' event of the module UPDATE plist for OBJ to its handler."
  (pcase-dolist (`(,kind . ,args) (plist-get update :relay))
    (when-let* ((handler (alist-get kind spectreshell--relay-handlers)))
      (apply handler obj args))))

(defvar-local spectreshell--relay-kept nil
  "Alist of (KEY STRING OBJ CLEAR) relayed again when this buffer is shown.
See `spectreshell--relay-keep'.")

(defun spectreshell--relay-keep (obj key string &optional clear)
  "Relay STRING for OBJ and keep it as the latest state under KEY.
The kept string is sent again to the terminal of every window that
starts showing OBJ's buffer, for state the outer terminal should keep
showing (a progress bar) rather than a one-off event.  Keeping is per
buffer, so a later call with the same KEY replaces the earlier string
whichever terminal it came from.  STRING nil stops keeping KEY and
sends nothing.

With CLEAR, KEY stays OBJ's to undo: if OBJ is finalized
\(`spectreshell--relay-release') or its buffer killed while KEY is still
kept from this call, CLEAR is relayed and keeping stops, so the outer
terminal is not left showing state no one will update any more."
  (with-current-buffer (spectreshell-buffer obj)
    (setf (alist-get key spectreshell--relay-kept nil t)
          (and string (list string obj clear)))
    (add-hook 'window-buffer-change-functions #'spectreshell--relay-resend nil t)
    (add-hook 'kill-buffer-hook #'spectreshell--relay-kill-buffer nil t))
  (when string
    (spectreshell--relay obj string)))

(defun spectreshell--relay-resend (window)
  "Relay the strings kept for WINDOW's buffer to WINDOW's terminal.
Buffer-local member of `window-buffer-change-functions', added by
`spectreshell--relay-keep'."
  (when-let* ((terminal (spectreshell--relay-terminal (window-frame window))))
    (pcase-dolist (`(,_ ,string . ,_)
                   (buffer-local-value 'spectreshell--relay-kept
                                       (window-buffer window)))
      (send-string-to-terminal string terminal))))

(defun spectreshell--relay-release (obj)
  "Stop keeping what OBJ kept with a CLEAR string, relaying each CLEAR.
See `spectreshell--relay-keep'."
  (with-current-buffer (spectreshell-buffer obj)
    (pcase-dolist (`(,key ,_ ,owner ,clear) (copy-sequence spectreshell--relay-kept))
      (when (and clear (eq owner obj))
        (setf (alist-get key spectreshell--relay-kept nil t) nil)
        (spectreshell--relay obj clear)))))

(defun spectreshell--relay-kill-buffer ()
  "Relay the CLEAR string of everything kept for the buffer being killed.
Buffer-local member of `kill-buffer-hook', added by
`spectreshell--relay-keep'.  The windows still show the buffer at this
point, so the terminals to clear are still found."
  (pcase-dolist (`(,_ ,_ ,owner ,clear) spectreshell--relay-kept)
    (when clear
      (spectreshell--relay owner clear))))

;; ---------------------------------------------------------------------
;; Frames the user looks at
;; ---------------------------------------------------------------------

(defun spectreshell--frame-shown-p (frame)
  "Return non-nil if FRAME may be in front of the user.
A daemon's initial frame is not: nobody looks at it.  Nor is an
iconified or invisible frame.  A tty frame is only while its root frame
is its terminal's top frame, since Emacs leaves the frame a tty switched
away from marked visible.  A tty frame that the outer terminal hides
behind another tab looks shown, since Emacs cannot tell."
  (and (not (frame-initial-p frame))
       (eq (frame-visible-p frame) t)
       (or (not (eq (framep frame) t))
           (eq (frame-root-frame frame) (tty-top-frame frame)))))

(defun spectreshell--buffer-shown-p (buffer)
  "Return t if a window of a shown frame shows BUFFER.
Any window counts, not only the selected one.  See
`spectreshell--frame-shown-p' for the frames that count."
  (and (seq-some (lambda (frame)
                   (and (spectreshell--frame-shown-p frame)
                        (get-buffer-window buffer frame)))
                 (frame-list))
       t))

;; ---------------------------------------------------------------------
;; Clipboard (OSC 52 / OSC 5522)
;; ---------------------------------------------------------------------

(defcustom spectreshell-clipboard-read 'ask
  "Whether the child may read Emacs's clipboard (OSC 52 / OSC 5522).
`allow' answers without asking, `ask' (the default) asks in the
minibuffer first and `deny' answers with nothing.  The clipboard is the
front of the kill ring as `current-kill' sees it, so a newer selection
from another program comes first.  Reads are never asked about when
nobody can answer (`spectreshell--clipboard-can-ask-p'); they are
answered with nothing instead.  Nor are OSC 5522 reads that ask for no
text (only the list of types, or only types other than text), or that
carry a password already allowed: they reveal nothing, or were allowed
before."
  :type '(choice (const :tag "Allow" allow)
                 (const :tag "Ask" ask)
                 (const :tag "Deny" deny))
  :group 'spectreshell)

(defcustom spectreshell-clipboard-write 'allow
  "Whether the child may write Emacs's clipboard (OSC 52 / OSC 5522).
`allow' writes without asking, `ask' asks in the minibuffer first and
`deny' drops the write.  A write to the clipboard goes to the kill ring
with `kill-new', which hands it on to `interprogram-cut-function'; a
write to the primary selection goes to `gui-set-selection' only.
Writes are never asked about when nobody can answer
\(`spectreshell--clipboard-can-ask-p'); they are dropped instead.  An
OSC 5522 write is told it succeeded before it is asked about, unless
this is `deny'."
  :type '(choice (const :tag "Allow" allow)
                 (const :tag "Ask" ask)
                 (const :tag "Deny" deny))
  :group 'spectreshell)

(defvar xterm-max-cut-length)

(defvar spectreshell--clipboard-ask-function #'spectreshell--clipboard-ask
  "Function asking the user about a clipboard request.
Called with the `spectreshell' object, the request plist and a prompt;
returns `allow', `deny', or `always' to allow this and later requests
carrying the same password.")

(defconst spectreshell--clipboard-queue-limit 64
  "Most requests one terminal may have waiting to be handled.
More are denied at once, so that a child cannot grow the queue without
bound while a prompt waits.  The module's limit on unanswered reads.")

(defvar spectreshell--clipboard-queues nil
  "Clipboard requests not yet handled, as (OBJ . REQUESTS) per terminal.
Each terminal's REQUESTS are oldest first, and handled in that order.")

(defvar spectreshell--clipboard-timer nil
  "Timer that will run `spectreshell--clipboard-run', or nil.")

(defvar spectreshell--clipboard-running nil
  "Non-nil while `spectreshell--clipboard-run' handles requests.")

(defvar spectreshell--clipboard-ask-timer nil
  "Timer that will run `spectreshell--clipboard-ask-tick', or nil.")

;; Longer than the pause between keys while typing, so that a key meant
;; for the terminal does not land in the prompt, yet short enough not to
;; feel like a wait once the user stops.
(defconst spectreshell--clipboard-ask-delay 0.5
  "Seconds without input before a clipboard prompt is shown.")

(defconst spectreshell--clipboard-ask-poll 0.1
  "Seconds between checks whether a clipboard prompt can be shown.")

(defvar spectreshell--clipboard-input-seen nil
  "(COUNT . TIME) of `num-nonmacro-input-events' last seen to change, or nil.")

(defvar spectreshell--clipboard-asking nil
  "The terminal whose request is being asked about, or nil.
One prompt at a time across all terminals.  The asked terminal's later
requests wait behind it; the other terminals' requests do not.")

(defun spectreshell--clipboard-take (obj update)
  "Queue the `:clipboard' requests of the module UPDATE plist for OBJ.
Member of `spectreshell--update-functions'.  They are handled from a
timer rather than here: this runs inside the process filter, where
`kill-new' or `current-kill' waiting on the outer terminal or the
window system would let the filter run again in the middle of a feed,
and where `inhibit-quit' keeps \\[keyboard-quit] from answering a prompt.
Requests beyond `spectreshell--clipboard-queue-limit' are denied here."
  (when-let* ((requests (plist-get update :clipboard)))
    (let ((entry (assq obj spectreshell--clipboard-queues)))
      (unless entry
        (setq entry (list obj))
        (setq spectreshell--clipboard-queues
              (nconc spectreshell--clipboard-queues (list entry))))
      (dolist (request requests)
        (if (< (length (cdr entry)) spectreshell--clipboard-queue-limit)
            (setcdr entry (nconc (cdr entry) (list request)))
          (spectreshell--clipboard-answer obj request nil))))
    (spectreshell--clipboard-schedule)))

(add-hook 'spectreshell--update-functions #'spectreshell--clipboard-take)

(defun spectreshell--clipboard-schedule ()
  "Arm the timer handling the queued requests, unless it is armed."
  (unless spectreshell--clipboard-timer
    (setq spectreshell--clipboard-timer
          (run-at-time 0 nil #'spectreshell--clipboard-run))))

(defun spectreshell--clipboard-run ()
  "Handle the queued requests that need no prompt, in each terminal's order.
A terminal's requests stop at the first one that needs a prompt, and
all of them wait while one of its requests is being asked about; the
prompt is left to `spectreshell--clipboard-ask-next'.  Does nothing
when already running: handling a request can let timers run, and the
outer call picks up whatever was queued meanwhile."
  (setq spectreshell--clipboard-timer nil)
  (unless spectreshell--clipboard-running
    (let ((spectreshell--clipboard-running t)
          (taken nil)
          (finished nil))
      (unwind-protect
          (progn
            (while-let ((next (spectreshell--clipboard-take-decided)))
              (setq taken t)
              (apply #'spectreshell--clipboard-handle next))
            (setq finished t))
        ;; Only after taking a request, so that an error before taking
        ;; any, were it to come every time, does not keep a timer
        ;; running every moment.
        (when (and taken (not finished))
          (spectreshell--clipboard-schedule))
        (spectreshell--clipboard-forget-done)
        (spectreshell--clipboard-schedule-ask)))))

(defun spectreshell--clipboard-take-decided ()
  "Take the first queued request that is decided without a prompt.
Return (OBJ REQUEST DECISION), or nil when every terminal's first
request needs a prompt or waits behind one."
  (seq-some (lambda (entry)
              (let ((obj (car entry)))
                (when-let* (((cdr entry))
                            ((not (eq obj spectreshell--clipboard-asking)))
                            ((spectreshell--clipboard-live-p obj))
                            (decision (spectreshell--clipboard-decision
                                       obj (cadr entry))))
                  (list obj (pop (cdr entry)) decision))))
            spectreshell--clipboard-queues))

(defun spectreshell--clipboard-forget-done ()
  "Forget the terminals with nothing queued, or finalized.
A finalized terminal's requests go unanswered: its module is gone."
  (setq spectreshell--clipboard-queues
        (seq-filter (lambda (entry)
                      (and (cdr entry) (spectreshell--clipboard-live-p (car entry))))
                    spectreshell--clipboard-queues)))

(defun spectreshell--clipboard-schedule-ask ()
  "Start checking for a moment to show a prompt, if a request waits for one.
Not while a prompt is shown: its end runs the queue again, which calls
this."
  (when (and (not spectreshell--clipboard-asking)
             (not spectreshell--clipboard-ask-timer)
             spectreshell--clipboard-queues)
    (setq spectreshell--clipboard-input-seen nil)
    (spectreshell--clipboard-arm-ask)))

(defun spectreshell--clipboard-arm-ask ()
  "Arm the timer running `spectreshell--clipboard-ask-tick'."
  ;; Not a repeating timer: `timer-event-handler' re-arms one before
  ;; calling it, so it would run again in the middle of the prompt.
  (setq spectreshell--clipboard-ask-timer
        (run-at-time spectreshell--clipboard-ask-poll nil
                     #'spectreshell--clipboard-ask-tick)))

(defun spectreshell--clipboard-ask-tick ()
  "Show a prompt if input has stopped, and check again while requests wait.
The prompt waits until the user has stopped typing
\(`spectreshell--clipboard-input-stopped-p'), so that the child cannot
time a request to take a key typed for something else as the answer.
The timer stops once no request is waiting, and while a prompt is shown."
  ;; A timer checking `num-nonmacro-input-events' rather than an idle
  ;; timer: Emacs counts itself idle again only after the next key once
  ;; a prompt has read its answer, so the next prompt would wait for
  ;; that key, and a user away from the keyboard would never see it.
  (setq spectreshell--clipboard-ask-timer nil)
  (when (spectreshell--clipboard-input-stopped-p)
    (spectreshell--clipboard-ask-next))
  (spectreshell--clipboard-forget-done)
  (when (and spectreshell--clipboard-queues
             (not spectreshell--clipboard-asking)
             (not spectreshell--clipboard-ask-timer))
    (spectreshell--clipboard-arm-ask)))

(defun spectreshell--clipboard-input-stopped-p ()
  "Return non-nil if no input has come for `spectreshell--clipboard-ask-delay'.
That is, `num-nonmacro-input-events' has not changed since that long
ago, as far as the calls to this have seen."
  (let ((count num-nonmacro-input-events)
        (now (float-time)))
    (if (eql count (car spectreshell--clipboard-input-seen))
        (>= (- now (cdr spectreshell--clipboard-input-seen))
            spectreshell--clipboard-ask-delay)
      (setq spectreshell--clipboard-input-seen (cons count now))
      nil)))

(defun spectreshell--clipboard-ask-next ()
  "Ask about the first request waiting for a prompt, and handle it.
Whether the prompt is still needed, and whether anyone can answer it,
is decided again here, just before asking.  Nothing is asked while the
minibuffer is in use: the prompt would then fail, end the user's
minibuffer, or with `enable-recursive-minibuffers' open on top of it;
the request waits instead.  The request is answered however asking
ends, a denial unless the user allowed it.  \\[keyboard-quit] also
denies every request of the same terminal still waiting for a prompt,
so that a child asking again and again can be stopped.

Nothing is asked while requests are being handled either: the end of
`spectreshell--clipboard-run' looks for prompts again.  The terminals
take turns: the one asked about goes to the back of the queue, so that
a child asking again and again does not keep the others waiting."
  (unless (or spectreshell--clipboard-asking
              spectreshell--clipboard-running
              (> (minibuffer-depth) 0))
    (let ((entry (spectreshell--clipboard-next-to-ask)))
      (spectreshell--clipboard-forget-done)
      (when entry
        (let ((obj (car entry)))
          (if (spectreshell--clipboard-decision obj (cadr entry))
              ;; Decided meanwhile (the user options changed): no prompt.
              (spectreshell--clipboard-schedule)
            (setq spectreshell--clipboard-queues
                  (nconc (delq entry spectreshell--clipboard-queues) (list entry)))
            (let ((request (pop (cdr entry)))
                  (decision 'deny))
            (setq spectreshell--clipboard-asking obj)
            (unwind-protect
                (setq decision (spectreshell--clipboard-ask-user obj request))
              (setq spectreshell--clipboard-asking nil)
              (spectreshell--clipboard-schedule)
              (unwind-protect
                  (spectreshell--clipboard-handle obj request decision)
                (when (eq decision 'quit)
                  (spectreshell--clipboard-deny-prompts obj)))))))))))

(defun spectreshell--clipboard-next-to-ask ()
  "Return the queue entry of the first live terminal with a request to take.
That is a first request decided meanwhile, or one to ask about while
the selected frame shows the terminal's buffer
\(`spectreshell--clipboard-in-front-p'); the others wait.  Requests the
module no longer waits on (`spectreshell--clipboard-awaited-p') are
dropped from the front of each queue on the way, unasked."
  (seq-find (lambda (entry)
              (let ((obj (car entry)))
                (when (spectreshell--clipboard-live-p obj)
                  (while (and (cdr entry)
                              (not (spectreshell--clipboard-awaited-p
                                    obj (cadr entry))))
                    (pop (cdr entry)))
                  (and (cdr entry)
                       (or (spectreshell--clipboard-decision obj (cadr entry))
                           (spectreshell--clipboard-in-front-p
                            (spectreshell-buffer obj)))))))
            spectreshell--clipboard-queues))

(defun spectreshell--clipboard-awaited-p (obj request)
  "Return non-nil unless OBJ's module no longer waits on REQUEST.
A request with an `:id' stops being waited on when the child resets
\(RIS); one without cannot be told, and counts as waited on."
  (let ((id (plist-get request :id)))
    (or (null id)
        (spectreshell--clipboard-pending-p (spectreshell-term obj) id))))

(defun spectreshell--clipboard-ask-user (obj request)
  "Ask about OBJ's REQUEST; return `allow', `deny', `always' or `quit'.
`quit' is \\[keyboard-quit] at the prompt; an error is `deny'."
  ;; Not `with-local-quit': it sets `quit-flag' again on the way out,
  ;; which would quit whatever runs the timer.
  (condition-case nil
      (let ((inhibit-quit nil))
        (funcall spectreshell--clipboard-ask-function obj request
                 (spectreshell--clipboard-prompt obj request)))
    (quit 'quit)
    (error 'deny)))

(defun spectreshell--clipboard-deny-prompts (obj)
  "Deny every queued request of OBJ's that would need a prompt."
  (when-let* ((entry (assq obj spectreshell--clipboard-queues)))
    (let ((kept nil)
          (denied nil))
      (dolist (request (cdr entry))
        (if (spectreshell--clipboard-decision obj request)
            (push request kept)
          (push request denied)))
      (setcdr entry (nreverse kept))
      (dolist (request (nreverse denied))
        (spectreshell--clipboard-answer obj request nil)))))

(defun spectreshell--clipboard-live-p (obj)
  "Return non-nil if OBJ has been neither finalized nor its buffer killed."
  (marker-buffer (spectreshell-marker obj)))

(defun spectreshell--clipboard-can-ask-p (buffer)
  "Return non-nil if the user can be asked about BUFFER's child.
Not in batch, and only while BUFFER is shown
\(`spectreshell--buffer-shown-p'): a daemon with no clients has nobody
to answer, and a hidden buffer leaves the user guessing which program
asks."
  (and (not noninteractive)
       (spectreshell--buffer-shown-p buffer)))

(defun spectreshell--clipboard-in-front-p (buffer)
  "Return non-nil if the selected frame is shown and shows BUFFER.
A prompt waits for this, so that with several clients of a daemon it
comes up where the user looks at BUFFER, not on another terminal."
  (let ((frame (selected-frame)))
    (and (spectreshell--frame-shown-p frame)
         (get-buffer-window buffer frame)
         t)))

(defun spectreshell--clipboard-decision (obj request)
  "Return `allow' or `deny' for OBJ's REQUEST if no prompt is needed, else nil.
The policy is `spectreshell-clipboard-read' or `-write'.  `ask' needs
a prompt unless REQUEST is already granted (a password remembered with
`always', or a paste event's), asks for no text, or nobody can answer."
  (let ((policy (if (eq (plist-get request :op) 'read)
                    spectreshell-clipboard-read
                  spectreshell-clipboard-write)))
    (cond
     ((eq policy 'deny) 'deny)
     ((and (eq (plist-get request :op) 'write)
           (string-empty-p (plist-get request :text)))
      'deny)
     ((or (eq policy 'allow)
          (plist-get request :granted)
          (plist-get request :no-text))
      'allow)
     ((not (spectreshell--clipboard-can-ask-p (spectreshell-buffer obj))) 'deny))))

(defconst spectreshell--clipboard-word-characters "abcdefghjkmnpqrstuvwxyz23456789"
  "Characters of the words typed to answer a clipboard prompt.
Lowercase letters and digits, without those easily taken for one
another: 0 and o, 1, l and i.")

(defconst spectreshell--clipboard-word-length 4
  "Length of the words typed to answer a clipboard prompt.")

(defvar spectreshell--clipboard-word-function #'spectreshell--clipboard-random-word
  "Function of no arguments returning a fresh word to answer a prompt with.")

(defvar spectreshell--clipboard-answer-history nil
  "History of the answers to clipboard prompts, bound empty while asking.")

;; `random' rather than a cryptographic source: the words only have to
;; be unknown to the child, which sees neither Emacs's state nor its
;; display, and Emacs seeds `random' from the system's entropy at
;; startup.
(defun spectreshell--clipboard-random-word ()
  "Return a random word of `spectreshell--clipboard-word-characters'."
  (let ((chars spectreshell--clipboard-word-characters))
    (apply #'string
           (cl-loop repeat spectreshell--clipboard-word-length
                    collect (aref chars (random (length chars)))))))

(defun spectreshell--clipboard-ask (_obj request prompt)
  "Ask with PROMPT about REQUEST; return `allow', `deny' or `always'.
Each prompt shows fresh words from `spectreshell--clipboard-word-function':
one allows this request, and another, offered only when REQUEST can be
remembered, also allows the later ones carrying its password.  Anything
else typed, an empty answer included, denies.  The answer is read
without completion, history, or a dialog after a mouse event."
  ;; Words made up for each prompt rather than fixed answers (y, yes,
  ;; always): a child can show a question of its own and time its
  ;; request so that what the user types for that question lands here.
  (let* ((once (funcall spectreshell--clipboard-word-function))
         (always (and (plist-get request :remember)
                      (let ((word once))
                        (while (equal word once)
                          (setq word (funcall spectreshell--clipboard-word-function)))
                        word)))
         (answer (let ((use-dialog-box nil)
                       (spectreshell--clipboard-answer-history nil))
                   (read-string
                    (format "%s  Allow once: %s%s / Anything else denies: "
                            prompt once
                            (if always (format " / Always allow: %s" always) ""))
                    nil 'spectreshell--clipboard-answer-history))))
    (cond ((equal answer once) 'allow)
          ((and always (equal answer always)) 'always)
          (t 'deny))))

(defun spectreshell--clipboard-prompt (obj request)
  "Return the question whether to allow OBJ's REQUEST, for a prompt."
  (let ((where (if (eq (plist-get request :loc) 'primary)
                   "primary selection"
                 "clipboard")))
    (if (eq (plist-get request :op) 'read)
        (format "Spectreshell: %s wants to read the %s."
                (spectreshell--clipboard-program obj request) where)
      (format "Spectreshell: %s wants to copy %d characters to the %s."
              (spectreshell--clipboard-program obj request)
              (length (spectreshell--clipboard-text request))
              where))))

(defconst spectreshell--clipboard-name-width 40
  "Most columns of the child's name shown in a prompt.")

(defun spectreshell--clipboard-program (obj request)
  "Describe who sent OBJ's REQUEST, for a prompt.
The name the child gave, if any, keeps only letters and digits (of any
script), spaces and -_.:/+@, is cut to `spectreshell--clipboard-name-width'
columns and is quoted with `prin1', so that it can neither redraw nor
reorder the prompt nor pass its own words off as the prompt's."
  (let ((name (truncate-string-to-width
               (replace-regexp-in-string
                "[^[:alnum:] _.:/+@-]" ""
                (decode-coding-string (or (plist-get request :name) "") 'utf-8-unix))
               spectreshell--clipboard-name-width nil nil t)))
    (format "%s in %s"
            (if (string-empty-p name) "the program" (format "%S" name))
            (buffer-name (spectreshell-buffer obj)))))

(defun spectreshell--clipboard-text (request)
  "Return the text of the write REQUEST, decoded as UTF-8.
Line ends are kept as the child wrote them."
  (decode-coding-string (plist-get request :text) 'utf-8-unix))

(defun spectreshell--clipboard-answer (obj request result &optional remember)
  "Answer OBJ's REQUEST with RESULT, a string or nil to deny, and send it.
REMEMBER non-nil remembers the request's password.  Nothing to do for a
request without an `:id', or for a finalized terminal.  An error is
reported rather than signaled: this runs where the rest must go on."
  (condition-case err
      (when-let* ((id (plist-get request :id))
                  ((spectreshell--clipboard-live-p obj))
                  (bytes (spectreshell--clipboard-reply
                          (spectreshell-term obj) id result remember)))
        (funcall (spectreshell-send-fn obj) bytes))
    (error (message "Spectreshell: clipboard answer failed: %S" err))))

(defun spectreshell--clipboard-handle (obj request decision)
  "Carry out DECISION, `allow', `always' or else a denial, on OBJ's REQUEST."
  (if (eq (plist-get request :op) 'read)
      (spectreshell--clipboard-handle-read obj request decision)
    (spectreshell--clipboard-handle-write obj request decision)))

(defun spectreshell--clipboard-handle-write (obj request decision)
  "Write the text of OBJ's write REQUEST if DECISION allows it.
A REQUEST with an `:id' is answered whether to remember its password
however writing ends; leaving without finishing does not remember.
An OSC 5522 write was already told it succeeded (the module answers
during the feed), so a write denied here is dropped silently."
  (let ((remember nil))
    (unwind-protect
        (when (memq decision '(allow always))
          (condition-case err
              (spectreshell--clipboard-write
               (eq (plist-get request :loc) 'primary)
               (spectreshell--clipboard-text request))
            (error (message "Spectreshell: clipboard write failed: %S" err)))
          (setq remember (eq decision 'always)))
      (spectreshell--clipboard-answer obj request nil remember))))

(defun spectreshell--clipboard-handle-read (obj request decision)
  "Answer OBJ's read REQUEST as DECISION says.
The answer goes out however reading ends, a denial unless the text was
read, so that the child is not left waiting."
  (let ((result nil))
    (unwind-protect
        (when (memq decision '(allow always))
          (setq result
                (condition-case err
                    (if (plist-get request :no-text)
                        ;; Only the list of types: nothing to read.
                        ""
                      (encode-coding-string
                       (spectreshell--clipboard-read
                        (eq (plist-get request :loc) 'primary))
                       'utf-8-unix))
                  (error (message "Spectreshell: clipboard read failed: %S" err)
                         nil))))
      (spectreshell--clipboard-answer obj request result
                                      (and result (eq decision 'always))))))

(defun spectreshell--clipboard-read (primary)
  "Return the primary selection if PRIMARY, else the front of the kill ring.
Through `current-kill' rather than `interprogram-paste-function' itself,
so that the kill ring takes in what it returns as a yank would.  Nothing
there, or an error getting it, gives the empty string."
  (let ((text (if primary
                  (condition-case nil (gui-get-primary-selection) (error nil))
                (condition-case nil (current-kill 0 t) (error nil)))))
    (if (stringp text) (substring-no-properties text) "")))

(defun spectreshell--clipboard-write (primary text)
  "Put TEXT in the primary selection if PRIMARY, else in the kill ring.
TEXT that xterm.el would refuse to send to the outer terminal
\(`spectreshell--clipboard-too-long-p') only goes to the kill ring, or
nowhere for the primary selection: xterm.el would warn and wait two
seconds."
  (let ((too-long (spectreshell--clipboard-too-long-p text)))
    (cond
     ((and primary too-long)
      (message "Spectreshell: %d characters are too long for the terminal's primary selection (`xterm-max-cut-length')"
               (length text)))
     (primary (gui-set-selection 'PRIMARY text))
     (t
      (let ((interprogram-cut-function (unless too-long interprogram-cut-function)))
        (kill-new text))
      ;; The command loop has set `last-command' to the command before
      ;; this timer; left so, the next command would take this write as
      ;; part of the user's own kills or yanks: `kill-region' would
      ;; append to it, and `yank-pop' would rotate past it.  Other
      ;; commands are left alone, so as not to break a run of `undo',
      ;; the goal column of `next-line', or a history search.
      (when (memq last-command '(kill-region yank))
        (setq last-command nil))
      (when too-long
        (message "Spectreshell: copied %d characters to the kill ring only; too long for the terminal's clipboard (`xterm-max-cut-length')"
                 (length text)))))))

(defun spectreshell--track-clipboard-write (obj)
  "Tell OBJ's module `spectreshell-clipboard-write'.
Member of `spectreshell--before-feed-functions'.  The module answers an
OSC 5522 write during the feed, before any prompt can be shown: `deny'
with EPERM, the others with success."
  (spectreshell--set-clipboard-write
   (spectreshell-term obj)
   (if (memq spectreshell-clipboard-write '(allow ask)) spectreshell-clipboard-write 'deny)))

(add-hook 'spectreshell--before-feed-functions #'spectreshell--track-clipboard-write)

(defun spectreshell--clipboard-paste-event (obj)
  "Return OBJ's kitty paste event for a yank, or nil to paste the text.
An event only while the child has asked for them (mode 5522), and not
when `spectreshell-clipboard-read' is `deny': the child reads the text
after the event, and a denied read would lose the paste."
  (unless (eq spectreshell-clipboard-read 'deny)
    (spectreshell--encode-paste-event (spectreshell-term obj))))

(defun spectreshell--clipboard-too-long-p (text)
  "Return non-nil if xterm.el would refuse to send TEXT to the outer terminal.
That is when the selected frame's terminal takes selections as OSC 52
\(`xterm--set-selection') and TEXT in base64 is longer than
`xterm-max-cut-length', the same check xterm.el makes."
  (and (not (display-graphic-p))
       (eq (terminal-parameter nil 'xterm--set-selection) t)
       (boundp 'xterm-max-cut-length)
       (> (* 4 (/ (+ (length (encode-coding-string text 'utf-8-unix)) 2) 3))
          xterm-max-cut-length)))

;; ---------------------------------------------------------------------
;; Desktop notifications (OSC 777 / OSC 9)
;; ---------------------------------------------------------------------

(defun spectreshell--relay-notification (obj title body)
  "Relay the child's desktop notification of TITLE and BODY for OBJ.
Both OSC 777 and OSC 9 go out as OSC 777: an OSC 9 body starting with
a digit and a semicolon would read as a ConEmu command instead.  Control
characters are dropped from both so the child cannot slip other escape
sequences to the outer terminal, and so is a semicolon in TITLE, which
would otherwise end it early."
  (spectreshell--relay
   obj (concat "\e]777;notify;"
               (replace-regexp-in-string "[\0-\37\177;]" "" title)
               ";"
               (replace-regexp-in-string "[\0-\37\177]" "" body)
               "\a")))

(setf (alist-get 'notification spectreshell--relay-handlers)
      #'spectreshell--relay-notification)

;; ---------------------------------------------------------------------
;; Progress (OSC 9;4)
;; ---------------------------------------------------------------------

(defun spectreshell--relay-progress (obj state value)
  "Relay the child's OSC 9;4 progress STATE, with VALUE if non-nil, for OBJ.
The latest progress is kept (`spectreshell--relay-keep') and cleared
once OBJ's job ends.  STATE 0 is that clearing itself, so it is sent
once and stops the keeping instead."
  (let ((string (format "\e]9;4;%d%s\a" state (if value (format ";%d" value) ""))))
    (if (eq state 0)
        (progn
          (spectreshell--relay-keep obj 'progress nil)
          (spectreshell--relay obj string))
      (spectreshell--relay-keep obj 'progress string "\e]9;4;0\a"))))

(setf (alist-get 'progress spectreshell--relay-handlers)
      #'spectreshell--relay-progress)

;; ---------------------------------------------------------------------
;; Window titles (OSC 0/2)
;; ---------------------------------------------------------------------

(defun spectreshell-relay-title (obj title)
  "Send OBJ's child's TITLE to the outer terminals showing its buffer.
Meant for `spectreshell-title-functions'; spectreshell does not add it
there itself.  Sent as OSC 2 in UTF-8, with control characters dropped
so the child cannot slip other escape sequences to the outer terminal.
With `xterm-set-window-title' on, Emacs replaces this title with
`frame-title-format' after the next command."
  (spectreshell--relay
   obj (concat "\e]2;"
               (encode-coding-string
                (replace-regexp-in-string "[\0-\37\177]" "" title) 'utf-8)
               "\a")))

;; ---------------------------------------------------------------------
;; Bell
;; ---------------------------------------------------------------------

(defun spectreshell--relay-bell (obj)
  "Relay the child's BEL for OBJ.
Not `ding': that rings only on the selected frame, and goes through
`ring-bell-function' and `visible-bell' rather than letting the outer
terminal show the bell its own way."
  (spectreshell--relay obj "\a"))

(setf (alist-get 'bell spectreshell--relay-handlers)
      #'spectreshell--relay-bell)

;; ---------------------------------------------------------------------
;; Focus reports (mode 1004)
;; ---------------------------------------------------------------------

(defvar spectreshell--focus-terminals nil
  "Alist of (OBJ . FOCUSED) for terminals whose child wants focus reports.
FOCUSED is the focus last reported to the child.")

(defun spectreshell--focused-p (buffer)
  "Return t if a focused frame shows BUFFER in its selected window.
A frame whose focus is `unknown' counts as focused, as Ghostty assumes
focus until told otherwise.  A daemon's initial frame does not count:
nobody looks at it."
  (and (seq-some (lambda (frame)
                   (and (not (frame-initial-p frame))
                        (eq (window-buffer (frame-selected-window frame)) buffer)
                        (frame-focus-state frame)))
                 (frame-list))
       t))

(defun spectreshell--send-focus (obj focused)
  "Tell OBJ's child that it has gained focus if FOCUSED, else lost it."
  (funcall (spectreshell-send-fn obj) (if focused "\e[I" "\e[O")))

(defun spectreshell--track-focus (obj update)
  "Start or stop reporting focus to OBJ's child as the module UPDATE says.
On start the current focus is reported at once, as Ghostty does."
  (let ((entry (assq obj spectreshell--focus-terminals)))
    (cond
     ((and (plist-get update :focus-event) (not entry))
      (let ((focused (spectreshell--focused-p (spectreshell-buffer obj))))
        (push (cons obj focused) spectreshell--focus-terminals)
        (spectreshell--send-focus obj focused)))
     ((and entry (not (plist-get update :focus-event)))
      (setq spectreshell--focus-terminals
            (delq entry spectreshell--focus-terminals))))))

(add-hook 'spectreshell--update-functions #'spectreshell--track-focus)

(defun spectreshell--report-focus (&rest _)
  "Report focus changes to the children that want focus reports.
Terminals that have been finalized, or whose buffer is gone, are
forgotten instead."
  (dolist (entry spectreshell--focus-terminals)
    (let ((obj (car entry)))
      (if (not (marker-buffer (spectreshell-marker obj)))
          (setq spectreshell--focus-terminals
                (delq entry spectreshell--focus-terminals))
        (let ((focused (spectreshell--focused-p (spectreshell-buffer obj))))
          (unless (eq focused (cdr entry))
            (setcdr entry focused)
            (spectreshell--send-focus obj focused)))))))

(add-function :after after-focus-change-function #'spectreshell--report-focus)
(add-hook 'window-selection-change-functions #'spectreshell--report-focus)
(add-hook 'window-buffer-change-functions #'spectreshell--report-focus)

;; ---------------------------------------------------------------------
;; Frame for answering color queries
;; ---------------------------------------------------------------------

(defun spectreshell--buffer-frame (buffer)
  "Return the frame whose colors BUFFER's terminal answers the child with.
That is the selected window's frame if that window shows BUFFER, else
a frame of any window showing it, else the selected frame."
  (let ((window (if (eq (window-buffer (selected-window)) buffer)
                    (selected-window)
                  (get-buffer-window buffer t))))
    (if window (window-frame window) (selected-frame))))

;; ---------------------------------------------------------------------
;; Color scheme (?996n / mode 2031)
;; ---------------------------------------------------------------------

(defvar spectreshell--color-scheme-terminals nil
  "Terminals whose module was told the color scheme.
They are told again whenever it may have changed.")

(defun spectreshell--color-scheme (buffer)
  "Return `light' or `dark', the `background-mode' of a frame showing BUFFER.
The frame is the one `spectreshell--buffer-frame' picks."
  (if (eq (frame-parameter (spectreshell--buffer-frame buffer) 'background-mode)
          'light)
      'light
    'dark))

(defun spectreshell--update-color-scheme (obj)
  "Tell OBJ's module the current color scheme.
The module answers the child's queries with it, and returns a report
for the child when the scheme changed while the child asks for them
\(mode 2031); that report is sent here."
  (when-let* ((report (spectreshell--set-color-scheme
                       (spectreshell-term obj)
                       (spectreshell--color-scheme (spectreshell-buffer obj)))))
    (funcall (spectreshell-send-fn obj) report)))

(defun spectreshell--track-color-scheme (obj)
  "Tell OBJ's module the current color scheme and keep it told.
Member of `spectreshell--before-feed-functions'."
  (unless (memq obj spectreshell--color-scheme-terminals)
    (push obj spectreshell--color-scheme-terminals))
  (spectreshell--update-color-scheme obj))

(add-hook 'spectreshell--before-feed-functions #'spectreshell--track-color-scheme)

(defun spectreshell--report-color-scheme (&rest _)
  "Tell every tracked terminal the color scheme, which may have changed.
Terminals that have been finalized, or whose buffer is gone, are
forgotten instead."
  (dolist (obj spectreshell--color-scheme-terminals)
    (if (marker-buffer (spectreshell-marker obj))
        (spectreshell--update-color-scheme obj)
      (setq spectreshell--color-scheme-terminals
            (delq obj spectreshell--color-scheme-terminals)))))

(add-hook 'enable-theme-functions #'spectreshell--report-color-scheme)
(add-hook 'disable-theme-functions #'spectreshell--report-color-scheme)
(add-hook 'window-buffer-change-functions #'spectreshell--report-color-scheme)
(add-hook 'window-selection-change-functions #'spectreshell--report-color-scheme)

;; ---------------------------------------------------------------------
;; Visibility (?998n / mode 2033)
;; ---------------------------------------------------------------------

(defvar spectreshell--visibility-terminals nil
  "Terminals whose module was told the visibility.
They are told again whenever it may have changed.")

(defun spectreshell--update-visibility (obj)
  "Tell OBJ's module whether its buffer is visible.
The module answers the child's queries with it, and returns a report
for the child when the visibility changed while the child asks for them
\(mode 2033); that report is sent here."
  (when-let* ((report (spectreshell--set-visibility
                       (spectreshell-term obj)
                       (spectreshell--buffer-shown-p (spectreshell-buffer obj)))))
    (funcall (spectreshell-send-fn obj) report)))

(defun spectreshell--track-visibility (obj)
  "Tell OBJ's module the current visibility and keep it told.
Member of `spectreshell--before-feed-functions'."
  (unless (memq obj spectreshell--visibility-terminals)
    (push obj spectreshell--visibility-terminals))
  (spectreshell--update-visibility obj))

(add-hook 'spectreshell--before-feed-functions #'spectreshell--track-visibility)

(defun spectreshell--report-visibility (&rest _)
  "Tell every tracked terminal its visibility, which may have changed.
Terminals that have been finalized, or whose buffer is gone, are
forgotten instead."
  (dolist (obj spectreshell--visibility-terminals)
    (if (marker-buffer (spectreshell-marker obj))
        (spectreshell--update-visibility obj)
      (setq spectreshell--visibility-terminals
            (delq obj spectreshell--visibility-terminals)))))

;; Windows gaining or losing the buffer, the selection moving (switching
;; tty frames changes the top frame and selects it), frames being
;; deleted, and focus changes.  Emacs has no hook for a frame being
;; iconified or made visible, and special-event-map or advice would
;; override the user's own bindings; iconifying usually loses focus, so
;; that stands in for it.  `after-delete-frame-functions' rather than
;; `delete-frame-functions', which runs while the frame is still in
;; `frame-list'.
(add-hook 'window-buffer-change-functions #'spectreshell--report-visibility)
(add-hook 'window-selection-change-functions #'spectreshell--report-visibility)
(add-hook 'after-delete-frame-functions #'spectreshell--report-visibility)
(add-function :after after-focus-change-function
              #'spectreshell--report-visibility)

;; ---------------------------------------------------------------------
;; Colors (OSC 10 / 11 / 4)
;; ---------------------------------------------------------------------

(defvar spectreshell--colors-given (make-hash-table :test 'eq :weakness 'key)
  "Colors last given to each terminal's module, keyed by terminal.
The values are argument lists for `spectreshell--set-colors'.")

(defun spectreshell--colors (buffer)
  "Return (FG BG PALETTE), the colors to answer BUFFER's child with.
FG and BG are the `default' face's, and PALETTE lists the foregrounds
of `spectreshell-color-0' to 15 (the faces `spectreshell--resolve-color'
draws SGR 30-37 and 90-97 with; their backgrounds, used for SGR 40-47
and 100-107, are not answered).  Each is the `color-values' of the
color, or nil if it has none (a tty's unspecified-fg and -bg).

The faces are resolved on the frame `spectreshell--buffer-frame' picks,
while drawing resolves them on the frame selected at feed time; the two
can differ when tty and GUI frames are mixed and the theme specifies
the faces per display type.  Buffer-local face remapping is not
reflected."
  (let ((frame (spectreshell--buffer-frame buffer)))
    (cl-flet ((rgb (color) (and color (color-values color frame))))
      (list (rgb (face-foreground 'default frame t))
            (rgb (face-background 'default frame t))
            (mapcar (lambda (i)
                      (rgb (face-foreground
                            (intern (format "spectreshell-color-%d" i))
                            frame 'default)))
                    (number-sequence 0 15))))))

(defun spectreshell--update-colors (obj)
  "Give OBJ's module the current colors if they differ from the last given."
  (let ((colors (spectreshell--colors (spectreshell-buffer obj))))
    (unless (equal colors (gethash obj spectreshell--colors-given))
      (apply #'spectreshell--set-colors (spectreshell-term obj) colors)
      (puthash obj colors spectreshell--colors-given))))

(defun spectreshell--track-colors (obj)
  "Give OBJ's module the colors on its first feed.
Member of `spectreshell--before-feed-functions'.  Later changes come
from `spectreshell--report-colors', so that faces are not looked up
for every feed."
  (unless (gethash obj spectreshell--colors-given)
    (spectreshell--update-colors obj)))

(add-hook 'spectreshell--before-feed-functions #'spectreshell--track-colors)

(defun spectreshell--report-colors (&rest _)
  "Give every tracked terminal the colors, which may have changed.
Terminals that have been finalized, or whose buffer is gone, are
forgotten instead."
  (let (objs)
    (maphash (lambda (obj _) (push obj objs)) spectreshell--colors-given)
    (dolist (obj objs)
      (if (marker-buffer (spectreshell-marker obj))
          (spectreshell--update-colors obj)
        (remhash obj spectreshell--colors-given)))))

(add-hook 'enable-theme-functions #'spectreshell--report-colors)
(add-hook 'disable-theme-functions #'spectreshell--report-colors)
(add-hook 'window-buffer-change-functions #'spectreshell--report-colors)
(add-hook 'window-selection-change-functions #'spectreshell--report-colors)

;; ---------------------------------------------------------------------
;; Style table
;; ---------------------------------------------------------------------

(defun spectreshell--apply-styles (obj update)
  "Absorb UPDATE's :styles and :styles-reset into OBJ's style table.
The module sends each style once, when its ID is first used, so OBJ
must remember them: they are what later updates' spans refer to."
  (let ((table (spectreshell-styles obj)))
    (when (plist-get update :styles-reset)
      (clrhash table)
      ;; The IDs are renumbered from scratch, so a row can come back with
      ;; a span tuple identical to the one already drawn there while its
      ;; ID now means a different style; the row cache would skip it.
      (clrhash (spectreshell-row-cache obj)))
    ;; A stale generation invalidates the cached `face' values but not the
    ;; style plists themselves -- those are never re-sent, so dropping them
    ;; would leave later spans pointing at IDs this terminal cannot resolve.
    (unless (eq (spectreshell-face-generation obj) spectreshell--face-generation)
      (setf (spectreshell-face-generation obj) spectreshell--face-generation)
      (maphash (lambda (_id entry) (setcdr entry nil)) table))
    (pcase-dolist (`(,id . ,style) (plist-get update :styles))
      (puthash id (cons style nil) table))))

(defun spectreshell--style-face (obj id)
  "Return the `face' property value for style ID in OBJ, building it once.
Nil for an unknown ID (only reachable if the module and this file
disagree about the style protocol) and for a style with no visual
attributes (a span carrying only a hyperlink)."
  (when-let* ((entry (gethash id (spectreshell-styles obj))))
    (or (cdr entry)
        (setcdr entry (spectreshell--span-face (car entry))))))

;; ---------------------------------------------------------------------
;; Terminal-region geometry helpers
;; ---------------------------------------------------------------------

(defun spectreshell--region-end (obj)
  "Return the buffer position where OBJ's terminal region ends.
Everything from there on belongs to whoever else writes into the buffer
\(eshell's prompt and command line, another job's terminal region) and
must be left untouched by the redraw helpers."
  (marker-position (spectreshell-end-marker obj)))

(defun spectreshell--set-region-end (obj)
  "Repin OBJ's end marker to point, after point extended the region."
  (set-marker (spectreshell-end-marker obj) (point)))

(defun spectreshell--row-count (obj)
  "Return how many newline-terminated lines OBJ's terminal region has."
  (count-lines (spectreshell-marker obj) (spectreshell--region-end obj)))

(defun spectreshell--pad-rows (obj upto)
  "Append blank lines to OBJ's terminal region until row UPTO exists.
The line count is taken once and the whole padding inserted in one go:
counting it per appended line means re-scanning the entire region for
every row, which is the dominant cost when a full screen has to be
built up from nothing."
  (let ((missing (- (1+ upto) (spectreshell--row-count obj))))
    (when (> missing 0)
      (let ((blank (concat (make-string (spectreshell-cols obj) ?\s) "\n")))
        (goto-char (spectreshell--region-end obj))
        (insert (mapconcat #'identity (make-list missing blank)))
        (spectreshell--set-region-end obj)))))

(defun spectreshell--trim-rows (obj)
  "Delete trailing buffer lines beyond OBJ's current row count.
Only has an effect right after `spectreshell-resize' shrank the row
count; ordinary `spectreshell-feed' calls never change the line count
of the terminal region."
  (let ((excess (- (spectreshell--row-count obj) (spectreshell-rows obj))))
    (when (> excess 0)
      (goto-char (spectreshell-marker obj))
      (forward-line (spectreshell-rows obj))
      ;; Deleting up to the end marker leaves it collapsed onto point,
      ;; i.e. already repinned to the region's new end.
      (delete-region (point) (spectreshell--region-end obj)))))

(defun spectreshell--blank-row-p (beg end)
  "Return non-nil if BEG..END in the current buffer is nothing but padding.
Padding is the run of property-less spaces the module pads every row
out to the full terminal width with; a space carrying a text property
\(a colored background, say) is real terminal content, exactly as in
`spectreshell--trim-trailing-blanks', which decides it here too."
  (equal "" (spectreshell--trim-trailing-blanks (buffer-substring beg end))))

(defun spectreshell--trim-blank-tail (obj)
  "Shrink OBJ's terminal region to the last row that holds any output.
Only done for a terminal started with COMPACT (`spectreshell-start'),
i.e. a background job, whose region sits above eshell's prompt and the
command line being typed: padding it out to the full screen height
would push both a screenful down for as long as the job runs, even
after a single line of output.  A foreground job has nothing below it
and keeps the full screen, which is what a terminal-sized region is.
The rows come straight back from `spectreshell--pad-rows' as soon as
the job draws that far down again."
  (let* ((marker (marker-position (spectreshell-marker obj)))
         (end (spectreshell--region-end obj))
         (new-end end))
    (goto-char end)
    (while (and (> (point) marker)
                (progn (forward-line -1)
                       (spectreshell--blank-row-p (point) (line-end-position))))
      (setq new-end (point)))
    (when (< new-end end)
      ;; The end marker sits inside the deleted range and so collapses
      ;; onto NEW-END, i.e. is repinned to the region's new end.
      (delete-region new-end end))))

;; ---------------------------------------------------------------------
;; Dirty row diff application
;; ---------------------------------------------------------------------

(defun spectreshell--apply-dirty (obj dirty)
  "Apply DIRTY (the :dirty list from an update plist) to OBJ's buffer.
Rows whose module-side content is unchanged since they were last drawn
are skipped: ghostty-vt's dirty tracking is page-granular
\(module-api.org), and re-printing identical content marks rows dirty
too, so a batch routinely reports rows that render to what is already
on screen.

The comparison is against OBJ's cache of what the module last sent for
each row, not against the buffer text: the buffer text carries whatever
properties other modes have since added \(`fontified' from jit-lock
above all), which made a buffer-side comparison never match with
font-lock on.  The cost is that a foreign modification of the terminal
region is no longer noticed and repaired on the next dirty batch, which
no longer happens by ordinary means -- the region is rewritten from the
module, not edited."
  (when dirty
    ;; Pad once for the highest row, then walk the rows in one pass:
    ;; locating each row from the region's start instead would re-scan
    ;; the rows above it for every row in the batch.
    (spectreshell--pad-rows obj (apply #'max (mapcar #'car dirty)))
    (let ((cache (spectreshell-row-cache obj))
          (at-row 0))
      (goto-char (spectreshell-marker obj))
      (dolist (entry dirty)
        (pcase-let ((`(,row . ,content) entry))
          (forward-line (- row at-row))
          (setq at-row row)
          (let ((cached (gethash row cache)))
            (unless (equal cached content)
              (puthash row content cache)
              (let ((beg (point)))
                (delete-region beg (line-end-position))
                ;; `insert' leaves point at the end of the new row, which
                ;; is still on line `at-row', so the next `forward-line'
                ;; delta stays correct.
                (insert (spectreshell--mark-row-cells
                         (apply #'spectreshell--decorate-row obj content)
                         (nth 2 content)))))))))))

(defun spectreshell--mark-row-cells (text cells)
  "Return TEXT, a terminal-region row, carrying its CELLS for mouse coordinates.
CELLS is the module's per-character cell counts for TEXT
\(docs/module-api.org); when non-nil it is kept as the
`spectreshell-cells' property of TEXT's first character, where
`spectreshell--row-cell-column' finds it.  Confirmed rows do not get
it: nothing maps their coordinates, and it would travel with a yank."
  (when (and cells (> (length text) 0))
    ;; Only the first character carries it, so the trailing padding stays
    ;; property-less for `spectreshell--trim-trailing-blanks'.
    (put-text-property 0 1 'spectreshell-cells cells text))
  text)

(defun spectreshell--decorate-row (obj text spans cells)
  "Return TEXT with SPANS applied as face/button properties, using OBJ's styles.
SPANS is the module's per-row span list, each element (START END ID) or
\(START END ID . URI); TEXT is fresh from the module on every call, so it
is safe to add properties to it directly.  CELLS is the module's
per-character cell counts for TEXT (docs/module-api.org), which decide
how its graphemes are fitted or composed."
  (dolist (span spans)
    (pcase-let ((`(,start ,end ,id . ,uri) span))
      (when-let* ((face (spectreshell--style-face obj id)))
        (put-text-property start end 'face face text))
      (when uri
        ;; `make-text-button' only buttonizes a BEG..END buffer range OR
        ;; (as a convenience) an *entire* string, never a substring range
        ;; of one, so apply the properties it would have applied instead
        ;; of splicing a buttonized copy back into TEXT.
        (add-text-properties
         start end
         (list 'category (button-category-symbol 'spectreshell-hyperlink)
               'button '(t)
               'help-echo uri
               'spectreshell-hyperlink-uri uri)
         text))))
  (if (spectreshell--graphic-p)
      (spectreshell--fit-glyphs text cells)
    (spectreshell--compose-wide-graphemes text cells))
  text)

;; ---------------------------------------------------------------------
;; Glyph widths
;; ---------------------------------------------------------------------

(defvar spectreshell--glyph-fit-cache (make-hash-table :test 'equal)
  "Map a grapheme and its cells to its `spectreshell--glyph-fit' result, or `none'.
A single character's key is a fixnum packing the cell count above the
character's 22 bits, so the common lookup conses nothing; a longer
grapheme's is (CELLS . STRING).
Valid only for the frame font recorded in `spectreshell--glyph-fit-font'.")

(defvar spectreshell--glyph-fit-font nil
  "The selected frame's font when `spectreshell--glyph-fit-cache' was filled.")

(defun spectreshell--graphic-p ()
  "Return non-nil when rows are drawn for a GUI frame, the selected one."
  (display-graphic-p))

(defun spectreshell--pixel-width (string)
  "Return STRING's pixel width in the selected frame, or nil on a text terminal."
  (and (spectreshell--graphic-p) (string-pixel-width string)))

(defun spectreshell--shrunk-height (string target ratio)
  "Return the largest `display' height of STRING drawn within TARGET pixels.
RATIO is the first height to try, TARGET / width.  The scaled font size
is rounded, so RATIO can still leave the glyph a pixel too wide;
bisect below it then.  nil when no height fits."
  (if (<= (spectreshell--pixel-width
           (propertize string 'display (list 'height ratio)))
          target)
      ratio
    (let ((low 0.0) (high ratio))
      (while (> (- high low) 0.005)
        (let ((mid (/ (+ low high) 2)))
          (if (<= (spectreshell--pixel-width
                   (propertize string 'display (list 'height mid)))
                  target)
              (setq low mid)
            (setq high mid))))
      (and (> low 0.0) low))))

(defun spectreshell--glyph-fit-check-font ()
  "Empty `spectreshell--glyph-fit-cache' if the selected frame's font changed."
  (let ((font (frame-parameter nil 'font)))
    (unless (equal font spectreshell--glyph-fit-font)
      (clrhash spectreshell--glyph-fit-cache)
      (setq spectreshell--glyph-fit-font font))))

(defun spectreshell--glyph-fit (grapheme cells)
  "Return (HEIGHT . PAD) that fits GRAPHEME's glyph to its CELLS, or nil.
GRAPHEME, a character or a string, occupies CELLS cells of `frame-char-width' pixels in
the terminal, but a GUI frame draws it at its own width: an emoji font
may pick a wider glyph and stretch the line, wrapping a full-width row,
while a narrower one shifts everything after it left.  HEIGHT scales a
wide glyph down, or is nil to leave it; PAD is the width in pixels to
pad the glyph to, or nil when it already fills the cells.  nil when the
glyph fits exactly or there is no GUI frame to measure in.  Results are
cached in `spectreshell--glyph-fit-cache', which the caller keeps to the
selected frame's font with `spectreshell--glyph-fit-check-font'."
  (let* ((key (if (characterp grapheme)
                  (logior grapheme (ash cells 22))
                (cons cells grapheme)))
         (cached (gethash key spectreshell--glyph-fit-cache)))
    (if cached
        (and (not (eq cached 'none)) cached)
      (let* ((grapheme (if (characterp grapheme) (string grapheme) grapheme))
             (target (* cells (frame-char-width)))
             (width (spectreshell--pixel-width grapheme))
             (fit (and width (> target 0)
                       (if (> width target)
                           (when-let* ((height (spectreshell--shrunk-height
                                                grapheme target
                                                (/ (float target) width))))
                             (cons height
                                   (and (< (spectreshell--pixel-width
                                            (propertize grapheme 'display
                                                        (list 'height height)))
                                           target)
                                        target)))
                         (and (< width target) (cons nil target))))))
        (puthash key (or fit 'none) spectreshell--glyph-fit-cache)
        fit))))

(defun spectreshell--fit-grapheme (text start end cells)
  "Fit TEXT's grapheme from START to END to its CELLS cells.
All of the grapheme's characters share one `display' value, so it is
fitted as one run and its composition is kept.  The value is a fresh
list per grapheme: `min-width' treats neighbours sharing one as a
single run too."
  (when-let* ((fit (spectreshell--glyph-fit
                    (if (= end (1+ start))
                        (aref text start)
                      (substring-no-properties text start end))
                    cells)))
    (let ((shrink (and (car fit) (list 'height (car fit))))
          (pad (and (cdr fit) (list 'min-width (list (list (cdr fit)))))))
      (put-text-property start end 'display
                         (if (and shrink pad)
                             (list shrink pad)
                           (or shrink pad))
                         text))))

(defun spectreshell--fit-glyphs (text cells)
  "Fit TEXT's graphemes whose glyph does not fill their cells.
CELLS is the module's per-character cell counts for TEXT, nil when every
character is one cell (docs/module-api.org).  Only the `display' property
changes, so TEXT's characters stay as the module sent them."
  (let ((len (length text))
        ;; Jumping to the next non-ASCII character keeps ASCII runs as
        ;; cheap as a row without CELLS.
        (start (string-match "[^[:ascii:]]" text)))
    (when start
      (spectreshell--glyph-fit-check-font))
    (while start
      (let ((end (1+ start)))
        (when cells
          (while (and (> start 0) (= 0 (aref cells start)))
            (setq start (1- start)))
          (while (and (< end len) (= 0 (aref cells end)))
            (setq end (1+ end))))
        (spectreshell--fit-grapheme text start end (if cells (aref cells start) 1))
        (setq start (string-match "[^[:ascii:]]" text end))))))

(defun spectreshell--map-graphemes (function cells)
  "Call FUNCTION with the START and END of each grapheme that CELLS describes.
CELLS is the module's per-character cell counts for a row, where a
grapheme's characters after its first are 0."
  (let ((len (length cells))
        (start 0))
    (while (< start len)
      (let ((end (1+ start)))
        (while (and (< end len) (= 0 (aref cells end)))
          (setq end (1+ end)))
        (funcall function start end)
        (setq start end)))))

(defun spectreshell--compose-wide-graphemes (text cells)
  "Compose TEXT's graphemes that a text terminal would draw wider than their cells.
CELLS is as for `spectreshell--fit-glyphs'.  A text terminal frame has no
`display' widths to fit, but it counts a static composition as wide as
its widest character, which brings ZWJ sequences and skin tone
modifiers back to their cells.  Graphemes no wider than their cells are
left alone: composing a flag changes its width on the outer terminal."
  (when cells
    (spectreshell--map-graphemes
     (lambda (start end)
       (when (and (> end (1+ start))
                  (> (string-width text start end) (aref cells start)))
         (compose-string text start end)))
     cells)))

;; ---------------------------------------------------------------------
;; Style span -> face conversion
;; ---------------------------------------------------------------------

(defun spectreshell--span-face (style)
  "Build a `face' text-property value (a list) for STYLE-PLIST STYLE."
  (let* ((fg (spectreshell--resolve-color (plist-get style :fg) :foreground))
         (bg (spectreshell--resolve-color (plist-get style :bg) :background))
         (underline (plist-get style :underline))
         faces)
    ;; SGR 8 (隠し) は前景を背景に揃えて実現する。Emacs の `invisible'
    ;; text property は文字ごとレイアウトから外すので、セル位置と
    ;; バッファ位置の対応が崩れて `spectreshell--row-col-pos' が狂う。
    (when (plist-get style :invisible)
      (setq fg (or bg (face-background 'default nil t))))
    (when (or fg bg)
      (push (nconc (and fg (list :foreground fg)) (and bg (list :background bg)))
            faces))
    (when underline
      (push (list :underline (spectreshell--underline-value underline)) faces))
    (when (plist-get style :strikethrough) (push 'spectreshell-strikethrough faces))
    (when (plist-get style :faint) (push 'ansi-color-faint faces))
    (when (plist-get style :italic) (push 'ansi-color-italic faces))
    (when (plist-get style :bold) (push 'ansi-color-bold faces))
    (when (plist-get style :inverse) (push 'ansi-color-inverse faces))
    (nreverse faces)))

(defun spectreshell--underline-value (underline)
  "Translate a span's :underline value UNDERLINE to a face attribute.
Emacs faces only support `line' and `wave' underline styles natively,
so `double'/`dotted'/`dashed' fall back to a plain line; there is no
closer native approximation."
  (if (eq underline 'curly) '(:style wave) t))

(defun spectreshell--resolve-color (value attr)
  "Resolve module color VALUE to a concrete color string for ATTR.
VALUE is a palette index (0-255) or a \"#rrggbb\" string, as documented
in docs/module-api.org; ATTR is `:foreground' or `:background'.  Palette
indices 0-15 are resolved through the `spectreshell-color-N' faces,
mirroring the approach `ansi-color.el' itself uses, so freshly drawn
text picks up the user's current theme, though already-drawn spans do
not retroactively update if the theme changes later."
  (cond
   ((null value) nil)
   ((stringp value) value)
   ((< value 16)
    (funcall (if (eq attr :foreground) #'face-foreground #'face-background)
             (intern (format "spectreshell-color-%d" value))
             nil 'default))
   (t (spectreshell--256-color-hex value))))

(defun spectreshell--256-color-hex (index)
  "Convert an xterm 256-color palette INDEX (16-255) to \"#rrggbb\"."
  (if (>= index 232)
      (let ((v (+ 8 (* 10 (- index 232)))))
        (format "#%02x%02x%02x" v v v))
    (let* ((i (- index 16))
           (levels [0 95 135 175 215 255])
           (r (aref levels (/ i 36)))
           (g (aref levels (mod (/ i 6) 6)))
           (b (aref levels (mod i 6))))
      (format "#%02x%02x%02x" r g b))))

;; ---------------------------------------------------------------------
;; Scrollback confirmation
;; ---------------------------------------------------------------------

(defun spectreshell--trim-trailing-blanks (text)
  "Return TEXT without its trailing run of property-less spaces.
The module pads every row to the full terminal width; keeping that
padding on text confirmed as permanent scrollback would leave trailing
whitespace on every copied line and inflate the buffer by rows x cols.
Spaces that carry text properties (e.g. a colored-background span) are
real terminal content and are kept."
  (let ((end (length text)))
    (while (and (> end 0)
                (eq (aref text (1- end)) ?\s)
                (null (text-properties-at (1- end) text)))
      (setq end (1- end)))
    (substring text 0 end)))

(defun spectreshell--apply-scrolled-off (obj scrolled-off)
  "Confirm SCROLLED-OFF (the :scrolled-off list) as scrollback text in OBJ."
  (when scrolled-off
    (let ((marker (spectreshell-marker obj)))
      (goto-char marker)
      (insert (mapconcat (lambda (entry)
                            (spectreshell--trim-trailing-blanks
                             (apply #'spectreshell--decorate-row obj entry)))
                          scrolled-off "\n")
              "\n")
      ;; The marker's default (nil) insertion-type leaves it *behind* text
      ;; inserted at its own position, i.e. still pointing at the
      ;; scrollback we just confirmed instead of the terminal region that
      ;; now starts after it; `point' (left at the insertion end by
      ;; `insert') is exactly the position we want it repinned to.  The
      ;; end marker needs the same treatment while the region is still
      ;; empty (nothing padded yet): it sits at that very position too,
      ;; and would otherwise end up *before* the region's start.
      (set-marker marker (point))
      (when (< (spectreshell--region-end obj) (point))
        (spectreshell--set-region-end obj)))))

;; ---------------------------------------------------------------------
;; Alternate screen
;; ---------------------------------------------------------------------

(defun spectreshell--handle-alt-screen (obj alt-screen)
  "Enter or leave the alternate screen in OBJ per ALT-SCREEN.
ALT-SCREEN is the :alt-screen value from an update plist: `entered',
`left', or nil/omitted for no transition this batch."
  (pcase alt-screen
    ('entered (spectreshell--enter-alt-screen obj))
    ('left (spectreshell--leave-alt-screen obj))))

(defun spectreshell--enter-alt-screen (obj)
  "Snapshot OBJ's primary-screen region and blank it for the alt screen.
The snapshot is restored by `spectreshell--leave-alt-screen'."
  (clrhash (spectreshell-row-cache obj))
  (setf (spectreshell-alt-screen obj) t
        (spectreshell-alt-saved obj)
        (buffer-substring (spectreshell-marker obj) (spectreshell--region-end obj)))
  (delete-region (spectreshell-marker obj) (spectreshell--region-end obj))
  (spectreshell--pad-rows obj (1- (spectreshell-rows obj))))

(defun spectreshell--leave-alt-screen (obj)
  "Discard the alt screen's contents in OBJ and restore the saved primary screen."
  ;; Both transitions replace the whole terminal region behind the row
  ;; cache's back, so what it remembers per row no longer describes the
  ;; buffer.
  (clrhash (spectreshell-row-cache obj))
  (delete-region (spectreshell-marker obj) (spectreshell--region-end obj))
  (when-let* ((saved (spectreshell-alt-saved obj)))
    (goto-char (spectreshell-marker obj))
    (insert saved)
    (spectreshell--set-region-end obj))
  ;; The recorded cursor names a row of the screen just discarded, so it
  ;; says nothing about how far the restored one is used.  A live
  ;; transition has the same update's :cursor put a fresh one back right
  ;; after; a process that died in the alt screen leaves none, and
  ;; `spectreshell--used-rows' must fall back to the visible output.
  (setf (spectreshell-alt-screen obj) nil
        (spectreshell-alt-saved obj) nil
        (spectreshell-cursor-rowcol obj) nil))

;; ---------------------------------------------------------------------
;; Cursor tracking
;; ---------------------------------------------------------------------

(defvar spectreshell-semi-char-mode)
(defvar spectreshell--current)

(defun spectreshell--cursor-followed-p (obj position)
  "Return non-nil if POSITION should follow OBJ\='s cursor on this update.
POSITION is a point or `window-point' read before the update touched the
buffer, so comparing it against the position the previous update left
the cursor at is what tells a point sitting at the cursor apart from one
left behind in the scrollback.  In semi-char mode every position follows
unconditionally -- keys go straight to the terminal there, so point has
nowhere to be but at the cursor -- but only for the terminal those keys
actually reach (`spectreshell--current'): a background job redrawing its
own region must not drag point off the command line being typed on."
  (or (and spectreshell-semi-char-mode (eq obj spectreshell--current))
      (eql position (spectreshell-cursor-pos obj))))

(defun spectreshell--following-windows (obj)
  "Return the windows showing OBJ\='s buffer whose point follows the cursor.
Judged per window (`spectreshell--cursor-followed-p\='), so one window
can stay parked in the scrollback while another keeps tracking the
output."
  (let (windows)
    (dolist (window (get-buffer-window-list (spectreshell-buffer obj) nil t))
      (when (spectreshell--cursor-followed-p obj (window-point window))
        (push window windows)))
    windows))

(defun spectreshell--align-windows (obj)
  "Put OBJ\='s region at the top of every window it exactly fills.
Emacs scrolls only as far as it takes to bring point -- the terminal\='s
cursor -- into view, so a full-screen application that keeps its cursor
near the top (nvim right after opening a file) has everything below the
cursor row pushed off the window.

Only while the child is on the alternate screen, which is what says it
is drawing a screen of its own.  The height test alone does not: a
foreground job\='s region is always exactly as tall as the window,
because that is where its row count came from, so aligning on height
would put every `ls\=' at the top of the window too and push the
scrollback and the prompt out of sight (M-19).

Only for the terminal that keys are reaching in semi-char mode, which
is `spectreshell--cursor-followed-p\=''s condition as well: aligning
while the user reads the scrollback outside semi-char mode would
scroll the view away on every batch of output.  A compact region is a background
job\='s, deliberately shorter than the screen and sharing the window
with the prompt below it."
  (when (and spectreshell-semi-char-mode
             (eq obj spectreshell--current)
             (spectreshell-alt-screen obj)
             (not (spectreshell-compact obj)))
    (dolist (window (get-buffer-window-list (spectreshell-buffer obj) nil t))
      (when (= (window-body-height window) (spectreshell-rows obj))
        (set-window-start window (marker-position (spectreshell-marker obj)))))))

(defun spectreshell--region-position-p (obj pos)
  "Return non-nil if POS lies inside OBJ\='s terminal region.
The region\='s very end is outside it: that is where eshell\='s prompt and
the command line being typed begin."
  (and (>= pos (spectreshell-marker obj))
       (< pos (spectreshell--region-end obj))))

(defun spectreshell--save-line (obj pos)
  "Record POS for `spectreshell--restore-line\=' to find again after OBJ redraws.
A POS inside the terminal region is recorded as a line offset from the
region\='s start, not as a buffer position: confirming scrolled-off rows
inserts them at that start, which pushes every position below down by
as many lines as the terminal scrolled, so restoring the position
alone lands on whatever content has since slid up into that row.

The offset is measured from a marker left at the region\='s old start,
i.e. at the head of the rows about to be inserted, which is what makes
the one offset serve both cases: the old row R ends up at line R of
that marker whether it scrolled off (line R of the confirmed rows) or
stayed in the region (row R-N of a region now starting N lines lower).

A POS outside the region is recorded as a plain marker, which is all
it takes: nothing is inserted above the confirmed scrollback, and the
text after the region is not this terminal\='s to move."
  (save-excursion
    (goto-char pos)
    (if (spectreshell--region-position-p obj pos)
        (list (copy-marker (spectreshell-marker obj))
              (count-lines (spectreshell-marker obj) (line-beginning-position))
              (current-column))
      (list (point-marker)))))

(defun spectreshell--restore-line (obj saved)
  "Return the position SAVED recorded in OBJ, releasing its marker."
  (prog1
      (pcase-let ((`(,marker ,line ,column) saved))
        (if line
            (save-excursion
              (goto-char marker)
              (forward-line line)
              (move-to-column column)
              ;; The row can be gone entirely (a resize or a compact
              ;; region's blank tail), and walking past the region would
              ;; land on eshell's command line.
              (min (point) (spectreshell--region-end obj)))
          (marker-position marker)))
    (set-marker (car saved) nil)))

(defun spectreshell--save-window-views (obj follow-windows)
  "Record the view of the windows showing OBJ that are parked in its region.
Returns a list of (WINDOW START POINT) with START and POINT saved by
`spectreshell--save-line\='.  Only windows whose `window-start\=' is inside
the region are recorded: a start above it (in the confirmed
scrollback) does not move in the first place, and a window in
FOLLOW-WINDOWS is showing the terminal\='s own cursor, which is supposed
to scroll the view along with the output rather than stay on the
content it was reading."
  (let (views)
    (dolist (window (get-buffer-window-list (spectreshell-buffer obj) nil t))
      (when (and (not (memq window follow-windows))
                 (spectreshell--region-position-p obj (window-start window)))
        (push (list window
                    (spectreshell--save-line obj (window-start window))
                    (spectreshell--save-line obj (window-point window)))
              views)))
    views))

(defun spectreshell--restore-window-views (obj views)
  "Put back VIEWS, what `spectreshell--save-window-views\=' recorded for OBJ."
  (pcase-dolist (`(,window ,start ,point) views)
    (let ((start-pos (spectreshell--restore-line obj start))
          (point-pos (spectreshell--restore-line obj point)))
      (when (window-live-p window)
        ;; NOFORCE: a background job's region can be parked in a window
        ;; whose point is on the command line below it, and a forced
        ;; start that hides point has redisplay move point instead --
        ;; taking the very command line this restore is here to leave
        ;; alone.
        (set-window-start window start-pos t)
        (set-window-point window point-pos)))))

(defun spectreshell--move-point (obj cursor index follow-point follow-windows
                                    saved-point)
  "Place point and `window-point' after an update drew CURSOR in OBJ.
CURSOR is the :cursor (ROW . COL) cons from an update plist and INDEX its
:cursor-index, the character offset within the row that COL corresponds to.
FOLLOW-POINT and FOLLOW-WINDOWS are what
`spectreshell--cursor-followed-p\=' answered before the update, and
SAVED-POINT is `spectreshell--save-line\=''s record of where point stood
then: point is restored from it rather than simply left alone, because
the redraw helpers move point as they rewrite rows."
  (pcase-let ((`(,row . ,col) cursor))
    (let ((pos (spectreshell--row-col-pos obj row col index))
          (restored (spectreshell--restore-line obj saved-point)))
      (goto-char (if follow-point pos restored))
      (dolist (window follow-windows)
        (set-window-point window pos))
      (setf (spectreshell-cursor-pos obj) pos
            (spectreshell-cursor-rowcol obj) cursor))))

(defun spectreshell--row-col-pos (obj row col &optional index)
  "Return the buffer position of (ROW . COL) in OBJ's terminal region.
COL is a terminal *cell* column (docs/module-api.org), not a character
offset.  INDEX, when given, is the module's :cursor-index for COL: the
character offset within the row, which is what this walks.  Without it
the mapping falls back to display columns
\(`move-to-column', which counts each character's `char-width'), which
is only right for characters whose Emacs display width equals their cell
count: a regional indicator is 2 cells for ghostty but 1 column for
Emacs.  A COL past the end of a short row clamps to
the end of that line, and a ROW past the region's last line to
`spectreshell--region-end': a bare cursor-positioning sequence does not
dirty the rows it jumps over, so the region can legitimately be shorter
than ROW, and walking on into the text after it would record a cursor
position on eshell's command line."
  (save-excursion
    (let ((end (spectreshell--region-end obj)))
      (goto-char (spectreshell-marker obj))
      (forward-line row)
      (if (>= (point) end)
          end
        (if index
            (forward-char (min index (- (line-end-position) (point))))
          (move-to-column col))
        (min (point) end)))))

;; ---------------------------------------------------------------------
;; Key event normalization
;; ---------------------------------------------------------------------

(defconst spectreshell--special-key-symbols
  '(up down left right home end prior next insert delete backspace tab
    return escape
    f1 f2 f3 f4 f5 f6 f7 f8 f9 f10 f11 f12)
  "Symbols `spectreshell--encode-key' accepts as KEY (docs/module-api.org).
`spectreshell--event-to-key' passes an `event-basic-type' symbol through
unchanged exactly when it is a member of this list.")

(defconst spectreshell--ascii-special-keys
  '((?\t . tab) (?\r . return) (?\e . escape) (?\C-? . backspace))
  "ASCII control codes that name a special KEY of their own.
TAB/RET/ESC/DEL are indistinguishable, at the character level, from
Control-i/Control-m/Control-\\[/Control-? (`event-basic-type' cannot
tell them apart either), but docs/module-api.org encodes them as their
own symbols rather than as \"i\"/\"m\"/\"[\"/\"?\" plus `ctrl'.")

(defconst spectreshell--aliased-key-symbols
  '((backtab tab shift)
    (insertchar insert)
    (deletechar delete))
  "Function-key symbols that stand for another KEY plus extra MODIFIERS.
Emacs reports Shift-TAB as a `backtab' symbol of its own, carrying no
`shift' modifier, but docs/module-api.org has no such KEY: what the
terminal wants for it is TAB with `shift' (CSI Z).  A terminal frame
likewise decodes the Insert and Delete keys to `insertchar'/`deletechar'
rather than to the `insert'/`delete' that a GUI frame delivers, and
docs/module-api.org only names the latter pair.")

(defun spectreshell--event-char (event)
  "Return EVENT's character code with Emacs's modifier bits cleared.
Nil when EVENT is not an integer event.  `event-basic-type' cannot serve
this purpose: it also strips the control that a C0 code *is* (it reports
?\\M-\\r as ?m) and downcases, both of which discard exactly what the
callers below need to look at."
  (and (integerp event) (logand event (max-char))))

(defun spectreshell--event-to-key (event)
  "Normalize EVENT to a (KEY . MODIFIERS) pair for `spectreshell--encode-key'.
EVENT is anything `last-command-event' can hold: an integer (a plain or
control/meta-modified character) or a symbol (a function key, possibly
combined with modifiers, e.g. `C-up' or `M-S-f5').  KEY/MODIFIERS follow
docs/module-api.org.  Return nil when EVENT has no PTY-sendable
representation (mouse events, unrecognized function keys, a bare
modifier press, ...)."
  ;; TAB/RET/ESC/DEL must be matched on the modifier-bit-stripped EVENT,
  ;; not on `event-basic-type', because that function's stripping of the
  ;; "control" that is baked into those ASCII codes is exactly what turns
  ;; them into indistinguishable-from-C-i/C-m/C-[/C-? in the first place.
  (let* ((char (spectreshell--event-char event))
         (ascii (and char (assq char spectreshell--ascii-special-keys))))
    (if ascii
        (cons (cdr ascii)
              (spectreshell--event-modifiers-to-modifiers
               (remove 'control (event-modifiers event))))
      (let* ((basic (event-basic-type event))
             (alias (and (symbolp basic)
                         (assq basic spectreshell--aliased-key-symbols)))
             (mods (spectreshell--event-modifiers-to-modifiers
                    (event-modifiers event))))
        (if alias
            (cons (nth 1 alias) (delete-dups (append mods (cddr alias))))
          ;; `event-basic-type' downcases an upper-case character and reports
          ;; the case difference as a `shift' modifier instead, so its return
          ;; value alone would send `a' for a typed `A'.  Prefer EVENT's own
          ;; character whenever it *is* BASIC's upcased form -- true for `A'
          ;; and `M-A' (and for every character that is its own upcase, where
          ;; this changes nothing), but not for a modifier-bit encoded event
          ;; like `C-S-a', whose shift lives in a bit rather than in the
          ;; character; its KEY must stay the bare letter, with the case
          ;; carried by MODIFIERS as before.
          (when-let* ((key (spectreshell--basic-type-to-key
                            (if (and (characterp basic) char
                                     (eq char (upcase basic)))
                                char
                              basic))))
            (cons key mods)))))))

(defun spectreshell--basic-type-to-key (basic)
  "Return the `spectreshell--encode-key' KEY for modifier-stripped BASIC.
BASIC is the return value of `event-basic-type'."
  (cond
   ((integerp basic) (and (characterp basic) (string basic)))
   ((memq basic spectreshell--special-key-symbols) basic)))

(defun spectreshell--event-modifiers-to-modifiers (mods)
  "Translate MODS (an `event-modifiers' list) to encode-key MODIFIERS.
Only `control'/`meta'/`shift'/`super' have a counterpart there (`alt'
stands in for Emacs's `meta', per docs/module-api.org); anything else
\(mouse click counts, drag, Emacs's own separate `alt' modifier for a
literal Alt key, ...) has no PTY encoding and is dropped rather than
mapped to something misleading."
  (delq nil (list (and (memq 'control mods) 'ctrl)
                   (and (memq 'meta mods) 'alt)
                   (and (memq 'shift mods) 'shift)
                   (and (memq 'super mods) 'super))))

;; ---------------------------------------------------------------------
;; Terminal attachment for input commands
;; ---------------------------------------------------------------------

(defvar-local spectreshell--current nil
  "The `spectreshell' object this buffer's key commands send input to.
Only ever one terminal, even when several render into this buffer at
once: `spectreshell-eshell.el' points this at the *foreground* job,
since a background job has a region and a redraw of its own but no
claim on the keyboard.  Nil means there is currently nothing to send
input to, in which case the semi-char mode commands below are silent
no-ops rather than errors (matching a plain terminal buffer that just
hasn't started a job yet).")

;; ---------------------------------------------------------------------
;; Input commands
;; ---------------------------------------------------------------------

(defun spectreshell--esc-prefixed-key-p ()
  "Non-nil when the running command was invoked by an ESC-prefixed key.
A terminal frame delivers M-<char> as the two events ESC and <char>, and
`last-command-event' is then the bare character with no `meta' modifier
on it at all, so the meta can only be recovered from the whole key
sequence.  Requiring the sequence to end with `last-command-event'
itself keeps a direct call (with `last-command-event' let-bound, as the
tests do) from picking up whatever key sequence happens to be current."
  (let* ((keys (this-single-command-keys))
         (n (length keys)))
    (and (>= n 2)
         (eq (aref keys (- n 2)) ?\e)
         (eq (aref keys (1- n)) last-command-event))))

(defun spectreshell-send-key ()
  "Encode `last-command-event' and send it to `spectreshell--current'.
Bound throughout `spectreshell-semi-char-mode-map' (directly, and via
the `self-insert-command' remap) to turn nearly every key into a
`spectreshell--encode-key' call.  An ESC-prefixed key sequence
\(`spectreshell--esc-prefixed-key-p') contributes the `alt' modifier the
event itself does not carry.  Does nothing if there is no current
terminal, or if the event or the encoder has no bytes to send for it."
  (interactive)
  (spectreshell--send-event last-command-event (spectreshell--esc-prefixed-key-p)))

(defun spectreshell--send-event (event &optional alt)
  "Encode EVENT and send it to `spectreshell--current'.
ALT non-nil adds the `alt' modifier EVENT itself does not carry.  Does
nothing if there is no current terminal, or if the event or the encoder
has no bytes to send for it."
  (when-let* ((obj spectreshell--current)
              (key+mods (spectreshell--event-to-key event))
              (bytes (spectreshell--encode-key
                      (spectreshell-term obj) (car key+mods)
                      (if alt
                          (delete-dups (cons 'alt (cdr key+mods)))
                        (cdr key+mods)))))
    (funcall (spectreshell-send-fn obj) bytes)))

(defun spectreshell-send-next-key ()
  "Read one key and send it to `spectreshell--current' as it is.
Bound to `C-\\' in `spectreshell-semi-char-mode-map', for the keys that
semi-char mode leaves to Emacs (`C-c', `C-x', `M-x', `C-u', `C-y') and
for `C-\\' itself.  A key sequence is sent one key per `C-\\'.  The key
goes through the same encoder as `spectreshell-send-key'."
  (interactive)
  (let ((event (read-key))
        (keys (this-single-command-keys)))
    ;; A terminal frame without kkp delivers M-x as ESC x; `read-key'
    ;; returns only the ESC and leaves the x in the keys it read.
    (if (and (eq event ?\e) (= (length keys) 2) (eq (aref keys 0) ?\e))
        (spectreshell--send-event (aref keys 1) t)
      (spectreshell--send-event event))))

(defun spectreshell-send-escape ()
  "Send one ESC byte to `spectreshell--current'.
Bound to `ESC ESC' in `spectreshell-semi-char-mode-map'.  A key of its
own is needed because a terminal frame's ESC is `meta-prefix-char':
Emacs waits for the following key indefinitely, so a bare ESC can never
complete a key sequence and vim/less/fzf could not be escaped from."
  (interactive)
  (when-let* ((obj spectreshell--current)
              (bytes (spectreshell--encode-key (spectreshell-term obj) 'escape nil)))
    (funcall (spectreshell-send-fn obj) bytes)))

(defun spectreshell--send-paste (string)
  "Send STRING to `spectreshell--current' as one paste.
One `spectreshell--encode-paste' call (bracketed paste, if the terminal
has that mode on) rather than a `spectreshell-send-key' call per
character.  Silently does nothing without a current terminal, like the
other input commands."
  (when-let* ((obj spectreshell--current))
    (funcall (spectreshell-send-fn obj)
             (spectreshell--encode-paste (spectreshell-term obj) string))))

(defun spectreshell-yank ()
  "Send the front of the kill ring to `spectreshell--current' as a paste.
Bound to `C-y' in `spectreshell-semi-char-mode-map' instead of ordinary
`yank'.  While the child asks for kitty paste events (mode 5522), it is
sent an event instead and reads the text itself
\(`spectreshell--clipboard-paste-event')."
  (interactive)
  (let ((text (current-kill 0)))
    (if-let* ((obj spectreshell--current)
              (event (spectreshell--clipboard-paste-event obj)))
        (funcall (spectreshell-send-fn obj) event)
      (spectreshell--send-paste text))))

(defun spectreshell-xterm-paste (event)
  "Send EVENT's pasted text to `spectreshell--current' as one paste.
EVENT is an `xterm-paste' event, which is how a terminal frame's Emacs
reports a bracketed paste from the terminal itself (a middle click, or
the terminal emulator's own paste command).  Bound to `xterm-paste' in
`spectreshell-semi-char-mode-map' instead of the global `xterm-paste',
which would insert the text into the buffer -- editing the terminal
region as if it were ordinary text -- without the process ever seeing
it."
  (interactive "e")
  (spectreshell--send-paste (nth 1 event)))

;; ---------------------------------------------------------------------
;; Mouse input
;; ---------------------------------------------------------------------

(defun spectreshell--posn-terminal (posn)
  "Return the `spectreshell--current' terminal for POSN's window, or nil.
POSN is an `event-start'/`event-end' position object; nil covers both
\"no terminal object there\" (mode-line, minibuffer, another buffer's
window, ...) and \"nothing at all there\" (posn-window returned a frame,
not a window, e.g. a click below the last line)."
  (when-let* ((window (posn-window posn))
              ((windowp window)))
    (buffer-local-value 'spectreshell--current (window-buffer window))))

(defun spectreshell--row-cell-column (pos)
  "Return the terminal cell column of the character at POS in its row.
The row's `spectreshell-cells' (see `spectreshell--mark-row-cells') maps
characters to cells; a row without it has one cell per character.  A
character inside a grapheme answers the grapheme's first cell."
  (let* ((bol (save-excursion (goto-char pos) (line-beginning-position)))
         (index (- pos bol))
         (cells (get-text-property bol 'spectreshell-cells)))
    (if (null cells)
        index
      (setq index (min index (length cells)))
      (while (and (> index 0) (< index (length cells)) (= 0 (aref cells index)))
        (setq index (1- index)))
      (let ((column 0))
        (dotimes (i index)
          (setq column (+ column (aref cells i))))
        column))))

(defun spectreshell--posn-terminal-coords (obj posn)
  "Return OBJ's 0-origin (ROW . COL) terminal coordinates for POSN.
POSN is an `event-start'/`event-end' position object.  Return nil when
POSN has no buffer position at all (e.g. a click in the fringe) or
falls outside OBJ's terminal region -- a click on already-confirmed
scrollback text above it, or on the prompt/command line below it,
neither of which is part of the live terminal grid."
  (when-let* ((pt (posn-point posn))
              (marker-pos (marker-position (spectreshell-marker obj)))
              ((>= pt marker-pos))
              ((< pt (spectreshell--region-end obj))))
    (with-current-buffer (spectreshell-buffer obj)
      (save-excursion
        (goto-char pt)
        ;; COL must be a terminal *cell* column (`spectreshell--encode-mouse'
        ;; encodes it as-is into the mouse report).  Clamp in case POSN
        ;; lands past a short row's last character (rows are padded to
        ;; `spectreshell-cols' by `spectreshell--pad-rows'/dirty-row
        ;; replacement, so this is mostly a defensive bound rather than a
        ;; normal occurrence).
        (cons (count-lines marker-pos (line-beginning-position))
              (max 0 (min (1- (spectreshell-cols obj))
                          (spectreshell--row-cell-column pt))))))))

(defun spectreshell--send-mouse (obj button action posn mods)
  "Encode a BUTTON/ACTION mouse report at POSN through OBJ and send it.
Return the encoded bytes on success, or nil if POSN falls outside OBJ's
terminal region or `spectreshell--encode-mouse' had nothing to send
\(mouse tracking off in the terminal, or this ACTION/BUTTON combination
is not reported by its current tracking mode)."
  (when-let* ((coords (spectreshell--posn-terminal-coords obj posn))
              (bytes (spectreshell--encode-mouse (spectreshell-term obj) button action
                                                  (car coords) (cdr coords) mods)))
    (funcall (spectreshell-send-fn obj) bytes)
    bytes))

(defun spectreshell--mouse-button-number (event)
  "Return the BUTTON argument for `spectreshell--encode-mouse' matching EVENT.
`event-basic-type' already strips down/click/drag/double/triple and any
modifier prefix off EVENT's head symbol, so it alone is enough to tell
which button (or wheel direction) EVENT names."
  (pcase (event-basic-type event)
    ('mouse-1 1)
    ('mouse-2 2)
    ('mouse-3 3)
    ((or 'wheel-up 'mouse-4) 'wheel-up)
    ((or 'wheel-down 'mouse-5) 'wheel-down)
    ((or 'wheel-left 'mouse-6) 'wheel-left)
    ((or 'wheel-right 'mouse-7) 'wheel-right)))

(defun spectreshell--track-mouse-drag (obj button mods)
  "Track a mouse drag already reported to OBJ as a BUTTON press with MODS.
Reads events in a `read-key' loop with mouse-movement events enabled, so
that a single Emacs down-mouse command invocation still reports the
live motion and eventual release ghostty-vt
\(and whatever PTY-side app asked for SGR mouse motion, e.g. vim/less)
expects to see, even though Emacs only ever delivered spectreshell one
discrete down event.  Any event that is not part of this drag (a key
press, a different mouse button, ...) ends the loop and is pushed back
onto `unread-command-events' so the normal command loop still sees it."
  (track-mouse
    (catch 'spectreshell--mouse-drag-done
      (while t
        ;; `read-key' rather than `read-event': on a terminal frame the
        ;; mouse arrives as an escape sequence that only `input-decode-map'
        ;; turns into a mouse event, and `read-event' does not consult that
        ;; keymap -- it would return a bare 27 here and no drag or release
        ;; would ever be recognized.  DISABLE-FALLBACKS is on so that a
        ;; press of another button mid-drag reaches the push-back arm below
        ;; instead of being discarded as an unbound down event.
        ;; `mouse-1-click-follows-link' would turn a release on a link (an
        ;; OSC 8 button) into a mouse-2 click: pushed back as another
        ;; button's event, it opens the link and the child that got the
        ;; press never gets its release.
        (let ((event (let ((mouse-1-click-follows-link nil))
                       (read-key nil t))))
          (cond
           ((and (consp event) (eq (car event) 'mouse-movement))
            (spectreshell--send-mouse obj button 'motion (event-start event) mods))
           ;; Only *this* BUTTON's release ends the drag as a release
           ;; report; a different button's up/down mid-drag must not be
           ;; reported as BUTTON's release, so it falls through to the
           ;; push-back arm below like any other unrelated event.
           ((and (consp event)
                 (memq (event-basic-type event) '(mouse-1 mouse-2 mouse-3))
                 (eq (spectreshell--mouse-button-number event) button))
            (spectreshell--send-mouse obj button 'release (event-end event) mods)
            (throw 'spectreshell--mouse-drag-done nil))
           (t
            ;; Push back unconditionally: integer events (ordinary key
            ;; presses) are just as valid in `unread-command-events' as
            ;; symbols/lists, and dropping them would silently eat a
            ;; keystroke typed while the mouse button was held down.
            (push event unread-command-events)
            (throw 'spectreshell--mouse-drag-done nil))))))))

(defun spectreshell-mouse-down (event)
  "Report a mouse-button press for EVENT, then track its drag/release.
Bound (with each ctrl/alt/shift combination) to `down-mouse-1/2/3' in
`spectreshell-semi-char-mode-map'.  Falls back to `mouse-set-point'
\(only) when EVENT's window has no current terminal, or the terminal's
mouse tracking is off (`spectreshell--encode-mouse' returned nil for the
press): docs/design.org accepts doing nothing beyond that, since fully
reimplementing `mouse-drag-region' style selection is out of scope, but
a plain click should still move point rather than being silently eaten."
  (interactive "e")
  (let* ((posn (event-start event))
         (button (spectreshell--mouse-button-number event))
         (mods (spectreshell--event-modifiers-to-modifiers (event-modifiers event)))
         (obj (spectreshell--posn-terminal posn)))
    (if (and obj (spectreshell--send-mouse obj button 'press posn mods))
        (spectreshell--track-mouse-drag obj button mods)
      (mouse-set-point event))))

(defun spectreshell-mouse-wheel (event)
  "Report a wheel-scroll EVENT to its window's current terminal.
Bound (with each ctrl/alt/shift combination) to `wheel-up'/`wheel-down'/
`wheel-left'/`wheel-right' and their `mouse-4'/`mouse-5'/`mouse-6'/
`mouse-7' equivalents in `spectreshell-semi-char-mode-map'.  Sent as a
single `press' report: ghostty-vt's mouse protocol (like every terminal
mouse protocol descended from xterm's) has no separate release phase for
a wheel click, mirroring how ghostty itself only ever calls its own
`mouseReport' with `.press' for scroll wheel events.  Falls back to
`mwheel-scroll' (ordinary Emacs scrolling) when there is no terminal to
report to, or its mouse tracking is off, so semi-char mode does not
disable mouse-wheel scrolling entirely between jobs that want it."
  (interactive "e")
  (let* ((posn (event-start event))
         (button (spectreshell--mouse-button-number event))
         (mods (spectreshell--event-modifiers-to-modifiers (event-modifiers event)))
         (obj (spectreshell--posn-terminal posn)))
    (unless (and obj (spectreshell--send-mouse obj button 'press posn mods))
      (mwheel-scroll event nil))))

;; ---------------------------------------------------------------------
;; semi-char / emacs mode
;; ---------------------------------------------------------------------

(defvar spectreshell-semi-char-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map [remap self-insert-command] #'spectreshell-send-key)
    ;; Bind both the raw char and the symbol form of TAB/RET/DEL: a
    ;; terminal frame delivers the former, a GUI frame can deliver either
    ;; depending on how it translates the physical key.  ESC is the odd one
    ;; out: keymaps store a Meta-modified char's binding as an ESC-prefixed
    ;; sub-keymap internally (terminals send Meta as literal ESC + char),
    ;; so a *non-prefix* binding at raw char 27 here would make every
    ;; `M-<letter>' binding below fail with "starts with non-prefix key
    ;; ESC"; only the `escape' symbol form is bound for that reason.
    (dolist (pair spectreshell--ascii-special-keys)
      (unless (eq (cdr pair) 'escape)
        (define-key map (vector (car pair)) #'spectreshell-send-key))
      (define-key map (vector (cdr pair)) #'spectreshell-send-key))
    ;; A modified function key (`C-up', `M-S-f5', ...) is its own distinct
    ;; symbol rather than a modifier bit layered on a shared base event, so
    ;; each combination needs its own binding.  tab/return/backspace/escape
    ;; are in the list too, for their GUI symbol form (`C-<backspace>');
    ;; their terminal form is a modifier bit on the raw C0 code and is
    ;; already covered above -- including `M-RET', which keymaps look up
    ;; through the ESC prefix and the raw binding.  The unmodified pass of
    ;; the inner loop re-binds what the ASCII loop just bound, to the same
    ;; command; splitting the list by modifier to avoid that would only
    ;; make the table harder to read.
    (dolist (key '(up down left right home end prior next insert delete
                   insertchar deletechar
                   tab return backspace escape backtab
                   f1 f2 f3 f4 f5 f6 f7 f8 f9 f10 f11 f12))
      (dolist (mods '(() (control) (meta) (control meta) (shift)
                       (control shift) (meta shift) (control meta shift)))
        (define-key map (vector (event-convert-list (append mods (list key))))
          #'spectreshell-send-key)))
    ;; Mouse: down-mouse-N starts `spectreshell--track-mouse-drag''s
    ;; self-contained press/motion*/release loop; wheel events (and their
    ;; mouse-4..7 legacy-numbered equivalents) have no separate down/up
    ;; phase of their own and go straight to `spectreshell-mouse-wheel'.
    (dolist (button '(down-mouse-1 down-mouse-2 down-mouse-3))
      (dolist (mods '(() (control) (meta) (control meta) (shift)
                       (control shift) (meta shift) (control meta shift)))
        (define-key map (vector (event-convert-list (append mods (list button))))
          #'spectreshell-mouse-down)))
    ;; The click halves of mouse-1/2/3 only ever fire here when the
    ;; terminal's mouse tracking was off (`spectreshell--track-mouse-drag'
    ;; consumes the release otherwise), i.e. right after the down binding
    ;; above already fell back to `mouse-set-point'.  Bind them to the same
    ;; benign command so mouse-2/mouse-3 cannot fall through to the global
    ;; `mouse-yank-primary'/`mouse-save-then-kill', both of which would
    ;; mutate the terminal region as ordinary buffer text.
    (dolist (button '(mouse-1 mouse-2 mouse-3))
      (dolist (mods '(() (control) (meta) (control meta) (shift)
                       (control shift) (meta shift) (control meta shift)))
        (define-key map (vector (event-convert-list (append mods (list button))))
          #'mouse-set-point)))
    (dolist (wheel '(wheel-up wheel-down wheel-left wheel-right
                      mouse-4 mouse-5 mouse-6 mouse-7))
      (dolist (mods '(() (control) (meta) (control meta) (shift)
                       (control shift) (meta shift) (control meta shift)))
        (define-key map (vector (event-convert-list (append mods (list wheel))))
          #'spectreshell-mouse-wheel)))
    ;; C-c and C-x (both kept as prefixes for Emacs commands, `C-c C-e'
    ;; below included), M-x, C-u (`universal-argument'), and C-y
    ;; (`spectreshell-yank' below, not a plain key send) are
    ;; docs/design.org's named exceptions to "send nearly everything";
    ;; every other control letter goes straight to the PTY.  Window/buffer
    ;; commands are the far more common need in a terminal buffer than a
    ;; nested `emacs -nw' or readline's `C-x C-e'; the keys themselves go
    ;; through `C-\' (`spectreshell-send-next-key') below.
    (dolist (letter (number-sequence ?a ?z))
      (unless (memq letter '(?c ?u ?x ?y))
        (define-key map (kbd (format "C-%c" letter)) #'spectreshell-send-key)))
    ;; Meta over the whole printable ASCII range, bound in its ESC-prefixed
    ;; form -- which is both how a terminal frame delivers M-<char> (two
    ;; events) and how keymaps store a meta character's binding anyway, so
    ;; one loop covers both frame types.  Digits and punctuation are in the
    ;; range because Emacs's own commands on them (`digit-argument',
    ;; `xref-find-definitions' on M-., `cycle-spacing' on M-SPC,
    ;; `dabbrev-expand' on M-/) are useless in a terminal buffer and the
    ;; last two edit the terminal region as ordinary text; upper case is in
    ;; the range because with `M-A' unbound Emacs shift-translates it down
    ;; to `M-a' and the case is gone before the event is ever seen.
    ;; M-x is docs/design.org's named exception.  ESC O (SS3) and ESC [
    ;; (CSI) must stay unbound, so M-O and M-[ need `C-\': they are the
    ;; prefixes the terminal itself sends for the arrows, F1-F4 and
    ;; Home/End, and `input-decode-map' only gets to translate those while
    ;; the sequence read so far has no binding in the active keymaps.
    (dolist (char (number-sequence ?\s 126))
      (unless (memq char '(?O ?\[ ?x))
        (define-key map (vector ?\e char) #'spectreshell-send-key)))
    ;; ESC ESC is the way to send a bare ESC; see `spectreshell-send-escape'.
    (define-key map (vector ?\e ?\e) #'spectreshell-send-escape)
    ;; C-M-<letter> is bound without exceptions: docs/design.org names
    ;; C-c/C-x (as prefixes), M-x and C-y, and none of those is the same
    ;; event as its C-M- counterpart, so nothing in this range has a
    ;; reason to stay on the Emacs side.
    (dolist (letter (number-sequence ?a ?z))
      (define-key map (kbd (format "C-M-%c" letter)) #'spectreshell-send-key))
    ;; Control keys whose base character is not a letter, plus M-DEL
    ;; (readline's `backward-kill-word'): none of them is reachable from
    ;; the letter loops above, and the Emacs commands they land on
    ;; otherwise (`undo' on C-_, `backward-kill-word' on M-DEL) edit the
    ;; terminal region as if it were ordinary buffer text.
    (dolist (key '("C-@" "C-]" "C-^" "C-_" "M-DEL"))
      (define-key map (kbd key) #'spectreshell-send-key))
    ;; C-S-<letter> and control on a printable non-letter whose control
    ;; form is no C0 byte (C--, C-1, C-SPC, C-/, ...) arrive as events of
    ;; their own on a GUI frame or under kkp.  Unbound, the former
    ;; shift-translates down to C-<letter> and the latter run Emacs
    ;; commands (`undo' on C-/ edits the terminal region).
    (dolist (letter (number-sequence ?a ?z))
      (define-key map (vector (event-convert-list (list 'control 'shift letter)))
        #'spectreshell-send-key))
    (dolist (char (number-sequence ?\s ?~))
      (let ((event (event-convert-list (list 'control char))))
        (unless (or (<= ?a (downcase char) ?z) (< event 128))
          (define-key map (vector event) #'spectreshell-send-key))))
    (define-key map (kbd "C-\\") #'spectreshell-send-next-key)
    (define-key map (kbd "C-y") #'spectreshell-yank)
    (define-key map [xterm-paste] #'spectreshell-xterm-paste)
    (define-key map (kbd "C-c C-e") #'spectreshell-emacs-mode)
    ;; The second C-c is `last-command-event', so this sends one C-c
    ;; instead of eshell's `eshell-interrupt-process'.  A child in raw
    ;; mode (Claude Code's press-twice-to-exit) needs the key, not a
    ;; SIGINT; one with ISIG on still gets SIGINT from the tty driver.
    (define-key map (kbd "C-c C-c") #'spectreshell-send-key)
    map)
  "Keymap active while `spectreshell-semi-char-mode' is on.
Sends nearly every key to the terminal; see docs/design.org's semi-char
mode section for the (small) set of keys deliberately left to Emacs.")

(defvar spectreshell--emulation-mode-map-alist
  (list (cons 'spectreshell-semi-char-mode spectreshell-semi-char-mode-map))
  "`emulation-mode-map-alists' entry for `spectreshell-semi-char-mode-map'.
The `minor-mode-map-alist' entry that `define-minor-mode' makes is not
enough on its own: a major mode's own minor modes can sit ahead of it
there (eshell's `eshell-cmpl-mode'/`eshell-hist-mode' do, and take TAB,
S-TAB and the arrows for themselves), and that order is fixed by the
order the modes were turned on, which spectreshell does not control.
`emulation-mode-map-alists' is searched before all of them.")

(add-to-list 'emulation-mode-map-alists 'spectreshell--emulation-mode-map-alist)

(defvar spectreshell-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "C-c C-j") #'spectreshell-semi-char-mode-on)
    map)
  "Keymap for `spectreshell-mode', active regardless of semi-char/emacs sub-mode.
Only holds the entry point back into `spectreshell-semi-char-mode', so
that it stays reachable while `spectreshell-emacs-mode' (in
`spectreshell-semi-char-mode-map') has left it turned off.")

;;;###autoload
(define-minor-mode spectreshell-mode
  "Base minor mode for a buffer with a `spectreshell--current' terminal.
Provides \\<spectreshell-mode-map>\\[spectreshell-semi-char-mode-on] to
\(re-)enter `spectreshell-semi-char-mode' and the mode-line indication
for \"emacs mode\" (semi-char off); the semi-char lighter is
contributed by `spectreshell-semi-char-mode' itself while it is on,
which also turns this mode on as a side effect of enabling it."
  :lighter (:eval (unless spectreshell-semi-char-mode " SpectreShell[emacs]"))
  :keymap spectreshell-mode-map)

(defun spectreshell-semi-char-mode-on ()
  "Enter `spectreshell-semi-char-mode'.
Bound to \\<spectreshell-mode-map>\\[spectreshell-semi-char-mode-on] in
`spectreshell-mode-map'."
  (interactive)
  (spectreshell-semi-char-mode 1))

;;;###autoload
(define-minor-mode spectreshell-semi-char-mode
  "Minor mode that sends nearly every key straight to `spectreshell--current'.
This is eshell-under-spectreshell's default mode while a job is running
\(docs/design.org); \\<spectreshell-semi-char-mode-map>\\[spectreshell-emacs-mode] leaves it (`spectreshell-emacs-mode') for
ordinary Emacs buffer editing, and
\\<spectreshell-mode-map>\\[spectreshell-semi-char-mode-on] (from the
always-present `spectreshell-mode-map') re-enters it."
  :lighter " SpectreShell[semi]"
  :keymap spectreshell-semi-char-mode-map
  ;; `spectreshell-mode' owns `C-c C-j' and the "emacs mode" lighter, both
  ;; needed to get back here after `spectreshell-emacs-mode'; turning this
  ;; mode on implies wanting those too, even before either mode has been
  ;; explicitly enabled in this buffer.
  (when spectreshell-semi-char-mode
    (spectreshell-mode 1)))

(defun spectreshell-emacs-mode ()
  "Leave semi-char mode for ordinary Emacs buffer editing.
Bound to \\<spectreshell-semi-char-mode-map>\\[spectreshell-emacs-mode] in
`spectreshell-semi-char-mode-map'.  All keys behave like ordinary Emacs
again until `spectreshell-semi-char-mode-on' re-enters semi-char mode."
  (interactive)
  (spectreshell-semi-char-mode -1))

(provide 'spectreshell)
;;; spectreshell.el ends here
