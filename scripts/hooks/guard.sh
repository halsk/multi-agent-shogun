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
  for tok in $seg; do
    [[ "$tok" == "rm" ]] && continue
    [[ "$tok" == -* ]] && continue
    tok="${tok#[\"\']}"
    tok="${tok%[\"\']}"
    [[ -z "$tok" ]] && continue
    echo "$tok"
  done
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
    /|/bin|/boot|/dev|/etc|/lib|/lib64|/proc|/root|/sbin|/srv|/sys|/usr|/var|/mnt|/mnt/*|/home|/home/*)
      RM_BLOCK_REASON="D001"; return 1 ;;
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
  echo "❌ 破壊的操作が検出されました: git reset --hard。D004 違反です。git stash を使用してください。" >&2
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
