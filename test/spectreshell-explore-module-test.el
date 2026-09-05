;;; spectreshell-explore-module-test.el --- 探索的テスト (module) の Probe -*- lexical-binding: t; -*-

;; 2026-09-05 の探索的テスト (worker 8 / 方向名 module) で、実端末でしか
;; 再現していなかった確定テキストの破壊を「モジュール + spectreshell.el
;; だけ」(eshell も redisplay も介さない) の batch で再現したもの。
;; 起票時は `:expected-result :failed' の Probe だったが、M-14 / M-15 / P-7
;; の修正で通常の期待に反転済み (回帰テストとして残す)。
;; 観察の記録は docs/issues.org の該当項目を参照 (2026-09-05 の探索的テスト)。

(require 'ert)
(require 'cl-lib)
(require 'spectreshell-test-helper)
(require 'spectreshell)

(defun spectreshell-explore-module-test--lines (n)
  "1..N を CRLF で区切った unibyte 文字列。
実 pty は ONLCR で LF を CRLF に変換するので、端末へ流すバイト列も
CRLF でなければ 2 行目以降が桁 0 に戻らない。"
  (string-to-unibyte
   (mapconcat (lambda (i) (format "%d\r\n" i)) (number-sequence 1 n) "")))

(defun spectreshell-explore-module-test--numbers (str)
  "STR のうち、行末の空白を除くと整数だけになる行の値のリスト。"
  (let (res)
    (dolist (line (split-string str "\n"))
      (let ((trimmed (replace-regexp-in-string " +\\'" "" line)))
        (when (string-match-p "\\`[0-9]+\\'" trimmed)
          (push (string-to-number trimmed) res))))
    (nreverse res)))

(defun spectreshell-explore-module-test--feed-with-resizes (obj data chunk resizes)
  "DATA を CHUNK バイトずつ OBJ へ流し、RESIZES の位置でリサイズする。
RESIZES は ((バイト位置 . (ROWS COLS)) ...) で、位置ちょうどでチャンクを
切ってから `spectreshell-resize' を呼ぶ。"
  (let ((off 0) (len (length data)) (pending resizes))
    (while (< off len)
      (let ((end (min len (+ off chunk))))
        (when (and pending (< off (caar pending)) (< (caar pending) end))
          (setq end (caar pending)))
        (while (and pending (<= (caar pending) off))
          (let ((r (pop pending)))
            (spectreshell-resize obj (nth 0 (cdr r)) (nth 1 (cdr r)))))
        (spectreshell-feed obj (substring data off end))
        (setq off end)))))

(defun spectreshell-explore-module-test--confirmed (obj)
  "OBJ の確定テキスト (端末領域より前) を返す。"
  (buffer-substring-no-properties
   (point-min) (marker-position (spectreshell-marker obj))))

(ert-deftest spectreshell-explore-module-test-height-grow-drops-lines ()
  "幅が同じまま端末の高さを戻すと、確定テキストから連番が抜ける。
実端末の F-concurrency-4 / F-concurrency-19 を eshell も redisplay も
介さずに再現したもの。縮小だけ・リサイズ無し・戻すときに幅も変える場合は
どれも欠落しないことは findings-module.org の表にある。"
  (with-temp-buffer
    (let ((obj (spectreshell-start (current-buffer) 21 80 (lambda (_)) nil)))
      (spectreshell-explore-module-test--feed-with-resizes
       obj (spectreshell-explore-module-test--lines 25000) 4096
       ;; 16207 行目付近で 21 -> 9 行、20303 行目付近で 9 -> 21 行へ戻す。
       (list (cons 102400 (list 9 80)) (cons 131072 (list 21 80))))
      (let ((nums (spectreshell-explore-module-test--numbers
                   (spectreshell-explore-module-test--confirmed obj))))
        ;; 20877..20879 の 3 行が確定テキストから消える。
        (should (equal nums (number-sequence (car nums) (car (last nums)))))))))

(ert-deftest spectreshell-explore-module-test-large-feed-drops-leading-lines ()
  "1 回の `spectreshell-feed' が長すぎると先頭の行が黙って落ちる。
80 桁の端末では 1 回の feed が約 1180 行を超えたところで、先頭の 576 行
\(ghostty のページ 1 枚分) がまるごと `:scrolled-off' に現れないまま消える。
`read-process-output-max' は Emacs 31.1 では 65536 なので、速い子プロセス
なら 1 回のフィルタ呼び出しでこの量に届く。"
  (with-temp-buffer
    (let ((obj (spectreshell-start (current-buffer) 21 80 (lambda (_)) nil)))
      (spectreshell-feed obj (spectreshell-explore-module-test--lines 1200))
      (let ((nums (spectreshell-explore-module-test--numbers
                   (spectreshell-explore-module-test--confirmed obj))))
        ;; 実際には 577 から始まる (1..576 が消える)。
        (should (equal 1 (car nums)))))))

(ert-deftest spectreshell-explore-module-test-width-change-joins-lines ()
  "出力中に幅を変えると、確定テキストで改行が失われ次の行が連結される。
実端末の F-concurrency-12 を eshell も redisplay も介さずに再現したもの。
折り返した行が旧幅ぶんの空白で埋められたうえ、次の出力行が同じバッファ行に
続いてしまう。"
  (let* ((body (mapconcat #'number-to-string (number-sequence 1 40) " "))
         (data (string-to-unibyte
                (mapconcat (lambda (i) (format "L%03d %s\r\n" i body))
                           (number-sequence 1 200) ""))))
    (with-temp-buffer
      (let ((obj (spectreshell-start (current-buffer) 21 100 (lambda (_)) nil)))
        (spectreshell-explore-module-test--feed-with-resizes
         obj data 331
         (list (cons 2000 (list 21 60)) (cons 4000 (list 21 120))
               (cons 6000 (list 21 80)) (cons 8000 (list 21 60))
               (cons 10000 (list 21 120)) (cons 12000 (list 21 80))))
        ;; L ラベルは必ず行頭にしか現れないはず。
        (let (joined)
          (dolist (line (split-string
                         (spectreshell-explore-module-test--confirmed obj) "\n"))
            (when (string-match "\\(.\\)L[0-9][0-9][0-9]" line)
              (push line joined)))
          (should (equal nil (nreverse joined))))))))

(ert-deftest spectreshell-explore-module-test-trailing-blank-lines-are-kept ()
  "出力の末尾の空行は `spectreshell-finalize' でも残る。
実端末の F-lifecycle-8 と同じことを、eshell 統合 (spectreshell-eshell.el)
を通さず `spectreshell-start' / `spectreshell-feed' / `spectreshell-finalize'
だけで確かめる。`spectreshell--trim-frozen-region' が畳むのは
カーソルが通り過ぎていない行だけで、空行を出したぶんは残る。"
  (cl-flet ((frozen (bytes)
              (with-temp-buffer
                (let ((obj (spectreshell-start (current-buffer) 21 80
                                               (lambda (_)) nil)))
                  (spectreshell-feed obj bytes)
                  (spectreshell-finalize obj)
                  (buffer-substring-no-properties (point-min) (point-max))))))
    ;; 素の eshell はどちらも空行をそのまま残す。
    (should (equal "\n" (frozen "\r\n")))
    (should (equal "\n\n\n" (frozen "\r\n\r\n\r\n")))
    (should (equal "x\n\n\n" (frozen "x\r\n\r\n\r\n")))))

(provide 'spectreshell-explore-module-test)
;;; spectreshell-explore-module-test.el ends here
