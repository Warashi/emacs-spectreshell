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
(declare-function spectreshell--release "libspectreshell" (term))
(declare-function spectreshell--encode-key "libspectreshell" (term key modifiers))
(declare-function spectreshell--encode-paste "libspectreshell" (term text))
(declare-function spectreshell--encode-mouse "libspectreshell" (term button action row col modifiers))

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
  rows
  cols
  send-fn
  alt-saved
  title)

(defvar spectreshell-title-functions nil
  "Abnormal hook run when a terminal's title changes (OSC 0/2).
Each function is called with two arguments, the `spectreshell' object
and the new title string, with the terminal's buffer current.  The
latest title is also always readable from `spectreshell-title'.
spectreshell itself deliberately renames nothing (a buffer rename would
break eshell's buffer bookkeeping, a frame title is not this layer's
to own); displaying the title anywhere is entirely up to these hooks.")

;;;###autoload
(defun spectreshell-start (buffer rows cols send-fn)
  "Start a ROWS x COLS spectreshell terminal rendering into BUFFER.

The terminal region begins at BUFFER's point at call time and always
extends to the end of the buffer afterwards; callers must therefore
invoke this right after a newline (mid-line start positions are not
supported).  SEND-FN is called with a single unibyte string argument
whenever `spectreshell-feed' or `spectreshell-resize' produces PTY
response bytes (e.g. a DSR cursor-position reply) that must be written
back to the child process.

Return a new `spectreshell' object to pass to the other
`spectreshell-*' functions."
  (spectreshell-ensure-module-loaded)
  (with-current-buffer buffer
    (spectreshell--make
     :term (spectreshell--create rows cols)
     :buffer buffer
     :marker (point-marker)
     :rows rows
     :cols cols
     :send-fn send-fn
     :alt-saved nil)))

(defun spectreshell-feed (obj bytes)
  "Feed BYTES (a unibyte string) to OBJ's terminal and update its buffer.
Return the raw update plist from `spectreshell--feed' (docs/module-api.org)."
  (spectreshell--apply-update obj (spectreshell--feed (spectreshell-term obj) bytes)))

(defun spectreshell-resize (obj rows cols)
  "Resize OBJ's terminal to ROWS x COLS and update its buffer accordingly.
Return the raw update plist from `spectreshell--resize'."
  (let ((update (spectreshell--resize (spectreshell-term obj) rows cols)))
    (setf (spectreshell-rows obj) rows
          (spectreshell-cols obj) cols)
    (spectreshell--apply-update obj update)))

(defun spectreshell-finalize (obj)
  "Freeze OBJ's terminal region as ordinary buffer text and release it.
Call this once when the backing process has exited; OBJ (and the
module terminal it wraps) must not be used again afterwards.  The
terminal region is already rendered as real buffer text throughout, so
there is nothing left to convert here beyond detaching the marker and
releasing the module's terminal object.

If the process died while the alternate screen was still active (a
clean exit would have sent ?1049l first), the saved primary screen is
restored just as leaving the alt screen would have, so the user's
pre-TUI screen content is not silently lost."
  (with-current-buffer (spectreshell-buffer obj)
    (save-restriction
      (widen)
      (let ((inhibit-read-only t)
            (buffer-undo-list t))
        (when (spectreshell-alt-saved obj)
          (spectreshell--leave-alt-screen obj))
        (spectreshell--trim-frozen-region obj)))
    (goto-char (point-max)))
  (set-marker (spectreshell-marker obj) nil)
  (spectreshell--release (spectreshell-term obj))
  nil)

(defun spectreshell--trim-frozen-region (obj)
  "Strip OBJ's terminal-region padding before it freezes into plain text.
Removes each line's trailing run of property-less spaces (the module
pads rows to the full terminal width; see
`spectreshell--trim-trailing-blanks' for why styled spaces survive),
then the all-blank tail rows below the last real output, so eshell's
next prompt lands right under the output instead of a screenful of
blank lines further down."
  (let ((marker (spectreshell-marker obj)))
    (goto-char marker)
    (while (< (point) (point-max))
      (end-of-line)
      (while (and (> (point) (line-beginning-position))
                  (eq (char-before) ?\s)
                  (null (text-properties-at (1- (point)))))
        (delete-char -1))
      (forward-line 1))
    (goto-char (point-max))
    (skip-chars-backward "\n" marker)
    (delete-region (point) (point-max))
    (insert "\n")))

;; ---------------------------------------------------------------------
;; Update plist application
;; ---------------------------------------------------------------------

(defun spectreshell--apply-update (obj update)
  "Apply the module UPDATE plist for OBJ to its buffer and send-fn.
Return UPDATE unchanged, for callers that want to inspect it further."
  (with-current-buffer (spectreshell-buffer obj)
    ;; This runs from a process filter at arbitrary times, so the user may
    ;; have narrowed the buffer meanwhile; every helper below treats
    ;; `point-max' as the terminal region's end, which a narrowed
    ;; `point-max' would silently corrupt (e.g. `spectreshell--trim-rows'
    ;; deleting up to the wrong "end of buffer").
    (save-restriction
      (widen)
      ;; `buffer-undo-list' is bound to t because terminal redraw churn
      ;; would otherwise accumulate unbounded undo entries (eshell buffers
      ;; have undo enabled), and undoing a redraw after the job exits
      ;; would corrupt confirmed scrollback text.
      (let ((inhibit-read-only t)
            (buffer-undo-list t))
        (spectreshell--handle-alt-screen obj (plist-get update :alt-screen))
        (spectreshell--apply-scrolled-off obj (plist-get update :scrolled-off))
        (spectreshell--apply-dirty obj (plist-get update :dirty))
        (spectreshell--trim-rows obj)
        (spectreshell--move-point obj (plist-get update :cursor))
        (when-let* ((title (plist-get update :title)))
          (setf (spectreshell-title obj) title)
          (run-hook-with-args 'spectreshell-title-functions obj title)))))
  (when-let* ((response (plist-get update :responses)))
    (funcall (spectreshell-send-fn obj) response))
  update)

;; ---------------------------------------------------------------------
;; Terminal-region geometry helpers
;; ---------------------------------------------------------------------

(defun spectreshell--row-count (obj)
  "Return how many newline-terminated lines OBJ's terminal region has."
  (count-lines (spectreshell-marker obj) (point-max)))

(defun spectreshell--pad-rows (obj upto)
  "Append blank lines to OBJ's terminal region until row UPTO exists."
  (let ((blank (concat (make-string (spectreshell-cols obj) ?\s) "\n")))
    (goto-char (point-max))
    (while (<= (spectreshell--row-count obj) upto)
      (insert blank))))

(defun spectreshell--row-bounds (obj row)
  "Return (BEG . END) of ROW's text, sans trailing newline, in OBJ."
  (save-excursion
    (goto-char (spectreshell-marker obj))
    (forward-line row)
    (cons (point) (line-end-position))))

(defun spectreshell--trim-rows (obj)
  "Delete trailing buffer lines beyond OBJ's current row count.
Only has an effect right after `spectreshell-resize' shrank the row
count; ordinary `spectreshell-feed' calls never change the line count
of the terminal region."
  (let ((excess (- (spectreshell--row-count obj) (spectreshell-rows obj))))
    (when (> excess 0)
      (goto-char (spectreshell-marker obj))
      (forward-line (spectreshell-rows obj))
      (delete-region (point) (point-max)))))

;; ---------------------------------------------------------------------
;; Dirty row diff application
;; ---------------------------------------------------------------------

(defun spectreshell--apply-dirty (obj dirty)
  "Apply DIRTY (the :dirty list from an update plist) to OBJ's buffer."
  (dolist (entry dirty)
    (pcase-let ((`(,row ,text ,spans) entry))
      (spectreshell--pad-rows obj row)
      (pcase-let* ((`(,beg . ,end) (spectreshell--row-bounds obj row))
                   (new (spectreshell--decorate-row text spans)))
        ;; ghostty-vt's dirty tracking is page-granular (module-api.org), so
        ;; a batch often marks rows dirty whose rendered content did not
        ;; actually change; skipping the replace avoids pointless
        ;; text-property churn (and keeps point/undo more stable) for them.
        (unless (equal-including-properties (buffer-substring beg end) new)
          (delete-region beg end)
          (goto-char beg)
          (insert new))))))

(defun spectreshell--decorate-row (text spans)
  "Return a copy of TEXT with SPANS applied as face/button properties.
SPANS is the module's per-row span list; TEXT is fresh from the module
on every call, so it is safe to add properties to it directly."
  (dolist (span spans)
    (pcase-let ((`(,start ,end . ,style) span))
      (let ((face (spectreshell--span-face style))
            (uri (plist-get style :hyperlink)))
        (when face
          (put-text-property start end 'face face text))
        (when uri
          ;; `make-text-button' only buttonizes a BEG..END buffer range OR
          ;; (as a convenience) an *entire* string, never a substring
          ;; range of one; splice a buttonized copy of just [start,end)
          ;; back into TEXT to get the same effect here. Length is
          ;; preserved, so later spans' indices in this same loop stay
          ;; valid.
          (setq text (concat (substring text 0 start)
                              (make-text-button
                               (substring text start end) nil
                               'type 'spectreshell-hyperlink
                               'help-echo uri
                               'spectreshell-hyperlink-uri uri)
                              (substring text end)))))))
  text)

;; ---------------------------------------------------------------------
;; Style span -> face conversion
;; ---------------------------------------------------------------------

(defun spectreshell--span-face (style)
  "Build a `face' text-property value (a list) for STYLE-PLIST STYLE."
  (let* ((fg (spectreshell--resolve-color (plist-get style :fg) :foreground))
         (bg (spectreshell--resolve-color (plist-get style :bg) :background))
         (underline (plist-get style :underline))
         faces)
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
                             (spectreshell--decorate-row (car entry) (cdr entry))))
                          scrolled-off "\n")
              "\n")
      ;; The marker's default (nil) insertion-type leaves it *behind* text
      ;; inserted at its own position, i.e. still pointing at the
      ;; scrollback we just confirmed instead of the terminal region that
      ;; now starts after it; `point' (left at the insertion end by
      ;; `insert') is exactly the position we want it repinned to.
      (set-marker marker (point)))))

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
  (setf (spectreshell-alt-saved obj)
        (buffer-substring (spectreshell-marker obj) (point-max)))
  (delete-region (spectreshell-marker obj) (point-max))
  (spectreshell--pad-rows obj (1- (spectreshell-rows obj))))

