#!/usr/bin/env bash
# guard.sh — Claude Code PreToolUse(Bash)hook。exit 0=許可 / exit 2=ブロック。
#
# ★適用範囲(正直に明記):
#   これは Claude Code 経由の Bash コマンドのみを検査する多重防御の「一層」である。
#   守れる: Claude Code の Bash ツールから発行されるコマンド。
#   守れぬ: 他CLI(Codex/Copilot/Kimi/OpenCode)・agent以外・GUI・直接シェル・
#           スクリプト内部からの再帰削除等は検査対象外。
#   ★Claude Code ハーネス自体の許可層とは独立に動く。ハーネスの穴
#     (-rf 文字列依存で rm -r を見落とす等)に依存せず、guard.sh 側で確実に捕捉する。
#   よって「これで全経路が安全」ではない。あくまで agent 経由の破壊的 Bash を止める一層。
# Reads JSON from stdin: {"tool_name": "Bash", "tool_input": {"command": "..."}}
# exit 0 = allow, exit 2 = block (stderr shown as error message)

set -euo pipefail

# Read JSON from stdin
INPUT=$(cat)
COMMAND=$(echo "$INPUT" | jq -r '.tool_input.command // ""')

if [[ -z "$COMMAND" ]]; then
  exit 0
fi

# ============================================================
# Helper: resolve effective working directory from cd in command
# Handles: "cd /path && git push", "cd /path; git commit"
# Falls back to current directory if no cd found
# ============================================================
# Extract the path argument following <kw> in a command string.
#   kw="cd"            → last `cd <path>`
#   kw="git[[:space:]]+-C" → last `git -C <path>`
# <kw> is an ERE fragment; the target is a quoted string or a non-ws/&/;/| run.
# Portable across GNU (Linux/WSL2) and BSD (macOS) grep — no PCRE -P/\K.
_arg_after() {
  echo "$1" | grep -oE "$2[[:space:]]+(\"[^\"]+\"|[^[:space:]&;|]+)" | sed -E "s/^$2[[:space:]]+//" | tail -1 | tr -d '"'
}

resolve_git_dir() {
  local cmd="$1" target
  # Prefer `git -C <dir>` (git operates there regardless of cwd), else last `cd <dir>`.
  target=$(_arg_after "$cmd" 'git[[:space:]]+-C')
  if [[ -n "$target" && -d "$target" ]]; then echo "$target"; return; fi
  target=$(_arg_after "$cmd" 'cd')
  if [[ -n "$target" && -d "$target" ]]; then echo "$target"; else echo "."; fi
}

GIT_TARGET_DIR=$(resolve_git_dir "$COMMAND")

