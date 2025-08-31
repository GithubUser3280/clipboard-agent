# Probably doesn't work. I'm too lazy to test this.
# lint-pack.ps1 — PowerShell 5.1+ and 7+ compatible. No npx/jq/awk/grep/sort/python.
# Requires: Node.js, eslint, tsc (prefer local ./node_modules/.bin).

$ErrorActionPreference = 'SilentlyContinue'
$copied = $false

function Find-Cmd([string]$name) {
  $local = Join-Path -Path (Join-Path -Path (Resolve-Path .).Path -ChildPath 'node_modules\.bin') -ChildPath ($name + '.cmd')
  if (Test-Path $local) { return $local }
  $g = Get-Command $name -ErrorAction SilentlyContinue
  if ($g) { return $g.Path }
  return $null
}

$eslint = Find-Cmd 'eslint'
$tsc    = Find-Cmd 'tsc'
$node   = Get-Command node -ErrorAction SilentlyContinue

if (-not $node)  { Write-Host 'node not found'; exit 1 }
if (-not $eslint){ Write-Host 'eslint not found'; exit 1 }
if (-not $tsc)   { Write-Host 'tsc not found'; exit 1 }

# Temp files
function New-Tmp([string]$tag){ try { New-TemporaryFile } catch { [IO.File]::CreateTempFile() } }
$EJSON = (New-Tmp 'eslint').FullName
$TOUT  = (New-Tmp 'tsc').FullName
$OTXT  = (New-Tmp 'out').FullName
$FLIST = (New-Tmp 'files').FullName

# 1) ESLint JSON
& $eslint . --no-color -f json 1> $EJSON 2>$null; $null = $LASTEXITCODE

# 2) tsc output
& $tsc --noEmit --incremental false --pretty false *>&1 | Set-Content -LiteralPath $TOUT

# 3) Parse and assemble with PowerShell (no external tools)
$pwdPath = (Resolve-Path .).Path
$outLines = New-Object System.Collections.Generic.List[string]
$files = New-Object System.Collections.Generic.HashSet[string]

function Add-File([string]$p) {
  if (-not $p) { return }
  try {
    $abs = (Resolve-Path -LiteralPath $p -ErrorAction SilentlyContinue).Path
    if (-not $abs) {
      if ([IO.Path]::IsPathRooted($p)) { $abs = $p } else { $abs = (Join-Path $pwdPath $p) }
    }
    [void]$files.Add($abs)
  } catch {}
}

# ESLint parse
$eslintHad = $false
try {
  $arr = Get-Content -LiteralPath $EJSON -Raw | ConvertFrom-Json
  foreach ($entry in $arr) {
    if ($entry -and $entry.messages -and $entry.messages.Count -gt 0) {
      $eslintHad = $true
      $rel = ($entry.filePath -replace [regex]::Escape("$pwdPath\"), '')
      foreach ($m in $entry.messages) {
        $rule = if ($m.ruleId) { " [$($m.ruleId)]" } else { "" }
        $sev  = if ($m.severity -eq 2) { 'error' } else { 'warn' }
        $outLines.Add("$rel:$($m.line):$($m.column): $sev: $($m.message)$rule")
      }
      Add-File $entry.filePath
    }
  }
} catch {}

# tsc parse
$tscHad = $false
$tscText = Get-Content -LiteralPath $TOUT -Raw
if ($tscText.Trim().Length -gt 0) { $tscHad = $true }
$regex = '^(?<path>.+?)(?:\(|:)\d+[,:\)]\d+'  # matches C:\...\file.ts:10:5 or /x/y/file.ts(10,5)
foreach ($line in ($tscText -split "`r?`n")) {
  $m = [regex]::Match($line, $regex)
  if ($m.Success) { Add-File $m.Groups['path'].Value }
}

if ($eslintHad -or $tscHad) {
  $outLines.Insert(0, '')
  $outLines.Insert(0, 'The following are the diagnostics from the TypeScript compiler and ESLint. Tell me how to fix every error and/or warning. Tell me exactly what lines I need to modify in what file and what I need to change them to.')
  Set-Content -LiteralPath $OTXT -Value ($outLines -join "`n")
  Set-Content -LiteralPath $FLIST -Value (($files.ToArray()) -join "`n")
}

# 4) Append file dumps with line numbers
if (Test-Path $OTXT -PathType Leaf -and (Get-Item $OTXT).Length -gt 0) {
  foreach ($p in Get-Content -LiteralPath $FLIST) {
    if (Test-Path -LiteralPath $p -PathType Leaf) {
      Add-Content -LiteralPath $OTXT -Value "`n## $p"
      $i = 1
      Get-Content -LiteralPath $p | ForEach-Object {
        Add-Content -LiteralPath $OTXT -Value ("{0,6} {1}" -f $i, $_)
        $i++
      }
    }
  }
}

# 5) Clipboard best-effort
if (Test-Path $OTXT -PathType Leaf -and (Get-Item $OTXT).Length -gt 0) {
  $data = Get-Content -LiteralPath $OTXT -Raw
  if (Get-Command Set-Clipboard -ErrorAction SilentlyContinue) {
    $data | Set-Clipboard; $copied = $true
  } elseif (Get-Command clip.exe -ErrorAction SilentlyContinue) {
    $data | clip.exe; $copied = $true
  }
}

# 6) Report
if ($copied) {
  Write-Host 'Copied context to clipboard.'
} elseif (Test-Path $OTXT -PathType Leaf -and (Get-Item $OTXT).Length -gt 0) {
  Write-Host "Diagnostics found. Clipboard tool not available. See: $OTXT"
} else {
  Write-Host 'No warnings or errors found. Nothing was copied to clipboard.'
}
