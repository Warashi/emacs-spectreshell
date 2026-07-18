;;; spectreshell-eshell-test.el --- ERT integration tests for spectreshell-eshell.el -*- lexical-binding: t; -*-

;; Phase 5 (spectreshell-eshell.el) の完了条件である「ERT 統合テストが
;; 通る」を満たすテスト。`emacs -batch' から実際に eshell バッファで
;; 外部プロセス (printf/sleep/false/cat) を走らせ、
;; `spectreshell-eshell-mode' がプロセスの出力を spectreshell 経由で
;; 描画し、semi-char モードの出入りとプロンプトへの復帰を正しく行う
;; ことを検証する。batch モードにはウィンドウがないため、
;; `spectreshell-eshell--terminal-size' の 80x24 フォールバック経路が
;; 常に使われる。

(require 'ert)
(require 'cl-lib)
(require 'eshell)

(defconst spectreshell-test--module-path
  (expand-file-name "../zig-out/lib/libspectreshell.so"
                     (file-name-directory (or load-file-name buffer-file-name)))
  "テスト対象の libspectreshell.so への絶対パス。
`just test-el' が事前に `zig build' を実行して用意する。")

(unless (featurep 'spectreshell-module)
  (module-load spectreshell-test--module-path)
  (provide 'spectreshell-module))

(require 'spectreshell)
(require 'spectreshell-eshell)

;; ---------------------------------------------------------------------
;; テストヘルパー
;; ---------------------------------------------------------------------

(defconst spectreshell-eshell-test--timeout 10
  "このファイルの待機ヘルパーが1回のポーリングでブロックしてよい上限秒数。
CI での flaky さを避けるため、無限ループにはせずここで確実に諦める。")

(defun spectreshell-eshell-test--wait-until (predicate)
  "PREDICATE (引数なし関数) が non-nil を返すまでポーリングして待つ。
`accept-process-output' で待ちつつ、
`spectreshell-eshell-test--timeout' 秒を過ぎたら諦める。戻り値は
PREDICATE の最終的な値なので、呼び出し側はこれを `should' に渡せば
タイムアウトをテスト失敗として検出できる。"
  (let ((deadline (time-add (current-time) spectreshell-eshell-test--timeout)))
    (while (and (not (funcall predicate))
                (time-less-p (current-time) deadline))
      (accept-process-output nil 0.05))
    (funcall predicate)))

(defun spectreshell-eshell-test--wait-for-command (buffer)
  "BUFFER で現在実行中の eshell コマンドが終わるまで待つ。"
  (spectreshell-eshell-test--wait-until
   (lambda () (with-current-buffer buffer (null (eshell-tail-process))))))

(defun spectreshell-eshell-test--kill-buffer (buffer)
  "BUFFER (とそこに残っている可能性のあるプロセス) を問い合わせなしで消す。"
  (when (buffer-live-p buffer)
    (let ((kill-buffer-query-functions nil)
          (eshell-kill-processes-on-exit t))
      (kill-buffer buffer))))

(defmacro spectreshell-eshell-test--with-eshell (buffer-var &rest body)
  "`spectreshell-eshell-mode' を有効にした新規 eshell バッファで BODY を実行する.
BUFFER-VAR にそのバッファを束縛する。BODY の前後で `spectreshell-eshell-mode'
のグローバル状態を元に戻し、バッファ (と残っていれば中のプロセス) は
BODY がエラーで抜けても確実に kill する。"
  (declare (indent 1))
  (let ((was-on (gensym "spectreshell-eshell-test-was-on")))
    `(let ((,was-on spectreshell-eshell-mode))
       (unwind-protect
           (progn
             (spectreshell-eshell-mode 1)
             (let ((,buffer-var (eshell t)))
               (unwind-protect
                   (progn ,@body)
                 (spectreshell-eshell-test--kill-buffer ,buffer-var))))
         (spectreshell-eshell-mode (if ,was-on 1 -1))))))

(defun spectreshell-eshell-test--send (buffer input)
  "BUFFER の末尾に INPUT を挿入し、コマンドとして送信する。"
  (with-current-buffer buffer
    (goto-char (point-max))
    (insert input)
    (eshell-send-input)))

(defun spectreshell-eshell-test--prompt-shown-p (buffer)
  "BUFFER が現在末尾にプロンプトを表示していれば non-nil を返す。
`em-prompt.el' の `eshell-emit-prompt' はプロンプト文字列全体に
`field' プロパティ `prompt' を付けるので、その有無で判定できる。"
  (with-current-buffer buffer
    (and (> (point-max) (point-min))
         (eq (get-text-property (1- (point-max)) 'field) 'prompt))))

;; ---------------------------------------------------------------------
;; 色付き出力 + プロンプト復帰
;; ---------------------------------------------------------------------

(ert-deftest spectreshell-eshell-test-colored-output-renders-and-prompt-returns ()
  "SGR 付き printf 出力が face 付きで描画され、コマンド後にプロンプトへ戻る。"
  (spectreshell-eshell-test--with-eshell buf
    (spectreshell-eshell-test--send buf "printf 'A\\033[31mB\\033[0m\\n'")
    (should (spectreshell-eshell-test--wait-for-command buf))
    (should (spectreshell-eshell-test--wait-until
             (lambda () (spectreshell-eshell-test--prompt-shown-p buf))))
    (with-current-buffer buf
      (save-excursion
        (goto-char (point-min))
        (should (search-forward "AB" nil t))
        ;; "B" (見つけた位置の直前の文字) に色付きの face が乗っている。
        (should (get-text-property (1- (point)) 'face))))))

;; ---------------------------------------------------------------------
;; rows を超える出力のスクロールアウト確定化
;; ---------------------------------------------------------------------

(ert-deftest spectreshell-eshell-test-output-past-rows-is-fully-committed ()
  "端末の rows (batch では 24) を超える行数を出しても、全行バッファに残る。"
  (spectreshell-eshell-test--with-eshell buf
    (spectreshell-eshell-test--send
     buf (format "printf '%%d\\n' %s"
                  (mapconcat #'number-to-string (number-sequence 1 40) " ")))
    (should (spectreshell-eshell-test--wait-for-command buf))
    (with-current-buffer buf
      (let ((lines (mapcar #'string-trim-right (split-string (buffer-string) "\n"))))
        (dolist (n (number-sequence 1 40))
          (should (member (number-to-string n) lines)))))))

;; ---------------------------------------------------------------------
;; semi-char モードの出入り
;; ---------------------------------------------------------------------

(ert-deftest spectreshell-eshell-test-semi-char-mode-during-then-off-after ()
  "実行中は semi-char モードに入り、終了後には抜けている。"
  (spectreshell-eshell-test--with-eshell buf
    (spectreshell-eshell-test--send buf "sleep 0.3")
    (should (spectreshell-eshell-test--wait-until
             (lambda () (with-current-buffer buf spectreshell-semi-char-mode))))
    (should (spectreshell-eshell-test--wait-for-command buf))
    (with-current-buffer buf
      (should-not spectreshell-semi-char-mode))))

;; ---------------------------------------------------------------------
;; 非0終了コード
;; ---------------------------------------------------------------------

(ert-deftest spectreshell-eshell-test-nonzero-exit-still-recovers ()
  "非0終了のコマンドでも semi-char を抜けて通常のプロンプトに戻る。"
  (spectreshell-eshell-test--with-eshell buf
    (spectreshell-eshell-test--send buf "false")
    (should (spectreshell-eshell-test--wait-for-command buf))
    (should (spectreshell-eshell-test--wait-until
             (lambda () (spectreshell-eshell-test--prompt-shown-p buf))))
    (with-current-buffer buf
      (should-not spectreshell-semi-char-mode)
      (should (= eshell-last-command-status 1)))))

;; ---------------------------------------------------------------------
;; sentinel の堅牢性
;; ---------------------------------------------------------------------

(ert-deftest spectreshell-eshell-test-detach-error-does-not-block-eshell-sentinel ()
  "detach が signal しても eshell-sentinel は必ず実行される。
実行されないと eshell-process-list からプロセスが消えず、eshell は
コマンド実行中のまま次のプロンプトを出せなくなる。batch モードでは
sentinel 内で escape したエラーが Emacs ごと落とすため、実プロセスは
使わず sentinel 関数を直接呼んで検証する。"
  (let ((sentinel-ran nil))
    (cl-letf (((symbol-function 'spectreshell-eshell--detach)
               (lambda (_proc)
                 (error "spectreshell-eshell-test: injected detach failure")))
              ((symbol-function 'eshell-sentinel)
               (lambda (_proc _string) (setq sentinel-ran t)))
              ((symbol-function 'process-live-p) (lambda (_proc) nil)))
      (should-error (spectreshell-eshell--sentinel 'fake-proc "finished\n"))
      (should sentinel-ran))))

;; ---------------------------------------------------------------------
;; キー送信経路の統合確認 (process-send-string 経由のエコー)
;; ---------------------------------------------------------------------

(ert-deftest spectreshell-eshell-test-typed-input-echoes-through-pty ()
  "*cat への process-send-string 入力が PTY エコー経由で描画される。
`*' プレフィックスで `eshell/cat' (Lisp 実装) をバイパスし、実プロセス
としての外部 cat を強制する (docs/design.org のキー送信経路は
`spectreshell-send-key'/`spectreshell-yank' が担うが、それらが最終的に
呼ぶ `process-send-string' 自体がここで検証したい統合経路)。"
  (spectreshell-eshell-test--with-eshell buf
    (spectreshell-eshell-test--send buf "*cat")
    (should (spectreshell-eshell-test--wait-until
             (lambda () (with-current-buffer buf
                          (and spectreshell-eshell--process
                               (process-live-p spectreshell-eshell--process))))))
    (process-send-string (with-current-buffer buf spectreshell-eshell--process) "hello\n")
    (should (spectreshell-eshell-test--wait-until
             (lambda () (with-current-buffer buf
                          (string-match-p "hello" (buffer-string))))))
    (process-send-string (with-current-buffer buf spectreshell-eshell--process) "\C-d")
    (should (spectreshell-eshell-test--wait-for-command buf))))

;; ---------------------------------------------------------------------
;; em-term.el の visual-command 迂回のバイパス
;; ---------------------------------------------------------------------

(ert-deftest spectreshell-eshell-test-visual-command-stays-in-eshell-buffer ()
  "less (eshell-visual-commands) が別 term バッファへ逃げず eshell 内で動く。
`em-term.el' はデフォルトで `less' を `eshell-exec-visual' へ回して
専用の `term-mode' バッファに逃がすが、それでは spectreshell が全く
関与できない (docs/design.org の \"visual command の別バッファ逃がしは
不要になる\" という決定の裏付け)。"
  (skip-unless (executable-find "less"))
  (spectreshell-eshell-test--with-eshell buf
    (let ((buffer-count-before (length (buffer-list))))
      (spectreshell-eshell-test--send buf "less docs/design.org")
      (should (spectreshell-eshell-test--wait-until
               (lambda () (with-current-buffer buf
                            (and spectreshell-eshell--process
                                 (process-live-p spectreshell-eshell--process))))))
      (with-current-buffer buf
        (should spectreshell-semi-char-mode))
      ;; `eshell-exec-visual' would have created and displayed a new
      ;; `term-mode' buffer; none should exist here.
      (should (= buffer-count-before (length (buffer-list))))
      (process-send-string (with-current-buffer buf spectreshell-eshell--process) "q")
      (should (spectreshell-eshell-test--wait-for-command buf))
      (with-current-buffer buf
        (should-not spectreshell-semi-char-mode)))))

;; ---------------------------------------------------------------------
;; 同梱 terminfo の自動検出
;; ---------------------------------------------------------------------

(defmacro spectreshell-eshell-test--with-fake-library (root-var files &rest body)
  "Run BODY with ROOT-VAR bound to a fresh temp dir laid out per FILES.
FILES is a list of relative paths; each is created as an empty file (or
directory, if it ends in \"/\"), with intermediate directories made as
needed.  Deletes ROOT-VAR's whole tree afterwards regardless of how BODY
exits."
  (declare (indent 2))
  `(let ((,root-var (make-temp-file "spectreshell-terminfo-test" t)))
     (unwind-protect
         (progn
           (dolist (rel ,files)
             (let ((path (expand-file-name rel ,root-var)))
               (if (string-suffix-p "/" rel)
                   (make-directory path t)
                 (make-directory (file-name-directory path) t)
                 (with-temp-file path (insert ";; stub")))))
           ,@body)
       (delete-directory ,root-var t))))

(ert-deftest spectreshell-eshell-test-detect-terminfo-directory-finds-local-zig-out ()
  "ライブラリと同じディレクトリの zig-out/share/terminfo を検出できる
(ローカルの `zig build'/`just build' チェックアウトの配置)。"
  (spectreshell-eshell-test--with-fake-library
      root '("spectreshell.el" "zig-out/share/terminfo/")
    (let ((load-path (cons root load-path)))
      (should (equal (spectreshell--detect-terminfo-directory)
                      (expand-file-name "zig-out/share/terminfo" root))))))

(ert-deftest spectreshell-eshell-test-detect-terminfo-directory-finds-nix-layout ()
  "nix パッケージの配置 ($out/share/emacs/site-lisp から見た
../../terminfo == $out/share/terminfo) を検出できる。"
  (spectreshell-eshell-test--with-fake-library
      root '("share/emacs/site-lisp/spectreshell.el" "share/terminfo/")
    (let ((load-path (cons (expand-file-name "share/emacs/site-lisp" root) load-path)))
      (should (equal (spectreshell--detect-terminfo-directory)
                      (expand-file-name "share/terminfo" root))))))

(ert-deftest spectreshell-eshell-test-detect-terminfo-directory-nil-when-absent ()
  "候補ディレクトリがどちらも存在しなければ nil を返す。"
  (spectreshell-eshell-test--with-fake-library
      root '("spectreshell.el")
    (let ((load-path (cons root load-path)))
      (should (null (spectreshell--detect-terminfo-directory))))))

;; ---------------------------------------------------------------------
;; TERM 決定ロジック (xterm-ghostty -> xterm-256color フォールバック)
;; ---------------------------------------------------------------------

(ert-deftest spectreshell-eshell-test-effective-term-name-falls-back-without-terminfo ()
  "既定値 xterm-ghostty のまま terminfo が見つからなければ xterm-256color にフォールバックする。"
  (let ((spectreshell-term-name "xterm-ghostty")
        (spectreshell-terminfo-directory nil))
    (should (equal (spectreshell-eshell--effective-term-name) "xterm-256color"))))

(ert-deftest spectreshell-eshell-test-effective-term-name-keeps-xterm-ghostty-when-terminfo-found ()
  "terminfo が見つかっていれば xterm-ghostty のまま送出する。"
  (let ((spectreshell-term-name "xterm-ghostty")
        (spectreshell-terminfo-directory "/some/dir"))
    (should (equal (spectreshell-eshell--effective-term-name) "xterm-ghostty"))))

(ert-deftest spectreshell-eshell-test-effective-term-name-respects-explicit-override ()
  "TERM をユーザーが明示的に変更していれば terminfo の有無に関わらずそのまま使う。"
  (let ((spectreshell-term-name "screen")
        (spectreshell-terminfo-directory nil))
    (should (equal (spectreshell-eshell--effective-term-name) "screen"))))

(provide 'spectreshell-eshell-test)
;;; spectreshell-eshell-test.el ends here
