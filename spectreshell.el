;;; spectreshell.el --- Terminal emulation rendering engine for eshell -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Shinnosuke Sawada-Dazai

;; Author: Shinnosuke Sawada-Dazai <shin@warashi.dev>
;; Keywords: terminals, processes
;; Package-Requires: ((emacs "31.1"))

;; This file is part of emacs-spectreshell, and is distributed under
;; the MIT License; see LICENSE for details.

;;; Commentary:

;; `spectreshell.el' is the eshell-independent rendering core described in
;; docs/design.md.  It owns the mapping between a `libspectreshell.so'
;; terminal object (see docs/module-api.md) and a region of an Emacs
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

;; Defined by `libspectreshell.so' (module-load'ed at runtime, not a
;; regular Elisp library); declared to keep the byte-compiler quiet.
(declare-function spectreshell--create "libspectreshell" (rows cols))
(declare-function spectreshell--feed "libspectreshell" (term bytes))
(declare-function spectreshell--resize "libspectreshell" (term rows cols))
(declare-function spectreshell--release "libspectreshell" (term))
(declare-function spectreshell--encode-key "libspectreshell" (term key modifiers))
(declare-function spectreshell--encode-paste "libspectreshell" (term text))

(defgroup spectreshell nil
  "Terminal emulation rendering engine for eshell."
  :group 'terminals
  :prefix "spectreshell-")

;; ---------------------------------------------------------------------
;; Faces
;; ---------------------------------------------------------------------

;; SGR 30-37/90-97 map onto palette indices 0-15 in this fixed order
;; (docs/module-api.md :fg/:bg); inheriting from the existing
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
  alt-saved)

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
Return the raw update plist from `spectreshell--feed' (docs/module-api.md)."
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
releasing the module's terminal object."
  (with-current-buffer (spectreshell-buffer obj)
    (goto-char (point-max)))
  (set-marker (spectreshell-marker obj) nil)
  (spectreshell--release (spectreshell-term obj))
  nil)

;; ---------------------------------------------------------------------
;; Update plist application
;; ---------------------------------------------------------------------

(defun spectreshell--apply-update (obj update)
  "Apply the module UPDATE plist for OBJ to its buffer and send-fn.
Return UPDATE unchanged, for callers that want to inspect it further."
  (with-current-buffer (spectreshell-buffer obj)
    (let ((inhibit-read-only t))
      (spectreshell--handle-alt-screen obj (plist-get update :alt-screen))
      (spectreshell--apply-scrolled-off obj (plist-get update :scrolled-off))
      (spectreshell--apply-dirty obj (plist-get update :dirty))
      (spectreshell--trim-rows obj)
      (spectreshell--move-point obj (plist-get update :cursor))))
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
        ;; ghostty-vt's dirty tracking is page-granular (module-api.md), so
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
in docs/module-api.md; ATTR is `:foreground' or `:background'.  Palette
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

(defun spectreshell--apply-scrolled-off (obj scrolled-off)
  "Confirm SCROLLED-OFF (the :scrolled-off list) as scrollback text in OBJ."
  (when scrolled-off
    (let ((marker (spectreshell-marker obj)))
      (goto-char marker)
      (insert (mapconcat (lambda (entry)
                            (spectreshell--decorate-row (car entry) (cdr entry)))
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
COL is clamped to the row's length in case the module ever reports a
column past the end of a short row."
  (save-excursion
    (goto-char (spectreshell-marker obj))
    (forward-line row)
    (min (line-end-position) (+ (point) col))))

;; ---------------------------------------------------------------------
;; Key event normalization
;; ---------------------------------------------------------------------

(defconst spectreshell--special-key-symbols
  '(up down left right home end prior next insert delete backspace tab
    return escape
    f1 f2 f3 f4 f5 f6 f7 f8 f9 f10 f11 f12)
  "Symbols `spectreshell--encode-key' accepts as KEY (docs/module-api.md).
`spectreshell--event-to-key' passes an `event-basic-type' symbol through
unchanged exactly when it is a member of this list.")

(defconst spectreshell--ascii-special-keys
  '((?\t . tab) (?\r . return) (?\e . escape) (?\C-? . backspace))
  "ASCII control codes that name a special KEY of their own.
TAB/RET/ESC/DEL are indistinguishable, at the character level, from
Control-i/Control-m/Control-\\[/Control-? (`event-basic-type' cannot
tell them apart either), but docs/module-api.md encodes them as their
own symbols rather than as \"i\"/\"m\"/\"[\"/\"?\" plus `ctrl'.")

(defun spectreshell--event-to-key (event)
  "Normalize EVENT to a (KEY . MODIFIERS) pair for `spectreshell--encode-key'.
EVENT is anything `last-command-event' can hold: an integer (a plain or
control/meta-modified character) or a symbol (a function key, possibly
combined with modifiers, e.g. `C-up' or `M-S-f5').  KEY/MODIFIERS follow
docs/module-api.md.  Return nil when EVENT has no PTY-sendable
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
stands in for Emacs's `meta', per docs/module-api.md); anything else
(mouse click counts, drag, Emacs's own separate `alt' modifier for a
literal Alt key, ...) has no PTY encoding and is dropped rather than
mapped to something misleading."
  (delq nil (list (and (memq 'control mods) 'ctrl)
                   (and (memq 'meta mods) 'alt)
                   (and (memq 'shift mods) 'shift)
                   (and (memq 'super mods) 'super))))

(provide 'spectreshell)
;;; spectreshell.el ends here