# ============================================================
# Helper: heredoc本文をgit検出用にマスクする (FP-H3是正・cmd_new_backtick_safety)
# ------------------------------------------------------------
# 背景: 軍師がPR#122のQC作業中、報告本文(ヒアドキュメント)の中に試験名として
# "git commit"/"git push" 等の語が地の文として含まれていただけで、
# has_git_subcmd() の単純な文字列一致がこれを実コマンドと誤判定し、
# 実際は `cat` によるファイル書き出しに過ぎない操作をブロックした(FP-H3)。
# 家老も同型(「git commit」「gh pr create」という語がプロース中にあっただけ)
# を本セッション中に2度踏んでいる。
#
# ★設計方針(v2・「本文の受け手」で判定する):
#   heredoc本文をマスクしてよいのは、本文が★データとして file に書き出される
#   だけで、この後どこでも実行されないと言える時に限る。判定は heredoc の
#   ★開始行の受け手で行う——
#     (a) `<<TAG` を持つコマンド区切り(; && || | ( { の後)の先頭が `cat` である
#     (b) 同じ区切りに stdout の file リダイレクト(`>`/`>>`・`2>` は不可)があり、
#         書き出し先が★リテラルなパス($/バッククォート無し・/dev/ /proc/ でない)
#     (c) cat 以降の開始行に | $( <( >( バッククォートが無い
#     (d) 書き出し先のパスが同じコマンドの他の場所に★再び現れない
#         (cat > s.sh <<EOF … EOF; bash s.sh のような書き出し→実行を除外)
#         ★FU-1是正(PR#125 v2 followup・軍師QC): (d) はリテラル一致のみを見るため
#         宛先を glob で実行する形(cat > /tmp/n8b.sh <<EOF … EOF; bash /tmp/n8b.*)が
#         すり抜けていた(N8b)。本文外の行に bash/sh/zsh/source/. のいずれかと
#         glob 文字(* ? [)が同一行に現れたら、宛先再利用とみなしマスクしない
#         (has_glob_exec_risk)。
#     (e) 本文に `$(` もバッククォートも無い(unquoted heredoc は展開される)
#   これを全て満たす時だけ本文を "HEREDOC_BODY_MASKED" に置換する。
#   それ以外(bash/sh/zsh/source/eval/パイプ先/プロセス置換/受け手不明の stdout/
#   tee 等)は heredoc と見なさず★素通し(=従来どおり本文の語で検知される)。
#   tee は本文を stdout にも複写するため受け手が定まらず、対象外とした。
#
# ★S8(設計上の受容点・欠陥ではない): 本文に実際の push 操作を書いても、
#   ★同一コマンド内で実行されなければ(=別の Bash 呼出で後から実行される)
#   allow のままである。これは「書いて実行しない二段構えは PreToolUse(1コマンド
#   しか見えない)の射程外」という受け手判定の設計そのものに内在する性質であり、
#   本PRが新たに作った危険ではない。次に読む者が「書いて実行する二段構えも
#   guard が見てくれる」と誤解せぬための一言として記す。
#
# ★v1(PR#125初版)の設計判断は誤りであった——「本文に $( もバッククォートも
#   無ければ安全」と★本文の中身だけで決め、★本文の行き先を見ていなかった。
#   bash <<EOF / sh <<'EOF' / cat <<EOF | bash / eval "$(cat <<EOF …)" /
#   bash <(cat <<EOF …) / source /dev/stdin <<EOF / zsh <<EOF の7形(N1〜N7)は
#   置換記号など無くとも本文がそのままスクリプトとして実行され、main が止めて
#   いたものを v1 は全て通した(軍師QC・N1 は実 push が通ることまで実証)。
#   has_git_subcmd の入口でマスクするため D003/D004 にも同じ穴が及んでいた。
#
#   ★全般的な引用符(単一/二重)の地の文除外は本taskの範囲外とした——
#   heredocが実際に踏まれた事故の形であり、二重引用符内の `$(`/バック
#   クォート実行可否を正しく見分けるには括弧の深さ追跡等が必要になり、
#   Hook8と同程度の一パス走査を超える。追加のfollowup taskとして
#   別途検討されたい(本コミットのコメントに正直に記録)。
# ============================================================
_mask_heredoc_bodies_for_git_detection() {
  local cmd="$1"
  awk '
    function strip_quotes(s,    t, n) {
      t = s
      if (substr(t,1,1) == "\047" || substr(t,1,1) == "\"" || substr(t,1,1) == "\\") {
        t = substr(t, 2)
      }
      n = length(t)
      if (n > 0 && (substr(t,n,1) == "\047" || substr(t,n,1) == "\"")) {
        t = substr(t, 1, n-1)
      }
      return t
    }
    # 開始行 probe のうち、最初の <<TAG を含むコマンド区切り(直前の ; && || | ( { 以降)を返す
    function owner_segment(p, hdpos,    seg, i, c, cut) {
      seg = substr(p, 1, hdpos - 1)
      cut = 0
      for (i = 1; i <= length(seg); i++) {
        c = substr(seg, i, 1)
        if (c == ";" || c == "|" || c == "(" || c == "{") cut = i
        else if (c == "&" && substr(seg, i + 1, 1) != ">") cut = i    # &> はリダイレクト、区切りではない
      }
      seg = substr(seg, cut + 1)
      sub(/^[ \t]+/, "", seg)
      sub(/^(then|do|else)[ \t]+/, "", seg)
      return seg
    }
    # stdout の file リダイレクト先(リテラルパス)を返す。無ければ ""。
    function sink_target(p,    s, pre, rest, tok, c) {
      s = p
      while (match(s, />>?/)) {
        pre = (RSTART > 1) ? substr(s, RSTART - 1, 1) : ""
        rest = substr(s, RSTART + RLENGTH)
        s = rest
        if (pre ~ /[02-9]/) continue              # 2> 等: stderr のみ。stdout は受け手不明
        sub(/^[ \t]+/, "", rest)
        c = substr(rest, 1, 1)
        if (c == "" || c == "&" || c == "(" || c == "|" || c == ">") continue
        tok = rest
        sub(/[ \t;&|<>].*$/, "", tok)
        tok = strip_quotes(tok)
        if (tok == "" || index(tok, "$") > 0 || index(tok, "`") > 0) return ""   # 変数展開先は不明
        if (tok ~ /^\/dev\// || tok ~ /^\/proc\//) return ""                     # stdout へ戻りうる
        return tok
      }
      return ""
    }
    # hay 中に needle がパス文字に挟まれず独立して現れる回数
    function occurs(hay, needle,    n, pos, off, b, a) {
      n = 0; off = 1
      while ((pos = index(substr(hay, off), needle)) > 0) {
        pos = pos + off - 1
        b = (pos > 1) ? substr(hay, pos - 1, 1) : ""
        a = substr(hay, pos + length(needle), 1)
        if (b !~ /[A-Za-z0-9_.\/~-]/ && a !~ /[A-Za-z0-9_.\/~-]/) n++
        off = pos + length(needle)
      }
      return n
    }
    # FU-1是正(PR#125 v2 followup): 行に bash/sh/zsh/source/. のいずれかの
    # 起動語と glob 文字(* ? [)が同一行に現れるか(宛先を glob で実行する
    # N8b のような形を、リテラル一致に頼らず捕らえる)。
    function has_glob_exec_risk(l) {
      if (l !~ /(^|[^A-Za-z0-9_.\/])(bash|sh|zsh|source|\.)[ \t]/) return 0
      if (l ~ /[*?\[]/) return 1
      return 0
    }
    { L[NR] = $0 }
    END {
      n = NR
      # pass 1: heredoc の範囲と「マスクしてよいか」を決める
      k = 0
      i = 1
      while (i <= n) {
        line = L[i]
        probe = line
        # here-string (<<<word) は heredoc ではない。検出用の写しからのみ潰す。
        gsub(/<<</, "HERESTRING", probe)
        if (match(probe, /<<-?[ ]*[A-Za-z_\x27"\\][A-Za-z0-9_]*[\x27"]?/)) {
          hdpos = RSTART
          tok = substr(probe, RSTART, RLENGTH)
          strip_tabs = (tok ~ /^<<-/) ? 1 : 0
          sub(/^<<-?[ ]*/, "", tok)
          term = strip_quotes(tok)
          if (term != "") {
            # 終端行を探す。無ければ bash と同じく EOF まで本文(溜めた本文は捨てず同じ規則で流す)
            e = 0
            for (j = i + 1; j <= n; j++) {
              chk = L[j]
              if (strip_tabs) sub(/^\t+/, "", chk)
              if (chk == term) { e = j; break }
            }
            terminated = (e > 0) ? 1 : 0
            if (e == 0) e = n
            k++; hs[k] = i; he[k] = e; hterm[k] = terminated
            # (a) 受け手が cat か
            seg = owner_segment(probe, hdpos)
            sink = (seg ~ /^cat([ \t]|$)/) ? 1 : 0
            # (c) cat 以降(開始行の残り全部)に | $( <( >( バッククォートが無いか
            after = seg substr(probe, hdpos)
            if (sink && (after ~ /\|/ || index(after, "$(") > 0 || index(after, "<(") > 0 || index(after, ">(") > 0 || index(after, "`") > 0)) sink = 0
            # (b) stdout の file リダイレクト先がリテラルか
            target = ""
            if (sink) {
              target = sink_target(after)
              if (target == "") sink = 0
            }
            # (d) 書き出し先が他の場所に再び現れないか(開始行の2回目以降・本文外の全行)
            if (sink && occurs(line, target) > 1) sink = 0
            for (j = 1; j <= n && sink; j++) {
              if (j >= i && j <= e) continue
              if (occurs(L[j], target) > 0) sink = 0
              if (has_glob_exec_risk(L[j])) sink = 0
            }
            # (e) 本文に置換記号が無いか(unquoted heredoc は展開される)
            last = terminated ? e - 1 : e
            for (j = i + 1; j <= last && sink; j++) {
              if (index(L[j], "$(") > 0 || index(L[j], "`") > 0) sink = 0
            }
            hmask[k] = sink
            i = e + 1
            continue
          }
        }
        i++
      }
      # pass 2: 出力(マスク対象の本文だけを HEREDOC_BODY_MASKED に置換)
      cur = 1
      for (m = 1; m <= k; m++) {
        for (i = cur; i < hs[m]; i++) print L[i]
        print L[hs[m]]
        last = hterm[m] ? he[m] - 1 : he[m]
        if (hmask[m]) {
          print "HEREDOC_BODY_MASKED"
        } else {
          for (i = hs[m] + 1; i <= last; i++) print L[i]
        }
        if (hterm[m]) print L[he[m]]
        cur = he[m] + 1
      }
      for (i = cur; i <= n; i++) print L[i]
    }
  ' <<<"$cmd"
}

# ============================================================
# Helper: detect git subcommand invocation
# Catches: direct (git push), full path (/usr/bin/git push),
#   command/env wrapper, function alias (f(){ git "$@"; }; f push),
#   variable alias (v=git; $v push)
# ★FP-H3是正: cmd は呼び出し直後に heredoc本文がマスクされたものへ
#   置き換える。呼び出し側 (Hook1/3/D003/D004) は改修不要。
# ============================================================
has_git_subcmd() {
  local cmd
  cmd="$(_mask_heredoc_bodies_for_git_detection "$1")"
  local subcmd="$2"
  # Direct: git push, git commit
  echo "$cmd" | grep -qE "git\s+$subcmd\b" && return 0
  # git -C <dir> subcmd (the -C global option breaks the direct "git <subcmd>" adjacency)
  echo "$cmd" | grep -qE "git\s+-C\s+(\"[^\"]+\"|[^[:space:]&;|]+)\s+$subcmd\b" && return 0
  # Full path: /usr/bin/git push
  echo "$cmd" | grep -qE "/git\s+$subcmd\b" && return 0
  # command/env wrapper: command git push, env git push
  echo "$cmd" | grep -qE "(command|env)\s+git\s+$subcmd\b" && return 0
  # Function alias: f() { git "$@"; } ... f push
  echo "$cmd" | grep -qE '\(\)\s*\{[^}]*git\b' && echo "$cmd" | grep -qE "\b$subcmd\b" && return 0
  # Variable alias: v=git; $v push
  echo "$cmd" | grep -qE '\w+=git(\s|;|&|$)' && echo "$cmd" | grep -qE "\b$subcmd\b" && return 0
  # Variable subcommand: SUBCMD=push; git $SUBCMD
  echo "$cmd" | grep -qiE "\w+=$subcmd(\s|;|&|\"|$)" && echo "$cmd" | grep -qE 'git\s+\$' && return 0
  return 1
}

# ============================================================
# Skip: Marker file `.guard-skip` present
# ----------------------------------------------------------------
# リポルートに .guard-skip ファイルがあれば全 hook をスキップ。
# Obsidian Vault のように auto-sync で main 直接 commit/push が運用前提の
# リポで、各環境 (WSL2 / Mac mini) のパスに依存せず明示マーカーで除外する。
# 殿の指示 (2026-06-06): Vault 削除事故 + push 阻害が起きたため恒久対策。
# Obsidian Vault には別途 .guard-skip を置くこと (リポ毎に明示)。
# ============================================================
SKIP_CWD=$(resolve_git_dir "$COMMAND")
SKIP_GIT_ROOT=$(git -C "$SKIP_CWD" rev-parse --show-toplevel 2>/dev/null || true)
if [ -n "$SKIP_GIT_ROOT" ] && [ -f "$SKIP_GIT_ROOT/.guard-skip" ]; then
  exit 0
fi

# ============================================================
# Hook 1: Co-Authored-By 禁止
# ============================================================
if has_git_subcmd "$COMMAND" "commit" && echo "$COMMAND" | grep -qi 'Co-Authored-By'; then
  echo "❌ Co-Authored-By は禁止です。CLAUDE.md の Git Commit Rules を確認してください。" >&2
  exit 2
fi

# ============================================================
# Hook 2: 破壊的操作ガード (D001-D008)
# ============================================================

# ============================================================
# D001/D002 ヘルパ (cmd_711): 再帰 rm の全フラグ形 + パスゾーン判定
# ------------------------------------------------------------
# 背景: 旧 D001 は `rm -rf` のリテラルにのみ反応し `rm -r`/`rm -fr`/
# `rm -R`/`rm --recursive` 等が素通りしていた(軍師 subtask_709c_qc 発見)。
# また D002 (プロジェクト作業ツリー外への再帰削除禁止) は rm について
# 一切未実装だった。本ブロックで両穴を塞ぐ。
# ★最重要方針: 過剰ブロックは穴と同じくらい有害。許可ゾーン(_in_allowed_zone)
# を必ず維持し、足軽の正当な削除(build/node_modules/scratchpad/隔離コピー)
# を止めぬこと。
# ============================================================

# realpath -m 相当をポータブルに得る。
# GNU realpath (Linux/WSL2) は -m 対応。macOS 標準 /bin/realpath は -m 非対応
# (illegal option で exit 1・stdout 無し)ゆえ grealpath → 純 bash 実装の順で
# フォールバックする。
_resolve_symlink_chain() {
  local p="$1" link
  local -i i=0
  while [[ -L "$p" ]] && (( i < 40 )); do
    link=$(readlink "$p" 2>/dev/null || true)
    [[ -z "$link" ]] && break
    if [[ "$link" != /* ]]; then
      link="$(dirname "$p")/$link"
    fi
    p="$link"
    i=$((i + 1))
  done
  echo "$p"
}

_lexical_normalize() {
  local path="$1"
  [[ "$path" != /* ]] && path="$PWD/$path"
  local IFS='/'
  local -a parts stack
  read -ra parts <<< "$path"
  local part
  for part in "${parts[@]}"; do
    case "$part" in
      ""|".") continue ;;
      "..") [[ ${#stack[@]} -gt 0 ]] && unset 'stack[${#stack[@]}-1]' ;;
      *) stack+=("$part") ;;
    esac
  done
  local out="" seg
  for seg in "${stack[@]}"; do
    out+="/$seg"
  done
  [[ -z "$out" ]] && out="/"
  echo "$out"
}

_realpath_m() {
  local raw="$1" out
  if out=$(realpath -m -- "$raw" 2>/dev/null); then
    echo "$out"; return 0
  fi
  if command -v grealpath >/dev/null 2>&1 && out=$(grealpath -m -- "$raw" 2>/dev/null); then
    echo "$out"; return 0
  fi
  _lexical_normalize "$(_resolve_symlink_chain "$raw")"
}

# 短縮束(-rf/-fr/-Rf/-rvf/-r/-R)または長形式(--recursive)を再帰フラグとして
# 捕捉する。-f の有無は判定を変えぬ(通常ファイルへの再帰削除力は -r で十分
# ——これが旧実装の穴の本質)。
_has_recursive_flag() {
  echo "$1" | grep -qE '(^|[[:space:]])(-[A-Za-z]*[rR][A-Za-z]*|--recursive)([[:space:]]|=|$)'
}

# rm 起動区間から非フラグ引数(=削除対象パス)を列挙する。
# ★引用符除去: `rm -rf "/etc"` は素の word-split では先頭 `"` が付いた
# トークンになり `[[ "$raw" != /* ]]` の相対パス分岐に誤って落ちて
# バイパスされる(cmd_711 レビューで検出)。前後の一致しない引用符1つずつを
# 剥がして絶対パス判定に戻す。スペースを含む引用パスの完全な再構成までは
# しない(word-split の既知の限界だが、危険な先頭セグメント (/etc・/home/*等)
# は引用符除去だけで正しく捕捉できる)。
_extract_rm_targets() {
  local seg="$1" tok
  # ★セルフレビュー是正(1巡目): `for tok in $seg` は素のword-splitのためglob文字(*?[)を
  # 含むトークン(例: `rm -f config/*.yaml`)がguard.sh自身のプロセスのcwd
  # 相手に実際にglob展開されてしまい、意図した文字列(可逆性ゲートの照合
  # 対象)ではなく guard.sh 実行時cwd依存の別ファイル名に化ける恐れがある。
  # このループは常に process substitution `<(...)` 経由(サブシェル内)で
  # 呼ばれるため、ここで `set -f` してもこの呼出元シェルの状態には漏れない。
  set -f
  for tok in $seg; do
    # ★軍師QC是正(check_2・C2): rm と同じ動詞として unlink を扱い、絶対/相対
    # パス接頭(/bin/rm等)・バックスラッシュエスケープ(\rm)・引用符
    # ("rm"/'rm')の形でコマンド名トークンが来ても、対象パスとして誤って
    # 位置引数扱いしないよう先頭語のスキップ判定を広げる。
    case "$tok" in
      rm|unlink) continue ;;
      '\rm'|'\unlink') continue ;;
      '"rm"'|'"unlink"'|"'rm'"|"'unlink'") continue ;;
      */rm|*/unlink) continue ;;
    esac
    [[ "$tok" == -* ]] && continue
    tok="${tok#[\"\']}"
    tok="${tok%[\"\']}"
    [[ -z "$tok" ]] && continue
    echo "$tok"
  done
  set +f
}

# 許可ゾーン三点: (a) 対象repoのgit toplevel配下 (b) セッションscratchpad配下
# (c) 隔離検証用の指定置き場 /tmp/shogun-isolated/ (cmd_711 新設)。
# ここに該当すれば D002 の対象外として通す。
_in_allowed_zone() {
  local p="$1" root
  root=$(git -C "$GIT_TARGET_DIR" rev-parse --show-toplevel 2>/dev/null || true)
  if [[ -n "$root" ]]; then
    case "$p/" in "$root"/*) return 0 ;; esac
  fi
  case "$p/" in /private/tmp/claude-*/*/scratchpad/*) return 0 ;; esac
  case "$p/" in /tmp/claude-*/*/scratchpad/*) return 0 ;; esac
  case "$p/" in /tmp/shogun-isolated/*) return 0 ;; esac
  case "$p/" in /private/tmp/shogun-isolated/*) return 0 ;; esac
  return 1
}

# rm 対象パス1件の可否を判定する。RM_BLOCK_REASON に D001/D002 を設定して
# 戻り値 1 (block) を返す。0 = allow。
RM_BLOCK_REASON=""
_rm_target_verdict() {
  local raw="$1" p cwd_root
  # guard.sh は文字列のみを見るためシェルの ~/$HOME 展開は起きない。明示的に
  # 展開する。★$HOME 未展開のまま(cmd_711f 将軍指摘): `rm -r $HOME/../etc`
  # は、文字列上「$HOME」という架空のリテラルディレクトリ名として扱われ、
  # 直後の `..` と字面上で相殺されて cwd_root 配下に丸め込まれ誤 ALLOW に
  # なる(実 bash 実行時は $HOME が実パスへ展開され、全く別の場所——多くは
  # プロジェクト外——を削除する)。static 解析側でも展開して整合させる。
  # ★${HOME}(中括弧付き)は "}" で self-terminating なので部分一致の
  # 心配はないが、素の $HOME は $HOMEBASE/$HOMEDIR 等の別変数名の接頭辞と
  # 衝突しうる。sed で「直後が識別子文字でない」場合のみ展開する(境界一致)。
  raw="${raw//\$\{HOME\}/$HOME}"
  if [[ "$raw" == *'$HOME'* ]]; then
    local _home_esc="${HOME//&/\\&}"
    raw="$(printf '%s' "$raw" | sed -E "s#\\\$HOME([^A-Za-z0-9_]|\$)#${_home_esc}\\1#g")"
  fi
  case "$raw" in
    "~") raw="$HOME" ;;
    "~/"*) raw="$HOME/${raw#\~/}" ;;
  esac
  # 過剰ブロック防止: 相対パス/裸のglob(`rm -rf *` 等)は、cwd が対象repoの
  # git toplevel配下に解決できる場合のみ許可する(シェル展開前の文字列しか
  # guard は見えぬため、cwd が許可ゾーン内なら安全側とみなす)。
  # ★軍師QC(subtask_711c_qc)指摘: これを`..`を含む相対パスにも無条件適用
  # すると`rm -r ../../../etc`等のツリー外脱出が素通りする。`..`を含む
  # 相対パスは cwd_root と結合し realpath 解決してから通常のゾーン判定へ
  # 回す(下の p=$(_realpath_m "$raw") 以降のフロー)。
  if [[ "$raw" != /* ]]; then
    cwd_root=$(git -C "$GIT_TARGET_DIR" rev-parse --show-toplevel 2>/dev/null || true)
    if [[ "$raw" != *..* ]]; then
      [[ -n "$cwd_root" ]] && return 0
    elif [[ -n "$cwd_root" ]]; then
      raw="$cwd_root/$raw"
    fi
    # finding_B是正 (cmd_711i): 上の分岐で解決できなかった相対パス
    # (非gitディレクトリ、例: scratchpad一時dir)は、_realpath_m の
    # $PWD フォールバック(=hookプロセス自身のcwd)ではなく GIT_TARGET_DIR
    # (コマンド文字列から抽出した cd 先)を基準に絶対化する。旧実装は
    # ここで raw を相対のまま _realpath_m へ渡していたため、
    # 「cd <scratchpad> && rm -rf ./sub」のような呼び出しが hook 自身の
    # cwd(通常はプロジェクトルート)基準で誤って絶対化され D002 誤爆していた。
    [[ "$raw" != /* ]] && raw="$GIT_TARGET_DIR/$raw"
  fi

  p=$(_realpath_m "$raw")

  case "$p" in
    /|/bin|/boot|/dev|/etc|/lib|/lib64|/proc|/root|/sbin|/srv|/sys|/usr|/var|/mnt|/home)
      RM_BLOCK_REASON="D001"; return 1 ;;
  esac
  # ★軍師QC是正相当(cmd_845実測): 旧実装は `/mnt/*`・`/home/*` を case パターン
  # に直接書いていたが、bashのcaseパターンにおける `*` は(実シェルのpathname
  # 展開と異なり)"/"を跨いで一致する。よって `/home/runner/work/<repo>/<repo>/
  # build` のような、/homeの★深い子孫(project worktree自身がその配下にある
  # だけ)まで誤って"/home/*"に一致し、D001としてブロックしてしまっていた
  # (実測: GitHub Actions ubuntu-latest runnerのcheckout先が/home/runner/work/…
  # であるため、test_hooks.shの「プロジェクト内: rm -rf <PROJ>/build」allow
  # テストがCIで初めて実行された際に発覚——ローカル操作者の$HOMEは通常
  # /home配下でないため気づかれなかった)。意図(CLAUDE.md D001: 「全ユーザの
  # ホームを丸ごと消す」`rm -rf /home/*`・WSL2の各Windowsドライブ丸ごと消す
  # `rm -rf /mnt/*`)は/mnt・/homeの★直下1階層のみを指すため、「対象が
  # /mnt または /home の直属の子(その先に/を含まない)か」で判定する
  # (深い子孫はプロジェクト外ならD002が別途捕捉する・worktree内ならそもそも
  # 通常のプロジェクト内作業として許可されるべき)。
  case "$p" in
    /mnt/*)
      [[ "${p#/mnt/}" != */* ]] && { RM_BLOCK_REASON="D001"; return 1; }
      ;;
    /home/*)
      [[ "${p#/home/}" != */* ]] && { RM_BLOCK_REASON="D001"; return 1; }
      ;;
  esac
  if [[ "$p" == "$HOME" ]]; then
    RM_BLOCK_REASON="D001"; return 1
  fi

  _in_allowed_zone "$p" && return 0

  RM_BLOCK_REASON="D002"
  return 1
}

