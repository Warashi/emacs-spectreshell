;;; spectreshell-key-test.el --- ERT tests for spectreshell.el key input -*- lexical-binding: t; -*-

;; Phase 4 (キー入力) の完了条件である「モード切替とキー送信の ERT が
;; 通る」を満たすテストの一部。まずはキーイベント正規化
;; (`spectreshell--event-to-key') 単体を検証する
;; (libspectreshell.so の module-load は不要: この関数は純粋な Elisp)。

(require 'ert)
(require 'spectreshell)

;; ---------------------------------------------------------------------
;; イベント正規化
;; ---------------------------------------------------------------------

(ert-deftest spectreshell-key-test-plain-printable-char ()
  "印字可能な平文字 ?a は修飾子なしの \"a\" に正規化される。"
  (should (equal (spectreshell--event-to-key ?a) '("a"))))

(ert-deftest spectreshell-key-test-control-letter ()
  "?\\C-a は ctrl 修飾子付きの \"a\" に復元される。"
  (should (equal (spectreshell--event-to-key ?\C-a) '("a" ctrl))))

(ert-deftest spectreshell-key-test-meta-letter ()
  "?\\M-f は alt 修飾子付きの \"f\" に正規化される (meta -> alt)。"
  (should (equal (spectreshell--event-to-key ?\M-f) '("f" alt))))

(ert-deftest spectreshell-key-test-control-meta-letter ()
  "?\\C-\\M-a は ctrl と alt の両方が立つ。"
  (should (equal (spectreshell--event-to-key ?\C-\M-a) '("a" ctrl alt))))

(ert-deftest spectreshell-key-test-tab-return-escape-backspace ()
  "TAB/RET/ESC/DEL は C-i/C-m/C-[/C-? ではなく専用シンボルになる。"
  (should (equal (spectreshell--event-to-key ?\t) '(tab)))
  (should (equal (spectreshell--event-to-key ?\r) '(return)))
  (should (equal (spectreshell--event-to-key ?\e) '(escape)))
  (should (equal (spectreshell--event-to-key ?\C-?) '(backspace))))

(ert-deftest spectreshell-key-test-space ()
  "スペースは特別扱いされず長さ1の文字列になる。"
  (should (equal (spectreshell--event-to-key ?\s) '(" "))))

;; `spectreshell-key-test-function-key-symbol' と
;; `spectreshell-key-test-control-shift-combination' (`up'/`f5' 等の
;; function key シンボル) は spectreshell-semi-char-mode-map 追加後の
;; テストファイルに含まれる: `event-basic-type'/`event-modifiers' は
;; そのセッションでまだ一度も使われていないシンボルには nil を返すことが
;; あり (docstring 参照)、`spectreshell-semi-char-mode-map' が define-key
;; 経由でこれらのシンボルに触れることが実質的なウォームアップになる。

(ert-deftest spectreshell-key-test-unrecognized-event-is-nil ()
  "マウスイベント等、対応する KEY がないイベントは nil になる。"
  (should (null (spectreshell--event-to-key 'mouse-1))))

(provide 'spectreshell-key-test)
;;; spectreshell-key-test.el ends here
