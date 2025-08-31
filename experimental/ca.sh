(
  # Print the initial instructions
  printf "The following are the diagnostics from the TypeScript compiler and ESLint. Tell me how to fix every error and/or warning. Tell me exactly what lines I need to modify in what file and what I need to change them to.\n\n"

  # Temporary file to store ESLint output
  e=$(mktemp)

  # Run ESLint, output as JSON, extract messages and file paths with jq
  npx eslint . --no-color --format=json \
    | jq -r '.[] | select(any(.messages[]?;true)) | "\(.messages)",.filePath' \
    > "$e"

  # Show ESLint messages without absolute paths
  grep -v '^/' "$e"

  # Temporary file to store TypeScript compiler output
  t=$(mktemp)

  # Run TypeScript compiler (no emit), capture output in temp file
  npx tsc --noEmit --incremental false --pretty false 2>&1 | tee "$t"

  # Temporary file to store all relevant file paths
  f=$(mktemp)

  {
    # Collect absolute paths from ESLint
    grep '^/' "$e"
    # Collect file paths from TypeScript diagnostics (strip after '(')
    awk -F'[(]' '{print $1}' "$t"
  } \
  | awk -v d="$PWD" '
      {
        p = $0
        # Trim whitespace
        gsub(/^[[:space:]]+|[[:space:]]+$/, "", p)
        if (p == "") next
        # Make relative paths absolute
        if (p !~ /^\//) p = d "/" p
        print p
      }
    ' \
  | while IFS= read -r p; do
      # Resolve to real paths if possible
      realpath "$p" 2>/dev/null || printf "%s\n" "$p"
    done \
  | sort -u > "$f"

  # For each file in the list, show file name and contents with line numbers
  while IFS= read -r f; do
    [ -f "$f" ] || continue
    echo "\n## $f"
    cat -n "$f"
  done < "$f"

  # Cleanup temp files
  rm -f "$e" "$t" "$f"
) | pbcopy
