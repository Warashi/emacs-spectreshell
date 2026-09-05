;;; spectreshell-explore-recheck-test.el --- 探索的テスト (recheck) の Probe -*- lexical-binding: t; -*-

;; 実端末の再確認 (2026-09-05 の探索的テスト) で見つかった症状を
;; batch で固定したもの。P-1 の修正で point の強制移動そのものは消えたが、
;; 端末領域の中に point を置いて画面をさかのぼっている間に出力が届くと、
;; スクロールアウト行の確定化が領域の先頭へテキストを挿入するため point が
;; そのぶん前へ押し出され、見ている場所が保てない。

(require 'ert)
(require 'spectreshell)

(defmacro spectreshell-explore-recheck-test--with-terminal (spec &rest body)
  "SPEC = (OBJ ROWS COLS)。一時バッファに端末を作って BODY を実行する。
`test/spectreshell-test.el' の同名ヘルパを borrow せず自前で持つのは、
この Probe ファイルを単体で -l できるようにするため。"
  (declare (indent 1))
  `(with-temp-buffer
     (let ((,(nth 0 spec) (spectreshell-start (current-buffer) ,(nth 1 spec)
                                              ,(nth 2 spec) #'ignore)))
       ,@body)))

(ert-deftest spectreshell-explore-recheck-test-point-inside-region-survives-scroll ()
  "領域の途中に置いた point は、行がスクロールアウトしても同じ行を指し続ける。
実端末では C-c C-e のあと M-v を 1 回打つと point が端末領域の途中
(領域の終端から 1 画面ぶん手前) に着地し、以後は出力が届くたびに
point が前へ滑って指す行が変わる。`point-max' との差が一定のまま
変わらないのが症状で、スクロールバックを見続けられない。"
  :expected-result :failed
  (spectreshell-explore-recheck-test--with-terminal (term 5 10)
    (spectreshell-feed term "l1\r\nl2\r\nl3\r\nl4\r\nl5")
    ;; 領域の 3 行目 ("l3") へ point を置く。カーソル位置ではないので
    ;; P-1 の修正どおりなら追従の対象外のはず。
    (goto-char (spectreshell-marker term))
    (forward-line 2)
    (should (string-prefix-p "l3" (buffer-substring-no-properties
                                   (point) (line-end-position))))
    ;; 3 行ぶんスクロールアウトさせる。確定化は領域の先頭へ挿入するので
    ;; 領域内の point はそのぶん前へ押し出される。
    (spectreshell-feed term "\r\nl6\r\nl7\r\nl8")
    (should (string-prefix-p "l3" (buffer-substring-no-properties
                                   (point) (line-end-position))))))

(provide 'spectreshell-explore-recheck-test)
;;; spectreshell-explore-recheck-test.el ends here
