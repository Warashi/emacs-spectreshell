;;; spectreshell-test-helper.el --- 共有テストヘルパー -*- lexical-binding: t; -*-

;; 各テストファイルが個別に持っていたモジュールパスの計算と module-load
;; を1箇所に集約する。ファイルごとに defconst を重複定義すると、計算方法
;; の食い違いやロード順による上書きの紛らわしさが生じるため。

(defconst spectreshell-test--repo-root
  (expand-file-name ".." (file-name-directory (or load-file-name buffer-file-name)))
  "このリポジトリのルートディレクトリへの絶対パス。
`load-file-name'/`buffer-file-name' はロード時 (トップレベルフォーム
評価中) にしか正しく束縛されないため、ERT のテスト本体からではなく
ここでロード時に一度だけ計算しておく。")

(defconst spectreshell-test--module-path
  (let ((candidates
         ;; zig は共有ライブラリをターゲット慣習で命名する (Linux は
         ;; .so、darwin は .dylib) ため、両方の拡張子を候補にする。
         (mapcar (lambda (name)
                   (expand-file-name name spectreshell-test--repo-root))
                 '("zig-out/lib/libspectreshell.so"
                   "zig-out/lib/libspectreshell.dylib"))))
    (or (seq-find #'file-exists-p candidates)
        (error "spectreshell-test: モジュールが見つからない (tried: %s)"
               (mapconcat #'identity candidates ", "))))
  "テスト対象の libspectreshell モジュールへの絶対パス。
`just test-el' が事前に `zig build' を実行して用意する。")

(unless (featurep 'spectreshell-module)
  (module-load spectreshell-test--module-path)
  (provide 'spectreshell-module))

(provide 'spectreshell-test-helper)
;;; spectreshell-test-helper.el ends here
