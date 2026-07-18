;;; spectreshell-key-test.el --- ERT tests for spectreshell.el key input -*- lexical-binding: t; -*-

;; Phase 4 (キー入力) の完了条件である「モード切替とキー送信の ERT が
;; 通る」を満たすテスト。イベント正規化 (`spectreshell--event-to-key')・
;; semi-char/emacs モードの切り替えとキーマップ・実際のキーイベント
;; 経由での送信を検証する。

(require 'ert)
(require 'cl-lib)

(defconst spectreshell-test--module-path
  (expand-file-name "../zig-out/lib/libspectreshell.so"
                     (file-name-directory (or load-file-name buffer-file-name)))
  "テスト対象の libspectreshell.so への絶対パス。
`just test-el' が事前に `zig build' を実行して用意する。")

(unless (featurep 'spectreshell-module)
  (module-load spectreshell-test--module-path)
  (provide 'spectreshell-module))

(require 'spectreshell)
;; `spectreshell-test--with-terminal' も一緒に持ってくる (spectreshell-test.el 参照)。
(require 'spectreshell-test)

;; ---------------------------------------------------------------------
;; イベント正規化
;; ---------------------------------------------------------------------

(ert-deftest spectreshell-key-test-plain-printable-char ()
  "印字可能な平文字 ?a は修飾子なしの \"a\" に正規化される。"
  (should (equal (spectreshell--event-to-key ?a) '("a"))))

(ert-deftest spectreshell-key-test-control-letter ()
  "?\\C-a は ctrl 修飾子付きの \"a\" に復元される。"
  (should (equal (spectreshell--event-to-key ?\C-a) '("a" ctrl))))

(ert-deftest spectreshell-key-test-meta-letter ()
  "?\\M-f は alt 修飾子付きの \"f\" に正規化される (meta -> alt)。"
  (should (equal (spectreshell--event-to-key ?\M-f) '("f" alt))))

(ert-deftest spectreshell-key-test-control-meta-letter ()
  "?\\C-\\M-a は ctrl と alt の両方が立つ。"
  (should (equal (spectreshell--event-to-key ?\C-\M-a) '("a" ctrl alt))))

(ert-deftest spectreshell-key-test-tab-return-escape-backspace ()
  "TAB/RET/ESC/DEL は C-i/C-m/C-[/C-? ではなく専用シンボルになる。"
  (should (equal (spectreshell--event-to-key ?\t) '(tab)))
  (should (equal (spectreshell--event-to-key ?\r) '(return)))
  (should (equal (spectreshell--event-to-key ?\e) '(escape)))
  (should (equal (spectreshell--event-to-key ?\C-?) '(backspace))))

(ert-deftest spectreshell-key-test-space ()
  "スペースは特別扱いされず長さ1の文字列になる。"
  (should (equal (spectreshell--event-to-key ?\s) '(" "))))

;; `event-basic-type'/`event-modifiers' はそのセッションで一度も使われて
;; いないシンボルには nil を返すことがある (それぞれの docstring 参照)。
;; `spectreshell-semi-char-mode-map' の定義が define-key 経由で
;; up/f5 等のシンボルに一度触れるので、この require の時点でどちらも
;; 実際のキー入力を経ずに正規化できるようになっている。
(ert-deftest spectreshell-key-test-function-key-symbol ()
  "'up や 'f5 のような function key シンボルはそのまま KEY になる。"
  (should (equal (spectreshell--event-to-key 'up) '(up)))
  (should (equal (spectreshell--event-to-key 'f5) '(f5))))

(ert-deftest spectreshell-key-test-control-shift-combination ()
  "C-S-up のような複合修飾子付き function key も分解できる。"
  (should (equal (spectreshell--event-to-key
                   (event-convert-list '(control shift up)))
                  '(up ctrl shift))))

(ert-deftest spectreshell-key-test-unrecognized-event-is-nil ()
  "マウスイベント等、対応する KEY がないイベントは nil になる。"
  (should (null (spectreshell--event-to-key 'mouse-1))))

(ert-deftest spectreshell-key-test-circular-modifier-list-signals ()
  "循環した MODIFIERS リストはハングせずエラーで返る。"
  (spectreshell-test--with-terminal (term 5 10)
    (let ((mods (list 'ctrl)))
      (setcdr mods mods)
      (should-error (spectreshell--encode-key (spectreshell-term term) "a" mods)))))

;; ---------------------------------------------------------------------
;; 矢印キー: DECCKM 追従
;; ---------------------------------------------------------------------

(ert-deftest spectreshell-key-test-arrow-key-follows-decckm ()
  "上矢印キーは DECCKM オフでは ESC[A、オンでは ESCOA を送信する。"
  (spectreshell-test--with-terminal (term 5 10 responses)
    (let ((spectreshell--current term)
          (last-command-event 'up))
      (spectreshell-send-key)
      (should (equal (car responses) "\x1b[A"))
      (spectreshell-feed term "\x1b[?1h")
      (spectreshell-send-key)
      (should (equal (car responses) "\x1bOA")))))

;; ---------------------------------------------------------------------
;; 印字可能文字の送信
;; ---------------------------------------------------------------------

(ert-deftest spectreshell-key-test-printable-char-is-sent ()
  "印字可能文字 \"a\" が send-fn にそのまま届く。"
  (spectreshell-test--with-terminal (term 5 10 responses)
    (let ((spectreshell--current term)
          (last-command-event ?a))
      (spectreshell-send-key)
      (should (equal (car responses) "a")))))

(ert-deftest spectreshell-key-test-send-key-noop-without-current-terminal ()
  "spectreshell--current が nil のときは送信されず、エラーにもならない。"
  (with-temp-buffer
    (let ((last-command-event ?a))
      (should (null (spectreshell-send-key))))))

;; ---------------------------------------------------------------------
;; C-y (paste)
;; ---------------------------------------------------------------------

(ert-deftest spectreshell-key-test-yank-sends-kill-ring-as-bracketed-paste ()
  "C-y は kill-ring 先頭を bracketed paste (有効時) で送信する。"
  (spectreshell-test--with-terminal (term 5 10 responses)
    (let ((spectreshell--current term))
      (spectreshell-feed term "\x1b[?2004h")
      (kill-new "hi")
      (spectreshell-yank)
      (should (equal (car responses) "\x1b[200~hi\x1b[201~")))))

;; ---------------------------------------------------------------------
;; モード切替
;; ---------------------------------------------------------------------

(defun spectreshell-key-test--lighter (mode)
  "Return MODE's `minor-mode-alist' lighter text, evaluating an :eval spec.
`format-mode-line' always returns \"\" under `emacs -batch' (there is no
frame for it to render against), so tests read `minor-mode-alist'
directly instead of going through the mode-line machinery."
  (let ((spec (cadr (assq mode minor-mode-alist))))
    (if (and (consp spec) (eq (car spec) :eval))
        (eval (cadr spec) t)
      spec)))

(ert-deftest spectreshell-key-test-mode-toggle-switches-lighter ()
  "C-c C-e / C-c C-j でモードが切り替わり、mode-line の lighter が変わる。"
  (with-temp-buffer
    (spectreshell-semi-char-mode 1)
    (should spectreshell-semi-char-mode)
    (should (equal (spectreshell-key-test--lighter 'spectreshell-semi-char-mode)
                   " SpectreShell[semi]"))
    (call-interactively #'spectreshell-emacs-mode)
    (should-not spectreshell-semi-char-mode)
    (should spectreshell-mode)
    (should (equal (spectreshell-key-test--lighter 'spectreshell-mode)
                   " SpectreShell[emacs]"))
    (call-interactively #'spectreshell-semi-char-mode-on)
    (should spectreshell-semi-char-mode)
    (should (equal (spectreshell-key-test--lighter 'spectreshell-semi-char-mode)
                   " SpectreShell[semi]"))))

(ert-deftest spectreshell-key-test-c-c-prefix-and-m-x-stay-in-emacs ()
  "semi-char モード中も C-c C-e と M-x は Emacs 側のコマンドのまま残る。"
  (with-temp-buffer
    (spectreshell-semi-char-mode 1)
    (should (eq (key-binding (kbd "C-c C-e")) #'spectreshell-emacs-mode))
    (should (eq (key-binding (kbd "M-x")) #'execute-extended-command))
    (should (eq (key-binding (kbd "C-u")) #'universal-argument))))

;; ---------------------------------------------------------------------
;; 実イベント経由での送信 (execute-kbd-macro)
;; ---------------------------------------------------------------------

(ert-deftest spectreshell-key-test-execute-kbd-macro-sends-printable-key ()
  "execute-kbd-macro によるキーイベント経由でも印字可能文字が送信される。
`with-temp-buffer' だけでは選択ウィンドウのバッファが切り替わらず
`execute-kbd-macro' の内部コマンドループがそちらを見てしまうため
(実際に self-insert-command が *scratch* に対して走ってしまう)、
`switch-to-buffer' で選択ウィンドウ自体を切り替える。"
  (spectreshell-test--with-terminal (term 5 10 responses)
    (let ((buf (generate-new-buffer "spectreshell-key-test")))
      (unwind-protect
          (save-window-excursion
            (switch-to-buffer buf)
            (spectreshell-semi-char-mode 1)
            (setq spectreshell--current term)
            (execute-kbd-macro "a")
            (should (equal (car responses) "a")))
        (kill-buffer buf)))))

;; ---------------------------------------------------------------------
;; マウス: BUTTON 判別
;; ---------------------------------------------------------------------

(ert-deftest spectreshell-key-test-mouse-button-number ()
  "down/click/drag いずれの接頭辞・修飾子付きでも event-basic-type だけで判別できる。"
  (should (equal (spectreshell--mouse-button-number '(down-mouse-1 nil)) 1))
  (should (equal (spectreshell--mouse-button-number '(mouse-2 nil)) 2))
  (should (equal (spectreshell--mouse-button-number '(drag-mouse-3 nil nil)) 3))
  (should (equal (spectreshell--mouse-button-number '(C-down-mouse-1 nil)) 1))
  (should (equal (spectreshell--mouse-button-number '(wheel-up nil)) 'wheel-up))
  (should (equal (spectreshell--mouse-button-number '(mouse-4 nil)) 'wheel-up))
  (should (equal (spectreshell--mouse-button-number '(wheel-down nil)) 'wheel-down))
  (should (equal (spectreshell--mouse-button-number '(mouse-5 nil)) 'wheel-down)))

;; ---------------------------------------------------------------------
;; マウス: posn -> 端末座標変換
;; ---------------------------------------------------------------------

(defun spectreshell-key-test--posn (window pos)
  "Return a minimal POSITION object usable with `posn-point'/`posn-window'.
WINDOW may be nil (only `spectreshell--posn-terminal-coords', which never
looks at `posn-window', is safe to use with that); POS is the buffer
position (a marker is resolved to its integer position, since
`posn-point' is documented to return an integer)."
  (list window nil '(0 . 0) 0 nil (if (markerp pos) (marker-position pos) pos) nil nil nil nil))

(ert-deftest spectreshell-key-test-mouse-posn-coords-first-row ()
  "端末領域先頭行の POSN は (0 . 0) から数えた行・桁に変換される。"
  (spectreshell-test--with-terminal (term 3 10)
    (spectreshell-feed term "0123456789ABCDEFGHIJ")
    (should (equal (spectreshell--posn-terminal-coords
                     term (spectreshell-key-test--posn nil (spectreshell-marker term)))
                    '(0 . 0)))
    (should (equal (spectreshell--posn-terminal-coords
                     term (spectreshell-key-test--posn nil (+ (spectreshell-marker term) 5)))
                    '(0 . 5)))))

(ert-deftest spectreshell-key-test-mouse-posn-coords-second-row ()
  "2行目の POSN は ROW 1 に変換される。"
  (spectreshell-test--with-terminal (term 3 10)
    (spectreshell-feed term "0123456789ABCDEFGHIJ")
    ;; 端末領域の2行目 ("ABCDEFGHIJ") の先頭は marker から11文字目
    ;; (1行目10文字 + 改行1文字)。
    (should (equal (spectreshell--posn-terminal-coords
                     term (spectreshell-key-test--posn nil (+ (spectreshell-marker term) 11)))
                    '(1 . 0)))))

(ert-deftest spectreshell-key-test-mouse-posn-coords-with-wide-chars ()
  "全角文字を含む行の POSN はバッファ文字オフセットではなくセル列になる。"
  (spectreshell-test--with-terminal (term 3 10)
    (spectreshell-feed term "あいうx")
    ;; 「x」は marker から 3 文字目 (0-origin) だが、全角 3 文字の後ろ
    ;; なのでセル列は 6。
    (should (equal (spectreshell--posn-terminal-coords
                     term (spectreshell-key-test--posn nil (+ (spectreshell-marker term) 3)))
                    '(0 . 6)))))

(ert-deftest spectreshell-key-test-mouse-posn-coords-before-terminal-region-is-nil ()
  "端末領域より前 (確定済みスクロールバック) の POSN は nil になる。"
  (spectreshell-test--with-terminal (term 1 5)
    ;; 1行が流れ出て確定化され、marker が後ろへ動く。
    (spectreshell-feed term "12345\r\n67890")
    (should (> (spectreshell-marker term) (point-min)))
    (should (null (spectreshell--posn-terminal-coords
                    term (spectreshell-key-test--posn nil (point-min)))))))

;; ---------------------------------------------------------------------
;; マウス: エンコード送信
;; ---------------------------------------------------------------------

(ert-deftest spectreshell-key-test-mouse-send-sgr-encodes-and-sends ()
  "mode 1000+1006 が有効な端末では send-mouse が SGR バイト列を送信する。"
  (spectreshell-test--with-terminal (term 5 10 responses)
    (spectreshell-feed term "\x1b[?1000h\x1b[?1006h")
    (let ((posn (spectreshell-key-test--posn nil (+ (spectreshell-marker term) 2))))
      (should (equal (spectreshell--send-mouse term 1 'press posn nil) "\x1b[<0;3;1M"))
      (should (equal (car responses) "\x1b[<0;3;1M")))))

(ert-deftest spectreshell-key-test-mouse-send-noop-when-tracking-disabled ()
  "マウストラッキング未設定の端末では send-mouse は何も送らず nil を返す。"
  (spectreshell-test--with-terminal (term 5 10 responses)
    (let ((posn (spectreshell-key-test--posn nil (spectreshell-marker term))))
      (should (null (spectreshell--send-mouse term 1 'press posn nil)))
      (should (null responses)))))

;; ---------------------------------------------------------------------
;; マウス: down/wheel コマンド
;; ---------------------------------------------------------------------

(ert-deftest spectreshell-key-test-mouse-down-sends-press-and-tracks-drag ()
  "down-mouse コマンドは press を送信してからドラッグ追跡に入る。
`spectreshell--track-mouse-drag' は実イベントを読む無限ループのため、
ここではそれ自体を差し替えて呼び出し引数だけを検証する。"
  (spectreshell-test--with-terminal (term 5 10 responses)
    (spectreshell-feed term "\x1b[?1000h\x1b[?1006h")
    (let ((buf (generate-new-buffer "spectreshell-key-test-mouse"))
          (tracked nil))
      (unwind-protect
          (save-window-excursion
            (switch-to-buffer buf)
            (setq spectreshell--current term)
            (cl-letf (((symbol-function 'spectreshell--track-mouse-drag)
                       (lambda (obj button mods) (setq tracked (list obj button mods)))))
              (spectreshell-mouse-down
               (list 'down-mouse-1 (spectreshell-key-test--posn (selected-window)
                                                                  (spectreshell-marker term))))
              (should (equal (car responses) "\x1b[<0;1;1M"))
              (should (equal tracked (list term 1 nil)))))
        (kill-buffer buf)))))

(ert-deftest spectreshell-key-test-mouse-down-falls-back-to-mouse-set-point ()
  "マウストラッキング無効時は mouse-set-point にフォールバックし、ドラッグ追跡はしない。"
  (spectreshell-test--with-terminal (term 5 10 responses)
    (let ((buf (generate-new-buffer "spectreshell-key-test-mouse"))
          (tracked nil)
          (fell-back nil))
      (unwind-protect
          (save-window-excursion
            (switch-to-buffer buf)
            (setq spectreshell--current term)
            (cl-letf (((symbol-function 'spectreshell--track-mouse-drag)
                       (lambda (obj button mods) (setq tracked (list obj button mods))))
                      ((symbol-function 'mouse-set-point)
                       (lambda (_event) (setq fell-back t))))
              (spectreshell-mouse-down
               (list 'down-mouse-1 (spectreshell-key-test--posn (selected-window)
                                                                  (spectreshell-marker term))))
              (should (null responses))
              (should (null tracked))
              (should fell-back)))
        (kill-buffer buf)))))

(ert-deftest spectreshell-key-test-mouse-wheel-sends-single-press ()
  "wheel-up はボタン64 (wheel_up) の press 1回として送信される。"
  (spectreshell-test--with-terminal (term 5 10 responses)
    (spectreshell-feed term "\x1b[?1000h\x1b[?1006h")
    (let ((buf (generate-new-buffer "spectreshell-key-test-mouse")))
      (unwind-protect
          (save-window-excursion
            (switch-to-buffer buf)
            (setq spectreshell--current term)
            (spectreshell-mouse-wheel
             (list 'wheel-up (spectreshell-key-test--posn (selected-window)
                                                            (spectreshell-marker term))))
            (should (equal (car responses) "\x1b[<64;1;1M")))
        (kill-buffer buf)))))

(ert-deftest spectreshell-key-test-mouse-wheel-falls-back-to-mwheel-scroll ()
  "マウストラッキング無効時の wheel イベントは mwheel-scroll にフォールバックする。"
  (spectreshell-test--with-terminal (term 5 10 responses)
    (let ((buf (generate-new-buffer "spectreshell-key-test-mouse"))
          (scrolled nil))
      (unwind-protect
          (save-window-excursion
            (switch-to-buffer buf)
            (setq spectreshell--current term)
            (cl-letf (((symbol-function 'mwheel-scroll)
                       (lambda (_event _arg) (setq scrolled t))))
              (spectreshell-mouse-wheel
               (list 'wheel-up (spectreshell-key-test--posn (selected-window)
                                                              (spectreshell-marker term))))
              (should (null responses))
              (should scrolled)))
        (kill-buffer buf)))))

(provide 'spectreshell-key-test)
;;; spectreshell-key-test.el ends here
