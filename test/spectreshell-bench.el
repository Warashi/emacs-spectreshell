;;; spectreshell-bench.el --- 描画パスの計測 -*- lexical-binding: t; -*-

;; git-delta のような「1行に多数の色区間が乗る」出力を pager でスクロール
;; したときの体感速度を数値で追うための計測。ERT ではなく `just bench' から
;; 手で回す。ホストを他の作業と共有していても比較できるよう、各条件を
;; 複数回試行してその最小値を採る (平均だと他プロセスの負荷を拾う)。

(require 'spectreshell-test-helper)
(require 'spectreshell)

(defvar spectreshell-bench-rows 50)
(defvar spectreshell-bench-cols 200)
(defvar spectreshell-bench-trials 5
  "1条件あたりの試行回数。表示するのはこのうちの最小値。")

(defun spectreshell-bench--screen (n spans)
  "カーソル移動で全行を塗り替える1画面分のバイト列を返す。
N は画面ごとに内容をずらす種、SPANS は1行あたりの色区間数。"
  (let ((width (/ spectreshell-bench-cols spans)))
    (mapconcat
     (lambda (row)
       (concat
        (format "\e[%d;1H" (1+ row))
        (mapconcat
         (lambda (i)
           (format "\e[38;5;%dm\e[48;5;%dm%s"
                   (+ 16 (mod (+ row i n) 200))
                   (mod (+ row i n) 8)
                   (make-string width (+ ?a (mod (+ row i n) 26)))))
         (number-sequence 0 (1- spans)) "")))
     (number-sequence 0 (1- spectreshell-bench-rows)) "")))

(defmacro spectreshell-bench--min (&rest body)
  "BODY を `spectreshell-bench-trials' 回計り、(実時間 . GC時間) の最小を返す。
最小値の組は「実時間が最小だった試行」のものを返す。"
  `(let (best)
     (dotimes (_ spectreshell-bench-trials)
       (let ((r (benchmark-run (progn ,@body))))
         (when (or (null best) (< (nth 0 r) (car best)))
           (setq best (cons (nth 0 r) (nth 2 r))))))
     best))

(defun spectreshell-bench--report (label frames elapsed)
  (message "%-28s %6.1f ms/frame  (GC %4.1f ms/frame)"
           label
           (* 1000.0 (/ (car elapsed) frames))
           (* 1000.0 (/ (cdr elapsed) frames))))

(defun spectreshell-bench-full-redraw (spans)
  "1行 SPANS 区間の全画面再描画を計測する。
alternate screen 内で計測するのは、pager (less/delta) 経由の
スクロールがこの経路を通るため。"
  (let ((screens (mapcar (lambda (n) (spectreshell-bench--screen n spans))
                         (number-sequence 0 4))))
    (with-temp-buffer
      (let ((obj (spectreshell-start (current-buffer)
                                     spectreshell-bench-rows
                                     spectreshell-bench-cols
                                     (lambda (_bytes)))))
        (spectreshell-feed obj "\e[?1049h")
        (spectreshell-bench--report
         (format "%d spans/row: 全体" spans)
         (length screens)
         (spectreshell-bench--min
          (dolist (s screens) (spectreshell-feed obj s))))
        (spectreshell-bench--report
         (format "%d spans/row: モジュールのみ" spans)
         (length screens)
         (spectreshell-bench--min
          (dolist (s screens)
            (spectreshell--feed (spectreshell-term obj) s))))))))

(defun spectreshell-bench-run ()
  "全ベンチを実行する。"
  (message "%dx%d, 試行 %d 回の最小値"
           spectreshell-bench-rows spectreshell-bench-cols
           spectreshell-bench-trials)
  (dolist (spans '(1 10 40))
    (spectreshell-bench-full-redraw spans)))

(provide 'spectreshell-bench)
;;; spectreshell-bench.el ends here
