;;; spectreshell-explore-stderr-test.el --- 探索的テスト (stderr) の Probe -*- lexical-binding: t; -*-

;; 2026-09-05 の探索的テスト (worker 9 / 方向名 stderr) の Probe。
;; ghostty-vt の std.log がプロセスの stderr (= emacs -nw では端末そのもの)
;; へ直接書かれ、Emacs の画面を壊す件 (F-geometry-2 / F-apps-9 / F-apps-10 /
;; F-stderr-1〜6) を batch で固定する。
;; 子 Emacs を `call-process' で起こして stderr を別ファイルに分けるので、
;; 実端末なしで「モジュールが stderr へ書くか」を判定できる。
;; 現状では書かれてしまうので `:expected-result :failed' を付けてある。
;; 観察の記録は docs/issues.org の該当項目を参照 (2026-09-05 の探索的テスト)。

(require 'ert)
(require 'spectreshell-test-helper)
(require 'spectreshell)

(defun spectreshell-explore-stderr-test--feed-in-subprocess (bytes)
  "子 Emacs で BYTES を端末に feed し、その stderr の中身を返す。
親プロセスの stderr を汚さずに測るために子を起こす。
`call-process' の DESTINATION に (BUFFER . STDERR-FILE) を渡すと
stderr だけ別ファイルへ分けられる。"
  (let* ((errfile (make-temp-file "spectreshell-stderr-probe"))
         (expr (format "(progn (module-load %S)
                          (let ((term (spectreshell--create 21 79)))
                            (spectreshell--feed term %S)
                            (spectreshell--release term)))"
                       spectreshell-test--module-path bytes)))
    (unwind-protect
        (progn
          (call-process (expand-file-name invocation-name invocation-directory)
                        nil (list nil errfile) nil
                        "-Q" "--batch" "--eval" expr)
          (with-temp-buffer
            (insert-file-contents errfile)
            (buffer-string)))
      (delete-file errfile))))

(ert-deftest spectreshell-explore-stderr-test-harness-is-sane ()
  "対照: 普通の文字を feed した子 Emacs の stderr は空。
これが失敗したら以下の `:expected-result :failed' 群は
「モジュールが警告を書いた」ではなく「子 Emacs 自体が壊れた」で
失敗していることになるので、ハーネスの健全性検査として先に置く。"
  (should (equal (spectreshell-explore-stderr-test--feed-in-subprocess "hello") "")))

(ert-deftest spectreshell-explore-stderr-test-csi-22-1-t-is-silent ()
  "vim が起動時に送る ESC [ 22 ; 1 t が stderr へ何も書かない。
ghostty-vt は XTWINOPS の 22/23 をタイトル (第 2 引数 0 か 2) しか
実装しておらず、アイコン (1) を `log.warn' で捨てる。その警告は
zig 既定の logFn で fd 2 へ直接書かれるため、emacs -nw では端末に
そのまま現れて画面表現とずれる。"
  :expected-result :failed
  (should (equal (spectreshell-explore-stderr-test--feed-in-subprocess "\e[22;1t") "")))

(ert-deftest spectreshell-explore-stderr-test-zero-width-leading-is-silent ()
  "行頭のゼロ幅文字 (U+200B) が stderr へ何も書かない (F-geometry-2)。"
  :expected-result :failed
  (should (equal (spectreshell-explore-stderr-test--feed-in-subprocess "​") "")))

(ert-deftest spectreshell-explore-stderr-test-unimplemented-mode-is-silent ()
  "未実装のプライベートモード (ESC [ ? 9999 h) が stderr へ何も書かない。
1..2031 のうち 1996 個がこの経路で警告を出す。"
  :expected-result :failed
  (should (equal (spectreshell-explore-stderr-test--feed-in-subprocess "\e[?9999h") "")))

(ert-deftest spectreshell-explore-stderr-test-info-level-also-leaks ()
  "info レベルのログ (未知の DCS hook) も stderr へ出る。
nix ビルドは --release=safe なので zig の既定 log_level は info であり、
`log.warn' だけでなく `log.info' も端末へ漏れる (F-stderr-1)。"
  :expected-result :failed
  (should (equal (spectreshell-explore-stderr-test--feed-in-subprocess "\ePxfoo\e\\") "")))

(provide 'spectreshell-explore-stderr-test)
;;; spectreshell-explore-stderr-test.el ends here
