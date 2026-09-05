;;; spectreshell-explore-geometry-test.el --- 探索的テスト (geometry) の Probe -*- lexical-binding: t; -*-

;; 2026-09-05 の探索的テスト (worker 6 / 方向名 geometry) で見つけた
;; 「ghostty-vt のセル幅と Emacs の表示幅 (char-width) が食い違う」ケースと、
;; 0 桁ウィンドウでの端末生成の失敗を、batch Emacs で固定したファイル。
;; いずれも現状では失敗するので `:expected-result :failed' を付けてある。
;; 観察の記録は docs/issues.org の該当項目を参照 (2026-09-05 の探索的テスト)。

(require 'ert)
(require 'spectreshell-test-helper)
(require 'spectreshell)

(defun spectreshell-explore-geometry-test--marker-column (bytes)
  "BYTES を 1 行の端末へ流し、CSI 20 G で置いた X の Emacs 上の列を返す。
BYTES は「測りたい文字列」の生バイト列。ghostty-vt は X を必ずセル 19 に
置くので、Emacs の表示幅がセル幅と一致していれば戻り値は 19 になる。"
  (with-temp-buffer
    (let ((obj (spectreshell-start (current-buffer) 3 79 (lambda (_)) nil)))
      (spectreshell-feed obj (concat bytes "\e[20GX"))
      (goto-char (point-min))
      (search-forward "X")
      (backward-char 1)
      (current-column))))

(ert-deftest spectreshell-explore-geometry-test-regional-indicator-width ()
  "国旗 (regional indicator) の幅が ghostty 2 セル / Emacs 1 桁でずれる。
ghostty-vt は U+1F1E6..U+1F1FF を wide (2 セル) として扱うが、Emacs の
`char-width' は 1 を返す。`spectreshell--row-col-pos' はセル列を
`move-to-column' で解決するので、この行のカーソル対応がずれる。"
  :expected-result :failed
  ;; 🇯 単独 (RI 1 つ) で 1 桁、🇯🇵 (RI 2 つ) で 2 桁ずれる。
  (should (equal 19 (spectreshell-explore-geometry-test--marker-column
                     (encode-coding-string "\N{U+1F1EF}" 'utf-8))))
  (should (equal 19 (spectreshell-explore-geometry-test--marker-column
                     (encode-coding-string "\N{U+1F1EF}\N{U+1F1F5}" 'utf-8)))))

(ert-deftest spectreshell-explore-geometry-test-del-is-not-stored ()
  "DEL (0x7F) がセルに格納され、Emacs では `^?' の 2 桁で表示される。
実端末 (xterm 等) は DEL を無視する。"
  :expected-result :failed
  (should (equal 19 (spectreshell-explore-geometry-test--marker-column "\x7f"))))

(ert-deftest spectreshell-explore-geometry-test-c1-control-width ()
  "C1 制御 (U+0085 / U+009B) がセルに格納され、Emacs では 4 桁で表示される。"
  :expected-result :failed
  (should (equal 19 (spectreshell-explore-geometry-test--marker-column
                     (encode-coding-string "\N{U+0085}" 'utf-8))))
  (should (equal 19 (spectreshell-explore-geometry-test--marker-column
                     (encode-coding-string "\N{U+009B}" 'utf-8)))))

(ert-deftest spectreshell-explore-geometry-test-zero-column-terminal ()
  "0 桁 / 0 行の端末生成が `args-out-of-range' を投げる。
`window-max-chars-per-line' は本文 1 桁のウィンドウで 0 を返すので、
`spectreshell-eshell--window-size-change' がこの経路で signal し、
redisplay 側で `Error muted by safe_call' になって端末サイズが取り残される。"
  :expected-result :failed
  (with-temp-buffer
    (should (spectreshell-start (current-buffer) 3 0 (lambda (_)) nil)))
  (with-temp-buffer
    (should (spectreshell-start (current-buffer) 0 3 (lambda (_)) nil))))

(provide 'spectreshell-explore-geometry-test)
;;; spectreshell-explore-geometry-test.el ends here
