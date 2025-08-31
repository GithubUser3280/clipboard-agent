#!/usr/bin/env sh

set -u

# Find local or global commands without npx.
find_cmd() {
  if [ -x "./node_modules/.bin/$1" ]; then
    printf '%s\n' "./node_modules/.bin/$1"
    return 0
  elif command -v "$1" >/dev/null 2>&1; then
    command -v "$1"
    return 0
  fi
  return 1
}

ESLINT_CMD=$(find_cmd eslint) || { echo "eslint not found"; exit 1; }
TSC_CMD=$(find_cmd tsc) || { echo "tsc not found"; exit 1; }
NODE_CMD=$(command -v node) || { echo "node not found"; exit 1; }

# Temp files (fallback if mktemp missing).
mkf() { mktemp 2>/dev/null || echo "/tmp/portable.$$.$1"; }
E_JSON=$(mkf eslint.json)
T_OUT=$(mkf tsc.out)
O_TXT=$(mkf out.txt)
F_LIST=$(mkf files.list)

copied="no"

# 1) ESLint JSON to file.
#    Redirect stdout to file; avoid tee.
"$ESLINT_CMD" . --no-color -f json > "$E_JSON" 2>/dev/null || true

# 2) Run tsc and save combined output.
"$TSC_CMD" --noEmit --incremental false --pretty false >"$T_OUT" 2>&1 || true

# 3) Use Node to:
#    - parse ESLint JSON
#    - parse tsc text to paths
#    - resolve absolute paths
#    - dedupe
#    - produce human messages (no absolute paths)
#    - write file list
#    - write header/prompt if any diagnostics
"$NODE_CMD" - <<'NODE' "$PWD" "$E_JSON" "$T_OUT" "$O_TXT" "$F_LIST"
const fs = require('fs');
const path = require('path');

const [pwd, eslintJsonPath, tscOutPath, outTxtPath, filesListPath] = process.argv.slice(2);
const outLines = [];
const files = new Set();

function abs(p) {
  if (!p) return null;
  try {
    // Resolve relative to project root, then realpath if possible.
    const r = path.resolve(pwd, p);
    try { return fs.realpathSync.native(r); } catch { return r; }
  } catch { return null; }
}

function pushFile(p) {
  const a = abs(p);
  if (a) files.add(a);
}

let eslintHad = false;
try {
  const raw = fs.readFileSync(eslintJsonPath, 'utf8');
  const arr = JSON.parse(raw);
  for (const entry of arr) {
    if (entry && Array.isArray(entry.messages) && entry.messages.length) {
      eslintHad = true;
      // human-readable, but avoid absolute file paths
      const rel = path.relative(pwd, entry.filePath || '');
      for (const m of entry.messages) {
        const rule = m.ruleId ? ` [${m.ruleId}]` : '';
        outLines.push(`${rel}:${m.line || 0}:${m.column || 0}: ${m.severity === 2 ? 'error' : 'warn'}: ${m.message}${rule}`);
      }
      pushFile(entry.filePath);
    }
  }
} catch {}

let tscHad = false;
try {
  const txt = fs.readFileSync(tscOutPath, 'utf8');
  if (txt.trim()) tscHad = true;
  // Match "path:line:col - ..." or "path(line,col): ..."
  const re = /^([^\r\n:(]+(?:\/|\\)[^\r\n:(]+?)[(:]\d+[,:\)]\d+/gm;
  let m;
  while ((m = re.exec(txt)) !== null) {
    pushFile(m[1]);
  }
} catch {}

if (eslintHad || tscHad) {
  outLines.unshift(
    'The following are the diagnostics from the TypeScript compiler and ESLint. ' +
    'Tell me how to fix every error and/or warning. Tell me exactly what lines I need to modify in what file and what I need to change them to.',
    ''
  );
  fs.writeFileSync(outTxtPath, outLines.join('\n') + '\n', 'utf8');
  fs.writeFileSync(filesListPath, Array.from(files).join('\n') + '\n', 'utf8');
} else {
  // nothing to do; create empty outputs
  try { fs.writeFileSync(outTxtPath, ''); } catch {}
  try { fs.writeFileSync(filesListPath, ''); } catch {}
}
NODE

# 4) Append file dumps with line numbers if any diagnostics.
if [ -s "$O_TXT" ]; then
  while IFS= read -r path; do
    [ -f "$path" ] || continue
    printf '\n## %s\n' "$path" >> "$O_TXT"
    # POSIX cat -n is standard
    cat -n "$path" >> "$O_TXT"
  done < "$F_LIST"
fi

# 5) Copy if possible; otherwise print a brief notice and path.
copy_to_clipboard() {
  if command -v pbcopy >/dev/null 2>&1; then pbcopy; return 0; fi
  if command -v wl-copy >/dev/null 2>&1; then wl-copy; return 0; fi
  if command -v xclip   >/dev/null 2>&1; then xclip -selection clipboard; return 0; fi
  if command -v xsel    >/dev/null 2>&1; then xsel --clipboard --input; return 0; fi
  if command -v clip.exe>/dev/null 2>&1; then clip.exe; return 0; fi
  return 1
}

if [ -s "$O_TXT" ]; then
  if copy_to_clipboard < "$O_TXT"; then
    copied="yes"
  else
    copied="no"
  fi
fi

# 6) Report
if [ "$copied" = "yes" ]; then
  echo "Copied context to clipboard."
elif [ -s "$O_TXT" ]; then
  echo "Diagnostics found. Clipboard tool not available. See: $O_TXT"
else
  echo "No warnings or errors found. Nothing was copied to clipboard."
fi
