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
| sed | GNU sed 4.9 と照合（`tests/sed_compat.py`）。ストリーム処理（`yes \| sed 3q` が終了）、アドレス `N` `$` `/re/IM` `\%re%` `first~step` `addr,+N` `addr,~N` `0,/re/`、全コマンド `{ } = a b c d D e F g G h H i l n N p P q Q r R s t T v w W x y z : #`、s フラグ `g p N i I m M e w`、`\U \L \u \l \E`・`\n \t \xHH \oNNN \dNNN \cX`、`\w \s \b \< \>`、`-n -e -f -E -r -i[SUF] -s -z -u -l --posix --sandbox --expression= --file=` と長いオプションの省略形。`--debug` の整形出力と UTF-8 ロケール固有の挙動は未対応 |
| awk | gawk 5.3 と照合（`tests/awk_compat.py`）。POSIX awk 全体と、`gensub gsub sub match(配列) split(seps) asort asorti strftime systime mktime strtonum and or xor lshift rshift compl typeof isarray`、`BEGINFILE/ENDFILE`、`RT`、正規表現 RS、`IGNORECASE`、`printf` 全書式、`getline` 各形式、パイプ・ファイルへのリダイレクト、`-F -v -f -e --source --assign --field-separator`。`-b`/UTF-8 ロケールでは文字単位。`FPAT`・`patsplit`・`PROCINFO`（version/pid/uid 等の基本項目）に対応。`@include`・`-M`（多倍長）・`--profile` は未対応 |
| sort | 数値・一般数値、キー・区切り、逆順・安定・一意・検査、大小文字・空白、出力ファイル、NUL 区切り |
| uniq | 件数・重複のみ・一意のみ・大小文字無視、フィールド・文字スキップ、比較幅、出力ファイル、NUL 区切り。入力は逐次処理し最大行長に比例するメモリを使用 |
| cut | バイト・文字・フィールドの範囲、区切り、補集合、出力区切り、NUL レコード |
| cmp | 通常比較、`-s`、標準入力、省略した第2ファイル、終了コード 0/1/2 |
| diff | 複数 hunk、通常・unified 形式、context 幅・ラベル、大小文字・空白、brief・identical、カラー |
| cp | GNU cp 9.10 と照合（`tests/cp_compat.py`、64 項目）。`-a -b -d -f -H -i -l -L -n -P -p -r/-R -s -S -t -T -u -v -x -Z`、`--backup[=CONTROL]`、`--preserve[=LIST]`/`--no-preserve`、`--parents`、`--remove-destination`、`--sparse`、`--reflink`、`--attributes-only`、`--update[=WHEN]`、`--strip-trailing-slashes`、ハードリンク保持、再帰時の `-v` 出力、自分自身へのコピー検出 |
| mv / ln | mv: `-b -f -i -n -S -t -T -u -v --backup --update --strip-trailing-slashes`、別デバイスへの移動（コピー後に削除）、上書き・自己移動の検査。ln: `-s -f -i -n -T -t -v -b -S -L -P -r`、`--backup`、ディレクトリへのハードリンク拒否。GNU 形式の診断 |
| mkdir / chmod | mkdir: `-p -m -v -Z`、シンボリック mode、親ディレクトリの u+wx、GNU 形式の診断。chmod: `-R -c -f -v --reference`、octal・symbolic mode、`X`・special bits |
| rm / rmdir | rm: `-f -i -I --interactive[=WHEN] -r -R -d -v --one-file-system --preserve-root --no-preserve-root`、GNU のプロンプト文言（`remove regular empty file`、`descend into directory`、`remove N arguments`）、`.` / `..` の拒否、ルート保護。rmdir: `-p -v --ignore-fail-on-non-empty` |
| ls | GNU ls の書式一式: `-1 -C -x -m -l`（桁揃えは GNU のカラム配置アルゴリズム）、`-a -A -d -R -L -H -F -p --file-type -i -s -k -h --si -n -g -o -G --author -Z`、並び替え `-S -t -X -v -U -r -c -u --sort --time --group-directories-first`、`-I --hide -B`、クォート `-b -N -q -Q --quoting-style`（端末では shell-escape）、`--time-style`（full-iso・long-iso・iso・+FORMAT）、`--full-time`、`-w -T`、`--color`（LS_COLORS）、リンク先の表示と着色 |
| basename / dirname | 複数入力、suffix、NUL 終端、連続 slash と root |
| readlink / realpath | symlink 解決、existing/missing、相対表示、NUL 終端 |
| mktemp | 排他的なファイル・ディレクトリ作成、template・suffix・tmpdir、dry-run |
| env | `-i -u`、変数上書き、PATH 検索と外部コマンド実行 |
| test / [ | 引数数による解釈、否定・括弧・論理式、文字列・整数・ファイル属性、閉じ括弧検証、構文エラーは2 |
| sleep / seq | 単位・小数・複数 sleep、数列の小数・逆順・区切り・書式・equal width |
| sh / ash | 下記参照 |

GNU の仕様に合わせて実装し直したコマンド（`tests/basic_compat.py` で固定の期待値と照合）:

| コマンド | 主な実装範囲 |
|---|---|
| date | `-d`（GNU の日付文字列: 絶対・相対・曜日・`@秒`・タイムゾーン）`-f -r -u -R -I --rfc-3339 -s`、`+FORMAT`（`%-d %_d %^a %10A %N %:z %P` 等のフラグ・幅）、`MMDDhhmm[[CC]YY][.ss]` |
| touch | `-a -m -c -d -f -h -r -t --time`、`-` と時刻ソース競合の検出、GNU と同じ終了コード |
| id / uname / hostname | id の全オプション（`-u -g -G -n -r -z`・ユーザー指定・euid/egid）、uname の `-a -s -n -r -v -m -p -i -o`、hostname の `-s -d -F` |
| chown / chgrp | `-R -H -L -P -h -c -v -f --from --reference --dereference`、`OWNER:GROUP` / `OWNER:` / `:GROUP` / `OWNER.GROUP` |
| env / which / pwd / dirname | env の `-i -u -0 -C -S -v`（終了コード 125/126/127）、which の `-a -s`、pwd の `-L -P` |
| true / false / yes / sync / tee / mkfifo / mknod / clear | `--help`/`--version`、sync の `-d -f`、tee の `-a -i -p --output-error`、mkfifo/mknod の `-m` と引数検証 |
| cksum | `-a crc/bsd/sysv/crc32b/md5/sha1/sha224/sha256/sha384/sha512/blake2b`、`--tag --untagged -c -l -z --raw --base64` |
| kill | `-s -n -SIG -NUM -l -L --`、リアルタイムシグナル、負の pid、util-linux 形式の診断 |
| hexdump | util-linux 形式。`-b -c -C -d -o -x -v -n -s`、`-e`/`-f` の書式言語（反復/バイト数・`%_a %_A %_c %_p %_u`・整数/浮動小数/文字列変換）、重複行の `*` 省略 |
| ps | procps 形式の UNIX 構文（`-e -A -a -x -f -F -l -j -o -p -C -u -U --sort --no-headers`）と BSD 構文（`aux`、`ax`、`u`、`l`、`v` ほか）、列幅・STAT・TIME/START の表記、`-o col=ヘッダ` |
| nice / killall | nice の `-n -N --adjustment` と `-10`/`--10`、終了コード 125/126/127。killall（psmisc）の `-e -I -g -i -l -q -r -s -u -v -w -y -o` と `-SIG` |
| df / free | df の `-a -B -h -H -i -k -l -m -P -t -T -x --total`、free の `-b -k -m -g -h --si -l -t -v -w -s -c` |

上記以外にも mount、umount、reboot、poweroff、halt、ping、wget、nslookup、
ifconfig、netstat、route、usleep、help を実装している。
これらは従来の簡易実装を含み、GNU・util-linux・procps・net-tools 等との対応は限定的。
`cmdbox --list` が実際の一覧となる。

## シェル

`sh` / `ash` は字句解析・構文解析・実行を分離した POSIX シェルとして実装し直した
（`src/sh_parse.zig`、`src/sh.zig`）。`tests/sh_compat.py` が 249 本のスクリプトを
`-c` 文字列・スクリプトファイル・標準入力の3方式で `bash --posix` と比較する。

- **構文**: 単純コマンド、パイプライン、`!`、`&&` / `||`、`;` / `&`、`( )` サブシェル、`{ }` グループ、
  `if/elif/else`、`while` / `until`、`for`、`case`（`|` 複数パターン・クォート）、関数定義、
  here-document（`<<` `<<-`・引用付き区切り・複数・パイプ/関数/ループ内）、全リダイレクト
  （`< > >> <> >| n>&m n>&- n<&m`・任意の fd・`exec` による恒久的な付け替え）、行継続、コメント
- **展開**: チルダ、`$name` / `${...}`（`:- - := = :? ? :+ + # ## % %% ${#x}`、拡張として `${x/p/r}` と `${x:off:len}`）、
  `$(...)` / バッククォート、`$((...))`（C の演算子を一通り、`**`、代入演算子、三項、`0x`/8進）、
  `$'...'`、IFS による単語分割、パス名展開（`* ? [...]`）、`"$@"` / `"$*"`、`$? $$ $! $# $- $0 $LINENO $PPID`
- **ビルトイン**: `: . source break continue eval exec exit export readonly return set shift times trap unset
  alias unalias cd read command type hash wait umask getopts local ulimit jobs let`、および `echo printf test [ true false kill pwd`
- **`set` オプション**: `-e -u -f -x -v -n -C -a`、`-o pipefail`、`set -o` の一覧
- **`trap`**: `EXIT` / `ERR` / シグナル名・番号、`trap ''`（無視）、`trap -`（リセット）、一覧、サブシェルでのリセットと独自 EXIT トラップ
- **対話**: PS1/PS2、複数行入力、Ctrl-C（130）、構文エラーからの復帰、Ctrl-D
- PATH に無いアプレット名はこのバイナリ自身で実行する（`cmdbox sh -c 'ls'` でも動く）

## 残る差分・未検証部分

- **全アプレットの全オプションは未実装。** help/version の出力や診断文言も GNU と異なる。
- シェルは完全な job control（`fg` / `bg` / `%n`）、Bash の配列・`[[ ]]`・ブレース展開・`(( ))`、
  対話時の行編集・履歴を実装していない。
- grep の `-P`、一部の GNU 正規表現拡張、NUL を含む正規表現の処理などに差分がある。
  正規表現は静的リンクした musl の POSIX エンジンを使用する。
- sed の `\`` `\'`（M モードのバッファ境界）、`-z` と M モードの組合せ、Unicode の大文字小文字変換は未対応。NUL を含むパターンスペースへの正規表現は NUL で打ち切られる。word 境界を含む正規表現の `g` 置換は musl 正規表現の制約により低速な経路を使う。
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
- vi は最小実装（移動・編集・検索・`:`コマンドの一部、busybox vi 風）を提供する。
  visualモード・正規表現検索・マーク・レジスタ複数・`:g`等は未実装。
- cpio、passwd、su、udhcpc 等は未実装。awk の `for (k in a)` の列挙順は挿入順で gawk とは異なる。旧パッケージから失われるパスは BUSYBOX-MIGRATION.md を参照。
- 一部の従来アプレットは未対応オプションを無視する。全コマンドが厳密に拒否する段階には未到達。
- musl の allocator で小さい確保をまとめるが、短命アプレット向けに解放を省略する箇所がある。
  シェルの長時間連続実行に対するメモリ上限は未保証。

## カラー・エスケープの検証

`tests/color_compat.py` は `echo`・`printf`・sh の ESC 出力をバイト単位で比較する。
ls/grep/diff の ANSI SGR、配色指定、reset、無色出力、PTY の自動判定も確認する。
16色・256色・RGB のシーケンスの描画そのものは利用端末の機能に依存する。

ランダムなスクリプトによる sed の差分ファジングは `tests/sed_fuzz.py cmdbox /path/to/gnu-sed`、有名なワンライナー集は `tests/oneliners_compat.py cmdbox gawk /path/to/gnu-sed`。sed は `tests/sed_compat.py cmdbox /path/to/gnu-sed`、awk は `tests/awk_compat.py cmdbox gawk` でGNU版と差分比較する（基準が GNU 版でない場合は結果が無意味）。

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

`tests/uniq_cut_compat.py`はuniqの逐次処理、長い行、NULレコード、書き込み失敗、
cutの範囲指定とオプションの検証を行う。64 MiBの入力を32 MiBのメモリ制限で処理する。
`GNU_COREUTILS_DIR=/path/to/gnu/bin`を指定するとGNU版との追加比較も行う。
比較先は`--version`でGNU coreutilsであることを確認し、cmdbox自身との自己比較を防ぐ。
