;;; spectreshell-test.el --- ERT tests for spectreshell.el -*- lexical-binding: t; -*-

;; Phase 3 (spectreshell.el 描画エンジン) の完了条件である「ERT で SGR
;; 色・進捗表示 (\r)・確定化・alt screen の描画テストが通る」を満たす
;; テスト。libspectreshell.so を module-load したうえで、一時バッファに
;; `spectreshell-start' + `spectreshell-feed' した結果のバッファ内容・
;; text property を検証する。

(require 'ert)
(require 'button)

(defconst spectreshell-test--repo-root
  (expand-file-name ".." (file-name-directory (or load-file-name buffer-file-name)))
  "このリポジトリのルートディレクトリへの絶対パス。
`load-file-name'/`buffer-file-name' はロード時 (トップレベルフォーム
評価中) にしか正しく束縛されないため、ERT のテスト本体からではなく
ここでロード時に一度だけ計算しておく。")

(defconst spectreshell-test--module-path
  (expand-file-name "zig-out/lib/libspectreshell.so" spectreshell-test--repo-root)
  "テスト対象の libspectreshell.so への絶対パス。
`just test-el' が事前に `zig build' を実行して用意する。")

(unless (featurep 'spectreshell-module)
  (module-load spectreshell-test--module-path)
  (provide 'spectreshell-module))

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

(ert-deftest spectreshell-test-carriage-return-overwrites-line ()
  "\\r による上書きは同じ行の内容を新しい内容で置き換える。"
  (spectreshell-test--with-terminal (term 1 20)
    (spectreshell-feed term "progress: 1\rprogress: 2")
    (should (string-prefix-p "progress: 2" (buffer-string)))
    (should-not (string-match-p "progress: 1" (buffer-string)))))

(ert-deftest spectreshell-test-scrolled-off-lines-become-permanent-scrollback ()
  "rows を超える出力で流れ出た行が端末領域より前に確定化され、
端末領域自体は rows 行のまま保たれる。"
  (spectreshell-test--with-terminal (term 3 5)
    (spectreshell-feed term "1\r\n2\r\n3\r\n4\r\n")
    (should (string-prefix-p "1    \n2    \n" (buffer-string)))
    (should (= 3 (spectreshell--row-count term)))
    (should (string-prefix-p "3    \n4    \n     "
                             (buffer-substring (spectreshell-marker term) (point-max))))))

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

(ert-deftest spectreshell-test-resize-changes-visible-row-count ()
  "resize で端末領域の行数が新しい rows に追従する (伸縮どちらも)。"
  (spectreshell-test--with-terminal (term 3 5)
    (spectreshell-feed term "hi")
    (spectreshell-resize term 5 5)
    (should (= 5 (spectreshell--row-count term)))
    (spectreshell-resize term 2 5)
    (should (= 2 (spectreshell--row-count term)))))

(ert-deftest spectreshell-test-responses-are-sent-via-send-fn ()
  "ESC[6n の応答バイト列が SEND-FN に渡る。"
  (spectreshell-test--with-terminal (term 5 10 responses)
    (spectreshell-feed term "Hi\x1b[6n")
    (should (equal responses '("\x1b[1;3R")))))

(ert-deftest spectreshell-test-osc8-hyperlink-becomes-clickable-button ()
  "OSC 8 のリンク区間が text-property ベースの button になる。"
  (spectreshell-test--with-terminal (term 1 10)
    (spectreshell-feed term "\x1b]8;;https://example.com\x1b\\link\x1b]8;;\x1b\\")
    (let ((button (button-at (point-min))))
      (should button)
      (should (equal (button-get button 'spectreshell-hyperlink-uri) "https://example.com")))))

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

(ert-deftest spectreshell-test-finalize-releases-terminal ()
  "finalize 後は端末が release され、追加の feed が signal される。"
  (spectreshell-test--with-terminal (term 1 10)
    (spectreshell-feed term "bye")
    (let ((term-ptr (spectreshell-term term)))
      (spectreshell-finalize term)
      (should-error (spectreshell--feed term-ptr "x")
                    :type 'spectreshell-terminal-released))))

;; ---------------------------------------------------------------------
;; libspectreshell.so の自動検出・自動ロード
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

(ert-deftest spectreshell-test-require-alone-autoloads-module ()
  "`(require (quote spectreshell))' だけでモジュールが自動ロードされる
(実運用向けの経路)。このテストファイル自身は他のテストのために
`spectreshell' を先に `module-load' 済みで require しているため、
同一プロセス内では `spectreshell-ensure-module-loaded' の no-op 分岐
しか検証できない。実際に module-load を発火させる経路は、まだ
何もロードしていないサブプロセスで別途検証する。"
  (let ((emacs (expand-file-name invocation-name invocation-directory)))
    (with-temp-buffer
      (let ((status (call-process
                     emacs nil t nil
                     "-Q" "--batch" "-L" spectreshell-test--repo-root
                     "--eval" "(require 'spectreshell)"
                     "--eval" "(unless (fboundp 'spectreshell--create) (error \"spectreshell--create not defined\"))")))
        (should (equal status 0))))))

(provide 'spectreshell-test)
;;; spectreshell-test.el ends here
