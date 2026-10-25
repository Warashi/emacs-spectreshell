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
  (let ((spectreshell-synchronized-timeout 0.05))
    (spectreshell-test--with-terminal (term 1 10)
      (spectreshell-feed term "\x1b[?2026hab")
      (should-not (string-prefix-p "ab" (buffer-string)))
      (sleep-for 0.2)
      (should (string-prefix-p "ab" (buffer-string))))))

(ert-deftest spectreshell-test-synchronized-timeout-is-not-extended-by-feeds ()
  "保留が続く feed が来続けても、タイムアウトは最初の保留から数える。
フレームの継ぎ目が毎回 feed の途中に来ると、閉じた feed が来ない。"
  (let ((spectreshell-synchronized-timeout 0.1))
    (spectreshell-test--with-terminal (term 1 10)
      (spectreshell-feed term "\x1b[?2026ha")
      (sleep-for 0.06)
      (spectreshell-feed term "\x1b[?2026l\x1b[?2026hb")
      (sleep-for 0.06)
      (should (string-prefix-p "ab" (buffer-string))))))

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
  `(let ((spectreshell--glyph-fit-cache (make-hash-table)))
     (cl-letf (((symbol-function 'frame-char-width) (lambda (&rest _) 10))
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
  (let ((spectreshell--glyph-fit-cache (make-hash-table)))
    (spectreshell-test--with-terminal (term 1 10)
      (spectreshell-feed term "⏱❌")
      (should-not (text-property-not-all (point-min) (line-end-position)
                                         'display nil)))))

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
;; OSC 52 の書き込みの中継 (M-24)
;; ---------------------------------------------------------------------

(defvar xterm-max-cut-length)

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

(ert-deftest spectreshell-test-osc52-write-reaches-selection-terminals ()
  "子の OSC 52 の書き込みは、xterm.el が OSC 52 を使うと判定した外側の
端末にだけ同じ形で届く。外側の書き込みの可否は外側の設定に従う。"
  (spectreshell-test--with-terminal (term 1 10)
    (spectreshell-test--with-relay-terminals '(t1 t2) '(t1) sent
      (spectreshell-feed term "\x1b]52;c;aGk=\x07")
      (should (equal sent '(("\e]52;c;aGk=\a" . t1)))))))

(ert-deftest spectreshell-test-osc52-write-reaches-terminal-while-synchronized ()
  "mode 2026 の中でも OSC 52 の書き込みは待たずに届く。"
  (spectreshell-test--with-terminal (term 1 10)
    (spectreshell-test--with-relay-terminals '(t1) '(t1) sent
      (spectreshell-feed term "\x1b[?2026h\x1b]52;c;aGk=\x07")
      (should (equal sent '(("\e]52;c;aGk=\a" . t1)))))))

(ert-deftest spectreshell-test-osc52-write-drops-unsafe-or-long-data ()
  "base64 以外の文字を含む書き込みと、`xterm-max-cut-length' を超える
書き込みは外側へ送らない。前者は子に外側の端末へ任意の文字列を書かせないため、
後者は xterm.el 自身の書き込みと同じ上限に揃えるため。"
  (spectreshell-test--with-terminal (term 1 10)
    (spectreshell-test--with-relay-terminals '(t1) '(t1) sent
      (let ((xterm-max-cut-length 4))
        (spectreshell-feed term "\x1b]52;c;aG;k=\x07")
        (spectreshell-feed term "\x1b]52;c;aGk=aGk=\x07")
        (should (null sent))))))

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
