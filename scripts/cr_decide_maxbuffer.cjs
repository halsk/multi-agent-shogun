// cr_decide_maxbuffer.cjs — cr-decide.mjs を呼ぶ時にだけ node へ --require で
// 読ませる preload(cmd_913 至急・ENOBUFS の根治)。
//
// cr-decide.mjs(geolonia/skills・検めた SHA に pin)は execFileSync を
// maxBuffer 無しで呼ぶ。Node の既定の上限は 1 MiB で、差分の大きい PR では
// `gh api --paginate --slurp .../pulls/N/files` の出力がこれを超え、
// 「spawnSync gh ENOBUFS」で落ちる(2026-09-28 実測: geolonia/geonicdb-docs#226
// の files は 1,103,253 バイト・73 ファイル・patch だけで 854,588 バイト)。
//
// pin したファイルは書き換えない(書き換えれば、検めた SHA と実際に走る
// コードが食い違う)。ここでは受け方だけを変える: 呼び出し側が maxBuffer を
// 指定していない時に限り、上限を MAX_BUFFER に上げる。判定の規則には触れない。
//
// ESM の `import { execFileSync } from "node:child_process"` にも効かせるため、
// 差し替えた後に syncBuiltinESMExports() を呼ぶ。
//
// ★cr-decide が execFileSync 以外(spawnSync・execSync 等)で gh を呼ぶように
// 変われば、ここは効かない。tool_ref を上げる時に、呼び方が変わっていないかを
// 検めること(scripts/test_cr_retrigger.py の Test40 が本物の node で確かめる)。
"use strict";

const childProcess = require("node:child_process");
const { syncBuiltinESMExports } = require("node:module");

const MAX_BUFFER = 64 * 1024 * 1024;
const originalExecFileSync = childProcess.execFileSync;

childProcess.execFileSync = function execFileSyncWithLargerBuffer(file, args, options) {
  // execFileSync(file, options) の形(args を省いた呼び方)にも合わせる。
  if (!Array.isArray(args) && args !== null && typeof args === "object") {
    options = args;
    args = [];
  }
  const opts = { ...(options || {}) };
  if (opts.maxBuffer === undefined) opts.maxBuffer = MAX_BUFFER;
  return originalExecFileSync.call(this, file, args, opts);
};

syncBuiltinESMExports();
