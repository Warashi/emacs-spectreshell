;;; spectreshell-test.el --- ERT tests for spectreshell.el -*- lexical-binding: t; -*-

;; Phase 3 (spectreshell.el 描画エンジン) の完了条件である「ERT で SGR
;; 色・進捗表示 (\r)・確定化・alt screen の描画テストが通る」を満たす
;; テスト。libspectreshell.so を module-load したうえで、一時バッファに
;; `spectreshell-start' + `spectreshell-feed' した結果のバッファ内容・
;; text property を検証する。

(require 'ert)
(require 'button)
(require 'spectreshell-test-helper)
(require 'spectreshell)

(defmacro spectreshell-test--with-terminal (spec &rest body)
  "Bind OBJ from SPEC in a fresh temp buffer, then run BODY.
SPEC is (OBJ ROWS COLS &optional SEND-FN-VAR), mirroring `spectreshell-start'
except that OBJ is bound to the returned object and, when SEND-FN-VAR is
given, that symbol is bound to a list accumulating every response
`spectreshell-feed'/`spectreshell-resize' report via the send-fn (most
recent last)."
  (declare (indent 1))
  (let ((obj (nth 0 spec))
        (rows (nth 1 spec))
        (cols (nth 2 spec))
        ;; Always collect responses under a real (if caller-unrequested,
        ;; gensym'd) variable rather than special-casing a quoted #'ignore
        ;; splice, which needs care to avoid inserting an *evaluated*
        ;; function value (a bare symbol) where a *form* is expected.
        (responses-var (or (nth 3 spec) (gensym "spectreshell-test-responses"))))
    `(with-temp-buffer
       (let* ((,responses-var nil)
              (,obj (spectreshell-start
                     (current-buffer) ,rows ,cols
                     (lambda (bytes) (push bytes ,responses-var)))))
         ,@body))))

(ert-deftest spectreshell-test-feed-writes-plain-text-to-buffer ()
  "feed した平文はそのまま端末領域のバッファテキストになる。"
  (spectreshell-test--with-terminal (term 1 10)
    (spectreshell-feed term "hello")
    (should (string-prefix-p "hello" (buffer-string)))))

(ert-deftest spectreshell-test-sgr-color-sets-foreground-face ()
  "\"\\e[31mred\\e[0m\" で塗った区間に spectreshell-color-1 相当の foreground が付く。"
  (spectreshell-test--with-terminal (term 1 10)
    (spectreshell-feed term "\x1b[31mred\x1b[0m")
    (should (member '(:foreground "red3") (get-text-property (point-min) 'face)))
    ;; SGR リセット後の "0m" 以降は既定 face (span なし) に戻る。
    (should (null (get-text-property (+ (point-min) 3) 'face)))))

(ert-deftest spectreshell-test-sgr-invisible-hides-text ()
  "\"\\e[8mhidden\" は前景が背景と同じ色になって読めなくなる。
Emacs の `invisible\' text property はレイアウトごと文字を潰して
セル位置がずれるので使わず、色を揃えることで隠す。"
  (spectreshell-test--with-terminal (term 1 10)
    (spectreshell-feed term "\x1b[8mhi")
    (let ((face (get-text-property (point-min) 'face)))
      (should (member (list :foreground (face-background 'default nil t))
                      face)))))

(ert-deftest spectreshell-test-sgr-invisible-uses-explicit-background ()
  "背景色が指定されていれば、隠す前景色はその背景色に揃う。"
  (spectreshell-test--with-terminal (term 1 10)
    (spectreshell-feed term "\x1b[41;8mhi")
    (let ((face (get-text-property (point-min) 'face)))
      (should (member '(:foreground "red3" :background "red3") face)))))

(ert-deftest spectreshell-test-cursor-lands-after-regional-indicator ()
  "単独の regional indicator の後ろのカーソルが、桁ではなく文字の位置で解決される。
ghostty は単独の regional indicator を 2 セルと数えるが Emacs の
`char-width' は 1 なので、セル列を `move-to-column' で解くと
1 桁ぶん後ろの文字に着く。"
  (spectreshell-test--with-terminal (term 1 10)
    (spectreshell-feed term (encode-coding-string
                             "\N{U+1F1EF}ab\e[3G" 'utf-8))
    (should (equal ?a (char-after (spectreshell-cursor-pos term))))))

(ert-deftest spectreshell-test-split-escape-sequence-across-feeds ()
  "feed 境界で分割された SGR シーケンスと UTF-8 文字も正しく描画される。
PTY の read はエスケープシーケンスや多バイト文字を任意の位置で切る。"
  (spectreshell-test--with-terminal (term 1 10)
    (spectreshell-feed term "\x1b[3")
    (spectreshell-feed term "1m")
    ;; "あ" (E3 81 82) を unibyte のまま1バイト目とそれ以降に分割する。
    (spectreshell-feed term "\343")
    (spectreshell-feed term "\201\202")
    (should (string-prefix-p "あ" (buffer-string)))
    (should (member '(:foreground "red3") (get-text-property (point-min) 'face)))))

(ert-deftest spectreshell-test-synchronized-frame-is-drawn-once-closed ()
  "mode 2026 で囲んだフレームが feed 境界で割れても、閉じるまでは直前の
画面が残り、閉じた feed で新しい画面にまとめて置き換わる。"
  (spectreshell-test--with-terminal (term 2 10)
    (spectreshell-feed term "old 1\r\nold 2")
    (spectreshell-feed term "\x1b[?2026h\x1b[2K\x1b[1F\x1b[2Knew 1")
    (should (string-prefix-p "old 1     \nold 2" (buffer-string)))
    (spectreshell-feed term "\r\nnew 2\x1b[?2026l")
    (should (string-prefix-p "new 1     \nnew 2" (buffer-string)))))

(ert-deftest spectreshell-test-synchronized-feed-still-sends-responses ()
  "描画を保留している間も、端末への問い合わせには応答する。"
  (spectreshell-test--with-terminal (term 1 10 responses)
    (spectreshell-feed term "\x1b[?2026h\x1b[6n")
    (should (equal responses '("\x1b[1;1R")))))

(ert-deftest spectreshell-test-synchronized-output-times-out ()
  "mode 2026 を閉じないまま出力が止まっても、タイムアウト後には描く。"
  (spectreshell-test--with-terminal (term 1 10)
    (spectreshell-feed term "\x1b[?2026hab")
    (should-not (string-prefix-p "ab" (buffer-string)))
    (let ((timer (spectreshell-sync-timer term)))
      (should (timerp timer))
      (timer-event-handler timer))
    (should (string-prefix-p "ab" (buffer-string)))))

(ert-deftest spectreshell-test-synchronized-timeout-is-not-extended-by-feeds ()
  "保留が続く feed が来続けても、タイムアウトは最初の保留から数える。
フレームの継ぎ目が毎回 feed の途中に来ると、閉じた feed が来ない。"
  (spectreshell-test--with-terminal (term 1 10)
    (spectreshell-feed term "\x1b[?2026ha")
    (let ((timer (spectreshell-sync-timer term)))
      (spectreshell-feed term "\x1b[?2026l\x1b[?2026hb")
      (should (eq timer (spectreshell-sync-timer term)))
      (timer-event-handler timer))
    (should (string-prefix-p "ab" (buffer-string)))))

(ert-deftest spectreshell-test-finalize-draws-pending-frame ()
  "保留中に確定化すると、保留していた描画を反映してから確定する。"
  (spectreshell-test--with-terminal (term 1 10)
    (spectreshell-feed term "\x1b[?2026hab")
    (spectreshell-finalize term)
    (should (equal "ab\n" (buffer-string)))))

(ert-deftest spectreshell-test-carriage-return-overwrites-line ()
  "\\r による上書きは同じ行の内容を新しい内容で置き換える。"
  (spectreshell-test--with-terminal (term 1 20)
    (spectreshell-feed term "progress: 1\rprogress: 2")
    (should (string-prefix-p "progress: 2" (buffer-string)))
    (should-not (string-match-p "progress: 1" (buffer-string)))))

(ert-deftest spectreshell-test-scrolled-off-lines-become-permanent-scrollback ()
  "rows を超える出力で流れ出た行が端末領域より前に確定化され
(行幅までのパディングは落とした上で)、端末領域自体は rows 行のまま
保たれる。"
  (spectreshell-test--with-terminal (term 3 5)
    (spectreshell-feed term "1\r\n2\r\n3\r\n4\r\n")
    (should (string-prefix-p "1\n2\n" (buffer-string)))
    (should (= 3 (spectreshell--row-count term)))
    (should (string-prefix-p "3    \n4    \n     "
                             (buffer-substring (spectreshell-marker term) (point-max))))))

(ert-deftest spectreshell-test-scrolled-off-row-with-grapheme-drops-padding ()
  "書記素を含む行も、確定化するときは行末の空白が落ちる。"
  (spectreshell-test--with-terminal (term 1 6)
    (spectreshell-feed term (encode-coding-string
                             "\N{U+1F1EF}\N{U+1F1F5}\r\nx" 'utf-8))
    (should (string-prefix-p "\N{U+1F1EF}\N{U+1F1F5}\n" (buffer-string)))))

(ert-deftest spectreshell-test-confirmed-rows-drop-cells ()
  "確定した行 (流れ出た行と finalize した領域) には `spectreshell-cells' が残らない。
セル情報は端末領域の中のマウスの座標にしか使わず、残すと yank で持ち出される。"
  (spectreshell-test--with-terminal (term 1 6)
    (spectreshell-feed term (encode-coding-string
                             "\N{U+1F1EF}\N{U+1F1F5}\r\n\N{U+6F22}" 'utf-8))
    (should (get-text-property (spectreshell-marker term) 'spectreshell-cells))
    (spectreshell-finalize term)
    (should-not (text-property-not-all (point-min) (point-max)
                                       'spectreshell-cells nil))))

(ert-deftest spectreshell-test-ascii-rewrite-drops-cells ()
  "書記素のある行を ASCII だけで書き直すと、`spectreshell-cells' が消える。"
  (spectreshell-test--with-terminal (term 1 6)
    (spectreshell-feed term (encode-coding-string "\N{U+1F1EF}\N{U+1F1F5}" 'utf-8))
    (should (get-text-property (spectreshell-marker term) 'spectreshell-cells))
    (spectreshell-feed term "\rabcdef")
    (should-not (text-property-not-all (spectreshell-marker term) (point-max)
                                       'spectreshell-cells nil))))

(ert-deftest spectreshell-test-scrolled-off-row-keeps-colors ()
  "確定化した行にも SGR の色が残る。"
  (spectreshell-test--with-terminal (term 1 5)
    (spectreshell-feed term "\x1b[31mr\x1b[0m\r\nx")
    (should (string-prefix-p "r\n" (buffer-string)))
    (should (member '(:foreground "red3") (get-text-property (point-min) 'face)))))

(ert-deftest spectreshell-test-alt-screen-restores-primary-content-on-exit ()
  "alternate screen へ出入りすると、元の主画面の内容が復元される。"
  (spectreshell-test--with-terminal (term 5 10)
    (spectreshell-feed term "hello")
    (let ((primary (buffer-substring (spectreshell-marker term) (point-max))))
      (spectreshell-feed term "\x1b[?1049h")
      (spectreshell-feed term "world")
      (should (string-prefix-p "     world" (buffer-string)))
      (spectreshell-feed term "\x1b[?1049l")
      (should (equal primary (buffer-substring (spectreshell-marker term) (point-max)))))))

(ert-deftest spectreshell-test-cursor-follows-point ()
  "feed 後、point が :cursor の (ROW . COL) に対応するバッファ位置へ移動する。"
  (spectreshell-test--with-terminal (term 5 10)
    (spectreshell-feed term "ab\r\ncd")
    ;; 2行目 ("cd") の2文字目まで書いた直後なのでカーソルは row 1 col 2。
    (should (= (point) (spectreshell--row-col-pos term 1 2)))))

(ert-deftest spectreshell-test-semi-char-mode-always-follows-cursor ()
  "semi-char モード中は point がどこにあっても新カーソル位置へ追従する。
キー入力は端末へ直送されるので、point は常にカーソルに居るべき。"
  (spectreshell-test--with-terminal (term 5 10)
    (spectreshell-semi-char-mode 1)
    (setq spectreshell--current term)
    (spectreshell-feed term "ab\r\ncd")
    (goto-char (point-min))
    (spectreshell-feed term "ef")
    (should (= (point) (spectreshell--row-col-pos term 1 4)))))

(ert-deftest spectreshell-test-emacs-mode-follows-cursor-when-point-is-there ()
  "emacs モードでも、point がカーソル位置にあるうちは追従する。"
  (spectreshell-test--with-terminal (term 5 10)
    (spectreshell-feed term "ab\r\ncd")
    (spectreshell-feed term "ef")
    (should (= (point) (spectreshell--row-col-pos term 1 4)))))

(ert-deftest spectreshell-test-emacs-mode-keeps-point-in-scrollback ()
  "emacs モードで point を確定済みスクロールバックへ動かしていたら、
スクロールを伴う出力があっても point は動かない。
毎 update で引き戻されるとスクロールバックの閲覧・コピーができない。"
  (spectreshell-test--with-terminal (term 2 10)
    (spectreshell-feed term "l1\r\nl2\r\nl3\r\n")
    ;; "l1" は端末領域から流れ出て marker より前の確定テキストになっている。
    (should (< (point-min) (spectreshell-marker term)))
    (goto-char (1+ (point-min)))
    (spectreshell-feed term "l4\r\nl5")
    (should (= (point) (1+ (point-min))))))

(ert-deftest spectreshell-test-point-in-region-keeps-its-row-on-scroll ()
  "端末領域の中の point は、行がスクロールしても同じ内容の行を指し続ける。
確定化は領域の先頭へ挿入するので、バッファ位置のままだと point の
上に新しい内容が流れ込み、見ている場所が更新のたびに入れ替わる。"
  (spectreshell-test--with-terminal (term 5 10)
    (spectreshell-feed term "l1\r\nl2\r\nl3\r\nl4\r\nl5")
    (goto-char (spectreshell--row-col-pos term 3 0))
    ;; 2 行スクロールさせる。point の行 ("l4") はまだ領域の中に残る。
    (spectreshell-feed term "\r\nl6\r\nl7")
    (should (>= (point) (spectreshell-marker term)))
    (should (string-prefix-p "l4" (buffer-substring-no-properties
                                   (point) (line-end-position))))))

(ert-deftest spectreshell-test-window-point-follows-cursor-per-window ()
  "追従判定はウィンドウごとに行う。
カーソル位置にあるウィンドウだけが追従し、履歴を表示している
ウィンドウの window-point は据え置かれる。"
  (spectreshell-test--with-terminal (term 5 10)
    (spectreshell-feed term "ab\r\ncd")
    (let* ((buffer (current-buffer))
           (window (selected-window))
           (other (split-window window)))
      (unwind-protect
          (progn
            (set-window-buffer window buffer)
            (set-window-buffer other buffer)
            (set-window-point other (1+ (spectreshell-marker term)))
            (goto-char (spectreshell--row-col-pos term 1 2))
            (spectreshell-feed term "ef")
            (should (= (window-point window) (spectreshell--row-col-pos term 1 4)))
            (should (= (window-point other) (1+ (spectreshell-marker term)))))
        (delete-window other)))))

(defmacro spectreshell-test--with-displayed-buffer (window &rest body)
  "選択ウィンドウへ出した一時バッファをカレントにして BODY を実行する。
WINDOW にはそのウィンドウを束縛する。`with-temp-buffer' のバッファは
どのウィンドウにも出ていないので、window-start を見るテストは
こちらを使う。"
  (declare (indent 1))
  `(let ((buffer (generate-new-buffer " *spectreshell-test-window*")))
     (unwind-protect
         (let ((,window (selected-window)))
           (set-window-buffer ,window buffer)
           (with-current-buffer buffer ,@body))
       (kill-buffer buffer))))

(ert-deftest spectreshell-test-window-view-in-region-keeps-its-row-on-scroll ()
  "領域の中を映しているウィンドウは、スクロールしても同じ行を映し続ける。
window-start も point と同じく確定化の挿入で押し出されるので、
写像で追わないと見ている画面が出力のたびに前へ滑る。"
  (spectreshell-test--with-displayed-buffer window
    (let ((term (spectreshell-start buffer 5 10 #'ignore)))
      (spectreshell-feed term "l1\r\nl2\r\nl3\r\nl4\r\nl5")
      ;; 領域の 2 行目 ("l2") を窓の先頭にして読んでいる状態。
      (set-window-start window (spectreshell--row-col-pos term 1 0))
      (set-window-point window (spectreshell--row-col-pos term 1 0))
      ;; 3 行スクロールさせる。"l2" は確定テキストへ出る。
      (spectreshell-feed term "\r\nl6\r\nl7\r\nl8")
      (should (string-prefix-p
               "l2" (buffer-substring-no-properties
                     (window-start window)
                     (save-excursion (goto-char (window-start window))
                                     (line-end-position)))))
      (should (= (window-point window) (window-start window))))))

(ert-deftest spectreshell-test-full-screen-region-is-aligned-to-window-start ()
  "alt screen に入った端末は、領域の先頭が窓の先頭に来る。
全画面 TUI (nvim 等) はカーソルを上端に置くことがあり、Emacs は
point が見える最小しかスクロールしないので、そのままだと領域の
下側が画面の外に落ちる。"
  (spectreshell-test--with-displayed-buffer window
    (insert (make-string 10 ?\n))
    (let ((term (spectreshell-start buffer (window-body-height window) 10 #'ignore)))
      (spectreshell-semi-char-mode 1)
      (setq spectreshell--current term)
      ;; alt screen に入って上端にカーソルを置く全画面アプリ相当。
      (spectreshell-feed term "\x1b[?1049htop\x1b[H")
      (should (= (window-start window) (marker-position (spectreshell-marker term)))))))

(ert-deftest spectreshell-test-plain-output-does-not-align-window-start ()
  "alt screen に入らないコマンドの出力は、窓の先頭を動かさない。
フォアグラウンドの端末の行数は常にウィンドウ本文と同じなので、
高さだけで整列すると ls のような普通のコマンドでもスクロールバックと
プロンプトが画面外へ追い出される (M-19)。"
  (spectreshell-test--with-displayed-buffer window
    (insert (make-string 10 ?\n))
    (let ((term (spectreshell-start buffer (window-body-height window) 10 #'ignore)))
      (spectreshell-semi-char-mode 1)
      (setq spectreshell--current term)
      (set-window-start window (point-min))
      (spectreshell-feed term "top\x1b[H")
      (should (= (window-start window) (point-min))))))

(ert-deftest spectreshell-test-leaving-alt-screen-stops-aligning ()
  "alt screen を出た後の出力は、窓の先頭を動かさない。
全画面アプリが終わって普通の出力へ戻ったら整列も止まらないと、
M-19 が alt screen を出た端末で再発する。"
  (spectreshell-test--with-displayed-buffer window
    (insert (make-string 10 ?\n))
    (let ((term (spectreshell-start buffer (window-body-height window) 10 #'ignore)))
      (spectreshell-semi-char-mode 1)
      (setq spectreshell--current term)
      (spectreshell-feed term "\x1b[?1049htop")
      (spectreshell-feed term "\x1b[?1049l")
      (set-window-start window (point-min))
      (spectreshell-feed term "done\x1b[H")
      (should (= (window-start window) (point-min))))))

(ert-deftest spectreshell-test-scrollback-view-keeps-window-start ()
  "emacs モードでスクロールバックを見ている間は window-start を動かさない。
全画面の整列がここまで効くと、閲覧中の画面が出力のたびに端末領域へ
引き戻されて実質スクロールバックを読めない (P-1)。"
  (spectreshell-test--with-displayed-buffer window
    (insert (make-string 10 ?\n))
    (let ((term (spectreshell-start buffer (window-body-height window) 10 #'ignore)))
      (spectreshell-feed term "top")
      (set-window-start window (point-min))
      (spectreshell-feed term "\r\nmore")
      (should (= (window-start window) (point-min))))))

(ert-deftest spectreshell-test-feed-does-not-record-undo ()
  "undo が有効なバッファでも feed の再描画は undo エントリを積まない。
積んでしまうと大量出力で undo リストが際限なく肥大化し、ジョブ終了後
の undo が確定済みスクロールバックまで巻き戻してしまう。"
  (spectreshell-test--with-terminal (term 3 5)
    (buffer-enable-undo)
    (spectreshell-feed term "hello")
    (spectreshell-feed term "\r\nworld")
    (should (null buffer-undo-list))))

(ert-deftest spectreshell-test-feed-is-immune-to-narrowing ()
  "ユーザーがバッファをナローイング中でも feed は端末領域を壊さない。
更新パスは point-max を端末領域終端として使うため、widen せずに動くと
狭められた point-max を誤認して行数計算や余剰行削除が誤動作する。"
  (spectreshell-test--with-terminal (term 3 5)
    (spectreshell-feed term "abc")
    (narrow-to-region (point-min) (1+ (point-min)))
    (spectreshell-feed term "\r\nxyz")
    (widen)
    (should (= 3 (spectreshell--row-count term)))
    (should (string-match-p "xyz" (buffer-string)))))

(ert-deftest spectreshell-test-cursor-position-with-wide-chars ()
  ":cursor の COL はセル列なので、全角文字の行では文字数と一致しない。
「あいう」はセル列 6 だが文字数は 3 であり、point は「う」の直後
(marker + 3 文字) に来るべき。"
  (spectreshell-test--with-terminal (term 1 10)
    (spectreshell-feed term "あいう")
    (should (= (point) (+ (spectreshell-marker term) 3)))))

(ert-deftest spectreshell-test-resize-changes-visible-row-count ()
  "resize で端末領域の行数が新しい rows に追従する (伸縮どちらも)。"
  (spectreshell-test--with-terminal (term 3 5)
    (spectreshell-feed term "hi")
    (spectreshell-resize term 5 5)
    (should (= 5 (spectreshell--row-count term)))
    (spectreshell-resize term 2 5)
    (should (= 2 (spectreshell--row-count term)))))

(ert-deftest spectreshell-test-resize-rejects-non-positive-size ()
  "0 行 / 0 桁への resize は、寸法を名指ししたエラーになる。
生成時と同じ検査を通る (モジュール由来の `args-out-of-range' は数字しか
出さないので `:exclude-subtypes' でそれと区別する)。端末オブジェクトの
rows / cols も更新されないままであるべき。"
  (spectreshell-test--with-terminal (term 3 5)
    (should-error (spectreshell-resize term 3 0) :type 'error :exclude-subtypes t)
    (should-error (spectreshell-resize term 0 5) :type 'error :exclude-subtypes t)
    (should-error (spectreshell-resize term -1 5) :type 'error :exclude-subtypes t)
    (should (= 3 (spectreshell-rows term)))
    (should (= 5 (spectreshell-cols term)))
    ;; 検査を足したあとも通常の resize は通る。
    (spectreshell-resize term 4 6)
    (should (= 4 (spectreshell-rows term)))
    (should (= 6 (spectreshell-cols term)))))

(ert-deftest spectreshell-test-responses-are-sent-via-send-fn ()
  "ESC[6n の応答バイト列が SEND-FN に渡る。"
  (spectreshell-test--with-terminal (term 5 10 responses)
    (spectreshell-feed term "Hi\x1b[6n")
    (should (equal responses '("\x1b[1;3R")))))

(ert-deftest spectreshell-test-decrqm-response-is-sent-via-send-fn ()
  "DECRQM (ESC[?25$p) の応答バイト列が SEND-FN に渡る。"
  (spectreshell-test--with-terminal (term 5 10 responses)
    (spectreshell-feed term "\x1b[?25$p")
    (should (equal responses '("\x1b[?25;1$y")))))

(ert-deftest spectreshell-test-kitty-keyboard-query-is-sent-via-send-fn ()
  "kitty keyboard query (ESC[?u) の応答バイト列が SEND-FN に渡る。"
  (spectreshell-test--with-terminal (term 5 10 responses)
    (spectreshell-feed term "\x1b[?u")
    (should (equal responses '("\x1b[?0u")))))

(ert-deftest spectreshell-test-xtgettcap-response-is-sent-via-send-fn ()
  "XTGETTCAP (ESC P + q 436F ESC \\) の応答バイト列が SEND-FN に渡る。"
  (spectreshell-test--with-terminal (term 5 10 responses)
    ;; 436F = "Co" (色数)、応答値の 323536 = "256"。
    (spectreshell-feed term "\x1bP+q436F\x1b\\")
    (should (equal responses '("\x1bP1+r436F=323536\x1b\\")))))

(ert-deftest spectreshell-test-osc8-hyperlink-becomes-clickable-button ()
  "OSC 8 のリンク区間が text-property ベースの button になる。"
  (spectreshell-test--with-terminal (term 1 10)
    (spectreshell-feed term "\x1b]8;;https://example.com\x1b\\link\x1b]8;;\x1b\\")
    (let ((button (button-at (point-min))))
      (should button)
      (should (equal (button-get button 'spectreshell-hyperlink-uri) "https://example.com")))))

(ert-deftest spectreshell-test-unchanged-row-is-not-rewritten ()
  "内容が変わらない dirty 行はバッファを書き換えない (他モードのプロパティが残る)。"
  (spectreshell-test--with-terminal (term 1 10)
    (spectreshell-feed term "hi")
    (let ((inhibit-read-only t))
      (put-text-property (point-min) (+ (point-min) 2) 'spectreshell-test-mark t))
    ;; 同じ内容を書き直す (行は dirty になるが描画結果は変わらない)。
    (should (plist-get (spectreshell-feed term "\x1b[Hhi") :dirty))
    (should (get-text-property (point-min) 'spectreshell-test-mark))))

(ert-deftest spectreshell-test-styles-reset-redraws-recycled-ids ()
  "スタイル ID の振り直し後は、同じ span でも新しいスタイルで描き直される。"
  (spectreshell-test--with-terminal (term 1 10)
    (spectreshell-feed term "\x1b[31mhi")
    (should (member (list :foreground (face-foreground 'spectreshell-color-1 nil 'default))
                    (get-text-property (point-min) 'face)))
    ;; 振り直しでは ID 0 が別のスタイルを指し得る。span の中身は同じまま
    ;; なので、行キャッシュも一緒に捨てないと古い色が残る。
    (spectreshell--apply-update
     term '(:styles-reset t :styles ((0 . (:fg 2))) :cursor (0 . 0)
            :dirty ((0 "hi        " ((0 2 0)) nil))))
    (should (member (list :foreground (face-foreground 'spectreshell-color-2 nil 'default))
                    (get-text-property (point-min) 'face)))))

(ert-deftest spectreshell-test-alt-screen-redraws-identical-content ()
  "alt screen へ入った直後は、同じ内容でも改めて描き直される。"
  (spectreshell-test--with-terminal (term 2 10)
    (spectreshell-feed term "hi")
    (spectreshell-feed term "\x1b[?1049h")
    (spectreshell-feed term "\x1b[Hhi")
    (should (string-prefix-p "hi" (buffer-substring-no-properties
                                   (point-min) (line-end-position))))))

(ert-deftest spectreshell-test-face-cache-follows-theme-change ()
  "テーマ変更後に描かれた行は、キャッシュされた古い色ではなく新しい色になる。"
  (let ((original (face-foreground 'spectreshell-color-1 nil t)))
    (unwind-protect
        (spectreshell-test--with-terminal (term 1 10)
          (set-face-foreground 'spectreshell-color-1 "#111111")
          (spectreshell-feed term "\x1b[31mHi")
          (should (member '(:foreground "#111111")
                          (get-text-property (point-min) 'face)))
          (set-face-foreground 'spectreshell-color-1 "#222222")
          (spectreshell--invalidate-faces)
          (spectreshell-feed term "\x1b[31mHo")
          (should (member '(:foreground "#222222")
                          (get-text-property (point-min) 'face))))
      (set-face-foreground 'spectreshell-color-1 original))))

(defun spectreshell-test--display-spec (display name)
  "DISPLAY (単独の仕様、または仕様のリスト) から NAME の仕様を返す。無ければ nil。"
  (cond ((null display) nil)
        ((symbolp (car display)) (and (eq (car display) name) display))
        (t (assq name display))))

(defun spectreshell-test--display-height (display)
  "DISPLAY の `height' 倍率を返す。無ければ nil。"
  (cadr (spectreshell-test--display-spec display 'height)))

(defun spectreshell-test--display-min-width (display)
  "DISPLAY の `min-width' のピクセル幅を返す。無ければ nil。"
  (car (car (cadr (spectreshell-test--display-spec display 'min-width)))))

(defmacro spectreshell-test--with-glyph-widths (widths &rest body)
  "セル幅 10px の GUI フレームで、文字のピクセル幅を WIDTHS として BODY を評価する。
WIDTHS は (CHAR . FN) の alist で、FN は `display' の height 倍率を受けて
描いた幅を返す。WIDTHS に無い文字は `char-width' × 10px。"
  (declare (indent 1))
  `(let ((spectreshell--glyph-fit-cache (make-hash-table :test 'equal)))
     (cl-letf (((symbol-function 'frame-char-width) (lambda (&rest _) 10))
               ((symbol-function 'spectreshell--graphic-p) (lambda () t))
               ((symbol-function 'spectreshell--pixel-width)
                (lambda (string)
                  (let* ((ch (aref string 0))
                         (height (or (spectreshell-test--display-height
                                      (get-text-property 0 'display string))
                                     1.0))
                         (fn (alist-get ch ,widths)))
                    (if fn (funcall fn height) (* 10 (char-width ch)))))))
       ,@body)))

(defun spectreshell-test--display-at (char)
  "CHAR の最初の出現位置に付いた `display' を返す。"
  (save-excursion
    (goto-char (point-min))
    (search-forward (string char))
    (get-text-property (1- (point)) 'display)))

(defun spectreshell-test--drawn-width (char)
  "CHAR の最初の出現位置に付いた `display' を反映した、描画後の幅を返す。
`min-width' の余白は実機の `string-pixel-width' に数えられないので、ここで足す。"
  (save-excursion
    (goto-char (point-min))
    (search-forward (string char))
    (max (spectreshell--pixel-width (buffer-substring (1- (point)) (point)))
         (or (spectreshell-test--display-min-width
              (get-text-property (1- (point)) 'display))
             0))))

(ert-deftest spectreshell-test-overwide-glyph-shrinks-to-its-cells ()
  "GUI でグリフが char-width ぶんのセルからはみ出す文字だけが、セルに収まるよう縮む。"
  (spectreshell-test--with-glyph-widths
      `((?⏱ . ,(lambda (h) (floor (* 20 h))))
        (?❌ . ,(lambda (h) (floor (* 22 h)))))
    (spectreshell-test--with-terminal (term 1 20)
      (spectreshell-feed term "a⏱⚠❌")
      (should (= (spectreshell-test--drawn-width ?⏱) 10))
      (should (= (spectreshell-test--drawn-width ?❌) 20))
      (should (< 0.8 (spectreshell-test--display-height
                      (spectreshell-test--display-at ?❌))))
      (dolist (pos (list (point-min) (+ (point-min) 2)))
        (should-not (get-text-property pos 'display)))
      (should (equal (buffer-substring-no-properties (point-min) (+ (point-min) 4))
                     "a⏱⚠❌")))))

(ert-deftest spectreshell-test-overwide-glyph-exact-fit-has-no-padding ()
  "縮めた幅がちょうどセルに収まる文字には、余白の min-width を付けない。"
  (spectreshell-test--with-glyph-widths
      `((?⏱ . ,(lambda (h) (floor (* 20 h)))))
    (spectreshell-test--with-terminal (term 1 10)
      (spectreshell-feed term "⏱")
      (should-not (spectreshell-test--display-min-width
                   (spectreshell-test--display-at ?⏱))))))

(ert-deftest spectreshell-test-overwide-glyph-padded-to-cell-despite-rounding ()
  "縮小後の幅がフォントサイズの丸めで目標に届かない場合、余白で目標の幅にそろえる。
倍率は目標以下で最大にし、グリフを必要以上に小さくしない。"
  (spectreshell-test--with-glyph-widths
      `((?⏱ . ,(lambda (h) (if (< h 0.5) (floor (* 20 h)) 11))))
    (spectreshell-test--with-terminal (term 1 10)
      (spectreshell-feed term "⏱")
      (let ((display (spectreshell-test--display-at ?⏱)))
        (should (= (spectreshell-test--drawn-width ?⏱) 10))
        (should (equal (spectreshell-test--display-min-width display) 10))
        (should (< 0.49 (spectreshell-test--display-height display) 0.5))))))

(ert-deftest spectreshell-test-narrow-glyph-is-padded-not-shrunk ()
  "グリフが char-width ぶんのセルより狭い文字は、縮めずに余白で目標の幅にそろえる。"
  (spectreshell-test--with-glyph-widths
      `((?漢 . ,(lambda (h) (floor (* 16 h)))))
    (spectreshell-test--with-terminal (term 1 10)
      (spectreshell-feed term "漢")
      (let ((display (spectreshell-test--display-at ?漢)))
        (should-not (spectreshell-test--display-height display))
        (should (equal (spectreshell-test--display-min-width display) 20))
        (should (= (spectreshell-test--drawn-width ?漢) 20))))))

(ert-deftest spectreshell-test-padding-is-not-shared-between-characters ()
  "隣り合う文字の min-width は別のリストにする。共有すると 1 つの塊として余白が足される。"
  (spectreshell-test--with-glyph-widths
      `((?漢 . ,(lambda (h) (floor (* 16 h)))))
    (spectreshell-test--with-terminal (term 1 10)
      (spectreshell-feed term "漢漢")
      (should (spectreshell-test--display-min-width
               (get-text-property (point-min) 'display)))
      (should-not (eq (cadr (get-text-property (point-min) 'display))
                      (cadr (get-text-property (1+ (point-min)) 'display)))))))

(ert-deftest spectreshell-test-glyph-fit-targets-module-cells ()
  "幅をそろえる目標は `char-width' ではなく、モジュールが返す書記素のセル数。
単独の regional indicator は `char-width' 1 だが 2 セル。"
  (spectreshell-test--with-glyph-widths
      `((#x1F1EF . ,(lambda (h) (floor (* 11 h)))))
    (spectreshell-test--with-terminal (term 1 10)
      (spectreshell-feed term (encode-coding-string "\N{U+1F1EF}" 'utf-8))
      (let ((display (spectreshell-test--display-at #x1F1EF)))
        (should-not (spectreshell-test--display-height display))
        (should (equal (spectreshell-test--display-min-width display) 20))))))

(ert-deftest spectreshell-test-glyph-fit-cache-separates-cell-counts ()
  "同じ書記素でもセル数が違えば、幅揃えの結果を別に覚える。"
  (spectreshell-test--with-glyph-widths
      `((#x1F1EF . ,(lambda (h) (floor (* 15 h)))))
    (dolist (grapheme (list #x1F1EF "\N{U+1F1EF}\N{U+1F1F5}"))
      (should (car (spectreshell--glyph-fit grapheme 1)))
      (should (equal (spectreshell--glyph-fit grapheme 2) '(nil . 20)))
      (should (car (spectreshell--glyph-fit grapheme 1))))))

(ert-deftest spectreshell-test-grapheme-shares-one-display ()
  "書記素の全文字が 1 つの display 値を共有し、隣の書記素とは共有しない。
共有した範囲は 1 つの塊として幅をそろえられ、合成も保たれる。"
  (spectreshell-test--with-glyph-widths
      `((#x1F1EF . ,(lambda (h) (floor (* 21 h)))))
    (spectreshell-test--with-terminal (term 1 10)
      (spectreshell-feed term (encode-coding-string
                               "\N{U+1F1EF}\N{U+1F1F5}\N{U+1F1EF}\N{U+1F1F5}x"
                               'utf-8))
      (let ((first (get-text-property (point-min) 'display))
            (second (get-text-property (+ (point-min) 2) 'display)))
        (should (spectreshell-test--display-height first))
        (should (eq first (get-text-property (1+ (point-min)) 'display)))
        (should (eq second (get-text-property (+ (point-min) 3) 'display)))
        (should-not (eq first second))
        (should-not (get-text-property (+ (point-min) 4) 'display))))))

(ert-deftest spectreshell-test-overwide-glyph-skips-zero-width ()
  "char-width 0 の文字は、描いた幅が 0 でなくても縮めない。"
  (spectreshell-test--with-glyph-widths
      `((#x301 . ,(lambda (h) (* 5 h))))
    (spectreshell-test--with-terminal (term 1 10)
      (spectreshell-feed term "é")
      (should-not (text-property-not-all (point-min) (line-end-position)
                                         'display nil)))))

(ert-deftest spectreshell-test-overwide-glyph-untouched-without-gui ()
  "GUI でないフレームでは、どの文字にも縮小の display を付けない。"
  (let ((spectreshell--glyph-fit-cache (make-hash-table :test 'equal)))
    (spectreshell-test--with-terminal (term 1 10)
      (spectreshell-feed term "⏱❌")
      (should-not (text-property-not-all (point-min) (line-end-position)
                                         'display nil)))))

(defconst spectreshell-test--wide-graphemes
  '("\N{U+1F468}\N{U+200D}\N{U+1F469}\N{U+200D}\N{U+1F467}"
    "\N{U+1F44D}\N{U+1F3FD}"
    "\N{U+1F3F3}\N{U+FE0F}\N{U+200D}\N{U+1F308}")
  "`string-width' がセル数 (2) を超える書記素: ZWJ 列・肌色修飾・🏳️‍🌈。")

(ert-deftest spectreshell-test-tty-composes-grapheme-wider-than-its-cells ()
  "tty では、`string-width' がセル数を超える書記素を 1 つに合成し、
後ろの文字の表示桁を ghostty-vt のセル列にそろえる。"
  (dolist (grapheme spectreshell-test--wide-graphemes)
    (spectreshell-test--with-terminal (term 1 10)
      (spectreshell-feed term (encode-coding-string (concat "a" grapheme "Z") 'utf-8))
      (goto-char (point-min))
      (should (equal (seq-take (find-composition (1+ (point-min))) 2)
                     (list (1+ (point-min)) (+ (point-min) 1 (length grapheme)))))
      (search-forward "Z")
      (backward-char 1)
      (should (= (current-column) 3)))))

(ert-deftest spectreshell-test-tty-leaves-grapheme-within-its-cells ()
  "tty でも、`string-width' がセル数以下の書記素は合成しない。
国旗は合成すると外側の端末で幅が変わり、単独の regional indicator と
VS16 の絵文字は合成しても広がらない。"
  (dolist (text '("\N{U+1F1EF}\N{U+1F1F5}" "\N{U+1F1EF}" "\N{U+2764}\N{U+FE0F}" "\N{U+6F22}"))
    (spectreshell-test--with-terminal (term 1 10)
      (spectreshell-feed term (encode-coding-string text 'utf-8))
      (should-not (text-property-not-all (point-min) (line-end-position)
                                         'composition nil)))))

(ert-deftest spectreshell-test-gui-does-not-compose-graphemes ()
  "GUI では合成せず、幅揃えだけにする。"
  (spectreshell-test--with-glyph-widths nil
    (spectreshell-test--with-terminal (term 1 10)
      (spectreshell-feed term (encode-coding-string
                               (car spectreshell-test--wide-graphemes) 'utf-8))
      (should-not (text-property-not-all (point-min) (line-end-position)
                                         'composition nil)))))

(ert-deftest spectreshell-test-24bit-color-sets-literal-rgb-foreground ()
  "24bit 色 (\\e[38;2;R;G;Bm) はそのまま \"#rrggbb\" として foreground に載る。"
  (spectreshell-test--with-terminal (term 1 10)
    (spectreshell-feed term "\x1b[38;2;10;20;30mHi")
    (should (member '(:foreground "#0a141e") (get-text-property (point-min) 'face)))))

(ert-deftest spectreshell-test-256-color-resolves-xterm-cube-value ()
  "256色パレット (\\e[38;5;208m) は xterm 色キューブの計算値に変換される。"
  (spectreshell-test--with-terminal (term 1 10)
    (spectreshell-feed term "\x1b[38;5;208mHi")
    (should (member '(:foreground "#ff8700") (get-text-property (point-min) 'face)))))

(ert-deftest spectreshell-test-palette-query-above-15-answers-drawn-color ()
  "OSC 4 の 16〜255 には、描画と同じ `spectreshell--256-color-hex' の色を
8bit の値を 257 倍した 16bit で答える。"
  (let ((term (spectreshell--create 1 10)))
    (dotimes (i 240)
      (let* ((index (+ 16 i))
             (response (plist-get (spectreshell--feed
                                   term (format "\e]4;%d;?\e\\" index))
                                  :responses)))
        (should (string-match "\\`\e]4;\\([0-9]+\\);rgb:\\(..\\)\\(..\\)/\\(..\\)\\(..\\)/\\(..\\)\\(..\\)\e\\\\\\'"
                              response))
        (should (equal (string-to-number (match-string 1 response)) index))
        (should (equal (match-string 2 response) (match-string 3 response)))
        (should (equal (match-string 4 response) (match-string 5 response)))
        (should (equal (match-string 6 response) (match-string 7 response)))
        (should (equal (format "#%s%s%s" (match-string 2 response)
                               (match-string 4 response) (match-string 6 response))
                       (spectreshell--256-color-hex index)))))
    (spectreshell--release term)))

(ert-deftest spectreshell-test-finalize-in-alt-screen-restores-primary ()
  "alt screen 表示中のまま finalize (プロセス異常死相当) しても、
保存済みの主画面が復元され (パディングは落とした上で)、TUI 起動前の
画面内容が失われない。"
  (spectreshell-test--with-terminal (term 5 10)
    (spectreshell-feed term "hello")
    (spectreshell-feed term "\x1b[?1049h")
    (spectreshell-feed term "TUI content")
    (let ((start (marker-position (spectreshell-marker term))))
      (spectreshell-finalize term)
      (should (equal "hello\n" (buffer-substring start (point-max)))))))

(ert-deftest spectreshell-test-finalize-trims-padding ()
  "finalize は行末パディングと出力より下の空白行を取り除いて確定する。
残すと全行に行末空白が付き、バッファが rows x cols で膨らむ。"
  (spectreshell-test--with-terminal (term 3 10)
    (spectreshell-feed term "hi")
    (let ((start (marker-position (spectreshell-marker term))))
      (spectreshell-finalize term)
      (should (equal "hi\n" (buffer-substring start (point-max)))))))

(ert-deftest spectreshell-test-finalize-keeps-styled-trailing-spaces ()
  "背景色付きの行末スペースは端末の実内容なのでトリムされない。"
  (spectreshell-test--with-terminal (term 1 10)
    (spectreshell-feed term "x\x1b[41m  \x1b[0m")
    (let ((start (marker-position (spectreshell-marker term))))
      (spectreshell-finalize term)
      (should (equal "x  \n" (buffer-substring-no-properties start (point-max))))
      (should (get-text-property (1+ start) 'face)))))

(ert-deftest spectreshell-test-title-change-runs-hook-and-updates-slot ()
  "OSC 2 のタイトル変更で spectreshell-title が更新され、
spectreshell-title-functions がバッファをカレントにして呼ばれる。"
  (spectreshell-test--with-terminal (term 1 10)
    (let* ((seen nil)
           (spectreshell-title-functions
            (list (lambda (obj title) (setq seen (list obj title (current-buffer)))))))
      (spectreshell-feed term "\x1b]2;hello title\x07")
      (should (equal (spectreshell-title term) "hello title"))
      (should (equal seen (list term "hello title" (current-buffer)))))))

;; ---------------------------------------------------------------------
;; 外側の端末への中継 (M-23)
;; ---------------------------------------------------------------------

(defmacro spectreshell-test--with-frames (frames sent &rest body)
  "FRAMES のウィンドウがカレントバッファを表示しているとして BODY を実行する.
FRAMES は (WINDOW FRAME TERMINAL KIND) の並びで、KIND は tty / gui /
initial (daemon の初期フレーム)。batch では tty フレームを作れないので、
フレームと端末を引く関数を FRAMES から引くものに差し替える。SENT には
`send-string-to-terminal' に渡った (STRING . TERMINAL) が送った順に溜まる。"
  (declare (indent 2))
  `(let ((frames ,frames)
         (,sent nil))
     (cl-letf (((symbol-function 'get-buffer-window-list)
                (lambda (&rest _) (mapcar #'car frames)))
               ((symbol-function 'window-frame)
                (lambda (w) (nth 1 (assq w frames))))
               ((symbol-function 'window-buffer)
                (let ((buffer (current-buffer))) (lambda (_) buffer)))
               ((symbol-function 'frame-terminal)
                (lambda (f) (nth 2 (seq-find (lambda (e) (eq (nth 1 e) f)) frames))))
               ((symbol-function 'display-graphic-p)
                (lambda (f) (eq (nth 3 (seq-find (lambda (e) (eq (nth 1 e) f)) frames)) 'gui)))
               ((symbol-function 'frame-initial-p)
                (lambda (f) (eq (nth 3 (seq-find (lambda (e) (eq (nth 1 e) f)) frames)) 'initial)))
               ((symbol-function 'send-string-to-terminal)
                (lambda (string terminal)
                  (setq ,sent (append ,sent (list (cons string terminal)))))))
       ,@body)))

(ert-deftest spectreshell-test-relay-sends-once-per-tty-terminal ()
  "中継はバッファを表示している tty フレームの端末へ 1 回ずつ送る。
同じ端末の複数フレームは 1 回にまとめ、GUI フレームと daemon の初期
フレームには送らない。"
  (spectreshell-test--with-terminal (term 1 10)
    (spectreshell-test--with-frames
        '((w1 f1 t1 tty) (w2 f1 t1 tty) (w3 f2 t1 tty)
          (w4 f3 t2 tty) (w5 f4 x gui) (w6 f5 init initial))
        sent
      (spectreshell--relay term "\a")
      (should (equal sent '(("\a" . t1) ("\a" . t2)))))))

(ert-deftest spectreshell-test-relay-drops-without-tty-frame ()
  "表示している tty フレームが無ければ送らず、後から表示しても送らない。"
  (spectreshell-test--with-terminal (term 1 10)
    (spectreshell-test--with-frames '((w1 f1 x gui)) sent
      (spectreshell--relay term "\a")
      (should (null sent))
      (setq frames '((w2 f2 t1 tty)))
      (run-hook-with-args 'window-buffer-change-functions 'w2)
      (should (null sent)))))

(ert-deftest spectreshell-test-relay-predicate-selects-terminals ()
  "PREDICATE が nil を返した端末には送らない。"
  (spectreshell-test--with-terminal (term 1 10)
    (spectreshell-test--with-frames '((w1 f1 t1 tty) (w2 f2 t2 tty)) sent
      (spectreshell--relay term "\a" (lambda (terminal) (eq terminal 't2)))
      (should (equal sent '(("\a" . t2)))))))

(ert-deftest spectreshell-test-relay-keep-resends-when-displayed ()
  "保持した文字列は送ったうえで、バッファが新たに表示されたウィンドウの
端末へ送り直す。同じ KEY で保持し直すと最新のものだけが残り、nil で
保持をやめる。"
  (spectreshell-test--with-terminal (term 1 10)
    (spectreshell-test--with-frames '((w1 f1 t1 tty)) sent
      (spectreshell--relay-keep term 'progress "old")
      (spectreshell--relay-keep term 'progress "new")
      (should (equal sent '(("old" . t1) ("new" . t1))))
      (setq sent nil
            frames '((w1 f1 t1 tty) (w2 f2 t2 tty) (w3 f3 x gui)))
      (run-hook-with-args 'window-buffer-change-functions 'w2)
      (run-hook-with-args 'window-buffer-change-functions 'w3)
      (should (equal sent '(("new" . t2))))
      (setq sent nil)
      (spectreshell--relay-keep term 'progress nil)
      (run-hook-with-args 'window-buffer-change-functions 'w2)
      (should (null sent)))))

(ert-deftest spectreshell-test-relay-keep-sends-later-when-hidden ()
  "表示している tty フレームが無いときに保持したものは、表示されたときに届く。"
  (spectreshell-test--with-terminal (term 1 10)
    (spectreshell-test--with-frames nil sent
      (spectreshell--relay-keep term 'progress "busy")
      (should (null sent))
      (setq frames '((w1 f1 t1 tty)))
      (run-hook-with-args 'window-buffer-change-functions 'w1)
      (should (equal sent '(("busy" . t1)))))))

;; ---------------------------------------------------------------------
;; 外側の端末への中継の差し替え
;; ---------------------------------------------------------------------

(defmacro spectreshell-test--with-relay-terminals (terminals selection sent &rest body)
  "外側の端末を TERMINALS として BODY を実行する.
`spectreshell--relay-terminals' の送り先の判定は M-23 のテストで固定
してあるので、ここでは描画を巻き込まないようにその結果だけを差し替える。
SELECTION の端末だけ xterm.el の `xterm--set-selection' が立っている。
SENT には `send-string-to-terminal' に渡った (STRING . TERMINAL) が
送った順に溜まる。"
  (declare (indent 3))
  `(let ((,sent nil)
         (orig (symbol-function 'terminal-parameter)))
     (cl-letf (((symbol-function 'spectreshell--relay-terminals)
                (lambda (_) ,terminals))
               ((symbol-function 'terminal-parameter)
                (lambda (terminal parameter)
                  (if (eq parameter 'xterm--set-selection)
                      (and (memq terminal ,selection) t)
                    (funcall orig terminal parameter))))
               ((symbol-function 'send-string-to-terminal)
                (lambda (string terminal)
                  (setq ,sent (append ,sent (list (cons string terminal)))))))
       ,@body)))

;; ---------------------------------------------------------------------
;; クリップボード (OSC 52)
;; ---------------------------------------------------------------------

(defvar xterm-max-cut-length)

(defmacro spectreshell-test--with-clipboard (spec &rest body)
  "空の kill-ring と差し替えたクリップボードの口で BODY を実行する.
SPEC は (CUTS ASKS ANSWER)。CUTS には `interprogram-cut-function' に
渡った文字列が渡った順に溜まる。確認の関数は確認のたびに式 ANSWER を
評価して返し、ASKS にはそのときのプロンプトが溜まる。batch では
ミニバッファを使えないので、確認できるかの判定は常に真にする。
要求の処理は timer を待たず `spectreshell-test--clipboard-drain' で進める。"
  (declare (indent 1))
  (pcase-let ((`(,cuts ,asks ,answer) spec))
    `(let ((,cuts nil)
           (,asks nil)
           (kill-ring nil)
           (kill-ring-yank-pointer nil)
           (interprogram-paste-function nil)
           (spectreshell--clipboard-queues nil)
           (spectreshell--clipboard-timer nil)
           (spectreshell--clipboard-running nil)
           (spectreshell--clipboard-ask-timer nil)
           (spectreshell--clipboard-input-seen nil)
           (spectreshell--clipboard-asking nil))
       (let ((interprogram-cut-function
              (lambda (text) (setq ,cuts (append ,cuts (list text)))))
             (spectreshell--clipboard-ask-function
              (lambda (_obj _request prompt)
                (setq ,asks (append ,asks (list prompt)))
                ,answer)))
         (cl-letf (((symbol-function 'spectreshell--clipboard-can-ask-p)
                    (lambda (_) t)))
           (unwind-protect (progn ,@body)
             (cancel-function-timers #'spectreshell--clipboard-run)
             (cancel-function-timers #'spectreshell--clipboard-ask-tick)))))))

(defun spectreshell-test--clipboard-run-timer ()
  "張られた要求の処理の timer を止めて、その関数をすぐに呼ぶ."
  (should spectreshell--clipboard-timer)
  (cancel-timer spectreshell--clipboard-timer)
  (spectreshell--clipboard-run))

(defun spectreshell-test--clipboard-tick ()
  "張られた確認の timer を止めて、その関数をすぐに呼ぶ."
  (should spectreshell--clipboard-ask-timer)
  (cancel-timer spectreshell--clipboard-ask-timer)
  (spectreshell--clipboard-ask-tick))

(defun spectreshell-test--clipboard-drain ()
  "クリップボードの要求を、timer を待たずに処理し尽くす.
張られた timer を止めて、その関数をすぐに呼ぶ。確認の timer では、入力が
止まるのを待たずに確認へ進む。呼んだ先がまた張った timer も同じように
呼び、どちらも張られていなくなるまで繰り返す。"
  (when spectreshell--clipboard-timer
    (cancel-timer spectreshell--clipboard-timer))
  (spectreshell--clipboard-run)
  (let ((rounds 0))
    (while (and (< rounds 1000)
                (or spectreshell--clipboard-timer spectreshell--clipboard-ask-timer))
      (setq rounds (1+ rounds))
      (if spectreshell--clipboard-timer
          (progn (cancel-timer spectreshell--clipboard-timer)
                 (spectreshell--clipboard-run))
        (cancel-timer spectreshell--clipboard-ask-timer)
        (setq spectreshell--clipboard-ask-timer nil)
        (spectreshell--clipboard-ask-next)))))

(ert-deftest spectreshell-test-osc52-write-goes-to-kill-ring-after-feed ()
  "子の OSC 52 の書き込みは feed の後の timer で、UTF-8 として kill-ring に
入る。外側への反映は `interprogram-cut-function' に 1 回だけ任せ、外側の
端末へ直接は送らない。feed の中では kill-ring に触らない。"
  (spectreshell-test--with-terminal (term 1 10)
    (spectreshell-test--with-clipboard (cuts asks 'allow)
      (spectreshell-test--with-relay-terminals '(t1) '(t1) sent
        (let ((spectreshell-clipboard-write 'allow))
          (spectreshell-feed term "\x1b]52;c;44GC\x07")
          (should (null kill-ring))
          (should spectreshell--clipboard-timer)
          (spectreshell-test--clipboard-drain)
          (should (equal kill-ring '("あ")))
          (should (equal cuts '("あ")))
          (should (null asks))
          (should (null sent)))))))

(ert-deftest spectreshell-test-osc52-write-goes-to-kill-ring-while-synchronized ()
  "mode 2026 の中の書き込みも、描画を待たずに kill-ring に入る。"
  (spectreshell-test--with-terminal (term 1 10)
    (spectreshell-test--with-clipboard (cuts _asks 'allow)
      (let ((spectreshell-clipboard-write 'allow))
        (spectreshell-feed term "\x1b[?2026h\x1b]52;c;aGk=\x07")
        (spectreshell-test--clipboard-drain)
        (should (equal kill-ring '("hi")))
        (should (equal cuts '("hi")))))))

(ert-deftest spectreshell-test-osc52-write-to-primary-sets-primary-only ()
  "p と s への書き込みは PRIMARY に入れ、kill-ring には入れない。"
  (spectreshell-test--with-terminal (term 1 10)
    (spectreshell-test--with-clipboard (cuts _asks 'allow)
      (let ((spectreshell-clipboard-write 'allow)
            (selections nil))
        (cl-letf (((symbol-function 'gui-set-selection)
                   (lambda (type data)
                     (setq selections (append selections (list (list type data)))))))
          (spectreshell-feed term "\x1b]52;p;aGk=\x07\x1b]52;s;eW8=\x07")
          (spectreshell-test--clipboard-drain))
        (should (equal selections '((PRIMARY "hi") (PRIMARY "yo"))))
        (should (null kill-ring))
        (should (null cuts))))))

(ert-deftest spectreshell-test-osc52-write-denied-is-dropped-without-asking ()
  "`spectreshell-clipboard-write' が deny なら、確認せずに捨てる。"
  (spectreshell-test--with-terminal (term 1 10)
    (spectreshell-test--with-clipboard (cuts asks 'allow)
      (let ((spectreshell-clipboard-write 'deny))
        (spectreshell-feed term "\x1b]52;c;aGk=\x07")
        (spectreshell-test--clipboard-drain)
        (should (null kill-ring))
        (should (null cuts))
        (should (null asks))))))

(ert-deftest spectreshell-test-osc52-write-ask-yes-and-no ()
  "ask では確認し、許したときだけ kill-ring に入れる。"
  (dolist (answer '(allow deny))
    (spectreshell-test--with-terminal (term 1 10)
      (spectreshell-test--with-clipboard (_cuts asks answer)
        (let ((spectreshell-clipboard-write 'ask))
          (spectreshell-feed term "\x1b]52;c;aGk=\x07")
          (spectreshell-test--clipboard-drain)
          (should (= (length asks) 1))
          (should (equal kill-ring (and (eq answer 'allow) '("hi")))))))))

(ert-deftest spectreshell-test-osc52-write-ask-quit-is-denial ()
  "確認中の C-g は拒否として扱い、quit を外へ漏らさない。timer の中
\(`inhibit-quit' が t) から呼ばれても C-g が効く。"
  (spectreshell-test--with-terminal (term 1 10)
    (spectreshell-test--with-clipboard (_cuts asks (progn (setq quit-flag t)
                                                         (ignore)
                                                         'allow))
      (let ((spectreshell-clipboard-write 'ask))
        (spectreshell-feed term "\x1b]52;c;aGk=\x07")
        (let ((inhibit-quit t))
          (spectreshell-test--clipboard-drain))
        (should (= (length asks) 1))
        (should (null kill-ring))
        (should (null quit-flag))))))

(ert-deftest spectreshell-test-clipboard-requests-are-asked-one-at-a-time ()
  "要求は来た順に処理し、確認中に timer がまた走っても次の確認を重ねない。"
  (spectreshell-test--with-terminal (term 1 10)
    (let ((depths nil))
      (spectreshell-test--with-clipboard (_cuts asks (progn
                                                       (spectreshell--clipboard-run)
                                                       (push (length asks) depths)
                                                       'allow))
        (let ((spectreshell-clipboard-write 'ask))
          (spectreshell-feed term "\x1b]52;c;aGk=\x07\x1b]52;c;eW8=\x07")
          (spectreshell-test--clipboard-drain)
          (should (equal depths '(2 1)))
          (should (equal kill-ring '("yo" "hi"))))))))

(ert-deftest spectreshell-test-clipboard-request-of-finalized-terminal-is-dropped ()
  "処理する前に端末が finalize されていたら、要求を捨てる。"
  (spectreshell-test--with-terminal (term 1 10)
    (spectreshell-test--with-clipboard (cuts _asks 'allow)
      (let ((spectreshell-clipboard-write 'allow))
        (spectreshell-feed term "\x1b]52;c;aGk=\x07")
        (spectreshell-finalize term)
        (spectreshell-test--clipboard-drain)
        (should (null kill-ring))
        (should (null cuts))))))

(ert-deftest spectreshell-test-clipboard-ask-is-denied-when-nobody-can-answer ()
  "確認できない状況では、ask でも確認せずに拒否する。"
  (spectreshell-test--with-terminal (term 1 10)
    (spectreshell-test--with-clipboard (_cuts asks 'allow)
      (let ((spectreshell-clipboard-write 'ask))
        (cl-letf (((symbol-function 'spectreshell--clipboard-can-ask-p)
                   (lambda (_) nil)))
          (spectreshell-feed term "\x1b]52;c;aGk=\x07")
          (spectreshell-test--clipboard-drain))
        (should (null asks))
        (should (null kill-ring))))))

(ert-deftest spectreshell-test-clipboard-can-ask-only-with-a-frame-showing-buffer ()
  "確認できるのは、batch でなく、初期フレーム以外のフレームがバッファを
表示しているときだけ。クライアントのいない daemon には初期フレームしか無い。"
  (with-temp-buffer
    (let ((buffer (current-buffer)))
      (should-not (spectreshell--clipboard-can-ask-p buffer))
      (let ((noninteractive nil)
            (frames nil))
        (cl-letf (((symbol-function 'frame-list) (lambda () (mapcar #'car frames)))
                  ((symbol-function 'frame-initial-p)
                   (lambda (&optional frame) (eq (cdr (assq frame frames)) 'initial)))
                  ((symbol-function 'get-buffer-window)
                   (lambda (_buffer frame) (memq (cdr (assq frame frames)) '(shows initial)))))
          (setq frames '((f0 . initial)))
          (should-not (spectreshell--clipboard-can-ask-p buffer))
          (setq frames '((f0 . initial) (f1 . other)))
          (should-not (spectreshell--clipboard-can-ask-p buffer))
          (setq frames '((f0 . initial) (f1 . other) (f2 . shows)))
          (should (spectreshell--clipboard-can-ask-p buffer)))))))

(ert-deftest spectreshell-test-osc52-write-too-long-for-tty-stays-in-kill-ring ()
  "tty で xterm.el が OSC 52 で書く端末に `xterm-max-cut-length' を超える
書き込みが来たら、外側へは送らず kill-ring にだけ入れて知らせる。xterm.el
の `sit-for' で待たせないため。上限以下なら外側へも送る。"
  (spectreshell-test--with-terminal (term 1 10)
    (spectreshell-test--with-clipboard (cuts _asks 'allow)
      (let ((spectreshell-clipboard-write 'allow)
            (xterm-max-cut-length 7)
            (messages nil)
            (orig (symbol-function 'terminal-parameter)))
        (spectreshell-feed term "\x1b]52;c;aGVsbG8=\x07\x1b]52;c;aGk=\x07")
        (cl-letf (((symbol-function 'display-graphic-p) #'ignore)
                  ((symbol-function 'terminal-parameter)
                   (lambda (terminal parameter)
                     (or (eq parameter 'xterm--set-selection)
                         (funcall orig terminal parameter))))
                  ((symbol-function 'message)
                   (lambda (&rest args) (push (apply #'format args) messages))))
          (spectreshell-test--clipboard-drain))
        (should (equal kill-ring '("hi" "hello")))
        (should (equal cuts '("hi")))
        (should (= (length messages) 1))))))

;; ---------------------------------------------------------------------
;; クリップボードの読み取り (OSC 52)
;; ---------------------------------------------------------------------

(ert-deftest spectreshell-test-osc52-read-answers-kill-ring-after-feed ()
  "子の OSC 52 の読み取りには、feed の後の timer で kill-ring の先頭を
UTF-8 の base64 にして答える。feed の中では答えない。"
  (spectreshell-test--with-terminal (term 1 10 responses)
    (spectreshell-test--with-clipboard (_cuts asks 'allow)
      (let ((spectreshell-clipboard-read 'allow))
        (kill-new "あ")
        (spectreshell-feed term "\x1b]52;c;?\x07")
        (should (null responses))
        (spectreshell-test--clipboard-drain)
        (should (equal responses '("\x1b]52;c;44GC\x07")))
        (should (null asks))))))

(ert-deftest spectreshell-test-osc52-read-uses-current-kill ()
  "読み取りは `current-kill' を通すので、外のクリップボードの新しい中身が
あればそれを kill-ring に取り込んで答える。"
  (spectreshell-test--with-terminal (term 1 10 responses)
    (spectreshell-test--with-clipboard (_cuts _asks 'allow)
      (let ((spectreshell-clipboard-read 'allow)
            (interprogram-paste-function (lambda () "ext")))
        (kill-new "old")
        (spectreshell-feed term "\x1b]52;c;?\x07")
        (spectreshell-test--clipboard-drain)
        (should (equal responses '("\x1b]52;c;ZXh0\x07")))
        (should (equal (car kill-ring) "ext"))))))

(ert-deftest spectreshell-test-osc52-read-of-empty-kill-ring-is-empty ()
  "kill-ring が空なら空で答える。"
  (spectreshell-test--with-terminal (term 1 10 responses)
    (spectreshell-test--with-clipboard (_cuts _asks 'allow)
      (let ((spectreshell-clipboard-read 'allow))
        (spectreshell-feed term "\x1b]52;c;?\x1b\\")
        (spectreshell-test--clipboard-drain)
        (should (equal responses '("\x1b]52;c;\x1b\\")))))))

(ert-deftest spectreshell-test-osc52-read-right-after-write-returns-it ()
  "書いた直後の読み取りには、書いた値で答える。"
  (spectreshell-test--with-terminal (term 1 10 responses)
    (spectreshell-test--with-clipboard (_cuts _asks 'allow)
      (let ((spectreshell-clipboard-read 'allow)
            (spectreshell-clipboard-write 'allow))
        (kill-new "old")
        (spectreshell-feed term "\x1b]52;c;aGk=\x07\x1b]52;c;?\x07")
        (spectreshell-test--clipboard-drain)
        (should (equal responses '("\x1b]52;c;aGk=\x07")))))))

(ert-deftest spectreshell-test-osc52-read-denied-is-answered-empty-without-asking ()
  "`spectreshell-clipboard-read' が deny なら、確認せずに空で答える。"
  (spectreshell-test--with-terminal (term 1 10 responses)
    (spectreshell-test--with-clipboard (_cuts asks 'allow)
      (let ((spectreshell-clipboard-read 'deny))
        (kill-new "secret")
        (spectreshell-feed term "\x1b]52;c;?\x07")
        (spectreshell-test--clipboard-drain)
        (should (equal responses '("\x1b]52;c;\x07")))
        (should (null asks))))))

(ert-deftest spectreshell-test-osc52-read-ask-yes-no-and-quit ()
  "ask では確認し、許したときだけ中身で答える。断ったときと C-g では空で
答え、quit を外へ漏らさない。"
  (pcase-dolist (`(,answer . ,reply) '(('allow . "\x1b]52;c;aGk=\x07")
                                       ('deny . "\x1b]52;c;\x07")
                                       ((progn (setq quit-flag t) (ignore) 'allow)
                                        . "\x1b]52;c;\x07")))
    (spectreshell-test--with-terminal (term 1 10 responses)
      (spectreshell-test--with-clipboard (_cuts asks (eval answer t))
        (let ((spectreshell-clipboard-read 'ask))
          (kill-new "hi")
          (spectreshell-feed term "\x1b]52;c;?\x07")
          (let ((inhibit-quit t))
            (spectreshell-test--clipboard-drain))
          (should (= (length asks) 1))
          (should (equal responses (list reply)))
          (should (null quit-flag)))))))

(ert-deftest spectreshell-test-osc52-read-of-finalized-terminal-is-dropped ()
  "処理する前と確認の間に端末が finalize されたら、答えずに捨てる。"
  (spectreshell-test--with-terminal (term 1 10 responses)
    (spectreshell-test--with-clipboard (_cuts _asks 'allow)
      (let ((spectreshell-clipboard-read 'allow))
        (spectreshell-feed term "\x1b]52;c;?\x07")
        (spectreshell-finalize term)
        (spectreshell-test--clipboard-drain)
        (should (null responses)))))
  (spectreshell-test--with-terminal (term 1 10 responses)
    (spectreshell-test--with-clipboard (_cuts asks (progn (spectreshell-finalize term) 'allow))
      (let ((spectreshell-clipboard-read 'ask))
        (spectreshell-feed term "\x1b]52;c;?\x07")
        (spectreshell-test--clipboard-drain)
        (should (= (length asks) 1))
        (should (null responses))))))

;; ---------------------------------------------------------------------
;; kitty のクリップボード (OSC 5522) と paste イベント (mode 5522)
;; ---------------------------------------------------------------------

(defconst spectreshell-test--kitty-write
  (concat "\e]5522;type=write:name=cHJvZw==:pw=c2VjcmV0\a"
          "\e]5522;type=wdata:mime=dGV4dC9wbGFpbg==;aGk=\a"
          "\e]5522;type=wdata\a")
  "名前 prog とパスワードの付いた、text/plain の hi の書き込み。")

(defconst spectreshell-test--kitty-read
  "\e]5522;type=read:name=cHJvZw==:pw=c2VjcmV0;dGV4dC9wbGFpbg==\a"
  "名前 prog とパスワードの付いた、text/plain の読み取り。")

(ert-deftest spectreshell-test-kitty-write-policy-reaches-module-before-feed ()
  "`spectreshell-clipboard-write' は feed の前にモジュールへ渡り、deny なら
OSC 5522 の書き込みに EPERM で答える。ask と allow は先に DONE で答える。"
  (pcase-dolist (`(,policy . ,status) '((deny . "EPERM") (ask . "DONE") (allow . "DONE")))
    (spectreshell-test--with-terminal (term 1 10 responses)
      (spectreshell-test--with-clipboard (_cuts _asks 'deny)
        (let ((spectreshell-clipboard-write policy))
          (spectreshell-feed term spectreshell-test--kitty-write)
          (should (equal responses
                         (list (format "\e]5522;type=write:status=%s\a" status))))
          (spectreshell-test--clipboard-drain)
          (should (equal kill-ring (and (eq policy 'allow) '("hi")))))))))

(ert-deftest spectreshell-test-kitty-read-answers-kill-ring ()
  "OSC 5522 の読み取りには、kill-ring の先頭で OK・DATA・DONE を答える。"
  (spectreshell-test--with-terminal (term 1 10 responses)
    (spectreshell-test--with-clipboard (_cuts _asks 'allow)
      (let ((spectreshell-clipboard-read 'allow))
        (kill-new "hi")
        (spectreshell-feed term "\e]5522;type=read:id=7;dGV4dC9wbGFpbg==\a")
        (spectreshell-test--clipboard-drain)
        (should (equal responses
                       (list (concat "\e]5522;type=read:status=OK:id=7\a"
                                     "\e]5522;type=read:status=DATA:id=7:mime=dGV4dC9wbGFpbg==;aGk=\a"
                                     "\e]5522;type=read:status=DONE:id=7\a"))))))))

(ert-deftest spectreshell-test-kitty-listing-is-answered-without-asking ()
  "一覧だけの要求には、ask でも確認せずに text/plain を答える。deny なら EPERM。"
  (pcase-dolist (`(,policy . ,reply)
                 `((ask . ,(concat "\e]5522;type=read:status=OK\a"
                                   "\e]5522;type=read:status=DATA:mime=Lg==;dGV4dC9wbGFpbgo=\a"
                                   "\e]5522;type=read:status=DONE\a"))
                   (deny . "\e]5522;type=read:status=EPERM\a")))
    (spectreshell-test--with-terminal (term 1 10 responses)
      (spectreshell-test--with-clipboard (_cuts asks 'deny)
        (let ((spectreshell-clipboard-read policy))
          (spectreshell-feed term "\e]5522;type=read;Lg==\a")
          (spectreshell-test--clipboard-drain)
          (should (null asks))
          (should (equal responses (list reply))))))))

(ert-deftest spectreshell-test-kitty-always-skips-later-asks ()
  "確認で always を選ぶと、同じパスワードの以後の読み取り・書き込みは
確認しない。always は覚えられる要求でだけ選べる。"
  (spectreshell-test--with-terminal (term 1 10 responses)
    (let ((remembers nil))
      (spectreshell-test--with-clipboard (_cuts asks 'always)
        (let ((spectreshell-clipboard-read 'ask)
              (spectreshell-clipboard-write 'ask)
              (spectreshell--clipboard-ask-function
               (lambda (_obj request prompt)
                 (push (plist-get request :remember) remembers)
                 (setq asks (append asks (list prompt)))
                 'always)))
          (kill-new "x")
          (spectreshell-feed term (concat spectreshell-test--kitty-read
                                          spectreshell-test--kitty-write))
          (spectreshell-test--clipboard-drain)
          (should (= (length asks) 2))
          (should (equal remembers '(t t)))
          (setq responses nil)
          (spectreshell-feed term (concat spectreshell-test--kitty-read
                                          spectreshell-test--kitty-write))
          (spectreshell-test--clipboard-drain)
          (should (= (length asks) 2))
          (should (equal (car kill-ring) "hi"))
          ;; 書き込みの DONE は feed の中で、読み取りの答えは後で送る。
          (should (string-match-p "status=DATA:mime=dGV4dC9wbGFpbg==;aGk=" (car responses))))))))

(ert-deftest spectreshell-test-kitty-ask-shows-name-without-control-characters ()
  "確認には子が名乗った名前を、制御文字を除いて出す。"
  (spectreshell-test--with-terminal (term 1 10)
    (spectreshell-test--with-clipboard (_cuts asks 'deny)
      (let ((spectreshell-clipboard-read 'ask))
        ;; 名前は "p\e[31mx\n"。
        (spectreshell-feed term "\e]5522;type=read:name=cBtbMzFteAo=;dGV4dC9wbGFpbg==\a")
        (spectreshell-test--clipboard-drain)
        (should (= (length asks) 1))
        (should (string-search "\"p31mx\"" (car asks)))
        (should-not (string-match-p "[\e\n]" (car asks)))))))

(ert-deftest spectreshell-test-kitty-ask-quotes-a-cleaned-and-shortened-name ()
  "名前からは引用符・双方向の制御文字・制御文字を除き、40 桁までに切って、
括りの壊れない形で出す。名前で確認の文言を偽れないようにするため。"
  (spectreshell-test--with-terminal (term 1 10)
    (spectreshell-test--with-clipboard (_cuts asks 'deny)
      (let* ((spectreshell-clipboard-read 'ask)
             (name (concat "a\"b\u202ec\u2066d\u200f\e[1m" (make-string 60 ?x)))
             (encoded (base64-encode-string (encode-coding-string name 'utf-8) t)))
        (spectreshell-feed
         term (format "\e]5522;type=read:name=%s;dGV4dC9wbGFpbg==\a" encoded))
        (spectreshell-test--clipboard-drain)
        (should (= (length asks) 1))
        (let ((prompt (car asks)))
          (should (string-match "\\`Spectreshell: \\(\"[^\"]*\"\\) in " prompt))
          (let ((shown (read (match-string 1 prompt))))
            (should (string-prefix-p "abcd1mxxx" shown))
            (should (<= (string-width shown) 40)))
          (should-not (string-match-p "[\u200e\u200f\u202a-\u202e\u2066-\u2069\e]" prompt)))))))

;; 名前の無害化は残す文字を決める形なので、ここに無い記号はすべて落ちる。
(ert-deftest spectreshell-test-kitty-ask-keeps-only-plain-name-characters ()
  "名前には英数字 (ほかの文字体系を含む)・空白・-_.:/+@ だけを残し、それ以外の
記号や見えない文字はすべて除く。"
  (spectreshell-test--with-terminal (term 1 10)
    (spectreshell-test--with-clipboard (_cuts asks 'deny)
      (let* ((spectreshell-clipboard-read 'ask)
             (name "vim 9.1-x_y.z:a/b+c@d日本<>!$`'\\;=?\u3000\u200b\u00ad")
             (encoded (base64-encode-string (encode-coding-string name 'utf-8) t)))
        (spectreshell-feed
         term (format "\e]5522;type=read:name=%s;dGV4dC9wbGFpbg==\a" encoded))
        (spectreshell-test--clipboard-drain)
        (should (string-search "\"vim 9.1-x_y.z:a/b+c@d日本\" in " (car asks)))))))

(defmacro spectreshell-test--with-read-string (spec &rest body)
  "`read-string' を差し替えて BODY を実行する.
SPEC は (CALLS INPUT)。`read-string' は変数 INPUT の値を返し、CALLS には
呼ばれるたびに (PROMPT HISTORY-SYMBOL HISTORY-VALUE `use-dialog-box') が
呼ばれた順に溜まる。"
  (declare (indent 1))
  (pcase-let ((`(,calls ,input) spec))
    `(let ((,calls nil)
           (,input nil))
       (cl-letf (((symbol-function 'read-string)
                  (lambda (prompt &optional _initial history &rest _)
                    (setq ,calls (append ,calls
                                         (list (list prompt history
                                                     (and (symbolp history) (boundp history)
                                                          (symbol-value history))
                                                     use-dialog-box))))
                    ,input)))
         ,@body))))

(defun spectreshell-test--clipboard-words (&rest words)
  "WORDS を順に返す、確認の語を作る関数を返す."
  (lambda () (or (pop words) (error "No more words"))))

(ert-deftest spectreshell-test-clipboard-ask-allows-only-the-shown-words ()
  "確認は、表示した今回だけ許可の語と打てば allow、常に許可の語なら always
で、それ以外 (RET だけの空・yes・always・語の一部・前後の空白・もう一方の
語) はすべて deny になる。常に許可の語は覚えられる要求でだけ受ける。"
  (spectreshell-test--with-read-string (_calls input)
    (pcase-dolist (`(,typed ,remember ,expected)
                   '(("kq7m" t allow) ("x3pd" t always)
                     ("kq7m" nil allow) ("x3pd" nil deny)
                     ("" t deny) ("yes" t deny) ("always" t deny) ("y" t deny)
                     ("kq7" t deny) ("x3p" t deny) ("kq7m " t deny) ("KQ7M" t deny)))
      (let ((spectreshell--clipboard-word-function
             (spectreshell-test--clipboard-words "kq7m" "x3pd"))
            (request (and remember '(:remember t))))
        (setq input typed)
        (should (eq (spectreshell--clipboard-ask nil request "Q.") expected))))))

(ert-deftest spectreshell-test-clipboard-ask-shows-fresh-words-each-time ()
  "確認のたびに新しい語を作って、問いの後に表示する。常に許可の語は覚え
られる要求でだけ作って出す。"
  (spectreshell-test--with-read-string (calls input)
    (let ((spectreshell--clipboard-word-function
           (spectreshell-test--clipboard-words "aaaa" "bbbb" "cccc" "dddd" "eeee")))
      (setq input "aaaa")
      (should (eq (spectreshell--clipboard-ask nil '(:remember t) "Q1.") 'allow))
      (setq input "aaaa")
      (should (eq (spectreshell--clipboard-ask nil '(:remember t) "Q2.") 'deny))
      (setq input "eeee")
      (should (eq (spectreshell--clipboard-ask nil nil "Q3.") 'allow)))
    (let ((prompts (mapcar #'car calls)))
      (should (string-prefix-p "Q1." (nth 0 prompts)))
      (should (string-search "aaaa" (nth 0 prompts)))
      (should (string-search "bbbb" (nth 0 prompts)))
      (should (string-search "cccc" (nth 1 prompts)))
      (should (string-search "dddd" (nth 1 prompts)))
      (should-not (string-search "aaaa" (nth 1 prompts)))
      (should (string-search "eeee" (nth 2 prompts)))
      (should-not (string-match-p "[Aa]lways" (nth 2 prompts))))))

(ert-deftest spectreshell-test-clipboard-ask-words-differ ()
  "今回だけ許可の語と常に許可の語は、同じ語が出たら作り直して違う語にする。"
  (spectreshell-test--with-read-string (calls input)
    (let ((spectreshell--clipboard-word-function
           (spectreshell-test--clipboard-words "aaaa" "aaaa" "aaaa" "bbbb")))
      (setq input "aaaa")
      (should (eq (spectreshell--clipboard-ask nil '(:remember t) "Q.") 'allow)))
    (should (string-search "bbbb" (car (car calls))))))

(ert-deftest spectreshell-test-clipboard-ask-reads-without-history-or-dialog ()
  "確認は補完のない `read-string' で読み、空の履歴を使い (M-p で前の答えを
呼べない)、マウスの直後でもダイアログにしない。"
  (spectreshell-test--with-read-string (calls input)
    (let ((spectreshell--clipboard-word-function
           (spectreshell-test--clipboard-words "aaaa" "bbbb"))
          (use-dialog-box t)
          (minibuffer-history '("aaaa")))
      (setq input "")
      (spectreshell--clipboard-ask nil '(:remember t) "Q."))
    (pcase-let ((`((,_prompt ,history ,value ,dialog)) calls))
      (should (symbolp history))
      (should-not (eq history 'minibuffer-history))
      (should (null value))
      (should (null dialog)))))

(ert-deftest spectreshell-test-clipboard-random-word-uses-unambiguous-characters ()
  "確認の語は 4 文字で、紛らわしい 0 o 1 l i を除いた英小文字と数字から作る。"
  (dotimes (_ 200)
    (let ((word (spectreshell--clipboard-random-word)))
      (should (string-match-p "\\`[a-z2-9]\\{4\\}\\'" word))
      (should-not (string-match-p "[0o1li]" word)))))

(ert-deftest spectreshell-test-clipboard-prompt-waits-until-input-stops ()
  "確認の要る要求は、処理しても確認を出さない。定期的に確かめる (idle では
ない) timer で、利用者の入力の数 (`num-nonmacro-input-events') が 0.5 秒
変わらなくなってから出す。打っている途中のキーを答えに取らないため。"
  (spectreshell-test--with-terminal (term 1 10)
    (spectreshell-test--with-clipboard (_cuts asks 'deny)
      (let ((spectreshell-clipboard-read 'ask)
            (num-nonmacro-input-events 10)
            (now 100.0))
        (cl-letf (((symbol-function 'float-time) (lambda (&optional _) now)))
          (spectreshell-feed term "\e]52;c;?\a")
          (spectreshell-test--clipboard-run-timer)
          (should (null asks))
          (let ((timer spectreshell--clipboard-ask-timer))
            (should timer)
            (should-not (timer--idle-delay timer))
            (should (memq timer timer-list)))
          (spectreshell-test--clipboard-tick)
          (setq now 100.4)
          (spectreshell-test--clipboard-tick)
          (should (null asks))
          (setq num-nonmacro-input-events 11 now 100.7)
          (spectreshell-test--clipboard-tick)
          (should (null asks))
          (setq now 101.1)
          (spectreshell-test--clipboard-tick)
          (should (null asks))
          (setq now 101.3)
          (spectreshell-test--clipboard-tick)
          (should (= (length asks) 1)))))))

(ert-deftest spectreshell-test-clipboard-next-prompt-needs-no-further-key ()
  "確認に答えた後の次の確認は、答えの後に入力が 0.5 秒止まれば、次のキーを
待たずに出る (席を離れていても出る)。待っている確認が無くなったら timer
を止める。"
  (spectreshell-test--with-terminal (term 1 10)
    (let ((num-nonmacro-input-events 10)
          (now 100.0))
      (spectreshell-test--with-clipboard (_cuts asks (progn
                                                       ;; 答えを打つと入力の数が増える。
                                                       (setq num-nonmacro-input-events
                                                             (+ num-nonmacro-input-events 5))
                                                       'deny))
        (let ((spectreshell-clipboard-read 'ask))
          (cl-letf (((symbol-function 'float-time) (lambda (&optional _) now)))
            (spectreshell-feed term "\e]52;c;?\a\e]52;c;?\a")
            (spectreshell-test--clipboard-run-timer)
            (spectreshell-test--clipboard-tick)
            (setq now 100.6)
            (spectreshell-test--clipboard-tick)
            (should (= (length asks) 1))
            (when spectreshell--clipboard-timer
              (spectreshell-test--clipboard-run-timer))
            (setq now 100.7)
            (spectreshell-test--clipboard-tick)
            (setq now 101.0)
            (spectreshell-test--clipboard-tick)
            (should (= (length asks) 1))
            (setq now 101.3)
            (spectreshell-test--clipboard-tick)
            (should (= (length asks) 2))
            (when spectreshell--clipboard-timer
              (spectreshell-test--clipboard-run-timer))
            (when spectreshell--clipboard-ask-timer
              (setq now 102.0)
              (spectreshell-test--clipboard-tick))
            (should (null spectreshell--clipboard-ask-timer))
            (should-not (seq-find (lambda (timer)
                                    (eq (timer--function timer)
                                        #'spectreshell--clipboard-ask-tick))
                                  timer-list))))))))

(ert-deftest spectreshell-test-clipboard-prompt-waits-while-minibuffer-is-in-use ()
  "利用者がミニバッファを使っている間は確認を出さず、要求を待たせたまま、
使われなくなってから出す。使っている最中に出すと、エラーで断りになるか、
利用者のミニバッファを終わらせるか、その上に重なる。"
  (spectreshell-test--with-terminal (term 1 10 responses)
    (spectreshell-test--with-clipboard (_cuts asks 'deny)
      (let ((spectreshell-clipboard-read 'ask)
            (num-nonmacro-input-events 10)
            (now 100.0)
            (depth 1))
        (cl-letf (((symbol-function 'float-time) (lambda (&optional _) now))
                  ((symbol-function 'minibuffer-depth) (lambda () depth)))
          (spectreshell-feed term "\e]52;c;?\a")
          (spectreshell-test--clipboard-run-timer)
          (spectreshell-test--clipboard-tick)
          (setq now 101.0)
          (spectreshell-test--clipboard-tick)
          (spectreshell--clipboard-ask-next)
          (should (null asks))
          (should (null responses))
          (setq now 102.0)
          (spectreshell-test--clipboard-tick)
          (should (null asks))
          (setq depth 0 now 103.0)
          (spectreshell-test--clipboard-tick)
          (should (= (length asks) 1)))))))

(ert-deftest spectreshell-test-clipboard-prompt-keeps-typed-input ()
  "確認の前に入力を捨てない (`discard-input' は記録中のキーボードマクロを
終わらせてしまう)。打っている途中の入力は確認の語と一致しないので断りになる。"
  (spectreshell-test--with-terminal (term 1 10)
    (let ((discarded nil))
      (spectreshell-test--with-clipboard (_cuts asks 'deny)
        (let ((spectreshell-clipboard-read 'ask))
          (cl-letf (((symbol-function 'discard-input)
                     (lambda () (setq discarded t))))
            (spectreshell-feed term "\e]52;c;?\a")
            (spectreshell-test--clipboard-drain))
          (should (= (length asks) 1))
          (should-not discarded))))))

(ert-deftest spectreshell-test-clipboard-prompt-checks-the-buffer-is-still-shown ()
  "確認を出す直前にバッファが見えなくなっていたら、確認せずに断る。"
  (spectreshell-test--with-terminal (term 1 10 responses)
    (spectreshell-test--with-clipboard (_cuts asks 'allow)
      (let ((spectreshell-clipboard-read 'ask)
            (shown t))
        (cl-letf (((symbol-function 'spectreshell--clipboard-can-ask-p)
                   (lambda (_) shown)))
          (kill-new "hi")
          (spectreshell-feed term "\e]52;c;?\a")
          (spectreshell--clipboard-run)
          (setq shown nil)
          (spectreshell-test--clipboard-drain))
        (should (null asks))
        (should (equal responses '("\e]52;c;\a")))))))

(defun spectreshell-test--paste-event-pw (event)
  "EVENT (paste イベント) の base64 のパスワードを返す。"
  (and (string-match ":pw=\\([A-Za-z0-9+/=]+\\)" event)
       (match-string 1 event)))

(ert-deftest spectreshell-test-yank-sends-paste-event-and-serves-follow-up-read ()
  "子が mode 5522 を立てている間の `spectreshell-yank' は本文の代わりに
paste イベントを送り、続く読み取りには ask でも確認せずに答える。"
  (spectreshell-test--with-terminal (term 1 10 responses)
    (spectreshell-test--with-clipboard (_cuts asks 'deny)
      (let ((spectreshell-clipboard-read 'ask)
            (spectreshell--current term))
        (kill-new "hi")
        (spectreshell-feed term "\e[?5522h")
        (spectreshell-yank)
        (let* ((event (car responses))
               (pw (spectreshell-test--paste-event-pw event)))
          (should (string-prefix-p "\e]5522;type=read:status=OK:pw=" event))
          (should-not (string-search "aGk=" event))
          (setq responses nil)
          (spectreshell-feed
           term (format "\e]5522;type=read:name=UGFzdGUgZXZlbnQ=:pw=%s;dGV4dC9wbGFpbg==\a" pw))
          (spectreshell-test--clipboard-drain)
          (should (null asks))
          (should (string-match-p "status=DATA:mime=dGV4dC9wbGFpbg==;aGk=" (car responses))))))))

(ert-deftest spectreshell-test-yank-sends-text-when-reads-are-denied ()
  "`spectreshell-clipboard-read' が deny なら、mode 5522 でも本文をそのまま
送る。イベントにすると続く読み取りが拒否されて貼り付けが消える。"
  (spectreshell-test--with-terminal (term 1 10 responses)
    (spectreshell-test--with-clipboard (_cuts _asks 'deny)
      (let ((spectreshell-clipboard-read 'deny)
            (spectreshell--current term))
        (kill-new "hi")
        (spectreshell-feed term "\e[?5522h")
        (spectreshell-yank)
        (should (equal responses '("hi")))))))

;; ---------------------------------------------------------------------
;; クリップボードの要求の順序・上限・後始末
;; ---------------------------------------------------------------------

(ert-deftest spectreshell-test-clipboard-prompt-does-not-hold-other-terminals ()
  "ある端末の確認の間も、ほかの端末の確認の要らない要求は待たずに処理する。"
  (spectreshell-test--with-terminal (a 1 10)
    (spectreshell-test--with-terminal (b 1 10)
      (let ((seen 'unset))
        (spectreshell-test--with-clipboard (_cuts asks (progn
                                                         (spectreshell-feed b "\e]52;c;aGk=\a")
                                                         (spectreshell--clipboard-run)
                                                         (setq seen (copy-sequence kill-ring))
                                                         'deny))
          (let ((spectreshell-clipboard-read 'ask)
                (spectreshell-clipboard-write 'allow))
            (spectreshell-feed a "\e]52;c;?\a")
            (spectreshell-test--clipboard-drain)
            (should (= (length asks) 1))
            (should (equal seen '("hi")))))))))

(ert-deftest spectreshell-test-clipboard-prompts-are-one-at-a-time-across-terminals ()
  "確認は全端末で一度に 1 つ。ある端末の確認の間に別の端末が確認の要る要求を
出しても、前の確認が終わってから出す。"
  (spectreshell-test--with-terminal (a 1 10)
    (spectreshell-test--with-terminal (b 1 10)
      (let ((depths nil))
        (spectreshell-test--with-clipboard (_cuts asks (progn
                                                         (when (= (length asks) 1)
                                                           (spectreshell-feed b "\e]52;c;?\a")
                                                           (spectreshell--clipboard-run)
                                                           (spectreshell--clipboard-ask-next))
                                                         (push (length asks) depths)
                                                         'deny))
          (let ((spectreshell-clipboard-read 'ask))
            (spectreshell-feed a "\e]52;c;?\a")
            (spectreshell-test--clipboard-drain)
            (should (equal depths '(2 1)))))))))

(ert-deftest spectreshell-test-clipboard-queue-is-limited-per-terminal ()
  "1 つの端末の処理を待つ要求は 64 件まで。超えた分は待たせずに断りで答える。"
  (spectreshell-test--with-terminal (term 1 10 responses)
    (spectreshell-test--with-clipboard (_cuts asks 'allow)
      (let ((spectreshell-clipboard-read 'ask)
            (spectreshell-clipboard-write 'ask)
            (kill-ring-max 100))
        (spectreshell-feed term (concat (apply #'concat (make-list 64 "\e]52;c;aGk=\a"))
                                        "\e]52;c;?\a"))
        (should (equal responses '("\e]52;c;\a")))
        (spectreshell-test--clipboard-drain)
        (should (= (length asks) 64))
        (should (= (length kill-ring) 64))))))

(ert-deftest spectreshell-test-clipboard-quit-denies-the-terminals-waiting-prompts ()
  "確認で C-g を押すと、その端末で確認を待つ要求もすべて断る。確認の要らない
要求と、ほかの端末の要求はそのまま処理する。"
  (spectreshell-test--with-terminal (a 1 10 a-responses)
    (spectreshell-test--with-terminal (b 1 10 b-responses)
      (spectreshell-test--with-clipboard (_cuts asks (if (= (length asks) 1)
                                                         (progn (setq quit-flag t) (ignore) 'allow)
                                                       'allow))
        (let ((spectreshell-clipboard-read 'ask)
              (spectreshell-clipboard-write 'allow))
          (kill-new "x")
          (spectreshell-feed a "\e]52;c;?\a\e]52;c;aGk=\a\e]52;c;?\a")
          (spectreshell-feed b "\e]52;c;?\a")
          (let ((inhibit-quit t))
            (spectreshell-test--clipboard-drain))
          (should (= (length asks) 2))
          (should (equal a-responses '("\e]52;c;\a" "\e]52;c;\a")))
          (should (equal b-responses '("\e]52;c;aGk=\a")))
          (should (equal kill-ring '("hi" "x")))
          (should (null quit-flag)))))))

(ert-deftest spectreshell-test-clipboard-write-is-answered-even-when-writing-fails ()
  "書き込みを断ったときも、書き込みがエラーになったときも、覚えるかの答えを
返して記録を残さない。後から覚えると答えても、次の同じパスワードの書き込みは
確認する。"
  (dolist (answer '(deny allow))
    (spectreshell-test--with-terminal (term 1 10)
      (spectreshell-test--with-clipboard (_cuts asks answer)
        (let ((spectreshell-clipboard-write 'ask)
              (orig (symbol-function 'spectreshell--clipboard-reply))
              (ids nil))
          (cl-letf (((symbol-function 'spectreshell--clipboard-reply)
                     (lambda (term id result &optional remember)
                       (push id ids)
                       (funcall orig term id result remember)))
                    ((symbol-function 'kill-new)
                     (lambda (&rest _) (error "Boom")))
                    ((symbol-function 'message) #'ignore))
            (spectreshell-feed term spectreshell-test--kitty-write)
            (spectreshell-test--clipboard-drain))
          (should (= (length ids) 1))
          (funcall orig (spectreshell-term term) (car ids) nil t)
          (spectreshell-feed term spectreshell-test--kitty-write)
          (spectreshell-test--clipboard-drain)
          (should (= (length asks) 2)))))))

(ert-deftest spectreshell-test-clipboard-read-is-answered-when-asking-exits-non-locally ()
  "確認から throw などで抜けても、取り出した読み取りには断りで答え、残りの
要求のために timer を張り直す。"
  (spectreshell-test--with-terminal (term 1 10 responses)
    (let ((thrown nil))
      (spectreshell-test--with-clipboard (_cuts asks (if thrown
                                                         'allow
                                                       (setq thrown t)
                                                       (throw 'escape nil)))
        (let ((spectreshell-clipboard-read 'ask))
          (kill-new "hi")
          (spectreshell-feed term "\e]52;c;?\a\e]52;c;?\a")
          (catch 'escape (spectreshell-test--clipboard-drain))
          (should (equal responses '("\e]52;c;\a")))
          (should (or spectreshell--clipboard-timer spectreshell--clipboard-ask-timer))
          (spectreshell-test--clipboard-drain)
          (should (= (length asks) 2))
          (should (equal responses '("\e]52;c;aGk=\a" "\e]52;c;\a"))))))))

(ert-deftest spectreshell-test-clipboard-run-rearms-only-after-taking-a-request ()
  "要求の処理がエラーで抜けたとき、timer を張り直すのは要求を取り出した後
だけ。取り出す前に毎回エラーになっても 0 秒の timer が回り続けない。"
  (spectreshell-test--with-terminal (term 1 10)
    (spectreshell-test--with-clipboard (_cuts _asks 'deny)
      (let ((spectreshell-clipboard-write 'allow))
        (spectreshell-feed term "\e]52;c;aGk=\a")
        (cancel-timer spectreshell--clipboard-timer)
        (setq spectreshell--clipboard-timer nil)
        (cl-letf (((symbol-function 'spectreshell--clipboard-decision)
                   (lambda (&rest _) (error "Boom"))))
          (should-error (spectreshell--clipboard-run)))
        (should-not spectreshell--clipboard-timer)
        (cl-letf (((symbol-function 'spectreshell--clipboard-handle)
                   (lambda (&rest _) (error "Boom"))))
          (should-error (spectreshell--clipboard-run)))
        (should spectreshell--clipboard-timer)))))

(ert-deftest spectreshell-test-clipboard-ask-next-waits-while-running ()
  "要求の処理の最中 (処理が timer を走らせたとき) には確認を出さず、処理の
終わりに任せる。"
  (spectreshell-test--with-terminal (term 1 10)
    (spectreshell-test--with-clipboard (_cuts asks 'deny)
      (let ((spectreshell-clipboard-read 'ask))
        (spectreshell-feed term "\e]52;c;?\a")
        (spectreshell-test--clipboard-run-timer)
        (let ((spectreshell--clipboard-running t))
          (spectreshell--clipboard-ask-next))
        (should (null asks))
        (spectreshell-test--clipboard-drain)
        (should (= (length asks) 1))))))

(ert-deftest spectreshell-test-clipboard-ask-next-forgets-finalized-terminals ()
  "確認を待つ間に端末が finalize されたら、次の確認を探すときにその queue を
捨てる。次の要求を待たずに捨てて、確認の timer も止める。"
  (spectreshell-test--with-terminal (term 1 10)
    (spectreshell-test--with-clipboard (_cuts asks 'deny)
      (let ((spectreshell-clipboard-read 'ask))
        (spectreshell-feed term "\e]52;c;?\a")
        (spectreshell-test--clipboard-run-timer)
        (should spectreshell--clipboard-queues)
        (spectreshell-finalize term)
        (spectreshell--clipboard-ask-next)
        (should (null spectreshell--clipboard-queues))
        (should (null asks))))))

(ert-deftest spectreshell-test-clipboard-requests-before-reset-are-not-asked ()
  "確認を待つ間に子が RIS (\\ec) を出したら、RIS の前の、もう答えを待って
いない要求は確認せずに捨てる。"
  (spectreshell-test--with-terminal (term 1 10 responses)
    (spectreshell-test--with-clipboard (_cuts asks 'allow)
      (let ((spectreshell-clipboard-read 'ask)
            (spectreshell-clipboard-write 'ask))
        (kill-new "x")
        (spectreshell-feed term (concat spectreshell-test--kitty-read
                                        "\e]52;c;?\a"
                                        spectreshell-test--kitty-write))
        (spectreshell-test--clipboard-run-timer)
        (setq responses nil)
        (spectreshell-feed term "\ec")
        (spectreshell-test--clipboard-drain)
        (should (null asks))
        (should (null responses))
        (should (equal kill-ring '("x")))
        (should (null spectreshell--clipboard-queues))))))

(ert-deftest spectreshell-test-clipboard-prompts-take-turns-across-terminals ()
  "確認は端末ごとに順番に (round-robin で) 出す。確認を出し続ける端末が
あっても、ほかの端末の確認が後回しにされ続けない。"
  (spectreshell-test--with-terminal (a 1 10)
    (spectreshell-test--with-terminal (b 1 10)
      (spectreshell-test--with-clipboard (_cuts _asks 'deny)
        (let* ((spectreshell-clipboard-read 'ask)
               (order nil)
               (spectreshell--clipboard-ask-function
                (lambda (obj _request _prompt)
                  (setq order (append order (list (if (eq obj a) 'a 'b))))
                  'deny)))
          (spectreshell-feed a "\e]52;c;?\a\e]52;c;?\a\e]52;c;?\a")
          (spectreshell-feed b "\e]52;c;?\a")
          (spectreshell-test--clipboard-drain)
          (should (equal order '(a b a a))))))))

(ert-deftest spectreshell-test-kitty-always-after-reset-is-not-remembered ()
  "確認の間に子が RIS (\\ec) を出したら、その前の読み取りに always と答えても
パスワードを覚えず、答えも送らない。"
  (spectreshell-test--with-terminal (term 1 10 responses)
    (spectreshell-test--with-clipboard (_cuts asks (progn
                                                     (when (= (length asks) 1)
                                                       (spectreshell-feed term "\ec"))
                                                     'always))
      (let ((spectreshell-clipboard-read 'ask))
        (kill-new "hi")
        (spectreshell-feed term spectreshell-test--kitty-read)
        (spectreshell-test--clipboard-drain)
        (should (null responses))
        (spectreshell-feed term spectreshell-test--kitty-read)
        (spectreshell-test--clipboard-drain)
        (should (= (length asks) 2))))))

(ert-deftest spectreshell-test-osc52-write-keeps-line-ends ()
  "書き込みの本文の CRLF は書き換えずに kill-ring に入れる。"
  (spectreshell-test--with-terminal (term 1 10)
    (spectreshell-test--with-clipboard (_cuts _asks 'allow)
      (let ((spectreshell-clipboard-write 'allow))
        (spectreshell-feed term "\e]52;c;YQ0KYg==\a")
        (spectreshell-test--clipboard-drain)
        (should (equal kill-ring '("a\r\nb")))))))

(ert-deftest spectreshell-test-osc52-write-keeps-other-last-commands ()
  "子の書き込みで `last-command' を変えるのは、kill と yank の続き
\(`kill-region'・`yank') のときだけ。`undo' の連続や `next-line' の桁、
eshell の履歴の巡回などは壊さない。"
  (dolist (command '(undo next-line eshell-previous-matching-input-from-input
                          self-insert-command))
    (spectreshell-test--with-terminal (term 1 10)
      (spectreshell-test--with-clipboard (_cuts _asks 'allow)
        (let ((spectreshell-clipboard-write 'allow)
              (last-command command))
          (spectreshell-feed term "\e]52;c;aGk=\a")
          (spectreshell-test--clipboard-drain)
          (should (equal kill-ring '("hi")))
          (should (eq last-command command)))))))

(ert-deftest spectreshell-test-osc52-write-breaks-kill-and-yank-sequences ()
  "子の書き込みを kill-ring に入れたら `last-command' を nil にする。続く
コマンドが、利用者の kill に子の本文を連結したり (`kill-append')、yank の
続きとして扱ったり (`yank-pop') しないため。"
  (dolist (command '(kill-region yank))
    (spectreshell-test--with-terminal (term 1 10)
      (spectreshell-test--with-clipboard (_cuts _asks 'allow)
        (let ((spectreshell-clipboard-write 'allow)
              (last-command command))
          (spectreshell-feed term "\e]52;c;aGk=\a")
          (spectreshell-test--clipboard-drain)
          (should (equal kill-ring '("hi")))
          (should (null last-command)))))))

;; ---------------------------------------------------------------------
;; デスクトップ通知の中継 (L-41)
;; ---------------------------------------------------------------------

(ert-deftest spectreshell-test-notification-reaches-terminals-as-osc777 ()
  "子の通知は OSC 777 でも OSC 9 でも、外側の端末へ OSC 777 で届く。
UTF-8 のタイトルと本文はそのままのバイト列で送る。"
  (spectreshell-test--with-terminal (term 1 10)
    (spectreshell-test--with-relay-terminals '(t1 t2) nil sent
      (let ((osc777 (encode-coding-string
                     "\e]777;notify;✳ Claude Code;入力待ち\a" 'utf-8)))
        (spectreshell-feed term osc777)
        (spectreshell-feed term "\x1b]9;done\x07")
        (should (equal sent `((,osc777 . t1) (,osc777 . t2)
                              ("\e]777;notify;;done\a" . t1)
                              ("\e]777;notify;;done\a" . t2))))
        (should-not (multibyte-string-p (car (car sent))))))))

(ert-deftest spectreshell-test-notification-drops-control-characters ()
  "通知のタイトルと本文から制御文字を除き、タイトルからは区切りと区別
できない ; も除く。子に外側の端末へ任意の制御列を書かせないため。"
  (spectreshell-test--with-terminal (term 1 10)
    (spectreshell-test--with-relay-terminals '(t1) nil sent
      (spectreshell--relay-notification term "a;b\e\x7f" "c;d\a\n")
      (should (equal sent '(("\e]777;notify;ab;c;d\a" . t1)))))))

;; ---------------------------------------------------------------------
;; 進捗表示の中継 (L-42)
;; ---------------------------------------------------------------------

(ert-deftest spectreshell-test-progress-reaches-terminals-and-resends ()
  "子の進捗は外側の端末へ OSC 9;4 で届き、バッファを新たに表示した
ウィンドウの端末へ最新の状態を送り直す。消去の後は送り直さない。"
  (spectreshell-test--with-terminal (term 1 10)
    (spectreshell-test--with-relay-terminals '(t1) nil sent
      (spectreshell-feed term "\x1b]9;4;1;50\x07\x1b]9;4;3;0\x07")
      (should (equal sent '(("\e]9;4;1;50\a" . t1) ("\e]9;4;3\a" . t1)))))
    (spectreshell-test--with-frames '((w2 f2 t2 tty)) sent
      (run-hook-with-args 'window-buffer-change-functions 'w2)
      (should (equal sent '(("\e]9;4;3\a" . t2)))))
    (spectreshell-test--with-relay-terminals '(t1) nil sent
      (spectreshell-feed term "\x1b]9;4;0;0\x07")
      (should (equal sent '(("\e]9;4;0\a" . t1)))))
    (spectreshell-test--with-frames '((w2 f2 t2 tty)) sent
      (run-hook-with-args 'window-buffer-change-functions 'w2)
      (should (null sent)))))

(ert-deftest spectreshell-test-progress-is-cleared-when-job-ends ()
  "進捗を出したままジョブが終わると (finalize) 外側の進捗を消し、送り直し
もやめる。進捗を出していない同じバッファの別の端末の終了では消さない。"
  (spectreshell-test--with-terminal (term 1 10)
    (goto-char (point-max))
    (insert "\n")
    (let ((other (spectreshell-start (current-buffer) 1 10 #'ignore)))
      (spectreshell-feed term "\x1b]9;4;3\x07")
      (spectreshell-test--with-frames '((w1 f1 t1 tty)) sent
        (spectreshell-finalize other)
        (should (null sent))
        (spectreshell-finalize term)
        (should (equal sent '(("\e]9;4;0\a" . t1))))
        (setq sent nil)
        (run-hook-with-args 'window-buffer-change-functions 'w1)
        (should (null sent))))))

(ert-deftest spectreshell-test-progress-is-cleared-when-buffer-is-killed ()
  "進捗を出したままバッファを kill すると外側の進捗を消す。"
  ;; `with-temp-buffer' のバッファは `kill-buffer-hook' を走らせないので、
  ;; 普通のバッファで確かめる。
  (let ((buffer (generate-new-buffer " *spectreshell-test-progress*")))
    (unwind-protect
        (with-current-buffer buffer
          (let ((term (spectreshell-start buffer 1 10 #'ignore)))
            (spectreshell-feed term "\x1b]9;4;3\x07")
            (spectreshell-test--with-frames '((w1 f1 t1 tty)) sent
              (kill-buffer buffer)
              (should (equal sent '(("\e]9;4;0\a" . t1)))))))
      (when (buffer-live-p buffer)
        (kill-buffer buffer)))))

;; ---------------------------------------------------------------------
;; ベルの中継 (L-44)
;; ---------------------------------------------------------------------

(ert-deftest spectreshell-test-bell-reaches-terminals ()
  "子の BEL は外側の端末へ BEL で届く。"
  (spectreshell-test--with-terminal (term 1 10)
    (spectreshell-test--with-relay-terminals '(t1 t2) nil sent
      (spectreshell-feed term "\x07")
      (should (equal sent '(("\a" . t1) ("\a" . t2)))))))

;; ---------------------------------------------------------------------
;; タイトルの中継 (L-43)
;; ---------------------------------------------------------------------

(ert-deftest spectreshell-test-relay-title-sends-osc2 ()
  "`spectreshell-relay-title' を hook に入れると、子のタイトルが外側の
端末へ UTF-8 の OSC 2 で届く。"
  (spectreshell-test--with-terminal (term 1 10)
    (spectreshell-test--with-relay-terminals '(t1) nil sent
      (let ((spectreshell-title-functions '(spectreshell-relay-title)))
        (spectreshell-feed term (encode-coding-string "\e]0;✳ Claude Code\a" 'utf-8))
        (should (equal sent `((,(encode-coding-string "\e]2;✳ Claude Code\a" 'utf-8)
                               . t1))))
        (should-not (multibyte-string-p (car (car sent))))))))

(ert-deftest spectreshell-test-relay-title-drops-control-characters ()
  "外側へ送るタイトルから制御文字を除く。子に外側の端末へ任意の制御列を
書かせないため。"
  (spectreshell-test--with-terminal (term 1 10)
    (spectreshell-test--with-relay-terminals '(t1) nil sent
      (spectreshell-relay-title term "a\eb\ac\177d")
      (should (equal sent '(("\e]2;abcd\a" . t1)))))))

;; ---------------------------------------------------------------------
;; フォーカス報告 (L-48)
;; ---------------------------------------------------------------------

(defmacro spectreshell-test--with-focus (focused &rest body)
  "フォーカスの判定を変数 FOCUSED の値に差し替えて BODY を実行する.
判定そのものは `spectreshell-test-focus-follows-selected-window-of-focused-frame'
で固定してあるので、ここでは報告の流れだけを見る。"
  (declare (indent 1))
  `(let ((,focused t))
     (cl-letf (((symbol-function 'spectreshell--focused-p)
                (lambda (_) ,focused)))
       ,@body)))

(ert-deftest spectreshell-test-focus-follows-selected-window-of-focused-frame ()
  "端末のバッファを選択中のウィンドウに表示しているフレームにフォーカスが
あれば、フォーカスがあるとみなす。フォーカスの有無が分からないフレームは
フォーカスがあるとみなし (Ghostty の既定と同じ)、daemon の初期フレームは
数えない。"
  (let* ((buffer (current-buffer))
         ;; (FRAME SELECTED-WINDOW BUFFER FOCUS INITIAL)
         (frames nil))
    (cl-letf (((symbol-function 'frame-list) (lambda () (mapcar #'car frames)))
              ((symbol-function 'frame-selected-window)
               (lambda (f) (nth 1 (assq f frames))))
              ((symbol-function 'window-buffer)
               (lambda (w) (nth 2 (seq-find (lambda (e) (eq (nth 1 e) w)) frames))))
              ((symbol-function 'frame-focus-state)
               (lambda (f) (nth 3 (assq f frames))))
              ((symbol-function 'frame-initial-p)
               (lambda (f) (nth 4 (assq f frames)))))
      (setq frames `((f1 w1 ,buffer t nil)))
      (should (spectreshell--focused-p buffer))
      (setq frames `((f1 w1 ,buffer unknown nil)))
      (should (spectreshell--focused-p buffer))
      (setq frames `((f1 w1 ,buffer nil nil) (f2 w2 other t nil)))
      (should-not (spectreshell--focused-p buffer))
      (setq frames `((f0 w0 ,buffer unknown t)))
      (should-not (spectreshell--focused-p buffer)))))

(ert-deftest spectreshell-test-focus-is-reported-while-mode-1004-is-on ()
  "子が mode 1004 を有効にした時点で今のフォーカスを送り、以後は変わった
ときだけ \\e[I / \\e[O を送る。無効にした後は送らない。"
  (spectreshell-test--with-terminal (term 1 10 responses)
    (spectreshell-test--with-focus focused
      (spectreshell-feed term "\x1b[?1004h")
      (should (equal responses '("\e[I")))
      (setq responses nil focused nil)
      (funcall after-focus-change-function)
      (run-hook-with-args 'window-selection-change-functions (selected-frame))
      (should (equal responses '("\e[O")))
      (setq responses nil focused t)
      (run-hook-with-args 'window-buffer-change-functions (selected-frame))
      (should (equal responses '("\e[I")))
      (setq responses nil)
      (spectreshell-feed term "\x1b[?1004l")
      (setq focused nil)
      (funcall after-focus-change-function)
      (should (null responses)))))

(ert-deftest spectreshell-test-focus-report-starts-while-synchronized ()
  "mode 2026 の中で mode 1004 を有効にしても、待たずに今のフォーカスを送る。"
  (spectreshell-test--with-terminal (term 1 10 responses)
    (spectreshell-test--with-focus focused
      (setq focused nil)
      (spectreshell-feed term "\x1b[?2026h\x1b[?1004h")
      (should (equal responses '("\e[O"))))))

(ert-deftest spectreshell-test-focus-is-not-reported-after-finalize ()
  "ジョブが終わった端末には、フォーカスが変わっても送らない。"
  (spectreshell-test--with-terminal (term 1 10 responses)
    (spectreshell-test--with-focus focused
      (spectreshell-feed term "\x1b[?1004h")
      (spectreshell-finalize term)
      (setq responses nil focused nil)
      (funcall after-focus-change-function)
      (should (null responses)))))

;; ---------------------------------------------------------------------
;; 可視性の報告 (?998n / mode 2033)
;; ---------------------------------------------------------------------

(defmacro spectreshell-test--with-visibility (visible &rest body)
  "可視性の判定を変数 VISIBLE の値に差し替えて BODY を実行する.
判定そのものは `spectreshell-test-visible-when-a-visible-frame-shows-buffer'
で固定してあるので、ここでは報告の流れだけを見る。"
  (declare (indent 1))
  `(let ((,visible t))
     (cl-letf (((symbol-function 'spectreshell--visible-p)
                (lambda (_) ,visible)))
       ,@body)))

(ert-deftest spectreshell-test-visible-when-a-visible-frame-shows-buffer ()
  "daemon の初期フレームを除く、見えているフレームのどれかのウィンドウ
(選択中でなくてよい) がバッファを表示していれば、見えているとみなす。
アイコン化したフレームと不可視のフレームは数えない。"
  (let ((buffer (current-buffer))
        ;; (FRAME VISIBILITY INITIAL SHOWN-BUFFER)
        (frames nil))
    (cl-letf (((symbol-function 'frame-list) (lambda () (mapcar #'car frames)))
              ((symbol-function 'frame-visible-p)
               (lambda (f) (nth 1 (assq f frames))))
              ((symbol-function 'frame-initial-p)
               (lambda (f) (nth 2 (assq f frames))))
              ((symbol-function 'get-buffer-window)
               (lambda (b f) (and (eq b (nth 3 (assq f frames))) 'window))))
      (setq frames `((f1 t nil ,buffer)))
      (should (spectreshell--visible-p buffer))
      (setq frames `((f1 t nil other) (f2 t nil ,buffer)))
      (should (spectreshell--visible-p buffer))
      (setq frames `((f1 t nil other)))
      (should-not (spectreshell--visible-p buffer))
      (setq frames `((f1 icon nil ,buffer) (f2 nil nil ,buffer)))
      (should-not (spectreshell--visible-p buffer))
      (setq frames `((f0 t t ,buffer)))
      (should-not (spectreshell--visible-p buffer)))))

(ert-deftest spectreshell-test-tty-frame-is-visible-only-as-top-frame ()
  "tty のフレームは、ルートのフレームがその端末の `tty-top-frame' のときだけ
見えているとみなす。Emacs は tty のフレームを切り替えても、裏に回った
フレームの可視性を落とさない。"
  (let ((buffer (current-buffer))
        ;; (FRAME ROOT SHOWN-BUFFER)。どれも同じ tty の、可視性 t のフレーム。
        (frames nil)
        (top nil))
    (cl-letf (((symbol-function 'frame-list) (lambda () (mapcar #'car frames)))
              ((symbol-function 'framep) (lambda (f) (and (assq f frames) t)))
              ((symbol-function 'frame-visible-p) (lambda (_) t))
              ((symbol-function 'frame-initial-p) #'ignore)
              ((symbol-function 'frame-root-frame)
               (lambda (&optional f) (nth 1 (assq f frames))))
              ((symbol-function 'tty-top-frame) (lambda (&optional _) top))
              ((symbol-function 'get-buffer-window)
               (lambda (b f) (and (eq b (nth 2 (assq f frames))) 'window))))
      (setq frames `((f1 f1 ,buffer) (f2 f2 other)) top 'f2)
      (should-not (spectreshell--visible-p buffer))
      (setq top 'f1)
      (should (spectreshell--visible-p buffer))
      ;; 子フレームは、ルートが一番上にあれば見えている。
      (setq frames `((f1 f1 other) (c1 f1 ,buffer)))
      (should (spectreshell--visible-p buffer))
      (setq top 'f2)
      (should-not (spectreshell--visible-p buffer)))))

(ert-deftest spectreshell-test-visibility-is-reevaluated-on-selection-change ()
  "tty のフレームの切り替えは選択の変化として来るので、
`window-selection-change-functions' でも可視性を引き直す。"
  (should (memq #'spectreshell--report-visibility
                (default-value 'window-selection-change-functions))))

(ert-deftest spectreshell-test-report-visibility-is-not-a-command ()
  "可視性の引き直しはフックから呼ぶ関数で、コマンドではない。"
  (should-not (commandp #'spectreshell--report-visibility)))

(ert-deftest spectreshell-test-visibility-query-answers-current-visibility ()
  "\\e[?998n には、バッファの今の可視性で Ghostty と同じ形で答える。"
  (spectreshell-test--with-visibility visible
    (spectreshell-test--with-terminal (term 1 10 responses)
      (spectreshell-feed term "\x1b[?998n")
      (should (equal responses '("\e[?999;1n")))
      (setq responses nil visible nil)
      (spectreshell-feed term "\x1b[?998n")
      (should (equal responses '("\e[?999;2n"))))))

(ert-deftest spectreshell-test-visibility-is-reported-while-mode-2033-is-on ()
  "子が mode 2033 を有効にした時点で今の可視性を送り、以後は変わったとき
だけ送る。ウィンドウのバッファの変化と、フレームの削除・可視性の変化の
どれのきっかけでも再評価する。無効にした後と、ジョブが終わった後は送らない。"
  (spectreshell-test--with-visibility visible
    (spectreshell-test--with-terminal (term 1 10 responses)
      (setq visible nil)
      (spectreshell-feed term "\x1b[?2033h")
      (should (equal responses '("\e[?999;2n")))
      (setq responses nil visible t)
      (run-hook-with-args 'window-buffer-change-functions (selected-frame))
      (should (equal responses '("\e[?999;1n")))
      (setq responses nil)
      (run-hook-with-args 'window-buffer-change-functions (selected-frame))
      (should (null responses))
      (setq visible nil)
      (run-hook-with-args 'after-delete-frame-functions (selected-frame))
      (should (equal responses '("\e[?999;2n")))
      (setq responses nil visible t)
      (funcall after-focus-change-function)
      (should (equal responses '("\e[?999;1n")))
      (setq responses nil visible nil)
      (funcall after-focus-change-function)
      (should (equal responses '("\e[?999;2n")))
      (setq responses nil)
      (spectreshell-feed term "\x1b[?2033l")
      (setq visible t)
      (run-hook-with-args 'window-buffer-change-functions (selected-frame))
      (should (null responses))
      (spectreshell-feed term "\x1b[?2033h")
      (spectreshell-finalize term)
      (setq responses nil visible nil)
      (run-hook-with-args 'window-buffer-change-functions (selected-frame))
      (should (null responses)))))

;; ---------------------------------------------------------------------
;; 明暗の問い合わせと通知 (L-50)
;; ---------------------------------------------------------------------

(defmacro spectreshell-test--with-background-mode (mode &rest body)
  "フレームの `background-mode' を変数 MODE の値に差し替えて BODY を実行する."
  (declare (indent 1))
  `(let ((,mode 'dark)
         (orig (symbol-function 'frame-parameter)))
     (cl-letf (((symbol-function 'frame-parameter)
                (lambda (frame parameter)
                  (if (eq parameter 'background-mode)
                      ,mode
                    (funcall orig frame parameter)))))
       ,@body)))

(ert-deftest spectreshell-test-color-scheme-query-answers-background-mode ()
  "\\e[?996n には、バッファを表示しているフレームの `background-mode' で
Ghostty と同じ形で答える。"
  (spectreshell-test--with-background-mode mode
    (spectreshell-test--with-terminal (term 1 10 responses)
      (setq mode 'light)
      (spectreshell-feed term "\x1b[?996n")
      (should (equal responses '("\e[?997;2n")))
      (setq responses nil mode 'dark)
      (spectreshell-feed term "\x1b[?996n")
      (should (equal responses '("\e[?997;1n"))))))

(ert-deftest spectreshell-test-color-scheme-change-is-reported-with-mode-2031 ()
  "子が mode 2031 を有効にしている間は、テーマを替えて明暗が変わったとき
だけ子へ通知する。無効にした後と、ジョブが終わった後は送らない。"
  (spectreshell-test--with-background-mode mode
    (spectreshell-test--with-terminal (term 1 10 responses)
      (spectreshell-feed term "\x1b[?2031h")
      (setq mode 'light)
      (run-hook-with-args 'enable-theme-functions 'some-theme)
      (should (equal responses '("\e[?997;2n")))
      (setq responses nil)
      (run-hook-with-args 'disable-theme-functions 'some-theme)
      (should (null responses))
      (spectreshell-feed term "\x1b[?2031l")
      (setq mode 'dark)
      (run-hook-with-args 'enable-theme-functions 'some-theme)
      (should (null responses))
      (spectreshell-feed term "\x1b[?2031h")
      (spectreshell-finalize term)
      (setq mode 'light)
      (run-hook-with-args 'enable-theme-functions 'some-theme)
      (should (null responses)))))

(defmacro spectreshell-test--with-colors (calls &rest body)
  "BODY を実行し、BODY で変えた face の色を後で戻す。
`color-values' は \"#rrggbb\" を batch の端末の色に寄せずに 16bit の
3 つ組にし (それ以外は nil)、呼ばれた回数を変数 CALLS に数える。"
  (declare (indent 1))
  (let ((saved (make-symbol "saved")))
    `(let ((,calls 0)
           (,saved (mapcar (lambda (face)
                             (list face
                                   (face-attribute face :foreground)
                                   (face-attribute face :background)))
                           (cons 'default
                                 (mapcar (lambda (i)
                                           (intern (format "spectreshell-color-%d" i)))
                                         (number-sequence 0 15))))))
       (unwind-protect
           (cl-letf (((symbol-function 'color-values)
                      (lambda (color &optional _frame)
                        (setq ,calls (1+ ,calls))
                        (and (stringp color)
                             (string-match "\\`#\\(..\\)\\(..\\)\\(..\\)\\'" color)
                             (mapcar (lambda (i)
                                       (* 257 (string-to-number (match-string i color) 16)))
                                     '(1 2 3))))))
             ,@body)
         (pcase-dolist (`(,face ,fg ,bg) ,saved)
           (set-face-attribute face nil :foreground fg :background bg))))))

(ert-deftest spectreshell-test-color-queries-answer-theme-colors ()
  "OSC 10 / 11 には `default' の前景・背景で、OSC 4 の 0〜15 には
`spectreshell-color-N' の前景で、Ghostty と同じ形で答える。"
  (spectreshell-test--with-colors calls
    (set-face-attribute 'default nil :foreground "#ffeedd" :background "#010203")
    (set-face-attribute 'spectreshell-color-1 nil :foreground "#cd0000")
    (spectreshell-test--with-terminal (term 1 10 responses)
      (spectreshell-feed term "\e]10;?\e\\\e]11;?\a\e]4;1;?\e\\")
      (should (equal responses
                     '("\e]10;rgb:ffff/eeee/dddd\e\\\e]11;rgb:0101/0202/0303\a\e]4;1;rgb:cdcd/0000/0000\e\\"))))))

(ert-deftest spectreshell-test-unspecified-colors-are-not-answered ()
  "色が決まっていない `default' (tty の unspecified-fg / -bg) の問い合わせには
答えず、続く問い合わせには答える。"
  (spectreshell-test--with-colors calls
    (set-face-attribute 'default nil :foreground 'unspecified :background 'unspecified)
    (spectreshell-test--with-terminal (term 1 10 responses)
      (spectreshell-feed term "\e]10;?\e\\\e]11;?\e\\\e[c")
      (should (equal responses '("\e[?62;22;52c"))))))

(ert-deftest spectreshell-test-color-queries-follow-theme-change ()
  "色は feed ごとには引き直さず、テーマを替えたときに引き直した色で答える。"
  (spectreshell-test--with-colors calls
    (set-face-attribute 'spectreshell-color-1 nil :foreground "#cd0000")
    (spectreshell-test--with-terminal (term 1 10 responses)
      (spectreshell-feed term "\e]4;1;?\e\\")
      (setq responses nil calls 0)
      (set-face-attribute 'spectreshell-color-1 nil :foreground "#ff5555")
      (spectreshell-feed term "\e]4;1;?\e\\")
      (should (equal calls 0))
      (should (equal responses '("\e]4;1;rgb:cdcd/0000/0000\e\\")))
      (setq responses nil)
      (run-hook-with-args 'enable-theme-functions 'some-theme)
      (spectreshell-feed term "\e]4;1;?\e\\")
      (should (equal responses '("\e]4;1;rgb:ffff/5555/5555\e\\")))
      (spectreshell-finalize term)
      (run-hook-with-args 'enable-theme-functions 'some-theme)
      (should-not (gethash term spectreshell--colors-given)))))

(ert-deftest spectreshell-test-same-colors-are-not-given-again ()
  "引き直した色が前回と同じなら、モジュールに渡し直さない。"
  (spectreshell-test--with-colors calls
    (spectreshell-test--with-terminal (term 1 10)
      (spectreshell-feed term "a")
      (let ((given 0)
            (orig (symbol-function 'spectreshell--set-colors)))
        (cl-letf (((symbol-function 'spectreshell--set-colors)
                   (lambda (&rest args)
                     (setq given (1+ given))
                     (apply orig args))))
          (run-hook-with-args 'enable-theme-functions 'some-theme)
          (should (equal given 0))
          (set-face-attribute 'spectreshell-color-1 nil :foreground "#ff5555")
          (run-hook-with-args 'enable-theme-functions 'some-theme)
          (should (equal given 1)))))))

(ert-deftest spectreshell-test-color-queries-follow-window-and-theme-changes ()
  "ウィンドウの選択・バッファの変化とテーマの無効化でも色を引き直す。"
  (spectreshell-test--with-colors calls
    (spectreshell-test--with-terminal (term 1 10 responses)
      (spectreshell-feed term "a")
      (pcase-dolist (`(,hook ,color ,answer)
                     '((window-selection-change-functions "#010203" "0101/0202/0303")
                       (window-buffer-change-functions "#040506" "0404/0505/0606")
                       (disable-theme-functions "#070809" "0707/0808/0909")))
        (set-face-attribute 'spectreshell-color-1 nil :foreground color)
        (run-hook-with-args hook (if (eq hook 'disable-theme-functions)
                                     'some-theme
                                   (selected-frame)))
        (setq responses nil)
        (spectreshell-feed term "\e]4;1;?\e\\")
        (should (equal responses
                       (list (format "\e]4;1;rgb:%s\e\\" answer))))))))

(ert-deftest spectreshell-test-finalize-releases-terminal ()
  "finalize 後は端末が release され、追加の feed が signal される。"
  (spectreshell-test--with-terminal (term 1 10)
    (spectreshell-feed term "bye")
    (let ((term-ptr (spectreshell-term term)))
      (spectreshell-finalize term)
      (should-error (spectreshell--feed term-ptr "x")
                    :type 'spectreshell-terminal-released))))

;; ---------------------------------------------------------------------
;; 端末領域の終端 (領域より後ろのテキストの保護)
;; ---------------------------------------------------------------------

(defmacro spectreshell-test--with-trailing-text (spec text &rest body)
  "SPEC の端末を作り、その領域の直後に TEXT を置いてから BODY を実行する.
SPEC は `spectreshell-test--with-terminal' と同じ。TEXT は eshell が
背景ジョブの領域より後ろに書くプロンプトやコマンドラインに相当する。"
  (declare (indent 2))
  `(spectreshell-test--with-terminal ,spec
     (save-excursion (goto-char (point-max)) (insert ,text))
     ,@body))

(defun spectreshell-test--region-string (obj)
  "OBJ の端末領域のテキストを返す。"
  (buffer-substring-no-properties (spectreshell-marker obj)
                                  (spectreshell--region-end obj)))

(ert-deftest spectreshell-test-update-keeps-text-after-region ()
  "領域より後ろのテキストは feed の再描画で消えず、行数計算にも入らない。
背景ジョブの領域の後ろには eshell のプロンプトと編集中のコマンド
ラインが並ぶので、そこを端末領域とみなして削除・上書きしてはならない。"
  (spectreshell-test--with-trailing-text (term 5 10) "$ typing"
    (spectreshell-feed term "ab\r\ncd")
    (should (= 5 (spectreshell--row-count term)))
    (should (string-prefix-p "ab        \ncd        \n"
                             (spectreshell-test--region-string term)))
    (should-not (string-match-p "\\$ typing"
                                (spectreshell-test--region-string term)))
    (should (string-suffix-p "$ typing" (buffer-string)))))

(ert-deftest spectreshell-test-scrolled-off-keeps-text-after-region ()
  "スクロールアウト行の確定化でも領域より後ろのテキストは動かない。
確定化は領域の先頭に挿入するので、空の領域では終端マーカーも一緒に
押し出さないと領域の前後が入れ替わる。"
  (spectreshell-test--with-trailing-text (term 2 5) "$ typing"
    (spectreshell-feed term "1\r\n2\r\n3\r\n")
    (should (<= (spectreshell-marker term) (spectreshell--region-end term)))
    (should (= 2 (spectreshell--row-count term)))
    (should (string-suffix-p "$ typing" (buffer-string)))))

(ert-deftest spectreshell-test-resize-shrink-keeps-text-after-region ()
  "行数を縮める resize の余剰行削除は領域の終端までしか消さない。"
  (spectreshell-test--with-trailing-text (term 4 5) "$ typing"
    (spectreshell-feed term "a\r\nb\r\nc\r\nd")
    (spectreshell-resize term 2 5)
    (should (= 2 (spectreshell--row-count term)))
    (should (string-suffix-p "$ typing" (buffer-string)))))

(ert-deftest spectreshell-test-alt-screen-keeps-text-after-region ()
  "alt screen の出入りで領域を丸ごと入れ替えても後ろのテキストは残る。"
  (spectreshell-test--with-trailing-text (term 3 10) "$ typing"
    (spectreshell-feed term "hello")
    (spectreshell-feed term "\x1b[?1049h")
    (should (string-suffix-p "$ typing" (buffer-string)))
    (spectreshell-feed term "\x1b[?1049l")
    (should (string-prefix-p "hello" (spectreshell-test--region-string term)))
    (should (string-suffix-p "$ typing" (buffer-string)))))

(ert-deftest spectreshell-test-finalize-keeps-text-after-region ()
  "finalize の確定化 (パディング除去) も領域の外へはみ出さない。"
  (spectreshell-test--with-trailing-text (term 5 10) "$ typing"
    (spectreshell-feed term "hi")
    (let ((start (marker-position (spectreshell-marker term))))
      (should (= (spectreshell-finalize term) (+ start 3)))
      (should (equal "hi\n$ typing" (buffer-substring-no-properties
                                     start (point-max)))))))

(ert-deftest spectreshell-test-finalize-of-empty-region-adds-no-line ()
  "何も描かれなかった端末領域は空行を残さずに確定する。
出力しない背景ジョブ (=sleep 3 &= 等) の終了で、プロンプトと編集中の
コマンドラインが 1 行ぶん押し下げられてはならない。"
  (spectreshell-test--with-trailing-text (term 5 10) "$ typing"
    (let ((start (marker-position (spectreshell-marker term))))
      (should (= (spectreshell-finalize term) start))
      (should (equal "$ typing" (buffer-substring-no-properties
                                 start (point-max)))))))

(ert-deftest spectreshell-test-cursor-position-stays-inside-region ()
  "描かれていない行へのカーソル移動でも、カーソル位置は領域内に収まる。
CUP は行を dirty にしないので領域はまだ短く、素直に行送りすると
領域の後ろのプロンプトの上にカーソル位置を記録してしまう。"
  (spectreshell-test--with-trailing-text (term 5 10) "$ typing"
    (spectreshell-feed term "\x1b[4;1H")
    (should (<= (spectreshell-cursor-pos term) (spectreshell--region-end term)))))

(ert-deftest spectreshell-test-finalize-keeps-point-outside-region ()
  "領域の外に point があるまま finalize しても point は動かない。
背景ジョブの終了でコマンドライン編集中の point を奪ってはならない。"
  (spectreshell-test--with-trailing-text (term 5 10) "$ typing"
    (spectreshell-feed term "hi")
    (goto-char (point-max))
    (spectreshell-finalize term)
    ;; 確定化で領域は縮むので、位置ではなく「後ろのテキストの末尾に
    ;; いる」ことで据え置きを検査する。
    (should (= (point) (point-max)))))

(ert-deftest spectreshell-test-other-terminal-update-keeps-point ()
  "semi-char モード中でも、キー入力の宛先でない端末の更新は point を動かさない。
背景ジョブの出力のたびに前景のコマンドライン上の point が
背景ジョブのカーソルへ引きずられると、入力が成立しない。"
  (spectreshell-test--with-terminal (background 5 10)
    (goto-char (point-max))
    (insert "$ ")
    (let ((foreground (spectreshell-start (current-buffer) 5 10 #'ignore))
          (saved (point-marker)))
      (spectreshell-semi-char-mode 1)
      (setq spectreshell--current foreground)
      (spectreshell-feed background "bg output")
      (should (= (point) (marker-position saved))))))

(ert-deftest spectreshell-test-compact-region-drops-trailing-blank-rows ()
  "COMPACT の端末領域は出力のある行までしか占めない。
背景ジョブの領域は eshell のプロンプトの上に居座るので、1 行の出力で
画面いっぱいにパディングするとプロンプトが 1 画面ぶん下へ落ちる。"
  (with-temp-buffer
    (let ((term (spectreshell-start (current-buffer) 5 10 #'ignore t)))
      (goto-char (point-max))
      (insert "$ typing")
      (spectreshell-feed term "hi")
      (should (= 1 (spectreshell--row-count term)))
      (should (equal "hi        \n" (buffer-substring-no-properties
                                     (spectreshell-marker term)
                                     (spectreshell--region-end term))))
      (should (string-suffix-p "$ typing" (buffer-string))))))

(ert-deftest spectreshell-test-compact-region-regrows-for-lower-rows ()
  "COMPACT でも、下の行に描き直せば領域はそこまで伸び直す。"
  (with-temp-buffer
    (let ((term (spectreshell-start (current-buffer) 5 10 #'ignore t)))
      (spectreshell-feed term "hi")
      (should (= 1 (spectreshell--row-count term)))
      (spectreshell-feed term "\x1b[3;1Hlow")
      (should (= 3 (spectreshell--row-count term)))
      (should (string-match-p "low" (buffer-string))))))

(ert-deftest spectreshell-test-compact-region-keeps-styled-blank-rows ()
  "背景色の付いた空白だけの行は端末の実内容なので畳まれない。"
  (with-temp-buffer
    (let ((term (spectreshell-start (current-buffer) 5 10 #'ignore t)))
      (spectreshell-feed term "hi\r\n\x1b[41m          \x1b[0m")
      (should (= 2 (spectreshell--row-count term))))))

(ert-deftest spectreshell-test-non-compact-region-keeps-full-screen ()
  "既定 (前景ジョブ) の端末領域は出力が 1 行でも rows 行を保つ。
端末サイズの領域であること自体が全画面 TUI の前提になる。"
  (spectreshell-test--with-terminal (term 5 10)
    (spectreshell-feed term "hi")
    (should (= 5 (spectreshell--row-count term)))))

;; ---------------------------------------------------------------------
;; libspectreshell モジュールの自動検出・自動ロード
;; ---------------------------------------------------------------------

(ert-deftest spectreshell-test-detect-module-path-finds-local-zig-out ()
  "ライブラリと同じディレクトリの zig-out/lib/libspectreshell.so を検出できる
(ローカルの `zig build'/`just build' チェックアウトの配置)。"
  (let ((root (make-temp-file "spectreshell-module-test" t)))
    (unwind-protect
        (progn
          (make-directory (expand-file-name "zig-out/lib" root) t)
          (with-temp-file (expand-file-name "spectreshell.el" root) (insert ";; stub"))
          (with-temp-file (expand-file-name "zig-out/lib/libspectreshell.so" root) (insert ""))
          (let ((load-path (cons root load-path)))
            (should (equal (spectreshell--detect-module-path)
                            (expand-file-name "zig-out/lib/libspectreshell.so" root)))))
      (delete-directory root t))))

(ert-deftest spectreshell-test-detect-module-path-finds-local-dylib ()
  "zig が darwin 慣習で命名した zig-out/lib/libspectreshell.dylib も検出できる。"
  (let ((root (make-temp-file "spectreshell-module-test" t)))
    (unwind-protect
        (progn
          (make-directory (expand-file-name "zig-out/lib" root) t)
          (with-temp-file (expand-file-name "spectreshell.el" root) (insert ";; stub"))
          (with-temp-file (expand-file-name "zig-out/lib/libspectreshell.dylib" root) (insert ""))
          (let ((load-path (cons root load-path)))
            (should (equal (spectreshell--detect-module-path)
                            (expand-file-name "zig-out/lib/libspectreshell.dylib" root)))))
      (delete-directory root t))))

(ert-deftest spectreshell-test-detect-module-path-finds-nix-dylib-layout ()
  "nix パッケージ配置でも .dylib ($out/lib/libspectreshell.dylib) を検出できる。"
  (let ((root (make-temp-file "spectreshell-module-test" t)))
    (unwind-protect
        (progn
          (make-directory (expand-file-name "share/emacs/site-lisp" root) t)
          (make-directory (expand-file-name "lib" root) t)
          (with-temp-file (expand-file-name "share/emacs/site-lisp/spectreshell.el" root)
            (insert ";; stub"))
          (with-temp-file (expand-file-name "lib/libspectreshell.dylib" root) (insert ""))
          (let ((load-path (cons (expand-file-name "share/emacs/site-lisp" root) load-path)))
            (should (equal (spectreshell--detect-module-path)
                            (expand-file-name "lib/libspectreshell.dylib" root)))))
      (delete-directory root t))))

(ert-deftest spectreshell-test-detect-module-path-finds-nix-layout ()
  "nix パッケージの配置 ($out/share/emacs/site-lisp から見た
../../../lib/libspectreshell.so == $out/lib/libspectreshell.so) を検出できる。"
  (let ((root (make-temp-file "spectreshell-module-test" t)))
    (unwind-protect
        (progn
          (make-directory (expand-file-name "share/emacs/site-lisp" root) t)
          (make-directory (expand-file-name "lib" root) t)
          (with-temp-file (expand-file-name "share/emacs/site-lisp/spectreshell.el" root)
            (insert ";; stub"))
          (with-temp-file (expand-file-name "lib/libspectreshell.so" root) (insert ""))
          (let ((load-path (cons (expand-file-name "share/emacs/site-lisp" root) load-path)))
            (should (equal (spectreshell--detect-module-path)
                            (expand-file-name "lib/libspectreshell.so" root)))))
      (delete-directory root t))))

(ert-deftest spectreshell-test-detect-module-path-nil-when-absent ()
  "候補パスがどちらも存在しなければ nil を返す。"
  (let ((root (make-temp-file "spectreshell-module-test" t)))
    (unwind-protect
        (progn
          (with-temp-file (expand-file-name "spectreshell.el" root) (insert ";; stub"))
          (let ((load-path (cons root load-path)))
            (should (null (spectreshell--detect-module-path)))))
      (delete-directory root t))))

(ert-deftest spectreshell-test-start-autoloads-module ()
  "`spectreshell-start' が最初の呼び出しでモジュールを自動ロードする
(実運用向けの経路)。require 時点ではロードされない (ロード時副作用
なし) ことも同時に検証する。このテストファイル自身は他のテストの
ために `spectreshell' を先に `module-load' 済みで require している
ため、実際に module-load を発火させる経路は、まだ何もロードしていない
サブプロセスで検証する。"
  (let ((emacs (expand-file-name invocation-name invocation-directory)))
    (with-temp-buffer
      (let ((status (call-process
                     emacs nil t nil
                     "-Q" "--batch" "-L" spectreshell-test--repo-root
                     "--eval" "(require 'spectreshell)"
                     "--eval" "(when (fboundp 'spectreshell--create) (error \"module loaded eagerly at require time\"))"
                     "--eval" "(with-temp-buffer (spectreshell-start (current-buffer) 5 10 #'ignore))"
                     "--eval" "(unless (fboundp 'spectreshell--create) (error \"spectreshell--create not defined\"))")))
        (should (equal status 0))))))

(ert-deftest spectreshell-test-require-succeeds-without-module ()
  "モジュール未ビルドの環境でも `(require (quote spectreshell))' 自体は
成功する (init.el を巻き込んで落とさない)。エラーになるのは
`spectreshell-start' を呼んだ時点でよい。"
  (let ((emacs (expand-file-name invocation-name invocation-directory))
        (root (make-temp-file "spectreshell-no-module" t)))
    (unwind-protect
        (progn
          (copy-file (expand-file-name "spectreshell.el" spectreshell-test--repo-root)
                     (expand-file-name "spectreshell.el" root))
          (with-temp-buffer
            (let ((status (call-process
                           emacs nil t nil
                           "-Q" "--batch" "-L" root
                           "--eval" "(require 'spectreshell)"
                           "--eval" "(with-temp-buffer (unless (condition-case nil (progn (spectreshell-start (current-buffer) 5 10 #'ignore) nil) (error t)) (error \"spectreshell-start should signal without module\")))")))
              (should (equal status 0)))))
      (delete-directory root t))))

(provide 'spectreshell-test)
;;; spectreshell-test.el ends here