(defun spectreshell--leave-alt-screen (obj)
  "Discard the alt screen's contents in OBJ and restore the saved primary screen."
  (delete-region (spectreshell-marker obj) (point-max))
  (when-let* ((saved (spectreshell-alt-saved obj)))
    (goto-char (spectreshell-marker obj))
    (insert saved))
  (setf (spectreshell-alt-saved obj) nil))

;; ---------------------------------------------------------------------
;; Cursor tracking
;; ---------------------------------------------------------------------

(defun spectreshell--move-point (obj cursor)
  "Move point (and window-point, if displayed) to CURSOR in OBJ.
CURSOR is the :cursor (ROW . COL) cons from an update plist."
  (pcase-let ((`(,row . ,col) cursor))
    (let ((pos (spectreshell--row-col-pos obj row col)))
      (goto-char pos)
      (dolist (window (get-buffer-window-list (spectreshell-buffer obj) nil t))
        (set-window-point window pos)))))

(defun spectreshell--row-col-pos (obj row col)
  "Return the buffer position of (ROW . COL) in OBJ's terminal region.
COL is a terminal *cell* column (docs/module-api.org), not a character
offset: a double-width character occupies two cells but only one buffer
position, so the mapping goes through display columns
\(`move-to-column', which counts each character's `char-width') rather
than character counting.  A COL past the end of a short row clamps to
the end of that line."
  (save-excursion
    (goto-char (spectreshell-marker obj))
    (forward-line row)
    (move-to-column col)
    (point)))

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

(defun spectreshell--event-to-key (event)
  "Normalize EVENT to a (KEY . MODIFIERS) pair for `spectreshell--encode-key'.
EVENT is anything `last-command-event' can hold: an integer (a plain or
control/meta-modified character) or a symbol (a function key, possibly
combined with modifiers, e.g. `C-up' or `M-S-f5').  KEY/MODIFIERS follow
docs/module-api.org.  Return nil when EVENT has no PTY-sendable
representation (mouse events, unrecognized function keys, a bare
modifier press, ...)."
  ;; TAB/RET/ESC/DEL must be matched on the raw EVENT, not on
  ;; `event-basic-type', because that function's stripping of the
  ;; "control" that is baked into those ASCII codes is exactly what turns
  ;; them into indistinguishable-from-C-i/C-m/C-[/C-? in the first place.
  (let ((ascii (and (integerp event) (assq event spectreshell--ascii-special-keys))))
    (if ascii
        (cons (cdr ascii)
              (spectreshell--event-modifiers-to-modifiers
               (remove 'control (event-modifiers event))))
      (when-let* ((key (spectreshell--basic-type-to-key (event-basic-type event))))
        (cons key (spectreshell--event-modifiers-to-modifiers (event-modifiers event)))))))

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
`spectreshell-eshell.el' (Phase 5) sets this when a process starts;
nil means there is currently nothing to send input to, in which case
the semi-char mode commands below are silent no-ops rather than errors
\(matching a plain terminal buffer that just hasn't started a job yet).")

;; ---------------------------------------------------------------------
;; Input commands
;; ---------------------------------------------------------------------

(defun spectreshell-send-key ()
  "Encode `last-command-event' and send it to `spectreshell--current'.
Bound throughout `spectreshell-semi-char-mode-map' (directly, and via
the `self-insert-command' remap) to turn nearly every key into a
`spectreshell--encode-key' call.  Does nothing if there is no current
terminal, or if the event or the encoder has no bytes to send for it."
  (interactive)
  (when-let* ((obj spectreshell--current)
              (key+mods (spectreshell--event-to-key last-command-event))
              (bytes (spectreshell--encode-key (spectreshell-term obj)
                                                (car key+mods) (cdr key+mods))))
    (funcall (spectreshell-send-fn obj) bytes)))

(defun spectreshell-yank ()
  "Send the front of the kill ring to `spectreshell--current' as a paste.
Bound to `C-y' in `spectreshell-semi-char-mode-map' instead of ordinary
`yank': pasted text is one `spectreshell--encode-paste' call (bracketed
paste, if the terminal has that mode on) rather than a `spectreshell-send-key'
call per character."
  (interactive)
  (when-let* ((obj spectreshell--current))
    (funcall (spectreshell-send-fn obj)
             (spectreshell--encode-paste (spectreshell-term obj) (current-kill 0)))))

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

(defun spectreshell--posn-terminal-coords (obj posn)
  "Return OBJ's 0-origin (ROW . COL) terminal coordinates for POSN.
POSN is an `event-start'/`event-end' position object.  Return nil when
POSN has no buffer position at all (e.g. a click in the fringe) or
falls before OBJ's terminal-region marker (a click on already-confirmed
scrollback text, which is not part of the live terminal grid)."
  (when-let* ((pt (posn-point posn))
              (marker-pos (marker-position (spectreshell-marker obj)))
              ((>= pt marker-pos)))
    (with-current-buffer (spectreshell-buffer obj)
      (save-excursion
        (goto-char pt)
        ;; COL must be a terminal *cell* column (`spectreshell--encode-mouse'
        ;; encodes it as-is into the mouse report), so use `current-column'
        ;; -- display columns, counting a double-width character as two --
        ;; rather than the character offset from the line start.  Clamp in
        ;; case POSN lands past a short row's last character (rows are
        ;; padded to `spectreshell-cols' by `spectreshell--pad-rows'/
        ;; dirty-row replacement, so this is mostly a defensive bound
        ;; rather than a normal occurrence).
        (cons (count-lines marker-pos (line-beginning-position))
              (max 0 (min (1- (spectreshell-cols obj)) (current-column))))))))

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
Reads events in a `read-event' loop with mouse-movement events enabled
-- the same idiom `mouse-drag-region' uses -- so
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
        (let ((event (read-event)))
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
    ;; Unlike TAB/RET/ESC/DEL, a modified function key (`C-up', `M-S-f5', ...)
    ;; is its own distinct symbol rather than a modifier bit layered on a
    ;; shared base event, so each combination needs its own binding.
    (dolist (key '(up down left right home end prior next insert delete
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
    ;; C-c (kept as a prefix for Emacs commands, `C-c C-e' below included),
    ;; M-x, C-u (`universal-argument'), and C-y (`spectreshell-yank' below,
    ;; not a plain key send) are docs/design.org's named exceptions to
    ;; "send nearly everything"; every other control letter goes straight
    ;; to the PTY.
    (dolist (letter (number-sequence ?a ?z))
      (unless (memq letter '(?c ?u ?y))
        (define-key map (kbd (format "C-%c" letter)) #'spectreshell-send-key)))
    ;; M-x is the only named meta exception.
    (dolist (letter (number-sequence ?a ?z))
      (unless (eq letter ?x)
        (define-key map (kbd (format "M-%c" letter)) #'spectreshell-send-key)))
    (define-key map (kbd "C-y") #'spectreshell-yank)
    (define-key map (kbd "C-c C-e") #'spectreshell-emacs-mode)
    map)
  "Keymap active while `spectreshell-semi-char-mode' is on.
Sends nearly every key to the terminal; see docs/design.org's semi-char
mode section for the (small) set of keys deliberately left to Emacs.")

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