# D001/D002: rm 起動を個別に走査(複合コマンド `rm -f a && rm -r /x` で
# 2件目を見落とさぬよう、区切りで1回だけ切るのでなく各 rm 起動をループで評価)。
while IFS= read -r rm_invocation; do
  [[ -z "$rm_invocation" ]] && continue
  # 抽出時に混入し得る先頭の区切り文字(;&|(=)を1つだけ除去
  rm_invocation="$(echo "$rm_invocation" | sed -E 's/^[;&|(=]//')"
  _has_recursive_flag "$rm_invocation" || continue
  while IFS= read -r target; do
    [[ -z "$target" ]] && continue
    if ! _rm_target_verdict "$target"; then
      if [[ "$RM_BLOCK_REASON" == "D001" ]]; then
        echo "❌ 破壊的操作が検出されました: rm 再帰削除が重要パスを対象 ($target)。D001 違反です。" >&2
      else
        echo "❌ 破壊的操作が検出されました: rm 再帰削除がプロジェクト作業ツリー外を対象 ($target)。D002 違反です。" >&2
      fi
      exit 2
    fi
  done < <(_extract_rm_targets "$rm_invocation")
done < <(echo "$COMMAND" | grep -oE '(^|[[:space:];&|(=])rm[[:space:]][^;&|]*' || true)

# ============================================================
# Hook 9: 可逆性ゲート (cmd_813・殿ご裁可2026-09-13深夜)
# ------------------------------------------------------------
# 背景: 本日02:10、config/settings.yaml が消失した(subtask_pr129_followups_f1_f2_f3・
# bloom_level=L3・risk_flag=false)。旧来の夜間ルールは「重さ」(bloom_level/risk_flag)
# で新規着手の可否を判じており、この事故そのものは「軽い」として夜間発注を許して
# いた。軸が逆を向いていた——判ずるべきは「重さ」でなく「元に戻せるか」である。
#
# ★新しい軸(殿ご指示): 次のいずれかに該当する操作は昼夜を問わず門の対象とする。
#   ② worktree外(git toplevel外・scratchpad/isolated以外)への書込み・削除
#   ④ 常駐設定ファイル(config/settings.yaml・.claude/settings.json等)への
#      書込み・削除、および launchd/cron の変更
#   (③ 外部への不可逆操作は本Hookの末尾で別途扱う——gh pr merge/close等)
#
# ★スコープを絞った理由(実測に基づく判断・過剰ブロック防止):
#   「①gitignore対象すべてを門にする」案は採らなかった。既存の許可テスト
#   (`rm -rf $PROJ_ROOT/build`・`rm -r $PROJ_ROOT/node_modules` 等・いずれも
#   gitignore対象)が示すとおり、build成果物・node_modules・ログ等の使い捨て
#   gitignoreファイルの削除は worktree 内の通常作業そのものであり、これを
#   門にすると「誤検知で家中が止まる」(過去のguard.sh FP是正の教訓)を
#   再現する。ゆえに①は「git管理外か」ではなく「常駐設定として名指しされた
#   少数の重要ファイルか」(④)へ限定して実装する。これにより build/
#   node_modules 等は従来どおり素通りし、config/settings.yaml 等の一点物は
#   場所(git管理下/外・worktree内/外)を問わず門に掛かる。
#   また `>` によるファイル上書きリダイレクトの検知は本Hookでは実装しない
#   (heredoc受け手判定=FP-H3/FN-H3是正と衝突しうる一般化のコストが高く、
#   acceptance_criteriaの実証対象=rm/cpの範囲を超えるため)。同様に
#   `sed -i` in-place編集も対象外とした(sed起動の位置引数解析はcp/mvより
#   曖昧で誤検知リスクが高い)。いずれも既知のギャップとして報告に明記する。
#   ★既知のギャップ(セルフレビュー是正・1巡目・PR初版で発見): rm/cp/mv の対象パス抽出は
#   `for tok in $seg` による素の word-split(IFS区切り)であり、スペースを
#   含む引用符付きパス(例: `mv "a file.txt" "/outside/b file.txt"`)は
#   正しく1トークンへ復元されない。これは D001/D002(_extract_rm_targets)
#   が既に持つのと同じ既知の限界であり、正しく解くには実shell文法を解釈する
#   トークナイザが要る(evalによる再解釈は、まさにHook8が塞いでいる
#   コマンド置換注入のリスクを本Hookに持ち込むため採らない)。本PRの範囲では
#   解決せず、follow-upとして正直に記す。
#

