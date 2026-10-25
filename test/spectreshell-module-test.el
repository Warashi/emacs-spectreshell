;;; spectreshell-module-test.el --- ERT smoke tests for libspectreshell.so -*- lexical-binding: t; -*-

;; Phase 2 (モジュール境界) の完了条件である「emacs -batch から create →
;; feed → 戻り値検証のスモークテストが通る」を満たすためのテスト。
;; docs/module-api.org の plist 仕様と、emacs-module の unibyte/multibyte
;; 文字列の挙動 (copy_string_contents / make_unibyte_string) を実証する。

(require 'ert)
(require 'spectreshell-test-helper)

(ert-deftest spectreshell-module-test-create-and-feed-returns-dirty-row ()
  "feed \"hello\" した直後の :dirty に行0のテキスト \"hello...\" が含まれる。"
  (let* ((term (spectreshell--create 5 10))
         (update (spectreshell--feed term "hello"))
         (row0 (car (plist-get update :dirty))))
    (should (eq (nth 0 row0) 0))
    (should (string-prefix-p "hello" (nth 1 row0)))
    (spectreshell--release term)))

(ert-deftest spectreshell-module-test-sgr-color-produces-fg-in-style-plist ()
  "SGR (ESC[31m) で塗った span の style ID が :styles で :fg 1 と対応づく。"
  (let* ((term (spectreshell--create 1 10))
         (update (spectreshell--feed term "\x1b[31mHi\x1b[0m"))
         (row0 (car (plist-get update :dirty)))
         (span (car (nth 2 row0))))
    ;; span = (START END ID)
    (should (equal (seq-take span 2) '(0 2)))
    (should (eq (plist-get (alist-get (nth 2 span) (plist-get update :styles)) :fg) 1))
    (spectreshell--release term)))

(ert-deftest spectreshell-module-test-styles-are-sent-only-on-first-use ()
  "同じスタイルの 2 回目の feed では :styles が空で、ID だけが再利用される。"
  (let* ((term (spectreshell--create 1 10))
         (first (spectreshell--feed term "\x1b[31mHi"))
         (id (nth 2 (car (nth 2 (car (plist-get first :dirty))))))
         (second (spectreshell--feed term "\x1b[31mHo")))
    (should (plist-get first :styles))
    (should (null (plist-get second :styles)))
    (should (eq id (nth 2 (car (nth 2 (car (plist-get second :dirty)))))))
    (spectreshell--release term)))

(ert-deftest spectreshell-module-test-osc8-span-carries-uri-in-cdr ()
  "OSC 8 のリンク区間は (START END ID . URI) の形になる。"
  (let* ((term (spectreshell--create 1 10))
         (update (spectreshell--feed term "\x1b]8;;https://example.com\x1b\\li\x1b]8;;\x1b\\"))
         (span (car (nth 2 (car (plist-get update :dirty))))))
    (should (equal (cddr (cdr span)) "https://example.com"))
    (spectreshell--release term)))

(ert-deftest spectreshell-module-test-dsr-cursor-position-produces-responses ()
  "ESC[6n (カーソル位置問い合わせ) は :responses に応答バイト列を積む。"
  (let* ((term (spectreshell--create 5 10))
         (update (spectreshell--feed term "Hi\x1b[6n")))
    (should (equal (plist-get update :responses) "\x1b[1;3R"))
    (should (not (multibyte-string-p (plist-get update :responses))))
    (spectreshell--release term)))

(ert-deftest spectreshell-module-test-synchronized-feed-returns-only-responses ()
  "mode 2026 の中で終わった feed は :synchronized t と :responses だけを返す。"
  (let* ((term (spectreshell--create 5 10))
         (update (spectreshell--feed term "\x1b[?2026hHi\x1b[6n")))
    (should (equal update '(:synchronized t :responses "\x1b[1;3R")))
    (spectreshell--release term)))

(ert-deftest spectreshell-module-test-osc52-write-produces-relay ()
  "OSC 52 の書き込みは :relay に (clipboard KIND BASE64) を積む。
種別を省いた書き込みは c になる。"
  (let* ((term (spectreshell--create 5 10))
         (update (spectreshell--feed term "\x1b]52;p;aGk=\x07\x1b]52;;eW8=\x07")))
    (should (equal (plist-get update :relay)
                   '((clipboard "p" "aGk=") (clipboard "c" "eW8="))))
    (spectreshell--release term)))

(ert-deftest spectreshell-module-test-osc52-read-is-ignored ()
  "OSC 52 の読み取り (?) は :relay にも :responses にも何も積まない。"
  (let* ((term (spectreshell--create 5 10))
         (update (spectreshell--feed term "\x1b]52;c;?\x07")))
    (should-not (plist-member update :relay))
    (should-not (plist-member update :responses))
    (spectreshell--release term)))

(ert-deftest spectreshell-module-test-synchronized-feed-keeps-relay ()
  "mode 2026 の中で終わった feed も :relay を返す。描画ではないので
保留しない。"
  (let* ((term (spectreshell--create 5 10))
         (update (spectreshell--feed term "\x1b[?2026h\x1b]52;c;aGk=\x07")))
    (should (equal update '(:synchronized t :relay ((clipboard "c" "aGk=")))))
    (spectreshell--release term)))

(ert-deftest spectreshell-module-test-primary-device-attributes-report-clipboard ()
  "DA1 には Ghostty と同じく 52 (クリップボード) を含めて答える。"
  (let* ((term (spectreshell--create 5 10))
         (update (spectreshell--feed term "\x1b[c")))
    (should (equal (plist-get update :responses) "\x1b[?62;22;52c"))
    (spectreshell--release term)))

(ert-deftest spectreshell-module-test-decrqm-sgr-pixels-is-unsupported ()
  "DECRQM ?1016 (SGR pixel 座標) には、設定の前後とも 0 (未対応) で答える。
マウス報告はセル座標しか出せないので、子にピクセル座標を前提にさせない。"
  (let* ((term (spectreshell--create 5 10))
         (update (spectreshell--feed term "\x1b[?1016$p\x1b[?1016h\x1b[?1016$p")))
    (should (equal (plist-get update :responses) "\x1b[?1016;0$y\x1b[?1016;0$y"))
    (spectreshell--release term)))

(ert-deftest spectreshell-module-test-xtversion-reports-ghostty ()
  "XTVERSION (CSI > q) には、同梱する ghostty の版で Ghostty と同じ形で答える。"
  :expected-result :failed
  (let* ((term (spectreshell--create 5 10))
         (update (spectreshell--feed term "\x1b[>q\x1b[>0q")))
    (should (equal (plist-get update :responses)
                   "\x1bP>|ghostty 1.3.1\x1b\\\x1bP>|ghostty 1.3.1\x1b\\"))
    (spectreshell--release term)))

(ert-deftest spectreshell-module-test-desktop-notification-produces-relay ()
  "OSC 777 の通知と、9;4 などの ConEmu 拡張でない OSC 9 の通知は :relay に
\(notification TITLE BODY) を積む。OSC 9 には TITLE が無いので空になる。"
  (let* ((term (spectreshell--create 5 10))
         (update (spectreshell--feed term "\x1b]777;notify;T;a;b\x07\x1b]9;done\x07")))
    (should (equal (plist-get update :relay)
                   '((notification "T" "a;b") (notification "" "done"))))
    (should-not (multibyte-string-p (nth 2 (car (plist-get update :relay)))))
    (spectreshell--release term)))

(ert-deftest spectreshell-module-test-progress-report-produces-relay ()
  "OSC 9;4 の進捗は :relay に (progress STATE VALUE) を積む。値を持たない
状態 (0 消去・3 不定) の VALUE は nil で、値を省いた 1 (設定) は 0 になる。"
  (let* ((term (spectreshell--create 5 10))
         (update (spectreshell--feed
                  term "\x1b]9;4;1;50\x07\x1b]9;4;1\x07\x1b]9;4;3;0\x07\x1b]9;4;0;0\x07")))
    (should (equal (plist-get update :relay)
                   '((progress 1 50) (progress 1 0) (progress 3 nil) (progress 0 nil))))
    (spectreshell--release term)))

(ert-deftest spectreshell-module-test-bell-produces-relay ()
  "BEL は :relay に (bell) を積む。OSC の終端の BEL は積まない。"
  (let* ((term (spectreshell--create 5 10))
         (update (spectreshell--feed term "a\x07\x1b]2;t\x07z\x07")))
    (should (equal (plist-get update :relay) '((bell) (bell))))
    (spectreshell--release term)))

(ert-deftest spectreshell-module-test-flush-draws-pending-frame ()
  "--flush は保留中の描画を通常の update plist で返す。"
  (let* ((term (spectreshell--create 1 10))
         (_ (spectreshell--feed term "\x1b[?2026hHi"))
         (update (spectreshell--flush term)))
    (should-not (plist-get update :synchronized))
    (should (string-prefix-p "Hi" (nth 1 (car (plist-get update :dirty)))))
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
  "release 後に feed / resize / flush / encode-key / encode-paste を呼ぶと
signal されるだけでクラッシュしない。--release 自体は二重に呼んでも安全。"
  (let ((term (spectreshell--create 5 10)))
    (spectreshell--release term)
    (should-error (spectreshell--feed term "x")
                  :type 'spectreshell-terminal-released)
    (should-error (spectreshell--resize term 5 5)
                  :type 'spectreshell-terminal-released)
    (should-error (spectreshell--flush term)
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
