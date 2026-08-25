;;; spectreshell-key-table-test.el --- キーストローク -> PTY バイト列の網羅表 -*- lexical-binding: t; -*-

;; semi-char モードで送るキー面を 1 枚の表に並べ、「その打鍵で PTY に出る
;; バイト列」を固定する退行検出用のテスト。
;;
;; spectreshell-key-test.el の正規化テストが `spectreshell--event-to-key' の
;; 戻り値を手書きの期待値と突き合わせるのに対し、こちらは実キーイベントから
;; send-fn に届くバイト列までを通しで見る。両者の継ぎ目 (正規化は正しいが
;; エンコード結果が意図と違う、キーマップに束縛が無くて送信自体が起きない)
;; は片側だけの単体テストでは素通りするため、通しの表を別に持つ。
;;
;; 期待値は xterm 系端末の慣習 (CSI / SS3 シーケンス、C0 制御文字) から
;; 手書きする。モジュールの出力をそのまま焼き付けると退行を「正しい値」と
;; して固定してしまい、この表の目的が失われる。

(require 'ert)
(require 'spectreshell-test-helper)
(require 'spectreshell)
;; `spectreshell-test--with-terminal' も一緒に持ってくる (spectreshell-test.el 参照)。
(require 'spectreshell-test)

;; ---------------------------------------------------------------------
;; ハーネス
;; ---------------------------------------------------------------------

(defun spectreshell-key-table-test--bytes (keys &optional feed)
  "Return the bytes KEYS sends to the PTY when typed in semi-char mode.
KEYS is either a `kbd' string or a key vector.  FEED, when non-nil, is fed
to the terminal first to put it in a particular mode (e.g. \"\\e[?1h\" for
DECCKM); the terminal's own replies to FEED are dropped so that only the
bytes produced by KEYS are returned.  Concatenates every send-fn call, so
a key that sends nothing at all yields \"\"."
  (let ((result nil))
    (spectreshell-test--with-terminal (term 5 20 responses)
      ;; `with-temp-buffer' のバッファは選択ウィンドウに出ないため、
      ;; `execute-kbd-macro' のコマンドループはそちらを見てくれない
      ;; (spectreshell-key-test.el の execute-kbd-macro テスト参照)。
      (let ((buf (generate-new-buffer "spectreshell-key-table-test")))
        (unwind-protect
            (save-window-excursion
              (switch-to-buffer buf)
              (spectreshell-semi-char-mode 1)
              (setq spectreshell--current term)
              (when feed (spectreshell-feed term feed))
              (setq responses nil)
              (execute-kbd-macro (if (stringp keys) (kbd keys) keys))
              (setq result (apply #'concat (reverse responses))))
          (kill-buffer buf))))
    result))

(defmacro spectreshell-key-table-test--deftests (expected-result &rest rows)
  "Define one ERT test per ROWS entry, each with EXPECTED-RESULT.
Each row is (KEYS EXPECTED &optional FEED DOC): KEYS is what the user
types (a `kbd' string or a key vector), EXPECTED the bytes that must
reach the PTY, FEED an optional terminal mode setup string.  One test per
row rather than one test per table so that a row flipping from failing to
passing is reported on its own (ERT only reports an unexpected pass when
every `should' in the test passes)."
  (declare (indent 1))
  `(progn
     ,@(mapcar
        (lambda (row)
          (let ((keys (nth 0 row))
                (expected (nth 1 row))
                (feed (nth 2 row))
                (doc (nth 3 row)))
            `(ert-deftest ,(intern (format "spectreshell-key-table-test-%s%s"
                                           (if (stringp keys) keys (format "%S" keys))
                                           ;; 同じキーを端末モード違いで複数行
                                           ;; 置く (DECCKM の on/off) ため、
                                           ;; FEED もテスト名に混ぜて衝突を防ぐ。
                                           (if feed (format "-after-%S" feed) "")))
                 ()
               ,(or doc (if feed
                            (format "%s を %S 直後に打つと %S を送る。" keys feed expected)
                          (format "%s は %S を送る。" keys expected)))
               :expected-result ,expected-result
               (should (equal (spectreshell-key-table-test--bytes ,keys ,feed)
                              ,expected)))))
        rows)))

;; ---------------------------------------------------------------------
;; 送れているキー
;; ---------------------------------------------------------------------

(spectreshell-key-table-test--deftests :passed
  ;; 印字可能 ASCII。self-insert-command の remap 経由で送る。
  ("a" "a")
  ("z" "z")
  ("A" "A")
  ("Z" "Z")
  ("0" "0")
  ("9" "9")
  ("SPC" " ")
  ("!" "!")
  ("%" "%")
  ("@" "@")
  ("~" "~")
  ([?\C-\S-a] "\C-a")

  ;; 制御文字。C-c / C-u / C-x / C-y は design.org の例外で Emacs 側に残る。
  ("C-a" "\C-a")
  ("C-b" "\C-b")
  ("C-d" "\C-d")
  ("C-z" "\C-z")

  ;; メタ。ESC 前置で送る。
  ("M-a" "\ea")
  ("M-f" "\ef")
  ("M-z" "\ez")
  ("M-A" "\eA")

  ;; C-M-<letter>。ESC 前置 + 制御文字。
  ("C-M-a" "\e\C-a")

  ;; TAB/RET/ESC/DEL。端末フレームは生の制御文字、GUI フレームはシンボル
  ;; 形で届くので両方を表に置く (ESC は生の 27 がプレフィックスキーの
  ;; ため、束縛があるのはシンボル形だけ)。
  ("TAB" "\t")
  ("<tab>" "\t")
  ("RET" "\r")
  ("<return>" "\r")
  ("<escape>" "\e")
  ("DEL" "\d")
  ("<backspace>" "\d")

  ;; 修飾付きの TAB/RET/DEL。修飾子ビットを剥がした文字で判定するので、
  ;; 生の制御文字に meta が乗った形でも特殊キー扱いになる。
  ("M-RET" "\e\r")
  ;; GUI のシンボル形は修飾子ごとに別イベントなので個別の束縛で拾う。
  ("C-<backspace>" "\C-h")

  ;; 矢印。DECCKM オフでは CSI、オンでは SS3。
  ("<up>" "\e[A")
  ("<down>" "\e[B")
  ("<right>" "\e[C")
  ("<left>" "\e[D")
  ("<up>" "\eOA" "\e[?1h")
  ("<down>" "\eOB" "\e[?1h")
  ("<right>" "\eOC" "\e[?1h")
  ("<left>" "\eOD" "\e[?1h")

  ;; 編集キー。
  ("<home>" "\e[H")
  ("<end>" "\e[F")
  ("<prior>" "\e[5~")
  ("<next>" "\e[6~")
  ("<insert>" "\e[2~")
  ("<delete>" "\e[3~")

  ;; ファンクションキー。F1-F4 は SS3、F5 以降は CSI ~ 形式。
  ("<f1>" "\eOP")
  ("<f2>" "\eOQ")
  ("<f3>" "\eOR")
  ("<f4>" "\eOS")
  ("<f5>" "\e[15~")
  ("<f6>" "\e[17~")
  ("<f7>" "\e[18~")
  ("<f8>" "\e[19~")
  ("<f9>" "\e[20~")
  ("<f10>" "\e[21~")
  ("<f11>" "\e[23~")
  ("<f12>" "\e[24~")

  ;; 修飾付き矢印。CSI 1 ; <修飾子> <終端> 形式で、修飾子は
  ;; 1 + shift(1) + alt(2) + ctrl(4)。
  ("S-<up>" "\e[1;2A")
  ("M-<up>" "\e[1;3A")
  ("C-<up>" "\e[1;5A")
  ("C-M-<up>" "\e[1;7A")
  ("C-<right>" "\e[1;5C"))

;; ---------------------------------------------------------------------
;; 既知の穴 (docs/issues.org L-2)
;; ---------------------------------------------------------------------

;; 期待値は「本来送るべきバイト列」で、現状は束縛や正規化が無いために
;; 一致しない。行を削らず :expected-result :failed で残すのは、削ると表の
;; 網羅が見た目だけになって穴が不可視になるのと、直したときに ERT が
;; unexpected pass として報告してくれるため。
(spectreshell-key-table-test--deftests :failed
  ;; GUI の S-TAB。`backtab' シンボルは tab + shift への読み替えが要る
  ;; (docs/issues.org L-2)。
  ("<backtab>" "\e[Z"))

(provide 'spectreshell-key-table-test)
;;; spectreshell-key-table-test.el ends here