# ★裁可の通し方(門であって禁止ではない): リポルートに `.guard-authorized`
# ファイル(task_id: <cmd_id> / expires: <ISO8601 UTC>)を置けば、期限内に
# 限り本Hookのみ(他のHookは従来どおり有効)を通す。口頭・inbox文言では
# 通さず、機械が確認できるファイルの存在と期限のみを根拠とする——
# 既存の `.guard-skip`(全hook無効・恒久)と異なり、本マーカーは
# 「このHookだけ・期限付き」に絞ってある。
# ============================================================

# ★軍師QC是正(check_1・C3): 名指し3ファイルのみでは、名簿に書き忘れた
# config/ 配下の一点物(config/ntfy_auth.env・config/projects.yaml等)が
# 裸のまま残る——本日失われたsettings.yamlと全く同じ性質(git管理外・
# 控え無し・一点物)の隣人が守られていなかった(軍師が隔離fixtureで実証)。
# 「config」(ディレクトリ自体・祖先削除/globでの一致判定用)と
# .claude/* の名指しは残しつつ、config/ 配下の個別ファイルは
# _is_config_resident_file() による一般化規則(*.sample以外は全て対象)へ
# 委ねる——新しいファイルが増えても名簿への追記漏れが起きない。
REVERSIBILITY_GUARDED_RELPATHS=(
  "config"
  ".claude/settings.json"
  ".claude/settings.local.json"
)

_reversibility_guard_root() {
  git -C "$GIT_TARGET_DIR" rev-parse --show-toplevel 2>/dev/null || echo "$GIT_TARGET_DIR"
}

# origin remoteでリポを識別できる場合のみ「multi-agent-shogunでない」と
# 確定させる(判定不能なら安全側=本リポ扱い)。GUARDED_CONFIG判定でのみ使う
# ——②worktree外・③外部不可逆操作・④daemon設定は本リポに限定しない
# (これらの性質はリポの種類を問わず危険であるため)。
_reversibility_repo_is_own() {
  local remote
  remote=$(git -C "$_REVERSIBILITY_ROOT" remote get-url origin 2>/dev/null || echo "")
  [[ -z "$remote" ]] && return 0
  case "$remote" in
    *multi-agent-shogun*) return 0 ;;
    *) return 1 ;;
  esac
}

# 常駐設定ファイル(④)に該当するか。git管理下/外・worktree内/外を問わず
# 名指しの少数パスのみを対象とする(スコープを絞った理由は上記コメント参照)。
# ★セルフレビュー是正(1巡目): 完全一致だけでは `rm -rf config/` のような親ディレクトリ
# 丸ごと削除(guarded fileを内包する)を見落とす。「対象がguarded fileそのもの」
# 「対象がguarded fileを内包するディレクトリ」の両方を判定する。
# ★セルフレビュー是正(1巡目): 完全一致(文字列比較)だけでは `rm -f config/*.yaml` のような
# glob指定が「config/settings.yaml」という文字列と一致せずすり抜ける。
# ★是正2のfollow-up(自己是正・回帰発見): 当初 `[[ guarded_abs == $p ]]` で
# 素朴にパターン一致させたところ、bashの `[[ == ]]` は`*`が`/`を跨いで
# 一致してしまう(実際のシェルglob展開とは異なる)ため、`rm -rf *`(プロジェクト
# 直下の裸ワイルドカード・test_hooks.shが従来からallowとして固定してきた
# 正当な操作)まで誤ってguarded configに一致し、既存回帰テストを壊した。
# 実際のシェルglob展開は`*`が`/`をまたがない——ディレクトリ部を先に完全一致
# させ、globパターンは★同じディレクトリ内のbasenameにのみ適用することで、
# `config/*.yaml`(同一ディレクトリ内)は捕捉しつつ`rm -rf *`(ディレクトリを
# 跨ぐ裸ワイルドカード)は誤検知しない。
# ★セルフレビュー是正(2巡目・自己是正): 祖先ディレクトリ判定 `case "$guarded_abs" in
# "$p"/*)` は $p を★クォート付きで使っていたため、bashのcaseパターン規則
# (クォートされた展開内のglob文字はリテラル一致にしかならない)により、
# $p自体にglob文字が含まれる場合(`rm -rf con*` 等・ディレクトリ名そのものを
# globで指定する形)にワイルドカードとして機能せず、実シェルでは
# `config`ディレクトリへ展開されうる `con*` がguarded_abs(.../config/...)と
# 一致せずすり抜けていた(実証: `cd <repo> && rm -rf con*` が是正前は exit 0)。
# $p を★クォート無しでcaseパターン位置に置くことで、glob文字を意図通り
# ワイルドカードとして機能させる(basename側の判定で既にこの流儀を使って
# いたのと対称)。
_is_guarded_config_path() {
  local p="$1" root="$2" g guarded_abs
  # ★セルフレビュー是正(3巡目): 対象が root★そのもの(`rm -rf .`・`rm -rf <絶対
  # worktreeパス>`)の場合、旧ガードは「rootの厳密に配下」だけを受理して
  # いたためここで即 return 1 してしまい、worktree丸ごと削除(guarded file
  # を道連れにする)を素通りしていた(実証済み)。root自身も対象に含める。
  case "$p" in "$root"|"$root"/*) ;; *) return 1 ;; esac
  # ★セルフレビュー是正(2巡目): このガードは「本リポ(multi-agent-shogun)自身」に
  # 限定する。config/settings.yaml・.claude/settings.json のような相対パスは
  # 他の一般的なリポ(Python/dynaconf系プロジェクト等)にもありふれた命名であり、
  # CLAUDE.md の External Repo Context Rule に従って外部リポのworktreeへcdして
  # 作業する足軽の通常業務(そのリポ自身の無関係なconfig/settings.yaml操作)を
  # 誤って阻害しかねない。origin remoteでリポを識別できる場合のみ「他リポと
  # 確定できたら対象外」とし、判定不能(remote未設定・隔離テストrepo等)の
  # 場合は安全側(=対象とする)に倒す。
  _reversibility_repo_is_own || return 1
  _is_config_resident_file "$p" "$root" && return 0
  for g in "${REVERSIBILITY_GUARDED_RELPATHS[@]}"; do
    guarded_abs="$root/$g"
    _reversibility_path_glob_matches "$p" "$guarded_abs" && return 0
  done
  return 1
}

# ★軍師QC是正(check_1・C3): config/ 配下を「gitignore対象で*.sample以外は
# 全て名簿入り」へ一般化する(karo推奨の代替案を採用)。config/直下1階層
# のみを対象とし(深い階層は対象外・現状config/には何も無い)、対象パスに
# glob文字が含まれる場合も同一ディレクトリ内のbasenameマッチとして扱う
# (`config/proj*` 等)。ancestor(config自体の削除・`rm -rf con*`等)は
# 上位のREVERSIBILITY_GUARDED_RELPATHSの"config"エントリが別途担う。
_is_config_resident_file() {
  local p="$1" root="$2" rel
  case "$p" in "$root"/config/*) ;; *) return 1 ;; esac
  rel="${p#"$root"/config/}"
  [[ "$rel" == */* || -z "$rel" ]] && return 1
  # shellcheck disable=SC2053  # $rel は意図的にglobパターンとして展開させる
  # (例: `rm -f config/*.sample` の rel="*.sample" もここで正しく除外される)
  [[ "$rel" == *.sample ]] && return 1
  return 0
}

