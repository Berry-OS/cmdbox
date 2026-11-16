# 互換性の範囲

互換性の基準は BusyBox ではなく通常の GNU コマンド。
本環境の比較対象は GNU coreutils 9.10、grep 3.12、sed 4.9、diffutils 3.12、
Bash 5.3.9 の sh モード。バージョンによって終了コード等が異なる場合がある。

以下は実装の概要であり、GNU の全オプションの適合宣言ではない。
比較テストは基本的に stdout と終了コードを比較し、stderr の文言は一部だけを検証する。
日本語等の locale データ全体や、すべてのエラー文言の一致は保証しない。

| コマンド | 主な実装範囲 |
|---|---|
| echo / printf | GNU 形式の数値・文字列・浮動小数点の書式、書式再利用、エスケープ、ESC・SGR、`%b`、`\c` |
| base64 | GNU の encode/decode、wrap、ignore-garbage、ファイル・標準入力 |
| md5sum / sha1sum / sha256sum | ストリーム計算、text/binary、チェック、quiet/status/strict、BSD tag、escaped filename、NUL 出力 |
| gzip / gunzip / zcat | gzip形式、ストリーム圧縮・展開、CRC/サイズ検証、連結member、`-d -c -k -f -n -N -r -t -S`、圧縮レベル1〜9 |
| whoami / groups / nice / pwdx | ユーザー・グループ表示、niceness指定とexec、PIDのcwd表示 |
| cat | `-n -b -s -E -T -v -A`、複数ファイルをまたぐ行状態 |
| wc | 行・単語・バイト・文字・最大表示幅、合計、files0-from、C/UTF-8 の文字処理 |
| head / tail | 行・バイト、正負・`+N`、サイズ接尾辞、`-q -v -z`。tail の基本的な `-f` |
| grep | BRE/ERE/F、複数パターン・パターンファイル、単語・全行、前後行、再帰、最大件数、`-o -l -L -c -n -b -q -z`、カラー |
| sed | BRE/ERE、後方参照と `&`、複数置換、数値・正規表現・範囲・最終行・否定アドレス、`p P d D n N h H g G x y a i c b t T : q Q = z l r w { }`、`-n -e -f -E -i -s -z` |
| sort | 数値・一般数値、キー・区切り、逆順・安定・一意・検査、大小文字・空白、出力ファイル、NUL 区切り |
| uniq | 件数・重複のみ・一意のみ・大小文字無視、フィールド・文字スキップ、比較幅、出力ファイル |
| cut | バイト・文字・フィールドの範囲、区切り、補集合、出力区切り、NUL レコード |
| cmp | 通常比較、`-s`、標準入力、省略した第2ファイル、終了コード 0/1/2 |
| diff | 複数 hunk、通常・unified 形式、context 幅・ラベル、大小文字・空白、brief・identical、カラー |
| cp | 再帰、シンボリックリンクの追跡制御、同一 inode 保護、自己コピー検出、`-a -p -f -i -n -u -l -s -T -t`、mode/owner/time と hardlink の保持 |
| mv / ln | 複数入力・ターゲットディレクトリ、強制・対話・上書き抑止、通常・シンボリックリンク。mv の EXDEV 時コピー |
| mkdir / chmod | `-p -m`、octal・symbolic mode、コピー permission・`X`・special bits、再帰、reference |
| rm / rmdir | 再帰・force・対話・verbose、root 保護、`--`、親ディレクトリ削除、非空エラーの無視 |
| ls | `-a -A -d -R -l -n -g -o -F -p -i -h -L -H -r -S -t -1`、time-style、ファイルとディレクトリの表示、カラー |
| basename / dirname | 複数入力、suffix、NUL 終端、連続 slash と root |
| readlink / realpath | symlink 解決、existing/missing、相対表示、NUL 終端 |
| mktemp | 排他的なファイル・ディレクトリ作成、template・suffix・tmpdir、dry-run |
| env | `-i -u`、変数上書き、PATH 検索と外部コマンド実行 |
| test / [ | 引数数による解釈、否定・括弧・論理式、文字列・整数・ファイル属性、閉じ括弧検証、構文エラーは2 |
| sleep / seq | 単位・小数・複数 sleep、数列の小数・逆順・区切り・書式・equal width |
| sh / ash | 下記参照 |

上記以外にも touch、chown、mkfifo、mknod、pwd、which、clear、hexdump、tee、
cksum、true、false、yes、sync、hostname、uname、date、id、kill、killall、ps、
free、df、mount、umount、reboot、poweroff、halt、ping、wget、nslookup、
ifconfig、netstat、route、help を実装している。
これらは従来の簡易実装を含み、GNU・util-linux・procps・net-tools 等との対応は限定的。
`cmdbox --list` が実際の一覧となる。

## シェル

パイプ・バックグラウンド、`&& || ;`、クォート、変数・位置引数、
コマンド置換・算術・glob、for/while/until/if/case、関数と return、
source、export/unset、set の位置引数、umask、read、wait、exec 等を実装する。

外部コマンドは PATH に従って検索する。アプレットも通常のコマンド名として
使う場合はリンクを配置して PATH を設定する。ローカル変数と export を区別し、
環境変数の重複と argv/envp の256件での切り捨てを解消した。
リダイレクトは記述順に適用し、任意の FD、dup・close、追記、引用したファイル名、
組み込みコマンドと関数へのリダイレクトにも対応する。

## 残る差分・未検証部分

- **全アプレットの全オプションは未実装。** help/version の出力や診断文言も GNU と異なる。
- シェルは here-document、trap、完全な job control、`set -e/-u` 等のオプション、
  Bash の配列等を実装していない。シェル変数・関数のテーブルにも上限がある。
- grep の `-P`、一部の GNU 正規表現拡張、NUL を含む正規表現の処理などに差分がある。
  正規表現は静的リンクした musl の POSIX エンジンを使用する。
- sed の全 GNU 拡張、全てのアドレス形式・置換 flag・Unicode 置換は網羅していない。
- sort はメモリ内ソート。GNU の外部ソート・locale 照合・完全な version sort 等は未達。
- diff のディレクトリ比較・再帰・context/ed 形式等は未実装。
  曖昧な最小差分の選択は GNU と異なる場合がある。極端に異なる大入力では
  trace メモリを制限し、一つの変更区間へフォールバックする。
- cp の ACL・xattr・SELinux・sparse 等は完全には保持しない。特に `-a` は
  mode/owner/time/hardlink を中心とした実装で、GNU archive 全機能の保証ではない。
- ls の複数カラム・全 quoting style・device 番号等、tail の rotation/truncate 対応等に差分がある。
- wget は HTTP/HTTPS、TLS 1.2/1.3、CA/ホスト名/IP SAN/用途/CA制約検証、redirect、chunked、Range再開、認証、HTTPプロキシとHTTPS CONNECT、POST、主要GNUオプションに対応する。
  FTP、再帰取得、cookie jar、HSTS、クライアント証明書、完全なGNU wgetオプションは未実装。
  nameConstraints/policyConstraints等の未対応証明書制約は拒否する。失効確認（CRL/OCSP）は未対応。
  CA証明書はシステムのPEM bundle、`SSL_CERT_FILE`または`--ca-certificate`で指定する。
- mount の fstab/`-a` 等は未実装。特権操作の実機検証は未実施。
- awk、vi、cpio、passwd、su、udhcpc 等は未実装。旧パッケージから失われるパスは BUSYBOX-MIGRATION.md を参照。
- 一部の従来アプレットは未対応オプションを無視する。全コマンドが厳密に拒否する段階には未到達。
- musl の allocator で小さい確保をまとめるが、短命アプレット向けに解放を省略する箇所がある。
  シェルの長時間連続実行に対するメモリ上限は未保証。

## カラー・エスケープの検証

`tests/color_compat.py` は `echo`・`printf`・sh の ESC 出力をバイト単位で比較する。
ls/grep/diff の ANSI SGR、配色指定、reset、無色出力、PTY の自動判定も確認する。
16色・256色・RGB のシーケンスの描画そのものは利用端末の機能に依存する。

通常比較は `tests/gnu_compat.py`、ファイル操作は `tests/fs_compat.py`。
これらの通過件数はテストケースの件数であり、全仕様への適合率ではない。

## BusyBox RPMからの移行

`packaging/busybox-paths.list`に旧RPMの146コマンドパスを固定して収録する。
`packaging/layout.py`が実装済みアプレットとの共通部分だけを標準パスに配置し、
未実装一覧を`BUSYBOX-MIGRATION.md`へ出力する。現状は67パス対応、79コマンドが未実装。
対応済み67パスを標準配置して既存コマンドを置き換える。
GNU等も同じパスを所有する場合、RPM更新には`--replacefiles`が必要となる。
全アプレットはprivateリンクでも公開し、`/bin/busybox <command>`のdispatchにも対応する。

gzip圧縮のビット列はGNU gzipと同一とは限らないが、GNU版との相互展開を検証する。
`--list`・`--rsyncable`・旧compress形式等は未対応。一部の入力処理はメモリ内で行う。
追加ユーティリティの診断文言・help/version等もGNU全仕様を網羅していない。

`tests/wget_compat.py` は外部通信なしでHTTP/HTTPSと不正証明書の拒否を検証する。
ホストのwgetがBusyBox版の場合も実行できる。GNU版との追加比較は`GNU_WGET=/path/to/gnu-wget`で指定する。
テスト用公開鍵・秘密鍵は`tests/tls/`に同梱する。実運用には使用しない。
TLSはZig 0.16のMITライセンス実装に証明書ポリシーとTLS 1.2 ECDSA対応を追加したものを使用する。
