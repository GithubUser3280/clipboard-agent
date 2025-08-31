(
  # Write the prompt
  printf "The following are the diagnostics from the TypeScript compiler and ESLint. Tell me how to fix every error and/or warning. Tell me exactly what lines I need to modify in what file and what I need to change them to.\n\n"

  # Create temporary file to store ESLint output
  e=$(mktemp)

  # Write ESLint JSON, extracting diagnostics and file paths with jq
  npx eslint . --no-color --format=json \
    | jq -r '.[] | select(any(.messages[]?;true)) | "\(.messages)",.filePath' \
    > "$e"

  # Write ESLint diagnostics without file paths
  grep -v '^/' "$e"

  # Create temporary file to store TypeScript Compiler output
  t=$(mktemp)

  # Write TypeScript Compiler output in the temporary file
  npx tsc --noEmit --incremental false --pretty false 2>&1 | tee "$t"

  # Create temporary file to store all file paths
  f=$(mktemp)

  {
    # Get absolute paths from ESLint JSON
    grep '^/' "$e"
    # Get file paths from TypeScript Compiler output, getting after '('
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
      # Use realpath if possible, otherwise print the path as is
      realpath "$p" 2>/dev/null || printf "%s\n" "$p"
    done \
  | sort -u > "$f"

  # For each file, write file name and contents with line numbers
  while IFS= read -r f; do
    [ -f "$f" ] || continue
    echo "\n## $f"
    cat -n "$f"
  done < "$f"

  # Clean up temporary files
  rm -f "$e" "$t" "$f"
) | pbcopy
