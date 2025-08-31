#!/usr/bin/env sh
set -u

# Find and define commands
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

ESLINT_CMD=$(find_cmd eslint) || { echo "eslint not found."; exit 1; }
TSC_CMD=$(find_cmd tsc) || { echo "tsc not found."; exit 1; }
NODE_CMD=$(command -v node) || { echo "node not found."; exit 1; }

# Create temporary files with fallback if mktemp missing
mkf() {
  mktemp 2>/dev/null || {
    f="/tmp/portable.$$.$1"
    (umask 077; : >"$f")
    printf '%s\n' "$f"
  }
}
ESLINT_JSON=$(mkf eslint.json)
TSC_OUT=$(mkf tsc.out)
OUT_TXT=$(mkf out.txt)
FILES_LIST=$(mkf files.list)

# Write ESLint JSON to temporary file
"$ESLINT_CMD" . --no-color -f json >"$ESLINT_JSON" 2>"$ESLINT_JSON.err" || true

# Write Typescript Compiler output to temporary file
"$TSC_CMD" --noEmit --incremental false --pretty false >"$TSC_OUT" 2>&1 || true

# Use Node to:
#   - parse ESLint JSON for diagnostics and paths
#   - parse Typescript Compiler output for paths
#   - resolve absolute paths
#   - dedupe duplicate paths
#   - write diagnositics
#   - write file paths
#   - write prompt if diagnostics are found

"$NODE_CMD" - "$PWD" "$ESLINT_JSON" "$TSC_OUT" "$OUT_TXT" "$FILES_LIST" <<'NODE'
// Define constants
const fs = require('fs');
const path = require('path');
const [pwd, eslintJsonPath, tscOutPath, outTxtPath, filesListPath] = process.argv.slice(2);
const outLines = [];
const files = new Set();

// Add normalized absolute file path to files set
function appendFile(filePath) {
  if (!filePath) return;

  try {
    const resolvedPath = path.resolve(pwd, filePath);
    let absolutePath;

    try {
      absolutePath = fs.realpathSync.native(resolvedPath);
    } catch {
      absolutePath = resolvedPath;
    }

    files.add(absolutePath);
  } catch {}
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
      appendFile(entry.filePath);
    }
  }
} catch {}

let tscHad = false;
try {
  const txt = fs.readFileSync(tscOutPath, 'utf8');

  // Capture "path(line,col): error TSxxxx: msg"
  const reParen = /^(.+?)\((\d+),(\d+)\):\s*error TS\d+:\s*(.+)$/gm;
  // Capture "path:line:col - error TSxxxx: msg"
  const reColon = /^(.+?):(\d+):(\d+)\s*-\s*error TS\d+:\s*(.+)$/gm;

  function pushTs(re) {
    let m;
    while ((m = re.exec(txt)) !== null) {
      tscHad = true;
      const absPath = m[1];
      const line = m[2];
      const col  = m[3];
      const msg  = m[4];
      const rel = path.relative(pwd, absPath);
      outLines.push(`${rel}:${line}:${col}: error: ${msg}`);
      appendFile(absPath);
    }
  }

  pushTs(reParen);
  pushTs(reColon);
} catch {}

// Write prompt and file paths
if (outLines.length > 0) {
  outLines.unshift('');
  outLines.unshift('The following are the diagnostics from the TypeScript compiler and ESLint. Tell me how to fix every error and/or warning. Tell me exactly what lines I need to modify in what file and what I need to change them to.');
  fs.writeFileSync(outTxtPath, outLines.join('\n') + '\n', 'utf8');
  fs.writeFileSync(filesListPath, Array.from(files).join('\n') + '\n', 'utf8');
} else {
  try { fs.writeFileSync(outTxtPath, ''); } catch {}
  try { fs.writeFileSync(filesListPath, ''); } catch {}
}
NODE

# 4) Append files with line numbers if any diagnostics.
if [ -s "$OUT_TXT" ]; then
  while IFS= read -r path; do
    [ -f "$path" ] || continue
    printf '\n## %s\n' "$path" >> "$OUT_TXT"
    nl -b a "$path" >> "$OUT_TXT"
  done < "$FILES_LIST"
fi

# Attempt to copy to system clipboard
copy_clipboard() {
  if command -v pbcopy >/dev/null 2>&1; then pbcopy; return 0; fi
  if command -v wl-copy >/dev/null 2>&1; then wl-copy; return 0; fi
  if command -v xclip   >/dev/null 2>&1; then xclip -selection clipboard; return 0; fi
  if command -v xsel    >/dev/null 2>&1; then xsel --clipboard --input; return 0; fi
  if command -v clip.exe>/dev/null 2>&1; then clip.exe; return 0; fi
  return 1
}

# Clean up temporary files
REMOVE_OUT_TXT=0
clean_up() {
  rm -f -- "$ESLINT_JSON" "$TSC_OUT" "$FILES_LIST"
  [ "${REMOVE_OUT_TXT:-0}" -eq 1 ] && rm -f -- "$OUT_TXT"
}
trap clean_up 0 INT TERM HUP

# Print summary
if [ -s "$OUT_TXT" ]; then
    if copy_clipboard < "$OUT_TXT"; then
        echo "Copied context to clipboard."
        REMOVE_OUT_TXT=1
    else
        echo "Diagnostics found. Clipboard tool not available. See: $OUT_TXT"
        REMOVE_OUT_TXT=0
    fi
else
    echo "No warnings or errors found. Nothing was copied to clipboard."
    REMOVE_OUT_TXT=1
fi
