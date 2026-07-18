;;; spectreshell-module-test.el --- ERT smoke tests for libspectreshell.so -*- lexical-binding: t; -*-

;; Phase 2 (モジュール境界) の完了条件である「emacs -batch から create →
;; feed → 戻り値検証のスモークテストが通る」を満たすためのテスト。
;; docs/module-api.md の plist 仕様と、emacs-module の unibyte/multibyte
;; 文字列の挙動 (copy_string_contents / make_unibyte_string) を実証する。

(require 'ert)

(defconst spectreshell-test--module-path
  (expand-file-name "../zig-out/lib/libspectreshell.so"
                     (file-name-directory (or load-file-name buffer-file-name)))
  "テスト対象の libspectreshell.so への絶対パス。
`just test-el' が事前に `zig build' を実行して用意する。")

(unless (featurep 'spectreshell-module)
  (module-load spectreshell-test--module-path)
  (provide 'spectreshell-module))

(ert-deftest spectreshell-module-test-create-and-feed-returns-dirty-row ()
  "feed \"hello\" した直後の :dirty に行0のテキスト \"hello...\" が含まれる。"
  (let* ((term (spectreshell--create 5 10))
         (update (spectreshell--feed term "hello"))
         (row0 (car (plist-get update :dirty))))
    (should (eq (nth 0 row0) 0))
    (should (string-prefix-p "hello" (nth 1 row0)))
    (spectreshell--release term)))

(ert-deftest spectreshell-module-test-sgr-color-produces-fg-in-style-plist ()
  "SGR (ESC[31m) で塗った文字の span に :fg 1 (パレット index) が付く。"
  (let* ((term (spectreshell--create 1 10))
         (update (spectreshell--feed term "\x1b[31mHi\x1b[0m"))
         (row0 (car (plist-get update :dirty)))
         (span (car (nth 2 row0))))
    ;; span = (START END :fg 1)
    (should (equal (seq-take span 2) '(0 2)))
    (should (eq (plist-get (cddr span) :fg) 1))
    (spectreshell--release term)))

(ert-deftest spectreshell-module-test-dsr-cursor-position-produces-responses ()
  "ESC[6n (カーソル位置問い合わせ) は :responses に応答バイト列を積む。"
  (let* ((term (spectreshell--create 5 10))
         (update (spectreshell--feed term "Hi\x1b[6n")))
    (should (equal (plist-get update :responses) "\x1b[1;3R"))
    (should (not (multibyte-string-p (plist-get update :responses))))
    (spectreshell--release term)))

(ert-deftest spectreshell-module-test-encode-key-arrow-up-decckm-off ()
  "DECCKM オフ (既定) では上矢印キーは ESC [ A にエンコードされる。"
  (let ((term (spectreshell--create 5 10)))
    (should (equal (spectreshell--encode-key term 'up nil) "\x1b[A"))
    (spectreshell--release term)))

(ert-deftest spectreshell-module-test-encode-key-printable-char ()
  "印字可能な1文字はそのまま UTF-8 バイト列としてエンコードされる。"
  (let ((term (spectreshell--create 5 10)))
    (should (equal (spectreshell--encode-key term "a" nil) "a"))
    (should (equal (spectreshell--encode-key term "a" '(ctrl)) "\x01"))
    (spectreshell--release term)))

(ert-deftest spectreshell-module-test-encode-paste-follows-bracketed-mode ()
  "encode-paste は bracketed paste モード (ESC[?2004h) の有無に追従する。"
  (let ((term (spectreshell--create 5 10)))
    (should (equal (spectreshell--encode-paste term "hi") "hi"))
    (spectreshell--feed term "\x1b[?2004h")
    (should (equal (spectreshell--encode-paste term "hi") "\x1b[200~hi\x1b[201~"))
    (spectreshell--release term)))

(ert-deftest spectreshell-module-test-release-then-feed-signals-not-crashes ()
  "release 後に feed / resize / encode-key / encode-paste を呼ぶと
signal されるだけでクラッシュしない。--release 自体は二重に呼んでも安全。"
  (let ((term (spectreshell--create 5 10)))
    (spectreshell--release term)
    (should-error (spectreshell--feed term "x")
                  :type 'spectreshell-terminal-released)
    (should-error (spectreshell--resize term 5 5)
                  :type 'spectreshell-terminal-released)
    (should-error (spectreshell--encode-key term 'up nil)
                  :type 'spectreshell-terminal-released)
    (should-error (spectreshell--encode-paste term "x")
                  :type 'spectreshell-terminal-released)
    ;; 二重解放は落ちない (no-op)。
    (should (null (spectreshell--release term)))))

(ert-deftest spectreshell-module-test-wrong-type-argument-for-non-term ()
  "TERM 以外の値 (整数・文字列など user-ptr でない値) は
wrong-type-argument になる。"
  (should-error (spectreshell--feed 42 "x") :type 'wrong-type-argument)
  (should-error (spectreshell--feed "not-a-term" "x") :type 'wrong-type-argument))

(ert-deftest spectreshell-module-test-raw-bytes-round-trip-through-encode-paste ()
  "0x80 以上を含む unibyte 文字列が copy_string_contents → Zig →
make_unibyte_string で1バイトも変化せず往復する
(encode-paste は改行以外のバイトを素通しするのでこの検証に向く)。"
  (let* ((term (spectreshell--create 3 20))
         (raw (unibyte-string 72 105 128 255 1 31))
         (out (spectreshell--encode-paste term raw)))
    (should (equal raw out))
    (should (not (multibyte-string-p out)))
    (spectreshell--release term)))

(ert-deftest spectreshell-module-test-multibyte-text-round-trips-through-feed ()
  "マルチバイト文字列を feed すると :dirty の TEXT に同じ文字列が
UTF-8 マルチバイト文字列として戻る。"
  (let* ((term (spectreshell--create 1 10))
         (update (spectreshell--feed term "こんにちは"))
         (row0 (car (plist-get update :dirty)))
         (text (nth 1 row0)))
    (should (string-prefix-p "こんにちは" text))
    (should (multibyte-string-p text))
    (spectreshell--release term)))

(ert-deftest spectreshell-module-test-finalizer-survives-garbage-collect ()
  "参照を手放した TERM が GC を跨いでもクラッシュしない
(finalizer が正しく呼ばれるかどうかを直接観測はできないが、
少なくとも安全に動作し続けることは確認できる)。"
  (let ((before (garbage-collect)))
    (dotimes (_ 20)
      (let ((term (spectreshell--create 5 10)))
        (spectreshell--feed term "load")))
    (garbage-collect)
    (should (garbage-collect))
    (should before)))

(provide 'spectreshell-module-test)
;;; spectreshell-module-test.el ends here
