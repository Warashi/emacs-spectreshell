;;; spectreshell-explore-lifecycle-test.el --- 探索的テスト (lifecycle) の Probe -*- lexical-binding: t; -*-

;; 2026-09-05 の探索的テスト (worker 3 / 方向名 lifecycle) で実端末上に見つけた
;; 「プロセス終了後に状態が元へ戻らない」欠陥のうち、batch Emacs でも再現できる
;; ものを固定したファイル。いずれも現状では失敗するので
;; `:expected-result :failed' を付けてある。直したときに unexpected pass で気付ける。
;; 観察の記録は docs/issues.org の該当項目を参照 (2026-09-05 の探索的テスト)。

(require 'ert)
(require 'eshell)
(require 'spectreshell-test-helper)
(require 'spectreshell)
(require 'spectreshell-eshell)
;; `--with-eshell' / `--send' / `--wait-for-command' をそのまま使うので、
;; 統合テスト側のヘルパを読み込んでおく。
(require 'spectreshell-eshell-test)

;; ---------------------------------------------------------------------
;; コマンド終了後に spectreshell-mode が残る (F-lifecycle-1)
;; ---------------------------------------------------------------------

(ert-deftest spectreshell-explore-lifecycle-test-mode-is-off-after-command ()
  "外部コマンドが終わったら `spectreshell-mode' も切れているべき。
`spectreshell-eshell--detach' は `spectreshell-semi-char-mode' しか
落とさないので、semi-char を有効にした副作用で on になった
`spectreshell-mode' が残り続ける。その結果、端末が無いプロンプト上でも
`spectreshell-mode-map' の C-c C-j が生きており、押すと端末の無い
semi-char モードに入って打鍵が黙って捨てられる。"
  :expected-result :failed
  (spectreshell-eshell-test--with-eshell buf
    (spectreshell-eshell-test--send buf "printf 'hi\\n'")
    (should (spectreshell-eshell-test--wait-for-command buf))
    (with-current-buffer buf
      (should-not spectreshell-semi-char-mode)
      (should-not spectreshell--current)
      (should-not spectreshell-mode)
      (should-not (memq spectreshell-mode-map (current-active-maps))))))

;; ---------------------------------------------------------------------
;; 出力末尾の空行が消える (F-lifecycle-8)
;; ---------------------------------------------------------------------

(ert-deftest spectreshell-explore-lifecycle-test-trailing-blank-lines-are-kept ()
  "コマンドが最後に出した空行はバッファに残るべき。
素の eshell では `printf \\n\\n\\n' が空行 3 行として残るが、
spectreshell 経由だと端末領域の末尾の空行が畳まれて 1 行も残らない。
途中の空行 (a\\n\\n\\nb) は残るので、失われるのは末尾だけ。"
  :expected-result :failed
  (spectreshell-eshell-test--with-eshell buf
    (spectreshell-eshell-test--send buf "printf 'MARK\\n\\n\\n\\n'")
    (should (spectreshell-eshell-test--wait-for-command buf))
    (with-current-buffer buf
      (save-excursion
        (goto-char (point-min))
        (should (search-forward "MARK\n" nil t))
        ;; MARK の直後に空行が 3 行続く。
        (should (looking-at-p "\n\n\n"))))))

(provide 'spectreshell-explore-lifecycle-test)
;;; spectreshell-explore-lifecycle-test.el ends here
