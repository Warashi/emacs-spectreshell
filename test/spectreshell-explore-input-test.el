;;; spectreshell-explore-input-test.el --- 探索的テスト (input) の Probe -*- lexical-binding: t; -*-

;; 2026-09-05 の探索的テスト (worker 2 / 方向名 input) で実端末上に見つけた
;; 入力経路の欠陥のうち、batch Emacs でも再現できるものを固定したファイル。
;; いずれも現状では失敗するので `:expected-result :failed' を付けてある。
;; 直したときに unexpected pass で気付ける。
;; 観察の記録は docs/issues.org の該当項目を参照 (2026-09-05 の探索的テスト)。

(require 'ert)
(require 'eshell)
(require 'spectreshell-test-helper)
(require 'spectreshell)
(require 'spectreshell-test)
(require 'spectreshell-eshell)

;; ---------------------------------------------------------------------
;; キーマップの穴
;; ---------------------------------------------------------------------

(ert-deftest spectreshell-explore-input-test-insertchar-deletechar-are-bound ()
  "端末の Insert/Delete は `insertchar'/`deletechar' として届くので束縛が要る。
tmux+terminfo 環境の `input-decode-map' は ESC [ 2 ~ / ESC [ 3 ~ を
`insert'/`delete' ではなく `insertchar'/`deletechar' に変換する。"
  :expected-result :failed
  (should (eq (lookup-key spectreshell-semi-char-mode-map [insertchar])
              #'spectreshell-send-key))
  (should (eq (lookup-key spectreshell-semi-char-mode-map [deletechar])
              #'spectreshell-send-key)))

(ert-deftest spectreshell-explore-input-test-non-letter-control-keys-are-bound ()
  "C-@ / C-\\ / C-] / C-^ / C-_ も PTY へ送られるべきだが束縛が無い。"
  :expected-result :failed
  (dolist (key '("C-@" "C-\\" "C-]" "C-^" "C-_"))
    (should (eq (lookup-key spectreshell-semi-char-mode-map (kbd key))
                #'spectreshell-send-key))))

(ert-deftest spectreshell-explore-input-test-meta-del-is-bound ()
  "M-DEL (readline の backward-kill-word) が束縛されていない。"
  :expected-result :failed
  (should (eq (lookup-key spectreshell-semi-char-mode-map (kbd "M-DEL"))
              #'spectreshell-send-key)))

(ert-deftest spectreshell-explore-input-test-xterm-paste-is-bound ()
  "端末側 bracketed paste は `xterm-paste' イベントで来るので束縛が要る。
束縛が無いとグローバルの `xterm-paste' がバッファへ直接挿入してしまい、
プロセスには何も届かない。"
  :expected-result :failed
  (should (lookup-key spectreshell-semi-char-mode-map [xterm-paste])))

;; ---------------------------------------------------------------------
;; ESC プレフィックス経由で meta が落ちる
;; ---------------------------------------------------------------------

(ert-deftest spectreshell-explore-input-test-esc-prefixed-meta-letter-keeps-esc ()
  "tty の M-a は ESC + a の 2 イベントで届き、meta が落ちて \"a\" だけが送られる。
`last-command-event' はキー列 [27 97] の最後の要素 97 なので、
`spectreshell-send-key' からは alt 修飾が見えない。"
  :expected-result :failed
  (spectreshell-test--with-terminal (term 5 10 responses)
    (let ((buf (generate-new-buffer "spectreshell-explore-input-test")))
      (unwind-protect
          (save-window-excursion
            (switch-to-buffer buf)
            (spectreshell-semi-char-mode 1)
            (setq spectreshell--current term)
            (execute-kbd-macro (kbd "ESC a"))
            (should (equal (car responses) "\ea")))
        (kill-buffer buf)))))

;; ---------------------------------------------------------------------
;; eshell の minor mode が semi-char モードの束縛を隠す
;; ---------------------------------------------------------------------

(ert-deftest spectreshell-explore-input-test-eshell-minor-modes-do-not-shadow ()
  "eshell-cmpl-mode / eshell-hist-mode が TAB・BTab・矢印を横取りする。
`minor-mode-map-alist' 上で eshell 側の minor mode が
`spectreshell-semi-char-mode' より前にあるため。"
  (let ((buf (generate-new-buffer "*spectreshell-explore-eshell*")))
    (unwind-protect
        (with-current-buffer buf
          (eshell-mode)
          (spectreshell-semi-char-mode 1)
          (dolist (key '("TAB" "<backtab>" "<up>" "<down>"))
            (should (eq (key-binding (kbd key)) #'spectreshell-send-key))))
      (let ((kill-buffer-query-functions nil))
        (kill-buffer buf)))))

(provide 'spectreshell-explore-input-test)
;;; spectreshell-explore-input-test.el ends here