# ★セルフレビュー是正(3巡目・自己是正・回帰再発見): 上記コメントの祖先ディレクトリ
# 判定を単純に `$p/*`(クォート無しcaseパターン)へ直しただけでは、`*`が
# 実シェルのglob展開と異なり `/` を跨いで一致してしまう問題が別の形で再発した
# ——`rm -rf *`(プロジェクト直下の裸ワイルドカード)が `$root/*` という
# パターンとなり、`/*`を後ろに足した`$root/*/*`が`$root/config/settings.yaml`
# に(*がconfigとsettings.yamlの間の/を跨いで)一致してしまい、既存の
# 「rm -rf *はallow」回帰テストを壊した(2度目の同型の罠)。
# ★正しい解: 実シェルのglobは"/"をまたがない(1セグメント=1階層にしか
# 効かない)。パスをセグメント(=path component)ごとに分解し、対応する
# セグメント同士だけでglobマッチさせる。pの★最終セグメントが裸の"*"一語
# だけ(文字情報が皆無)であれば、`rm -rf *`のような従来allowの広域
# ワイルドカードとして扱い、一致させない——`con*`のように文字を伴う
# セグメントは、最終セグメントであっても意図的な指定とみなし通常どおり
# マッチさせる。
# ★軍師QC是正(check_1・C3対応での再発見): 当初この除外は「n<m(祖先境界)の
# 時だけ」に限っていたが、guarded_abs のエントリを"config/settings.yaml"
# から"config"(ディレクトリ自体)へ一般化したことで、`rm -rf *`(p="$root/*"、
# n=root+1)と"config"(guarded_abs、m=root+1)が★同じ深さ(n==m)になり、
# n<m限定の除外が効かず`*`が"config"へ再び誤一致する回帰が起きた
# (「rm -rf *は/を跨がず不一致」という同じ罠の3度目)。n<mの限定を外し、
# pの最終セグメントが裸の"*"なら n==m でも n<m でも一律に不一致とする。
_reversibility_path_glob_matches() {
  local p="$1" guarded_abs="$2"
  local -a p_segs g_segs
  IFS='/' read -ra p_segs <<< "$p"
  IFS='/' read -ra g_segs <<< "$guarded_abs"
  local n=${#p_segs[@]} m=${#g_segs[@]}
  [[ $n -gt $m ]] && return 1
  local i pseg gseg
  for ((i = 0; i < n; i++)); do
    pseg="${p_segs[$i]}"
    gseg="${g_segs[$i]}"
    if [[ $i -eq $((n - 1)) && "$pseg" == "*" ]]; then
      # 祖先ディレクトリ境界の最終セグメントが裸の"*"のみ→広域ワイルドカード
      # として不一致扱い(rm -rf * 等の既存allow挙動を保つ)。
      return 1
    fi
    # shellcheck disable=SC2053  # $pseg は意図的にglobパターンとして展開させる
    [[ "$gseg" == $pseg ]] || return 1
  done
  return 0
}

# rm/cp/mv 共通の絶対パス解決。_rm_target_verdict の $HOME展開・~展開・
# 相対パス絶対化ロジックを一般化(verdict早期return最適化は持たず常に
# realpath -m まで通す——rm以外の呼出元でも同じ基準で判定するため)。
_resolve_reversibility_target() {
  local raw="$1" root="$2"
  raw="${raw//\$\{HOME\}/$HOME}"
  if [[ "$raw" == *'$HOME'* ]]; then
    local _home_esc="${HOME//&/\\&}"
    raw="$(printf '%s' "$raw" | sed -E "s#\\\$HOME([^A-Za-z0-9_]|\$)#${_home_esc}\\1#g")"
  fi
  case "$raw" in
    "~") raw="$HOME" ;;
    "~/"*) raw="$HOME/${raw#\~/}" ;;
  esac
  if [[ "$raw" != /* ]]; then
    if [[ -n "$root" ]]; then
      raw="$root/$raw"
    else
      raw="$GIT_TARGET_DIR/$raw"
    fi
  fi
  _realpath_m "$raw"
}

# ★セルフレビュー是正(1巡目・性能): git rev-parse / .guard-authorized の読取りは1回の
# guard.sh実行で複数回呼ばれうる(rm対象複数・cp/mv・gh/launchctl/crontab)。
# 1コマンドにつき1回だけ計算しキャッシュする。
_REVERSIBILITY_ROOT=$(_reversibility_guard_root)

# ★セルフレビュー是正(2巡目・FP-H3/FN-H3の教訓を未適用だった穴): has_git_subcmd は
# heredoc本文の地の文(例: 報告書に「手順: rm -f config/settings.yaml」と
# 書いただけ)を実コマンドと誤認しないよう既に _mask_heredoc_bodies_for_git_detection
# でマスクしているが、Hook 9 の rm/cp/mv/gh/launchctl/crontab 検知は素の
# $COMMAND を直接grepしており、この対策が適用されていなかった(実証: heredoc
# 本文に "gh pr merge" 等の語を含むだけの安全なファイル書き出しがblockされる
# FP)。同じマスク済みコマンド文字列を使い回す。
_REVERSIBILITY_MASKED_COMMAND="$(_mask_heredoc_bodies_for_git_detection "$COMMAND")"

# ★軍師QC是正(check_2・C2・X1/X2): `bash -c '...'` / `eval "..."` は中身を
# 再走査しないと、内部で書かれた `rm -f config/settings.yaml` 等が丸ごと
# 見えなくなる(軍師実証)。中身を安全に「実行はせず文字列として」取り出し、
# 走査対象テキストへ追記するだけに留める(evalによる再解釈はしない——
# Hook8がまさに塞いでいるコマンド置換注入のリスクを持ち込むため)。
# 単純な単一/二重引用符で閉じた形のみを対象とし(入れ子引用符・エスケープの
# 完全な解釈はしない・既知の限界としてコメントに明記)、以後の全チェック
# (rm/cp/mv/ln・gh/launchctl/crontab)がこの追記テキストも自然に見る。
_reversibility_extract_subshell_bodies() {
  local cmd="$1"
  # ★grep -oEは非一致時exit 1を返す(通常時のnot foundは大多数のコマンドで
  # 起きる)。set -euo pipefail 下でこれを無防備に置くとスクリプト全体が
  # 即死する(自己是正・実際にgit status等の無害なコマンドで再現)。
  # 各パイプラインへ `|| true` を付す。
  { echo "$cmd" | grep -oE "(^|[[:space:];&|(=])(bash|sh|zsh)[[:space:]]+-c[[:space:]]+'[^']*'" \
    | sed -E "s/^.*-c[[:space:]]+'//; s/'\$//"; } || true
  { echo "$cmd" | grep -oE '(^|[[:space:];&|(=])(bash|sh|zsh)[[:space:]]+-c[[:space:]]+"[^"]*"' \
    | sed -E 's/^.*-c[[:space:]]+"//; s/"$//'; } || true
  { echo "$cmd" | grep -oE "(^|[[:space:];&|(=])eval[[:space:]]+'[^']*'" \
    | sed -E "s/^.*eval[[:space:]]+'//; s/'\$//"; } || true
  { echo "$cmd" | grep -oE '(^|[[:space:];&|(=])eval[[:space:]]+"[^"]*"' \
    | sed -E 's/^.*eval[[:space:]]+"//; s/"$//'; } || true
}
_REVERSIBILITY_SUBSHELL_BODIES="$(_reversibility_extract_subshell_bodies "$COMMAND")"
if [[ -n "$_REVERSIBILITY_SUBSHELL_BODIES" ]]; then
  _REVERSIBILITY_MASKED_COMMAND="$_REVERSIBILITY_MASKED_COMMAND
$_REVERSIBILITY_SUBSHELL_BODIES"
fi

REVERSIBILITY_BLOCK_REASON=""
_reversibility_verdict() {
  local raw="$1" p
  p=$(_resolve_reversibility_target "$raw" "$_REVERSIBILITY_ROOT")
  if _is_guarded_config_path "$p" "$_REVERSIBILITY_ROOT"; then
    REVERSIBILITY_BLOCK_REASON="GUARDED_CONFIG(④常駐設定ファイル)"
    return 1
  fi
  if _in_allowed_zone "$p"; then
    return 0
  fi
  REVERSIBILITY_BLOCK_REASON="OUTSIDE_WORKTREE(②worktree外)"
  return 1
}

# ISO8601(UTC・Z終端)→epoch秒。GNU date(-d)優先、無ければBSD date(-j -f)。
_iso8601_to_epoch() {
  local iso="$1" out
  if out=$(date -u -d "$iso" +%s 2>/dev/null); then echo "$out"; return 0; fi
  if out=$(date -u -j -f "%Y-%m-%dT%H:%M:%SZ" "$iso" +%s 2>/dev/null); then echo "$out"; return 0; fi
  return 1
}

# `.guard-authorized`(task_id: <id> / expires: <ISO8601 UTC>)が存在し、
# 期限内であれば本Hookのみ通す。存在しない/期限切れ/フィールド欠如は
# 全て「裁可なし」として扱う(安全側)。
# ★軍師QC是正(check_4・C4b): 是正前は誰でも自分でこのファイルを作って
# 自分で通れた(軍師実証:printf で即席作成→rc=0)。git追跡下のファイルに
# 限定する——足軽はmainへ直接commitできぬ(Hook3)ため、真に設置するには
# 少なくとも一度はcommitという痕跡を残す必要が生じる。★完全な防御では
# ない(自分のfeatureブランチへcommitする分には依然として自己完結できる)
# ことは正直に記す——ただしgit履歴に残る点・(C4aの)使用時ログ記録と
# 組み合わさることで、「誰にも気づかれず無音で通る」経路は塞がれる。
_reversibility_override_active() {
  local file="$_REVERSIBILITY_ROOT/.guard-authorized" task_id expires now_epoch exp_epoch
  [[ -f "$file" ]] || return 1
  git -C "$_REVERSIBILITY_ROOT" ls-files --error-unmatch .guard-authorized >/dev/null 2>&1 || return 1
  task_id=$(grep -E '^task_id:' "$file" | head -1 | sed -E 's/^task_id:[[:space:]]*//')
  expires=$(grep -E '^expires:' "$file" | head -1 | sed -E 's/^expires:[[:space:]]*//')
  [[ -z "$task_id" || -z "$expires" ]] && return 1
  exp_epoch=$(_iso8601_to_epoch "$expires") || return 1
  now_epoch=$(date -u +%s)
  [[ "$now_epoch" -lt "$exp_epoch" ]]
}

# 1コマンドにつき1回だけ判定してキャッシュ(セルフレビュー是正・1巡目)。
if _reversibility_override_active; then
  _REVERSIBILITY_OVERRIDE_ACTIVE=1
else
  _REVERSIBILITY_OVERRIDE_ACTIVE=0
fi

# ★軍師QC是正(check_4・C4a): override使用時、是正前は無音でrc=0を返す
# だけだった(軍師実証)。使用の都度 logs/ へ1行追記し、dashboard.mdの
# 🚨要対応節へも積む(既存notify_dashboard系ウォッチャーの作法=見出し行
# 直後へsedで差し込む方式に相乗り)。「殿/将軍の裁可を機械的に確認する」
# 設計の趣旨を保つ——通しはするが、通した事実を消さない。
_reversibility_log_override_use() {
  # ★このHookはset -euo pipefail下で動く。本関数は素の文(if/whileの条件
  # としてではなく単独文として)呼ばれるため、内部のgrep等が「非一致=exit 1」
  # を返すと(自己是正・実際にgit status等の無害なコマンドで再現した罠と
  # 同根)スクリプト全体が即死する。全ての「非一致がありうる」抽出に
  # `|| true` を付す。
  local verb="$1" target="$2" ts task_id log_dir log_file entry dash marker_line tmpfile outfile
  ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  task_id=$( { grep -E '^task_id:' "$_REVERSIBILITY_ROOT/.guard-authorized" 2>/dev/null | head -1 | sed -E 's/^task_id:[[:space:]]*//'; } || true)
  log_dir="$_REVERSIBILITY_ROOT/logs"
  log_file="$log_dir/guard_override.log"
  entry="${ts} GUARD_OVERRIDE_USED verb=${verb} target=${target} task_id=${task_id:-unknown}"
  { mkdir -p "$log_dir" 2>/dev/null && echo "$entry" >> "$log_file" 2>/dev/null; } || true

  dash="$_REVERSIBILITY_ROOT/dashboard.md"
  if [[ -f "$dash" ]]; then
    marker_line=$( { grep -m1 -nE '^## .*要対応.*殿のご判断|^## .*🚨.*要対応' "$dash" 2>/dev/null | cut -d: -f1; } || true)
    if [[ -n "$marker_line" ]]; then
      tmpfile=$(mktemp 2>/dev/null) || true
      outfile=$(mktemp 2>/dev/null) || true
      if [[ -n "$tmpfile" && -n "$outfile" ]]; then
        printf -- '- 🚨 [guard.sh Hook9 override使用] %s\n' "$entry" > "$tmpfile" || true
        if sed "${marker_line}r ${tmpfile}" "$dash" > "$outfile" 2>/dev/null; then
          mv "$outfile" "$dash" 2>/dev/null || true
        fi
        rm -f "$tmpfile" "$outfile" 2>/dev/null || true
      fi
    fi
  fi
  return 0
}

_reversibility_denial_message() {
  local verb="$1" target="$2"
  echo "❌ 可逆性ゲート(cmd_813): $verb がgit管理外/worktree外/常駐設定ファイルを対象 ($target)。REASON=$REVERSIBILITY_BLOCK_REASON" >&2
  echo "   殿または将軍の明示裁可がある場合、リポルートに .guard-authorized (task_id/expires) を設置せよ。" >&2
}

# rm/unlink: 全形(非再帰も含む・D001/D002は再帰のみが対象のため取りこぼす)を
# 可逆性ゲートへ通す。
# ★軍師QC是正(check_2・C2): 直接形の `rm ...` のみを拾っていたため、軍師が
# 実証した以下の回避形が素通りしていた——
#   絶対/相対パス接頭(`/bin/rm ...`)・バックスラッシュエスケープ(`\rm ...`)・
#   引用符("rm"/'rm')・unlink(rmの直接の同義語)。
# 直接形に加えこれら4形を独立したパターンで拾う(bash -c/eval中身は
# 上で _REVERSIBILITY_MASKED_COMMAND へ追記済みのため、直接形の走査だけで
# 自然に再走査される)。
while IFS= read -r rm_invocation; do
  [[ -z "$rm_invocation" ]] && continue
  rm_invocation="$(echo "$rm_invocation" | sed -E 's/^[[:space:];&|(=]//')"
  while IFS= read -r target; do
    [[ -z "$target" ]] && continue
    if ! _reversibility_verdict "$target"; then
      if [[ "$_REVERSIBILITY_OVERRIDE_ACTIVE" -eq 1 ]]; then
        _reversibility_log_override_use "rm" "$target"
      else
        _reversibility_denial_message "rm" "$target"
        exit 2
      fi
    fi
  done < <(_extract_rm_targets "$rm_invocation")
done < <(
  {
    echo "$_REVERSIBILITY_MASKED_COMMAND" | grep -oE '(^|[[:space:];&|(=])(rm|unlink)[[:space:]][^;&|]*'
    echo "$_REVERSIBILITY_MASKED_COMMAND" | grep -oE '(^|[[:space:];&|(=])[^[:space:];&|]*/(rm|unlink)[[:space:]][^;&|]*'
    echo "$_REVERSIBILITY_MASKED_COMMAND" | grep -oE '(^|[[:space:];&|(=])\\(rm|unlink)[[:space:]][^;&|]*'
    echo "$_REVERSIBILITY_MASKED_COMMAND" | grep -oE '(^|[[:space:];&|(=])"(rm|unlink)"[[:space:]][^;&|]*'
    echo "$_REVERSIBILITY_MASKED_COMMAND" | grep -oE "(^|[[:space:];&|(=])'(rm|unlink)'[[:space:]][^;&|]*"
  } || true
)

# ★軍師QC是正(check_2・C2・X5): `R=rm; $R -f config/settings.yaml` のような
# 変数エイリアス経由の迂回(gh/launchctl/crontab向けに既にある変数エイリアス
# 検知と同型・軍師が「最も痛い指摘」と評した穴)。"$VAR args..." 形の呼出
# 候補を全て列挙し、その VAR が実際に rm/unlink へ代入されていた場合のみ
# rmと同じ対象抽出へ通す(単に迂回を粗くblockするのではなく、gh系と違い
# rmは対象パスの精密な抽出が既にあるため、そのまま流用できる)。
while IFS= read -r rm_alias_seg; do
  [[ -z "$rm_alias_seg" ]] && continue
  rm_alias_seg="$(echo "$rm_alias_seg" | sed -E 's/^[[:space:];&|(=]//')"
  rm_alias_first_tok="${rm_alias_seg%% *}"
  if [[ "$rm_alias_first_tok" == "$rm_alias_seg" ]]; then
    rm_alias_rest=""
  else
    rm_alias_rest="${rm_alias_seg#* }"
  fi
  rm_alias_varname="${rm_alias_first_tok#\$}"
  [[ "$rm_alias_varname" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || continue
  if ! echo "$_REVERSIBILITY_MASKED_COMMAND" | grep -qE "\\b${rm_alias_varname}=(rm|unlink)([[:space:];&]|\$)"; then
    continue
  fi
  while IFS= read -r target; do
    [[ -z "$target" ]] && continue
    if ! _reversibility_verdict "$target"; then
      if [[ "$_REVERSIBILITY_OVERRIDE_ACTIVE" -eq 1 ]]; then
        _reversibility_log_override_use "rm(変数エイリアス経由)" "$target"
      else
        _reversibility_denial_message "rm(変数エイリアス経由)" "$target"
        exit 2
      fi
    fi
  done < <(_extract_rm_targets "$rm_alias_rest")
done < <(echo "$_REVERSIBILITY_MASKED_COMMAND" | grep -oE '(^|[[:space:];&|(=])\$[A-Za-z_][A-Za-z0-9_]*[[:space:]][^;&|]*' || true)

# cp/mv/ln: 書込み先(cp)、または全ての位置引数(mv/ln)を可逆性ゲートへ通す。
# ★セルフレビュー是正(1巡目): 最後の非フラグ位置引数だけを見ると、GNU cp/mv/ln の
# `-t DIR`/`--target-directory=DIR`/`--target-directory DIR` 形(宛先を
# フラグの引数として渡す)では最後の位置引数が実は「送り側」のファイルで
# あり、本当の宛先(-t の引数)を見落とす。-t/--target-directory を明示的に
# 検出し、それがあればそちらを宛先として優先する。
# ★セルフレビュー是正(3巡目・実バイパス2件):
#   (a) `mv config/settings.yaml config/settings.yaml.bak` は宛先
#       (settings.yaml.bak)のみ判定していたため通っていた——mvは移動元を
#       その場から消し去るため、宛先だけでなく★全ての位置引数(移動元も)を
#       判定せねばならない(cpは元ファイルがコピー後も残るため宛先のみで
#       足りるが、mv/lnは違う)。
#   (b) `ln -f config/other.txt config/settings.yaml` はguarded fileの
#       上書き(unlink+新規リンク)そのものだが、rm/cp/mvのいずれの走査
#       対象にも `ln` が含まれておらず、丸ごと見落とされていた。
#       ln も宛先(linkname)判定の対象に加える(-t 対応もcp/mvと共通)。
_extract_cpmvln_targets() {
  local seg="$1" verb="$2" tok prev="" t_target=""
  local -a positional=()
  set -f
  for tok in $seg; do
    if [[ -n "$prev" ]]; then
      t_target="$tok"
      prev=""
      continue
    fi
    case "$tok" in
      -t) prev="-t"; continue ;;
      --target-directory) prev="--target-directory"; continue ;;
      --target-directory=*) t_target="${tok#--target-directory=}"; continue ;;
      -t?*) t_target="${tok#-t}"; continue ;;
    esac
    [[ "$tok" == "cp" || "$tok" == "mv" || "$tok" == "ln" ]] && continue
    [[ "$tok" == -* ]] && continue
    tok="${tok#[\"\']}"
    tok="${tok%[\"\']}"
    [[ -z "$tok" ]] && continue
    positional+=("$tok")
  done
  set +f
  # ★軍師QC是正(他エージェントによる独立レビューで発見・自己是正):
  # `ln target linkname` の target は★参照されるだけで書込み・削除は
  # されない(linkname が新規作成/上書きされる側)——mv の移動元(実際に
  # その場から消える)とは意味が異なる。ln を mv と同列で「全位置引数が
  # 対象」に含めると、`ln -s /usr/local/bin/node node_link` のような
  # 正当なシンボリックリンク作成(system配下等worktree外を指すのはlnの
  # ありふれた用法)まで誤ってOUTSIDE_WORKTREEでblockしてしまう
  # (実証済みFP)。ln は cp と同じく★宛先(linkname)のみを見る。
  if [[ "$verb" == "cp" || "$verb" == "ln" ]]; then
    # cp/ln: 宛先のみで足りる(cpは元ファイルがコピー後も残る・lnのtargetは
    # 参照されるのみで書込まれない)
    if [[ -n "$t_target" ]]; then
      echo "$t_target"
    elif [[ ${#positional[@]} -gt 0 ]]; then
      echo "${positional[$((${#positional[@]} - 1))]}"
    fi
  else
    # mv: 全ての位置引数(移動元を含む・移動元はその場から消える)+ -t 宛先を判定する
    local t
    for t in "${positional[@]}"; do
      echo "$t"
    done
    [[ -n "$t_target" ]] && echo "$t_target"
  fi
}

while IFS= read -r cpmvln_invocation; do
  [[ -z "$cpmvln_invocation" ]] && continue
  cpmvln_invocation="$(echo "$cpmvln_invocation" | sed -E 's/^[[:space:];&|(=]//')"
  cpmvln_verb="$(echo "$cpmvln_invocation" | grep -oE '^(cp|mv|ln)' || true)"
  [[ -z "$cpmvln_verb" ]] && continue
  while IFS= read -r cpmvln_target; do
    [[ -z "$cpmvln_target" ]] && continue
    if ! _reversibility_verdict "$cpmvln_target"; then
      if [[ "$_REVERSIBILITY_OVERRIDE_ACTIVE" -eq 1 ]]; then
        _reversibility_log_override_use "$cpmvln_verb" "$cpmvln_target"
      else
        _reversibility_denial_message "$cpmvln_verb" "$cpmvln_target"
        exit 2
      fi
    fi
  done < <(_extract_cpmvln_targets "$cpmvln_invocation" "$cpmvln_verb")
done < <(echo "$_REVERSIBILITY_MASKED_COMMAND" | grep -oE '(^|[[:space:];&|(=])(cp|mv|ln)[[:space:]][^;&|]*' || true)

# ③④ 外部への不可逆操作・常駐機構(daemon)の設定変更
# ★セルフレビュー是正(4巡目・実証): has_git_subcmd が git に対して持つ変数エイリアス
# 経由の検知(`v=git; $v push`)と同型の迂回が gh/launchctl/crontab には
# 無かった(実証: `GH=gh; $GH pr merge 42 --squash` が是正前は exit 0)。
# 直接呼出のパターンに加え、「baseコマンド名への変数エイリアスが存在し・
# その変数が実際に使われており・関連キーワードが本文に現れる」場合も
# 危険と判定する(has_git_subcmdの「サブコマンド語がどこかにあれば」という
# 緩い基準と同じ精度感——多少広めに倒すが、誤検知時は.guard-authorizedで
# 通せる)。6つの似た if ブロックを1つの関数へ集約(将軍QC是正・PR初版で
# 2度指摘された「7つ目の不可逆コマンドを足す度にif блокをコピペする」構造
# 上の指摘にも対応)。
_reversibility_check_irreversible_op() {
  local base="$1" direct_regex="$2" msg="$3" exclude_regex="$4" alias_keyword_regex="$5"
  local hit=0
  if echo "$_REVERSIBILITY_MASKED_COMMAND" | grep -qE "$direct_regex"; then
    hit=1
  elif echo "$_REVERSIBILITY_MASKED_COMMAND" | grep -qE "\\w+=$base(\\s|;|&|\$)" \
       && echo "$_REVERSIBILITY_MASKED_COMMAND" | grep -qE '\$\w+' \
       && { [[ -z "$alias_keyword_regex" ]] || echo "$_REVERSIBILITY_MASKED_COMMAND" | grep -qE "$alias_keyword_regex"; }; then
    hit=1
  fi
  if [[ -n "$exclude_regex" ]] && echo "$_REVERSIBILITY_MASKED_COMMAND" | grep -qE "$exclude_regex"; then
    hit=0
  fi
  if [[ $hit -eq 1 ]]; then
    if [[ "$_REVERSIBILITY_OVERRIDE_ACTIVE" -eq 1 ]]; then
      _reversibility_log_override_use "$base" "$msg"
    else
      echo "❌ 可逆性ゲート(cmd_813): $msg" >&2
      exit 2
    fi
  fi
}

_reversibility_check_irreversible_op "gh" '\bgh\s+pr\s+merge\b' \
  "gh pr merge は不可逆操作です。裁可があれば .guard-authorized を設置せよ。" "" '\bmerge\b'
_reversibility_check_irreversible_op "gh" '\bgh\s+(pr|issue)\s+close\b' \
  "gh pr/issue close は不可逆操作です。裁可があれば .guard-authorized を設置せよ。" "" '\bclose\b'
_reversibility_check_irreversible_op "gh" '\bgh\s+repo\s+(archive|delete)\b' \
  "gh repo archive/delete は不可逆操作です。裁可があれば .guard-authorized を設置せよ。" "" '\b(archive|delete)\b'
_reversibility_check_irreversible_op "launchctl" '\blaunchctl\s+(load|unload|bootstrap|bootout|remove)\b' \
  "launchctlによる常駐設定変更です。裁可があれば .guard-authorized を設置せよ。" "" '\b(load|unload|bootstrap|bootout|remove)\b'
_reversibility_check_irreversible_op "crontab" '\bcrontab\b' \
  "crontabによる常駐設定変更です。裁可があれば .guard-authorized を設置せよ。" '\bcrontab\s+(-l|--list)\b' ""

# D003: git push --force / -f (without --force-with-lease)
if has_git_subcmd "$COMMAND" "push" && echo "$COMMAND" | grep -qE '\-\-force\b' && ! echo "$COMMAND" | grep -q 'force-with-lease'; then
  echo "❌ 破壊的操作が検出されました: git push --force。D003 違反です。--force-with-lease を使用してください。" >&2
  exit 2
fi
if has_git_subcmd "$COMMAND" "push" && echo "$COMMAND" | grep -qE '(^|\s)-f\b'; then
  echo "❌ 破壊的操作が検出されました: git push -f。D003 違反です。--force-with-lease を使用してください。" >&2
  exit 2
fi

# D004: git reset --hard / git checkout -- . / git restore . / git clean -f
if has_git_subcmd "$COMMAND" "reset" && echo "$COMMAND" | grep -q '\-\-hard'; then
  echo "❌ 破壊的操作が検出されました: git reset --hard。D004 違反です。git stash は worktree間で共有されるrefs/stashの競合事故が実際に起きたため使用禁止。一時commit(git commit --no-verify -m wip → 確認 → git reset HEAD^)で退避してから扱ってください。" >&2
  exit 2
fi
if has_git_subcmd "$COMMAND" "checkout" && echo "$COMMAND" | grep -qE '\-\-\s+\.'; then
  echo "❌ 破壊的操作が検出されました: git checkout -- .。D004 違反です。" >&2
  exit 2
fi
if echo "$COMMAND" | grep -qE 'git\s+restore\s+\.'; then
  echo "❌ 破壊的操作が検出されました: git restore .。D004 違反です。" >&2
  exit 2
fi
if echo "$COMMAND" | grep -qE 'git\s+clean\s+-f'; then
  echo "❌ 破壊的操作が検出されました: git clean -f。D004 違反です。git clean -n でドライランを先に実行してください。" >&2
  exit 2
fi

# D005: chmod -R / chown -R on system paths
if echo "$COMMAND" | grep -qE '(chmod|chown)\s+-R\b' && \
   echo "$COMMAND" | grep -qE '\s/(etc|usr|bin|sbin|lib|lib64|var|opt|root|sys|proc|boot|dev|srv|mnt|snap)(/| |$)'; then
  echo "❌ 破壊的操作が検出されました: chmod/chown -R on system path。D005 違反です。" >&2
  exit 2
fi

# D006: kill/killall/pkill/tmux kill-server/tmux kill-session
if echo "$COMMAND" | grep -qE '\b(killall|pkill)\b'; then
  echo "❌ 破壊的操作が検出されました: killall/pkill。D006 違反です。" >&2
  exit 2
fi
if echo "$COMMAND" | grep -qE 'tmux\s+kill-(server|session)'; then
  echo "❌ 破壊的操作が検出されました: tmux kill-server/kill-session。D006 違反です。" >&2
  exit 2
fi

# D007: mkfs/dd if=/fdisk
if echo "$COMMAND" | grep -qE '\b(mkfs|fdisk)\b'; then
  echo "❌ 破壊的操作が検出されました: mkfs/fdisk。D007 違反です。" >&2
  exit 2
fi
if echo "$COMMAND" | grep -qE 'dd\s+if='; then
  echo "❌ 破壊的操作が検出されました: dd if=。D007 違反です。" >&2
  exit 2
fi

# D008: pipe-to-shell patterns
if echo "$COMMAND" | grep -qE '(curl|wget)\s+.*\|\s*(bash|sh)'; then
  echo "❌ 破壊的操作が検出されました: curl/wget|bash|sh パターン。D008 違反です。" >&2
  exit 2
fi

# ============================================================
# Hook 3: main ブランチ保護
# Uses GIT_TARGET_DIR to check the correct repo's branch
# (prevents false block when CWD is multi-agent-shogun/main
#  but command targets an external repo on a feature branch)
# ============================================================
if has_git_subcmd "$COMMAND" "commit" || has_git_subcmd "$COMMAND" "push"; then
  CURRENT_BRANCH=$(git -C "$GIT_TARGET_DIR" branch --show-current 2>/dev/null || echo "")
  if [[ "$CURRENT_BRANCH" == "main" || "$CURRENT_BRANCH" == "master" ]]; then
    echo "❌ main ブランチへの直接 commit/push は禁止です。ブランチを切ってください。" >&2
    exit 2
  fi
fi

# ============================================================
# Hook 4: push 前 lint/typecheck チェック
# Uses GIT_TARGET_DIR to find package.json in the correct repo
# ============================================================
if has_git_subcmd "$COMMAND" "push"; then
  PKG_JSON=$(find "$GIT_TARGET_DIR" -maxdepth 2 -name "package.json" ! -path "*/node_modules/*" 2>/dev/null | head -1)
  if [[ -n "$PKG_JSON" ]]; then
    PKG_DIR=$(dirname "$PKG_JSON")
    HAS_TYPECHECK=$(jq -r '.scripts.typecheck // ""' "$PKG_JSON")
    HAS_LINT=$(jq -r '.scripts.lint // ""' "$PKG_JSON")

    if [[ -n "$HAS_TYPECHECK" || -n "$HAS_LINT" ]]; then
      cd "$PKG_DIR"
      FAILED=0
      if [[ -n "$HAS_TYPECHECK" ]]; then
        if ! npm run typecheck --silent 2>/dev/null; then
          FAILED=1
        fi
      fi
      if [[ -n "$HAS_LINT" ]]; then
        if ! npm run lint --silent 2>/dev/null; then
          FAILED=1
        fi
      fi
      if [[ $FAILED -eq 1 ]]; then
        echo "❌ typecheck/lint エラーがあります。修正してから push してください。" >&2
        exit 2
      fi
    fi
  fi
fi

# ============================================================
# Hook 5: GH_TOKEN 自動 unset 警告
# ============================================================
if echo "$COMMAND" | grep -qE '\bgh\b'; then
  if [[ -n "${GH_TOKEN:-}" ]]; then
    echo "❌ GH_TOKEN が設定されています。\`unset GH_TOKEN && gh ...\` としてください。" >&2
    exit 2
  fi
fi

# ============================================================
# Hook 7: 上流 repo への gh pr create をブロック
# gh pr create --repo yohey-w/* または --repo digital-go-jp/* を検知して拒否。
# cwd の git remote origin が上流を指している場合も同様にブロック。
# read-only 操作 (gh api / gh pr list 等) はブロックしない。
# V002 CRITICAL 恒久対策 (足軽1が yohey-w/multi-agent-shogun に2度誤 PR した事例)。
# ============================================================
if echo "$COMMAND" | grep -qE 'gh\s+(pr|pull-request)\s+create'; then
  # --repo / -R フラグで上流 repo を直接指定している場合
  if echo "$COMMAND" | grep -qE '(-R|--repo)[[:space:]=]+(yohey-w/|digital-go-jp/)'; then
    echo "🚫 BLOCKED: 上流 repo への gh pr create は禁止 (yohey-w/* / digital-go-jp/*)" >&2
    echo "   正しい repo: halsk/* または geolonia/* を --repo に指定せよ" >&2
    exit 2
  fi
  # --repo フラグ未指定: gh はフォーク親 (upstream) に PR を送るため必ず明示が必要。
  # halsk/multi-agent-shogun は yohey-w のフォーク → --repo 省略で yohey-w に誤 PR が届く事例あり。
  if ! echo "$COMMAND" | grep -qE '(-R|--repo)\b'; then
    echo "🚫 BLOCKED: gh pr create には --repo <org/repo> を明示せよ" >&2
    echo "   フォーク repo で --repo を省略すると上流 (yohey-w/* 等) に誤 PR が発生する" >&2
    exit 2
  fi
  # cwd の git remote origin が上流を指している場合
  UPSTREAM_REMOTE=$(git -C "$GIT_TARGET_DIR" remote get-url origin 2>/dev/null || echo "")
  if echo "$UPSTREAM_REMOTE" | grep -qE '(yohey-w/|digital-go-jp/)'; then
    echo "🚫 BLOCKED: cwd の git remote origin が上流 repo を指しています (yohey-w/* / digital-go-jp/*)" >&2
    echo "   正しい repo: halsk/* または geolonia/* の worktree で作業せよ" >&2
    exit 2
  fi
fi

# ============================================================
# Hook 8: inbox_write.sh 呼出時のバッククォート事故防止 (2026-09-12・PR#116)
# followup是正(PR#118・軍師QC=条件付きNO-GO・subtask_backtick_safety_followup_fp_fn):
# FP-1/FP-2/FN-1 は直ったが、代わりに「正規表現で区切ってから見る」
# 「単一引用符を無条件に剥がす」という近道により、mainが止めていた5形
# (X1-X5: 本文に | ; & を含む/2つ目以降の呼出/二重引用符内のアポストロフィに
# 挟まれたバッククォート)が素通りするようになると軍師が実証した(NO-GO)。
# followup2是正(PR#118): 正規表現で切り刻む方式をやめ、★引用符を
# 理解しながら1文字ずつ歩く一パス走査に書き直した(軍師の試作方針を採用)。
# FN-2($()形式)は当時は対象外(殿/将軍の裁可待ち)——後述のFN-2是正で解消。
# followup3是正(PR#124・FP-3・軍師QC pass_with_followup追加探索):
# 区間を閉じる境界(引用符の外の ; & |)に★改行が含まれていなかったため、
# 安全な呼出(1行目で完結)の★次の行にバッククォートがあると同じ区間に
# 巻き込まれ誤ってブロックされていた。境界へ改行を1つ追加して是正する
# (二重引用符の中の改行は state=D のままなので影響を受けず、改行を跨ぐ
# 本文中のバッククォートは引き続き検知される)。
# followup4是正(PR#127・FU-1・_has_unescaped_backtick_in_inbox_write_args):
# RS="\001" は「入力に \001 が現れない」という前提に寄りかかっており、実際に
# \001 を挟むと段落(レコード)が分割される。exit が★各レコードの処理ブロック
# 内にあったため1レコード目だけで判定・終了し、後続レコードの本物の危険を
# 見ずに通す穴が残っていた。state/in_call/danger を BEGIN で持ち越し、exit を
# END へ移すことで、レコード分割そのものに免疫を付けた。
# FN-2是正(本コミット・殿ご裁可・subtask_guardsh_fn2_dollar_paren):
# バッククォートと並ぶもう一つのコマンド置換記法「$(...)」の★開き(ドル記号+
# 丸括弧)が検知対象から漏れていた(実証済みFN・実際の事故例ではないが殿が
# 塞ぐようご裁定)。既存のバッククォート判定と★全く同じ場所・同じ一パス走査
# (state=D/state=N の両方・in_call の時)へ、「$」の次の文字が「(」であれば
# danger とする分岐を追加するだけで足りる——過剰設計は避ける。関数名を
# バッククォート限定の旧名から実態に合わせて改める。
# ★重要な副作用: CLAUDE.mdが従来推奨していた「ファイルの中身を
# "$(cat file)" の形で二重引用符へ埋め込んで渡す」手順そのものが、本是正
# 以降はblock対象に含まれる。これは意図された結果(殿裁定「文脈依存の判定は
# 複雑化を招くため避け、二重引用符内の$(...)開きは無条件に塞ぐ」との趣旨)
# であり、CLAUDE.md側の推奨手順を変数経由の渡し方へ書き換えて対応する
# (本PRのCLAUDE.md差分を参照)。
# ------------------------------------------------------------
# 背景: 2026-09-12朝、家老・将軍の双方が★独立に同じ事故を起こした。
# `bash scripts/inbox_write.sh <agent> "..."` の二重引用符で囲んだ
# メッセージ本文の中でコマンド名・設定値をバッククォートで引用したところ、
# bash がそれをコマンド置換として実際に実行してしまった(家老の事故は
# .git/config の gpgsign 設定を消失させ、将軍の事故は
# `brew install --cask 1password` を意図せず実行させた)。
#
# ★原理的な制約: このコマンド置換は inbox_write.sh 自身が呼び出される
# ★より前(=シェルが Bash ツールのコマンド文字列を実行する際の引数展開時)
# に起きる。よって inbox_write.sh のスクリプト内部からは、置換後の
# (=展開済みで既に実行されてしまった後の)文字列しか見えず、原理的に
# 検知できない。ゆえに guard.sh(PreToolUse hook)側で、Bash ツールへ
# 渡される★実行前のコマンド文字列そのものを検査する——これが実行前に
# 検出できる唯一の層である。過剰設計は避け、検出(ブロック)のみを行う
# (自動エスケープ・自動修正は範囲外)。
#
# ★走査の設計(状態は none/single/double の3つのみ):
#   - "inbox_write.sh" という文字列に出会ったら、その時点から
#     (引用符の外の ; & | に出会うまで)「呼出の引数区間」に入ったと印を
#     立てる。呼出は1回に限らず、区間が閉じたあと再び出会えば何度でも
#     入り直す(head -1 で先頭だけを見る近道は採らない)。
#   - 区間の境界判定(; & | および改行)は★必ず引用符の外でのみ行う。
#     二重引用符の中にある | ; & や改行は本文の一部であり、区間を閉じない
#     (X1/X2/X3 是正・Y1=改行を跨ぐ二重引用符本文の維持)。改行は★呼出の
#     行が終わった印でもあるため、引用符の外では境界として区間を閉じる
#     (FP-3 是正——次の行のバッククォートを巻き込まない)。
#   - 区間内で、単一引用符の中でない未エスケープのバッククォートを見たら
#     危険と判定する。二重引用符の中の未エスケープバッククォートも対象
#     (シェルは二重引用符内でもコマンド置換を評価するため)。
#   - 区間内で、単一引用符の中でない「$」の直後が「(」であれば同様に危険と
#     判定する(FN-2是正・殿裁定「エスケープされていないコマンド置換の開き」)。
#     ★既存のバッククォート判定と全く同じ場所(state=D・state=N の両方)に
#     同じ条件(単一引用符の中は対象外)で追加しただけであり、判定の対称性は
#     崩していない。単一引用符内は従来どおりバックスラッシュ以外何もチェック
#     しない。
#   - 単一引用符は「二重引用符の外にあるものだけ」が開始と見なされる。
#     二重引用符の中にあるアポストロフィはただの文字であり、単一引用符
#     として状態遷移しない(X5 是正——2個のアポストロフィに挟まれた区間
#     ごとバッククォートを消してしまう誤りを避ける)。
#   - バックスラッシュは(単一引用符の中でない限り)常に次の1文字を
#     読み飛ばす(エスケープとして扱う——CLAUDE.mdが勧める回避策の一つ)。
# ============================================================
_has_dangerous_substitution_in_inbox_write_args() {
  local cmd="$1"
  # ★FU-1是正(PR#124 QC followup・軍師試作採用): RS="\001" は「入力に \001 が
  # 現れない」という前提に依存していた——\001 を実際に挟むと段落(レコード)が
  # 分割され、旧実装は exit が★各レコードの処理ブロック内にあったため、
  # ★1レコード目を読み終えた時点で(そのレコードだけの danger 判定で)終了し、
  # 後続レコードにある本物の危険を見ずに通してしまっていた(RS="\0" が
  # 実質 段落モード になっていた FN-3 と同根の穴)。
  # 是正: state/in_call/danger を BEGIN で初期化してレコードを跨いで持ち越し、
  # exit は★END ブロックへ移す(全レコードを読み終えてから一度だけ判定する)。
  # これによりレコード分割そのものに免疫が付く。
  printf '%s' "$cmd" | awk -v pat='inbox_write.sh' '
    BEGIN { RS="\001"; state = "N"; in_call = 0; danger = 0 }
    {
      n = length($0)
      plen = length(pat)
      i = 1
      while (i <= n) {
        c = substr($0, i, 1)
        # バックスラッシュ(単一引用符の中でない限り)は次の1文字を読み飛ばす
        if (state != "S" && c == "\\") { i += 2; continue }
        # "inbox_write.sh" に出会ったら呼出の引数区間に入る(引用符の内外を問わぬ)
        if (!in_call && substr($0, i, plen) == pat) { in_call = 1; i += plen; continue }
        if (state == "S") {
          if (c == "\047") state = "N"
          i++; continue
        }
        if (state == "D") {
          if (c == "\"") state = "N"
          else if (c == "`" && in_call) danger = 1
          else if (c == "$" && substr($0, i + 1, 1) == "(" && in_call) danger = 1
          i++; continue
        }
        # state == N
        if (c == "\047") state = "S"
        else if (c == "\"") state = "D"
        else if (c == "`" && in_call) danger = 1
        else if (c == "$" && substr($0, i + 1, 1) == "(" && in_call) danger = 1
        else if (c == ";" || c == "&" || c == "|" || c == "\n") in_call = 0
        i++
      }
    }
    END { exit (danger ? 0 : 1) }
  '
}

if echo "$COMMAND" | grep -qE '\binbox_write\.sh\b' && _has_dangerous_substitution_in_inbox_write_args "$COMMAND"; then
  echo "❌ inbox_write.sh 呼出のメッセージ本文(二重引用符内)に未エスケープのバッククォート、" >&2
  echo "   または \$(...) 形式のコマンド置換の開きが検出されました。" >&2
  echo "   二重引用符内ではどちらもシェルのコマンド置換として実行されてしまいます" >&2
  echo "   (2026-09-12 家老・将軍が独立に事故——gpgsign設定消失・brew install誤実行)。" >&2
  echo "   対処: 「 」で囲むか引用符なしで書く / 本文全体を単一引用符 '...' で囲む /" >&2
  echo "   長文はいったん変数へ読み込み(例: file_content=\"\$(cat file)\")、その変数を" >&2
  echo "   二重引用符で渡す。CLAUDE.md『Communication Protocol』節を参照。" >&2
  exit 2
fi

# ============================================================
# Hook 6 helpers: docs-only skip
# ============================================================
is_docs_only_file() {
  local f="$1"
  case "$f" in
    *.md|docs/*|.gitignore|.code-review-done|README*|LICENSE*) return 0 ;;
    *) return 1 ;;
  esac
}

determine_baseline() {
  local marker_hash="$1"
  if [[ -n "$marker_hash" ]] && git -C "$GIT_TARGET_DIR" rev-parse "$marker_hash" >/dev/null 2>&1; then
    echo "$marker_hash"
  else
    local base
    base=$(git -C "$GIT_TARGET_DIR" merge-base HEAD origin/main 2>/dev/null) || \
    base=$(git -C "$GIT_TARGET_DIR" rev-parse HEAD~1 2>/dev/null) || base=""
    echo "$base"
  fi
}

# ============================================================
# Hook 6: code-review-expert 実行強制（マーカーファイル方式）
# Uses GIT_TARGET_DIR for HEAD hash and .code-review-done lookup
# docs-only changes (docs/*, *.md, etc.) are auto-skipped
# ============================================================
if has_git_subcmd "$COMMAND" "push"; then
  HEAD_HASH=$(git -C "$GIT_TARGET_DIR" rev-parse HEAD 2>/dev/null || echo "")
  if [[ -n "$HEAD_HASH" ]]; then
    REVIEW_DONE_FILE="$GIT_TARGET_DIR/.code-review-done"
    if [[ ! -f "$REVIEW_DONE_FILE" ]]; then
      echo "❌ code-review-expert を実行してください。push 前にレビューが必要です。" >&2
      exit 2
    fi
    REVIEW_HASH=$(tr -d '[:space:]' < "$REVIEW_DONE_FILE" 2>/dev/null || echo "")
    if [[ "$REVIEW_HASH" != "$HEAD_HASH" ]]; then
      BASELINE=$(determine_baseline "$REVIEW_HASH")
      DOCS_ONLY_SKIP=0
      if [[ -n "$BASELINE" ]]; then
        CHANGED_FILES=$(git -C "$GIT_TARGET_DIR" diff --name-only "$BASELINE" HEAD 2>/dev/null || echo "")
        if [[ -n "$CHANGED_FILES" ]]; then
          ALL_DOCS=1
          while IFS= read -r file; do
            [[ -z "$file" ]] && continue
            if ! is_docs_only_file "$file"; then
              ALL_DOCS=0
              break
            fi
          done <<< "$CHANGED_FILES"
          if [[ $ALL_DOCS -eq 1 ]]; then
            DOCS_ONLY_SKIP=1
          fi
        fi
      fi
      if [[ $DOCS_ONLY_SKIP -eq 1 ]]; then
        echo "$HEAD_HASH" > "$REVIEW_DONE_FILE"
        echo "ℹ️  guard.sh: docs-only change detected, code-review skipped + marker auto-updated" >&2
      else
        echo "❌ code-review-expert を実行してください。push 前にレビューが必要です。（コミット後に再レビューが必要です）" >&2
        exit 2
      fi
    fi
  fi
fi

exit 0
