;;; spectreshell-key-test.el --- ERT tests for spectreshell.el key input -*- lexical-binding: t; -*-

;; Phase 4 (キー入力) の完了条件である「モード切替とキー送信の ERT が
;; 通る」を満たすテスト。イベント正規化 (`spectreshell--event-to-key')・
;; semi-char/emacs モードの切り替えとキーマップ・実際のキーイベント
;; 経由での送信を検証する。

(require 'ert)

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

(provide 'spectreshell-key-test)
;;; spectreshell-key-test.el ends here
