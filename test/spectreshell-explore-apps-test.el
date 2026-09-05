;;; spectreshell-explore-apps-test.el --- 探索的テスト (apps) の Probe -*- lexical-binding: t; -*-

;; 2026-09-05 の探索的テスト (worker 5 / 方向名 apps) で実アプリを動かして
;; 見つけた欠陥のうち、batch Emacs でも再現できるものを固定したファイル。
;; 起票時は `:expected-result :failed' の Probe だったが、L-24 の修正で
;; 通常の期待に反転済み (回帰テストとして残す)。
;; 観察の記録は docs/issues.org の該当項目を参照 (2026-09-05 の探索的テスト)。

(require 'ert)
(require 'spectreshell-test-helper)
(require 'spectreshell)

;; ---------------------------------------------------------------------
;; M-<大文字> の束縛が SS3 (ESC O x) の decode を横取りする
;; ---------------------------------------------------------------------

(defun spectreshell-explore-apps-test--read-with-semi-char-map (bytes)
  "BYTES を semi-char モードのキーマップ下で `read-key-sequence' に読ませる。
`input-decode-map' には SS3 の矢印だけを入れておく (tty フレームの
Emacs が持っているのと同じ変換)。"
  (let ((decode (make-sparse-keymap)))
    (define-key decode "\eOA" [up])
    (define-key decode "\eOB" [down])
    (define-key decode "\eOC" [right])
    (define-key decode "\eOD" [left])
    (let ((input-decode-map decode)
          (overriding-terminal-local-map spectreshell-semi-char-mode-map)
          (unread-command-events (listify-key-sequence bytes)))
      (read-key-sequence-vector nil))))

(ert-deftest spectreshell-explore-apps-test-ss3-arrow-survives-meta-letter-binding ()
  "SS3 の矢印 (ESC O D) が M-O の束縛に食われて `left' へ decode されない。
tty の Emacs は smkx を出すので矢印は ESC O D で届くが、
`spectreshell-semi-char-mode-map' が M-O を束縛しているため
Emacs は ESC O の時点で完全な束縛を見つけてしまい、
`input-decode-map' の変換に到達しない。結果として子プロセスへは
ESC の落ちた \"OD\" が素の文字として届く。"
  (should (equal (spectreshell-explore-apps-test--read-with-semi-char-map "\eOD")
                 [left])))

(ert-deftest spectreshell-explore-apps-test-ss3-arrows-all-survive ()
  "上下左右の SS3 すべてが同じ理由で壊れる (M-A / M-B / M-C / M-D)。"
  (dolist (pair '(("\eOA" . [up]) ("\eOB" . [down])
                  ("\eOC" . [right]) ("\eOD" . [left])))
    (should (equal (spectreshell-explore-apps-test--read-with-semi-char-map (car pair))
                   (cdr pair)))))

(provide 'spectreshell-explore-apps-test)
;;; spectreshell-explore-apps-test.el ends here
