<#
  agent-swarm-mcp text tools: grep, sed-style replace, line edits, a line
  pipeline (sort, unique, cut, ...), word counts, diff, copy and JSON, all
  confined to an agent's scratch folder. Dot-sourced by core.ps1; works on
  Windows PowerShell 5.1 and PowerShell 7. No code execution: every tool is a
  fixed text operation, and regular expressions time out after 2 seconds.
#>

$script:TextMaxLines   = 1000000
$script:TextMaxSteps   = 30
$script:RegexTimeout   = [TimeSpan]::FromSeconds(2)

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
function New-TextRegex([string]$Pattern, [bool]$IsRegex, [bool]$IgnoreCase, [bool]$Multiline = $false) {
    if (-not $Pattern) { throw 'pattern is empty.' }
    $opts = [System.Text.RegularExpressions.RegexOptions]::CultureInvariant
    if ($IgnoreCase) { $opts = $opts -bor [System.Text.RegularExpressions.RegexOptions]::IgnoreCase }
    if ($Multiline) { $opts = $opts -bor [System.Text.RegularExpressions.RegexOptions]::Multiline }
    $text = $Pattern; if (-not $IsRegex) { $text = [regex]::Escape($Pattern) }
    try { return (New-Object System.Text.RegularExpressions.Regex($text, $opts, $script:RegexTimeout)) }
    catch { throw "Invalid regular expression: $($_.Exception.InnerException.Message)$($_.Exception.Message -replace '^.*?: ', ' ')" }
}

function Get-Flag($A, [string]$Name, [bool]$Default = $false) {
    $v = Get-Prop $A $Name
    if ($null -eq $v) { return $Default }
    return ($v -eq $true -or [string]$v -eq 'true')
}

function Get-IntArg($A, [string]$Name, [int]$Default, [int]$Min = [int]::MinValue, [int]$Max = [int]::MaxValue) {
    $v = Get-Prop $A $Name
    if ($null -eq $v -or [string]$v -eq '') { return $Default }
    $n = 0
    if (-not [int]::TryParse([string]$v, [ref]$n)) { throw "$Name must be a whole number." }
    return [Math]::Min($Max, [Math]::Max($Min, $n))
}

# Converts a scratch-relative wildcard pattern to a regex: ** spans folders, * and ? don't.
function ConvertTo-GlobRegex([string]$Glob) {
    $g = $Glob.Trim().Replace('\', '/')
    while ($g.StartsWith('./')) { $g = $g.Substring(2) }
    $sb = New-Object System.Text.StringBuilder '^'
    $i = 0
    while ($i -lt $g.Length) {
        $c = $g[$i]
        if ($c -eq '*' -and $i + 1 -lt $g.Length -and $g[$i + 1] -eq '*') {
            $i += 2
            if ($i -lt $g.Length -and $g[$i] -eq '/') { [void]$sb.Append('(?:.*/)?'); $i++ } else { [void]$sb.Append('.*') }
            continue
        }
        if ($c -eq '*') { [void]$sb.Append('[^/]*') }
        elseif ($c -eq '?') { [void]$sb.Append('[^/]') }
        else { [void]$sb.Append([regex]::Escape([string]$c)) }
        $i++
    }
    [void]$sb.Append('$')
    $opts = [System.Text.RegularExpressions.RegexOptions]::CultureInvariant
    if ($script:OnWindows) { $opts = $opts -bor [System.Text.RegularExpressions.RegexOptions]::IgnoreCase }
    return (New-Object System.Text.RegularExpressions.Regex($sb.ToString(), $opts))
}

function Test-HasWildcard([string]$Path) { return ($null -ne $Path -and $Path.IndexOfAny([char[]]@('*', '?')) -ge 0) }

# The files a text tool works on: path is one file, a folder (recursively), a
# wildcard pattern relative to the scratch folder (e.g. levels/**/*.json), or
# empty for every file. name_filter (e.g. *.md) narrows it by file name.
function Get-TextFiles([string]$Root, [string]$Path, [string]$NameFilter) {
    if (-not $NameFilter) { $NameFilter = '*' }
    if (Test-HasWildcard $Path) {
        $rootFull = Resolve-ScratchPath $Root '' -AllowRoot
        if (([string]$Path).Contains('..') -or ([string]$Path).Contains(':') -or ([string]$Path).Trim().StartsWith('/')) { throw "Pattern '$Path' is not allowed: use a pattern relative to your scratch folder." }
        $rx = ConvertTo-GlobRegex $Path
        $files = @([System.IO.Directory]::GetFiles($rootFull, $NameFilter, [System.IO.SearchOption]::AllDirectories) |
            Where-Object { -not $_.EndsWith('.tmp') -and $rx.IsMatch((Get-ScratchRel $Root $_)) } | Sort-Object)
        return , $files
    }
    $base = Resolve-ScratchPath $Root $Path -AllowRoot
    if ([System.IO.File]::Exists($base)) { return , @($base) }
    if (-not [System.IO.Directory]::Exists($base)) { throw "No file or folder '$Path'." }
    $files = @([System.IO.Directory]::GetFiles($base, $NameFilter, [System.IO.SearchOption]::AllDirectories) | Where-Object { -not $_.EndsWith('.tmp') } | Sort-Object)
    return , $files
}

# Same, but at least one file must match.
function Get-ScopeFiles([string]$Root, $A, [string]$PathArg = 'path') {
    $p = [string](Get-Prop $A $PathArg)
    $files = Get-TextFiles $Root $p ([string](Get-Prop $A 'name_filter'))
    if (-not $files.Count) { $what = $p; if (-not $what) { $what = 'your scratch folder' }; throw "No files match $what$(if (Get-Prop $A 'name_filter') { " with name_filter $(Get-Prop $A 'name_filter')" })." }
    return , $files
}

# Lines of a text, and whether it ended with a newline.
function Split-TextLines([string]$Text) {
    $list = New-Object System.Collections.Generic.List[string]
    if (-not $Text) { return @{ Lines = $list; FinalNewline = $false } }
    $final = $Text.EndsWith("`n")
    $parts = $Text.Split("`n")
    $n = $parts.Length; if ($final) { $n-- }
    for ($i = 0; $i -lt $n; $i++) { $list.Add($parts[$i]) }
    return @{ Lines = $list; FinalNewline = $final }
}

function Join-TextLines($Lines, [bool]$FinalNewline) {
    $t = [string]::Join("`n", [string[]]@($Lines))
    if ($FinalNewline -and $Lines.Count) { $t += "`n" }
    return $t
}

# Rethrows an error, with a plain message when a regular expression timed out.
function Throw-TextError($Err) {
    $e = $Err.Exception
    while ($e) {
        if ($e -is [System.Text.RegularExpressions.RegexMatchTimeoutException]) { throw 'The regular expression took too long (over 2 seconds). Simplify it.' }
        $e = $e.InnerException
    }
    throw $Err
}

# Parses "1,3-5,7-" into a sorted list of 1-based field numbers (0 = to the end marker).
function ConvertTo-FieldList([string]$Spec) {
    $out = New-Object System.Collections.Generic.List[object]
    foreach ($part in $Spec.Split(',')) {
        $p = $part.Trim(); if (-not $p) { continue }
        if ($p -match '^(\d+)$') { $out.Add(@([int]$Matches[1], [int]$Matches[1])) }
        elseif ($p -match '^(\d+)-(\d+)$') { $out.Add(@([int]$Matches[1], [int]$Matches[2])) }
        elseif ($p -match '^(\d+)-$') { $out.Add(@([int]$Matches[1], [int]::MaxValue)) }
        elseif ($p -match '^-(\d+)$') { $out.Add(@(1, [int]$Matches[1])) }
        else { throw "fields '$Spec' is not valid: use numbers and ranges like 1,3-5,7-" }
    }
    if (-not $out.Count) { throw 'fields is empty.' }
    return , $out
}

function Split-Fields([string]$Line, [string]$Delimiter) {
    if ($Delimiter -eq 'whitespace') { return @($Line.Trim() -split '\s+') }
    return @($Line.Split([string[]]@($Delimiter), [System.StringSplitOptions]::None))
}

# ---------------------------------------------------------------------------
# Tool definitions
# ---------------------------------------------------------------------------
$script:ScopeDoc = 'Which files: one file, a folder (with its subfolders), a wildcard pattern relative to your scratch folder (* and ? within a name, ** across folders, e.g. levels/**/*.json), or empty for all files.'
$script:NameFilterDoc = 'Optional wildcard on file names to narrow the scope, e.g. *.md'

function Get-TextToolDefs {
    $scope = @{ type = 'string'; description = $script:ScopeDoc }
    $nf = @{ type = 'string'; description = $script:NameFilterDoc }
    $stepOps = @('grep', 'replace', 'extract', 'sort', 'unique', 'head', 'tail', 'lines', 'cut', 'trim', 'case', 'prefix', 'suffix', 'number', 'reverse', 'drop_empty', 'join', 'split')
    return @(
        @{ name = 'search_files'; description = 'Search text files like grep. Returns "path:line: text" for matches (context lines as "path-line- text", groups separated by "--"), or with output=files only the file names, output=count the number of matching lines per file, output=matches only the matched parts.'
           input_schema = @{ type = 'object'; properties = @{
                pattern = @{ type = 'string'; description = 'Text to find, or a .NET regular expression when regex is true.' }
                regex = @{ type = 'boolean'; description = 'Treat pattern as a regular expression. Default false (plain text).' }
                ignore_case = @{ type = 'boolean' }
                invert = @{ type = 'boolean'; description = 'Select the lines that do NOT match (grep -v).' }
                path = $scope
                name_filter = $nf
                context = @{ type = 'integer'; description = 'Lines of context before and after each match (0-20). Default 0.' }
                before = @{ type = 'integer'; description = 'Lines of context before each match (overrides context).' }
                after = @{ type = 'integer'; description = 'Lines of context after each match (overrides context).' }
                output = @{ type = 'string'; enum = @('lines', 'files', 'count', 'matches'); description = 'Default lines.' }
                max_results = @{ type = 'integer'; description = 'Stop after this many result lines (1-2000). Default 300.' } }; required = @('pattern') } },
        @{ name = 'replace_in_files'; description = 'Find and replace in one file or many, like sed s/// (regex groups: $1, ${name}; $$ for a literal $). Line by line by default; whole_file lets a pattern span lines (use \n). Set dry_run to preview the changed lines without writing.'
           input_schema = @{ type = 'object'; properties = @{
                pattern = @{ type = 'string' }
                replacement = @{ type = 'string'; description = 'Replacement text. Empty deletes the match.' }
                regex = @{ type = 'boolean'; description = 'Treat pattern as a regular expression. Default false (plain text, and the replacement is taken literally).' }
                ignore_case = @{ type = 'boolean' }
                path = $scope
                name_filter = $nf
                whole_file = @{ type = 'boolean'; description = 'Match against the whole file instead of each line (^ and $ still match at line ends). Default false.' }
                first_line = @{ type = 'integer'; description = 'Only change lines from this line on (1-based; line mode only).' }
                last_line = @{ type = 'integer'; description = 'Only change lines up to this line (line mode only).' }
                max_per_file = @{ type = 'integer'; description = 'At most this many replacements per file. Default 0 = all.' }
                dry_run = @{ type = 'boolean'; description = 'Show what would change, write nothing. Default false.' } }; required = @('pattern', 'replacement') } },
        @{ name = 'edit_lines'; description = 'Edit text files by line numbers (as read_file shows them): insert text before or after a line, replace a range of lines, or delete a range. With several files in scope, the same edit is made in each (e.g. add a header line to every file); a negative line counts from the end (-1 = the last line). Returns the edited region.'
           input_schema = @{ type = 'object'; properties = @{
                path = $scope
                name_filter = $nf
                operation = @{ type = 'string'; enum = @('insert_before', 'insert_after', 'replace', 'delete') }
                line = @{ type = 'integer'; description = 'Line number, 1-based; negative counts from the end (-1 = last line). insert_after with 0 inserts at the top.' }
                end_line = @{ type = 'integer'; description = 'Last line of the range for replace and delete (negative counts from the end). Default: line.' }
                text = @{ type = 'string'; description = 'The new lines for insert and replace (may contain several lines).' } }; required = @('path', 'operation', 'line') } },
        @{ name = 'transform_text'; description = 'Run text through a pipeline of line operations, like cat | grep | sed | sort | uniq | cut in a shell. The input is the files in scope (several files are joined in order, like cat), or a given text. The result is returned, written to output_path, or with in_place written back into each file separately. Steps run in order; each is an object with "op" and its options:
grep {pattern, regex, ignore_case, invert} keep matching lines
replace {pattern, replacement, regex, ignore_case} replace in each line
extract {pattern, regex (default true), ignore_case, group (number or name, default 0), all} keep only the matched part of each line (grep -o)
sort {reverse, numeric, ignore_case, field, delimiter} sort lines (by a 1-based field)
unique {ignore_case, count} drop repeated lines, keep the first; count prefixes each with its number of occurrences
head {count} | tail {count} | lines {from, to} keep the first, last, or a range of lines
cut {fields like "1,3-5", delimiter (default tab; "whitespace" splits on runs of spaces), output_delimiter}
trim {side: both|start|end} | case {to: upper|lower|title} | prefix {text} | suffix {text}
number {start, width, separator} number the lines | reverse {} | drop_empty {} drop blank lines
join {separator} make one line | split {separator, regex} split each line into several'
           input_schema = @{ type = 'object'; properties = @{
                path = $scope
                name_filter = $nf
                text = @{ type = 'string'; description = 'Input text instead of files.' }
                steps = @{ type = 'array'; description = 'The operations, in order (at most 30).'; items = @{ type = 'object'; properties = @{ op = @{ type = 'string'; enum = $stepOps } }; required = @('op') } }
                output_path = @{ type = 'string'; description = 'Write the result to this file (may be an input file).' }
                in_place = @{ type = 'boolean'; description = 'Run the pipeline on each file in scope separately and write each result back to its file.' } }; required = @('steps') } },
        @{ name = 'file_stats'; description = 'Count lines, words and characters (like wc) of each file in scope, with totals.'
           input_schema = @{ type = 'object'; properties = @{ path = $scope; name_filter = $nf } } },
        @{ name = 'diff_files'; description = 'Compare text and return a unified diff (lines starting with - are only in the first, + only in the second): two files, a file and a given text, or two folders (every file found in either, matched by its path inside the folder; name_filter narrows them).'
           input_schema = @{ type = 'object'; properties = @{
                path = @{ type = 'string'; description = 'The first file or folder.' }
                other_path = @{ type = 'string'; description = 'The second file or folder. Give other_path or other_text.' }
                name_filter = $nf
                other_text = @{ type = 'string'; description = 'Text to compare the first file with.' }
                context = @{ type = 'integer'; description = 'Unchanged lines shown around each change (0-20). Default 3.' } }; required = @('path') } },
        @{ name = 'copy_path'; description = 'Copy a file or a folder (with its content) inside your scratch folder.'
           input_schema = @{ type = 'object'; properties = @{ from = @{ type = 'string' }; to = @{ type = 'string' }; overwrite = @{ type = 'boolean'; description = 'Replace an existing file. Default false.' } }; required = @('from', 'to') } },
        @{ name = 'json_query'; description = 'Read a value from JSON files by its path, e.g. players[0].name or settings["max speed"] (empty for the whole document). Returns it as formatted JSON, or with keys=true the keys of an object (the length of an array). With several files in scope, returns the value from each ("file: value"; files without it say so).'
           input_schema = @{ type = 'object'; properties = @{ path = $scope; name_filter = $nf; query = @{ type = 'string'; description = 'Path to the value. Default: the whole document.' }; keys = @{ type = 'boolean' } } } },
        @{ name = 'json_edit'; description = 'Set or delete a value in JSON files by its path (as in json_query): one file, or every file in scope. Missing objects on the way are created; an array index equal to its length appends. Files are rewritten formatted.'
           input_schema = @{ type = 'object'; properties = @{
                path = @{ type = 'string'; description = $script:ScopeDoc + ' A single file that does not exist yet is created.' }
                name_filter = $nf
                query = @{ type = 'string'; description = 'Path to the value, e.g. enemies[2].hp' }
                value = @{ type = 'string'; description = 'The new value as JSON text: 42, true, null, "text", [1,2], {"a":1}. Text that is not valid JSON is stored as a string.' }
                delete = @{ type = 'boolean'; description = 'Delete the value instead of setting it.' } }; required = @('query') } }
    )
}

# ---------------------------------------------------------------------------
# search_files
# ---------------------------------------------------------------------------
function Invoke-SearchFiles([string]$Root, $A) {
    $rx = New-TextRegex ([string](Get-Prop $A 'pattern')) (Get-Flag $A 'regex') (Get-Flag $A 'ignore_case')
    $invert = Get-Flag $A 'invert'
    $mode = [string](Get-Prop $A 'output'); if (-not $mode) { $mode = 'lines' }
    if ($mode -notin @('lines', 'files', 'count', 'matches')) { throw 'output must be lines, files, count or matches.' }
    $ctx = Get-IntArg $A 'context' 0 0 20
    $before = Get-IntArg $A 'before' $ctx 0 20
    $after = Get-IntArg $A 'after' $ctx 0 20
    $max = Get-IntArg $A 'max_results' 300 1 2000
    $files = Get-ScopeFiles $Root $A
    $out = New-Object System.Collections.Generic.List[string]
    $total = 0; $filesHit = 0; $stopped = $false
    try {
        foreach ($f in $files) {
            if ($stopped) { break }
            try { $t = Read-ScratchText $f } catch { continue }
            $rel = Get-ScratchRel $Root $f
            $lines = (Split-TextLines $t).Lines
            $hits = New-Object System.Collections.Generic.List[int]
            for ($i = 0; $i -lt $lines.Count; $i++) { if ($rx.IsMatch($lines[$i]) -ne $invert) { $hits.Add($i) } }
            if (-not $hits.Count) { continue }
            $filesHit++; $total += $hits.Count
            switch ($mode) {
                'files' { $out.Add($rel) }
                'count' { $out.Add("${rel}: $($hits.Count)") }
                'matches' {
                    foreach ($i in $hits) {
                        if ($invert) { $out.Add("${rel}:$($i + 1): $(Limit-Text $lines[$i] 300)") }
                        else { foreach ($m in $rx.Matches($lines[$i])) { $out.Add("${rel}:$($i + 1): $(Limit-Text $m.Value 300)"); if ($out.Count -ge $max) { break } } }
                        if ($out.Count -ge $max) { $stopped = $true; break }
                    }
                }
                default {
                    $shown = -1
                    $hitSet = New-Object 'System.Collections.Generic.HashSet[int]'; foreach ($h in $hits) { [void]$hitSet.Add($h) }
                    foreach ($i in $hits) {
                        $from = [Math]::Max(0, $i - $before); $to = [Math]::Min($lines.Count - 1, $i + $after)
                        if ($from -le $shown) { $from = $shown + 1 }
                        elseif (($before -or $after) -and $shown -ge 0) { $out.Add('--') }
                        for ($j = $from; $j -le $to; $j++) {
                            $sep = '-'; if ($hitSet.Contains($j)) { $sep = ':' }
                            $out.Add("$rel$sep$($j + 1)$sep $(Limit-Text $lines[$j] 300)")
                        }
                        if ($to -gt $shown) { $shown = $to }
                        if ($out.Count -ge $max) { $stopped = $true; break }
                    }
                    if (($before -or $after) -and -not $stopped) { $out.Add('--') }
                }
            }
            if ($out.Count -ge $max) { $stopped = $true }
        }
    } catch { Throw-TextError $_ }
    if (-not $out.Count) { return 'No matches.' }
    if ($out.Count -and $out[$out.Count - 1] -eq '--') { $out.RemoveAt($out.Count - 1) }
    $res = ($out -join "`n")
    if ($stopped) { $res += "`n[stopped at $max result lines; narrow the search or raise max_results]" }
    elseif ($mode -eq 'count' -and $filesHit -gt 1) { $res += "`ntotal: $total lines in $filesHit files" }
    return $res
}

# ---------------------------------------------------------------------------
# replace_in_files
# ---------------------------------------------------------------------------
function Invoke-ReplaceInFiles($S, [string]$Root, $A) {
    $isRegex = Get-Flag $A 'regex'
    $whole = Get-Flag $A 'whole_file'
    $rx = New-TextRegex (ConvertTo-Lf ([string](Get-Prop $A 'pattern'))) $isRegex (Get-Flag $A 'ignore_case') $whole
    $rep = ConvertTo-Lf ([string](Get-Prop $A 'replacement'))
    if (-not $isRegex) { $rep = $rep.Replace('$', '$$') }
    $dry = Get-Flag $A 'dry_run'
    $maxPer = Get-IntArg $A 'max_per_file' 0 0
    $first = Get-IntArg $A 'first_line' 1 1
    $last = Get-IntArg $A 'last_line' ([int]::MaxValue) 1
    if ($whole -and ((Get-Prop $A 'first_line') -or (Get-Prop $A 'last_line'))) { throw 'first_line and last_line work in line mode only (whole_file false).' }
    $files = Get-ScopeFiles $Root $A
    $report = New-Object System.Collections.Generic.List[string]
    $preview = New-Object System.Collections.Generic.List[string]
    $grandTotal = 0; $changedFiles = 0
    try {
        foreach ($f in $files) {
            try { $t = Read-ScratchText $f } catch { continue }
            $rel = Get-ScratchRel $Root $f
            $count = 0
            if ($whole) {
                $n = $rx.Matches($t).Count
                if (-not $n) { continue }
                if ($maxPer -gt 0 -and $n -gt $maxPer) { $n = $maxPer; $new = $rx.Replace($t, $rep, $maxPer) } else { $new = $rx.Replace($t, $rep) }
                $count = $n
                if ($preview.Count -lt 60) {
                    $a = (Split-TextLines $t).Lines; $b = (Split-TextLines $new).Lines
                    $d = Get-UnifiedDiff $a $b 0 "$rel" "$rel"
                    foreach ($l in @($d.Split("`n") | Select-Object -First 40)) { $preview.Add($l) }
                }
            } else {
                $sp = Split-TextLines $t; $lines = $sp.Lines
                $left = [int]::MaxValue; if ($maxPer -gt 0) { $left = $maxPer }
                for ($i = [Math]::Max(0, $first - 1); $i -lt [Math]::Min($lines.Count, $last); $i++) {
                    if ($left -le 0) { break }
                    $line = $lines[$i]
                    $n = $rx.Matches($line).Count
                    if (-not $n) { continue }
                    if ($n -gt $left) { $n = $left }
                    $newLine = $rx.Replace($line, $rep, $n)
                    $left -= $n; $count += $n
                    if ($newLine -ne $line) {
                        if ($preview.Count -lt 60) { $preview.Add("${rel}:$($i + 1)"); $preview.Add("- $(Limit-Text $line 300)"); $preview.Add("+ $(Limit-Text $newLine 300)") }
                        $lines[$i] = $newLine
                    }
                }
                if (-not $count) { continue }
                $new = Join-TextLines $lines $sp.FinalNewline
            }
            if ($new -eq $t) { $report.Add("${rel}: $count match(es), no change"); continue }
            $changedFiles++; $grandTotal += $count
            $report.Add("${rel}: $count replacement(s)")
            if (-not $dry) {
                if ($new.Length -gt $script:ScratchMaxFileChars) { throw "$rel would grow past the size limit." }
                if ($new.Length -gt $t.Length) { Assert-ScratchQuota $S $Root ($new.Length - $t.Length) }
                Write-TextFile $f $new
            }
        }
    } catch { Throw-TextError $_ }
    if (-not $report.Count) { return 'No matches; nothing changed.' }
    $head = "Replaced $grandTotal time(s) in $changedFiles file(s)."
    if ($dry) { $head = "Dry run: would replace $grandTotal time(s) in $changedFiles file(s). Nothing was written." }
    $res = $head + "`n" + ($report -join "`n")
    if ($preview.Count) { $res += "`n`nChanges:`n" + ($preview -join "`n"); if ($preview.Count -ge 60) { $res += "`n[preview cut]" } }
    return $res
}

# ---------------------------------------------------------------------------
# edit_lines
# ---------------------------------------------------------------------------
function Edit-OneFile($S, [string]$Root, [string]$Full, [string]$Op, [int]$Line, [int]$End, $NewLines, [bool]$ShowRegion) {
    $t = Read-ScratchText $Full
    $sp = Split-TextLines $t; $lines = $sp.Lines
    $n = $lines.Count
    # Negative numbers count from the end: -1 is the last line.
    if ($Line -lt 0) { $Line = $n + 1 + $Line }
    if ($End -lt 0) { $End = $n + 1 + $End }
    $rel = Get-ScratchRel $Root $Full
    switch ($Op) {
        'insert_before' {
            if ($Line -lt 1 -or $Line -gt $n + 1) { throw "${rel}: line must be 1-$($n + 1) (the file has $n lines)." }
            $lines.InsertRange($Line - 1, $NewLines); $at = $Line; $cnt = $NewLines.Count; $msg = "inserted $cnt line(s) before line $Line"
        }
        'insert_after' {
            if ($Line -lt 0 -or $Line -gt $n) { throw "${rel}: line must be 0-$n (the file has $n lines; 0 inserts at the top)." }
            $lines.InsertRange($Line, $NewLines); $at = $Line + 1; $cnt = $NewLines.Count; $msg = "inserted $cnt line(s) after line $Line"
        }
        'replace' {
            if ($Line -lt 1 -or $End -lt $Line -or $End -gt $n) { throw "${rel}: line and end_line must be within 1-$n, with end_line >= line." }
            $lines.RemoveRange($Line - 1, $End - $Line + 1); $lines.InsertRange($Line - 1, $NewLines)
            $at = $Line; $cnt = $NewLines.Count; $msg = "replaced lines $Line-$End with $cnt line(s)"
        }
        'delete' {
            if ($Line -lt 1 -or $End -lt $Line -or $End -gt $n) { throw "${rel}: line and end_line must be within 1-$n, with end_line >= line." }
            $lines.RemoveRange($Line - 1, $End - $Line + 1); $at = $Line; $cnt = 0; $msg = "deleted lines $Line-$End"
        }
    }
    $new = Join-TextLines $lines ($sp.FinalNewline -or ($n -eq 0))
    if ($new.Length -gt $script:ScratchMaxFileChars) { throw "${rel} would grow past the size limit." }
    if ($new.Length -gt $t.Length) { Assert-ScratchQuota $S $Root ($new.Length - $t.Length) }
    Write-TextFile $Full $new
    $res = "${rel}: $msg, now $($lines.Count) lines."
    if ($ShowRegion) {
        $from = [Math]::Max(1, $at - 2); $to = [Math]::Min($lines.Count, $at + [Math]::Max($cnt, 1) + 1)
        $sb = New-Object System.Text.StringBuilder
        for ($i = $from; $i -le $to; $i++) { [void]$sb.Append($i).Append('|').Append($lines[$i - 1]).Append("`n") }
        $res += "`n" + $sb.ToString().TrimEnd("`n")
    }
    return $res
}

function Invoke-EditLines($S, [string]$Root, $A) {
    $op = [string](Get-Prop $A 'operation')
    if ($op -notin @('insert_before', 'insert_after', 'replace', 'delete')) { throw 'operation must be insert_before, insert_after, replace or delete.' }
    if ($null -eq (Get-Prop $A 'line')) { throw 'line is required.' }
    $line = Get-IntArg $A 'line' 0
    $end = Get-IntArg $A 'end_line' $line
    $newText = ConvertTo-Lf ([string](Get-Prop $A 'text'))
    $newLines = New-Object System.Collections.Generic.List[string]
    if ($newText) { foreach ($l in (Split-TextLines $newText).Lines) { $newLines.Add($l) } }
    if ($op -like 'insert_*' -and -not $newLines.Count) { throw 'text is empty.' }
    $files = Get-ScopeFiles $Root $A
    if ($files.Count -gt 500) { throw "$($files.Count) files are in scope; narrow it to 500 or fewer." }
    $out = New-Object System.Collections.Generic.List[string]
    $failed = 0
    foreach ($f in $files) {
        try { $out.Add((Edit-OneFile $S $Root $f $op $line $end $newLines ($files.Count -eq 1))) }
        catch { if ($files.Count -eq 1) { throw }; $failed++; $out.Add("skipped: $($_.Exception.Message)") }
    }
    if ($files.Count -gt 1) { $out.Insert(0, "Edited $($files.Count - $failed) of $($files.Count) files.") }
    return ($out -join "`n")
}

# ---------------------------------------------------------------------------
# transform_text
# ---------------------------------------------------------------------------
function Invoke-TextStep($Lines, $Step) {
    $op = [string](Get-Prop $Step 'op')
    $out = New-Object System.Collections.Generic.List[string]
    switch ($op) {
        'grep' {
            $rx = New-TextRegex ([string](Get-Prop $Step 'pattern')) (Get-Flag $Step 'regex') (Get-Flag $Step 'ignore_case')
            $inv = Get-Flag $Step 'invert'
            foreach ($l in $Lines) { if ($rx.IsMatch($l) -ne $inv) { $out.Add($l) } }
        }
        'replace' {
            $isRx = Get-Flag $Step 'regex'
            $rx = New-TextRegex ([string](Get-Prop $Step 'pattern')) $isRx (Get-Flag $Step 'ignore_case')
            $rep = [string](Get-Prop $Step 'replacement'); if (-not $isRx) { $rep = $rep.Replace('$', '$$') }
            foreach ($l in $Lines) { $out.Add($rx.Replace($l, $rep)) }
        }
        'extract' {
            $rx = New-TextRegex ([string](Get-Prop $Step 'pattern')) (Get-Flag $Step 'regex' $true) (Get-Flag $Step 'ignore_case')
            $g = Get-Prop $Step 'group'; if ($null -eq $g -or [string]$g -eq '') { $g = 0 }
            $all = Get-Flag $Step 'all'
            $gi = 0; $byNum = [int]::TryParse([string]$g, [ref]$gi)
            foreach ($l in $Lines) {
                foreach ($m in $rx.Matches($l)) {
                    if ($byNum) { $grp = $m.Groups[$gi] } else { $grp = $m.Groups[[string]$g] }
                    if ($grp.Success) { $out.Add($grp.Value) }
                    if (-not $all) { break }
                }
            }
        }
        'sort' {
            $rev = Get-Flag $Step 'reverse'; $num = Get-Flag $Step 'numeric'; $ic = Get-Flag $Step 'ignore_case'
            $field = Get-IntArg $Step 'field' 0 0
            $delim = [string](Get-Prop $Step 'delimiter'); if (-not $delim) { $delim = 'whitespace' }
            $keyed = New-Object System.Collections.Generic.List[object]
            $idx = 0
            foreach ($l in $Lines) {
                $k = $l
                if ($field -gt 0) { $f = @(Split-Fields $l $delim); if ($f.Count -ge $field) { $k = $f[$field - 1] } else { $k = '' } }
                $nk = [double]::NaN
                if ($num) { $d = 0.0; if ([double]::TryParse(($k.Trim() -replace '^([-+]?[0-9]*\.?[0-9]+([eE][-+]?[0-9]+)?).*$', '$1'), [System.Globalization.NumberStyles]::Float, [System.Globalization.CultureInfo]::InvariantCulture, [ref]$d)) { $nk = $d } }
                $keyed.Add([pscustomobject]@{ L = $l; K = $k; N = $nk; I = $idx }); $idx++
            }
            $cmp = [System.StringComparer]::Ordinal; if ($ic) { $cmp = [System.StringComparer]::OrdinalIgnoreCase }
            $arr = $keyed.ToArray()
            # Stable sort with a comparison: numbers first by value (non-numbers last), else text.
            $list = New-Object System.Collections.Generic.List[object]; $list.AddRange([object[]]$arr)
            $comparison = [System.Comparison[object]] {
                param($x, $y)
                $c = 0
                if ($num) {
                    $xn = -not [double]::IsNaN($x.N); $yn = -not [double]::IsNaN($y.N)
                    if ($xn -and $yn) { $c = $x.N.CompareTo($y.N) } elseif ($xn) { $c = -1 } elseif ($yn) { $c = 1 } else { $c = $cmp.Compare($x.K, $y.K) }
                } else { $c = $cmp.Compare($x.K, $y.K) }
                if ($rev) { $c = -$c }
                if ($c -eq 0) { $c = $x.I.CompareTo($y.I) }
                return $c
            }.GetNewClosure()
            $list.Sort($comparison)
            foreach ($e in $list) { $out.Add($e.L) }
        }
        'unique' {
            $ic = Get-Flag $Step 'ignore_case'; $withCount = Get-Flag $Step 'count'
            $cmp = [System.StringComparer]::Ordinal; if ($ic) { $cmp = [System.StringComparer]::OrdinalIgnoreCase }
            $counts = New-Object 'System.Collections.Generic.Dictionary[string,int]' ($cmp)
            $order = New-Object System.Collections.Generic.List[string]
            foreach ($l in $Lines) { if ($counts.ContainsKey($l)) { $counts[$l]++ } else { $counts[$l] = 1; $order.Add($l) } }
            foreach ($l in $order) { if ($withCount) { $out.Add("$($counts[$l]) $l") } else { $out.Add($l) } }
        }
        'head' { $c = Get-IntArg $Step 'count' 10 0; for ($i = 0; $i -lt [Math]::Min($c, $Lines.Count); $i++) { $out.Add($Lines[$i]) } }
        'tail' { $c = Get-IntArg $Step 'count' 10 0; for ($i = [Math]::Max(0, $Lines.Count - $c); $i -lt $Lines.Count; $i++) { $out.Add($Lines[$i]) } }
        'lines' {
            $from = Get-IntArg $Step 'from' 1 1; $to = Get-IntArg $Step 'to' $Lines.Count 1
            for ($i = $from - 1; $i -lt [Math]::Min($to, $Lines.Count); $i++) { $out.Add($Lines[$i]) }
        }
        'cut' {
            $spec = ConvertTo-FieldList ([string](Get-Prop $Step 'fields'))
            $delim = [string](Get-Prop $Step 'delimiter'); if (-not $delim) { $delim = "`t" }
            $od = Get-Prop $Step 'output_delimiter'; if ($null -eq $od) { if ($delim -eq 'whitespace') { $od = ' ' } else { $od = $delim } }
            foreach ($l in $Lines) {
                $f = @(Split-Fields $l $delim)
                $pick = New-Object System.Collections.Generic.List[string]
                foreach ($r in $spec) { for ($i = $r[0]; $i -le [Math]::Min($r[1], $f.Count); $i++) { $pick.Add($f[$i - 1]) } }
                $out.Add([string]::Join([string]$od, $pick.ToArray()))
            }
        }
        'trim' {
            $side = [string](Get-Prop $Step 'side'); if (-not $side) { $side = 'both' }
            foreach ($l in $Lines) { switch ($side) { 'start' { $out.Add($l.TrimStart()) } 'end' { $out.Add($l.TrimEnd()) } default { $out.Add($l.Trim()) } } }
        }
        'case' {
            $to = [string](Get-Prop $Step 'to'); $ti = [System.Globalization.CultureInfo]::InvariantCulture.TextInfo
            foreach ($l in $Lines) { switch ($to) { 'upper' { $out.Add($l.ToUpperInvariant()) } 'lower' { $out.Add($l.ToLowerInvariant()) } 'title' { $out.Add($ti.ToTitleCase($l.ToLowerInvariant())) } default { throw 'case: "to" must be upper, lower or title.' } } }
        }
        'prefix' { $p = [string](Get-Prop $Step 'text'); foreach ($l in $Lines) { $out.Add($p + $l) } }
        'suffix' { $p = [string](Get-Prop $Step 'text'); foreach ($l in $Lines) { $out.Add($l + $p) } }
        'number' {
            $n = Get-IntArg $Step 'start' 1; $w = Get-IntArg $Step 'width' 0 0 12
            $sep = Get-Prop $Step 'separator'; if ($null -eq $sep) { $sep = ': ' }
            foreach ($l in $Lines) { $out.Add(([string]$n).PadLeft($w) + [string]$sep + $l); $n++ }
        }
        'reverse' { for ($i = $Lines.Count - 1; $i -ge 0; $i--) { $out.Add($Lines[$i]) } }
        'drop_empty' { foreach ($l in $Lines) { if ($l.Trim()) { $out.Add($l) } } }
        'join' { $sep = Get-Prop $Step 'separator'; if ($null -eq $sep) { $sep = ' ' }; $out.Add([string]::Join([string]$sep, $Lines.ToArray())) }
        'split' {
            $sep = [string](Get-Prop $Step 'separator'); if (-not $sep) { throw 'split needs a separator.' }
            if (Get-Flag $Step 'regex') { $rx = New-TextRegex $sep $true $false; foreach ($l in $Lines) { foreach ($p in $rx.Split($l)) { $out.Add($p) } } }
            else { foreach ($l in $Lines) { foreach ($p in $l.Split([string[]]@($sep), [System.StringSplitOptions]::None)) { $out.Add($p) } } }
        }
        default { throw "Unknown step op '$op'. Use one of: grep, replace, extract, sort, unique, head, tail, lines, cut, trim, case, prefix, suffix, number, reverse, drop_empty, join, split." }
    }
    if ($out.Count -gt $script:TextMaxLines) { throw "The '$op' step produced over $($script:TextMaxLines) lines." }
    return , $out
}

function Invoke-TextPipeline($Lines, $Steps, $Log) {
    $i = 0
    foreach ($st in $Steps) {
        $i++
        try { $Lines = Invoke-TextStep $Lines $st }
        catch { try { Throw-TextError $_ } catch { throw "Step $i ($([string](Get-Prop $st 'op'))): $($_.Exception.Message)" } }
        if ($null -ne $Log) { $Log.Add("$i $([string](Get-Prop $st 'op')): $($Lines.Count) lines") }
    }
    return , $Lines
}

function Invoke-TransformText($S, [string]$Root, $A) {
    $text = Get-Prop $A 'text'
    $hasScope = [bool]([string](Get-Prop $A 'path')) -or [bool]([string](Get-Prop $A 'name_filter'))
    if ($hasScope -and $null -ne $text) { throw 'Give path (files) or text, not both.' }
    $steps = @(Get-Prop $A 'steps' | Where-Object { $null -ne $_ })
    if (-not $steps.Count) { throw 'steps is empty.' }
    if ($steps.Count -gt $script:TextMaxSteps) { throw "At most $($script:TextMaxSteps) steps." }
    $inPlace = Get-Flag $A 'in_place'
    $outPath = [string](Get-Prop $A 'output_path')
    if ($inPlace -and $outPath) { throw 'Use in_place or output_path, not both.' }
    if ($inPlace) {
        if ($null -ne $text) { throw 'in_place needs files (path), not text.' }
        $files = Get-ScopeFiles $Root $A
        if ($files.Count -gt 500) { throw "$($files.Count) files are in scope; narrow it to 500 or fewer." }
        $rep = New-Object System.Collections.Generic.List[string]; $changed = 0
        foreach ($f in $files) {
            try { $src = Read-ScratchText $f } catch { $rep.Add("$(Get-ScratchRel $Root $f): skipped (binary)"); continue }
            $sp = Split-TextLines $src
            $res = Join-TextLines (Invoke-TextPipeline $sp.Lines $steps $null) $sp.FinalNewline
            if ($res -eq $src) { $rep.Add("$(Get-ScratchRel $Root $f): unchanged"); continue }
            if ($res.Length -gt $script:ScratchMaxFileChars) { throw "$(Get-ScratchRel $Root $f) would grow past the size limit." }
            if ($res.Length -gt $src.Length) { Assert-ScratchQuota $S $Root ($res.Length - $src.Length) }
            Write-TextFile $f $res; $changed++
            $rep.Add("$(Get-ScratchRel $Root $f): $($sp.Lines.Count) -> $((Split-TextLines $res).Lines.Count) lines")
        }
        return "Changed $changed of $($files.Count) file(s) in place.`n" + ($rep -join "`n")
    }
    if ($null -ne $text) { $sp = Split-TextLines (ConvertTo-Lf ([string]$text)); $fromFiles = $false }
    else {
        # Several files are joined in order, like cat.
        $files = Get-ScopeFiles $Root $A
        $all = New-Object System.Collections.Generic.List[string]
        $size = 0
        foreach ($f in $files) {
            try { $t = Read-ScratchText $f } catch { continue }
            $size += $t.Length
            if ($size -gt $script:ScratchMaxFileChars) { throw "The files in scope are over $($script:ScratchMaxFileChars) characters together; narrow the scope." }
            $all.AddRange((Split-TextLines $t).Lines)
        }
        $sp = @{ Lines = $all; FinalNewline = $true }; $fromFiles = $true
    }
    $log = New-Object System.Collections.Generic.List[string]
    $lines = Invoke-TextPipeline $sp.Lines $steps $log
    $result = Join-TextLines $lines ($sp.FinalNewline -or $fromFiles)
    if ($outPath) {
        $of = Resolve-ScratchPath $Root $outPath
        if ([System.IO.Directory]::Exists($of)) { throw 'output_path is a folder.' }
        if ($result.Length -gt $script:ScratchMaxFileChars) { throw 'The result is over the file size limit.' }
        $oldLen = 0; if ([System.IO.File]::Exists($of)) { $oldLen = (New-Object System.IO.FileInfo $of).Length }
        if ($result.Length -gt $oldLen) { Assert-ScratchQuota $S $Root ($result.Length - $oldLen) }
        Write-TextFile $of $result
        return "Wrote $(Get-ScratchRel $Root $of): $($lines.Count) lines ($($result.Length) characters).`nSteps: $($log -join '; ')"
    }
    $shown = Limit-Text $result 50000
    return "[$($lines.Count) lines; steps: $($log -join '; ')]`n$shown"
}

# ---------------------------------------------------------------------------
# file_stats
# ---------------------------------------------------------------------------
function Invoke-FileStats([string]$Root, $A) {
    $files = Get-ScopeFiles $Root $A
    $rows = New-Object System.Collections.Generic.List[string]
    $tl = 0; $tw = 0; $tc = 0; $tb = [long]0; $n = 0
    foreach ($f in $files) {
        $bytes = (New-Object System.IO.FileInfo $f).Length
        try { $t = Read-ScratchText $f } catch { $rows.Add("$(Get-ScratchRel $Root $f): binary, $bytes bytes"); continue }
        $lines = (Split-TextLines $t).Lines
        $words = 0; $longest = 0
        foreach ($l in $lines) { if ($l.Length -gt $longest) { $longest = $l.Length }; $w = $l.Trim(); if ($w) { $words += @($w -split '\s+').Count } }
        $rows.Add("$(Get-ScratchRel $Root $f): $($lines.Count) lines, $words words, $($t.Length) characters, $bytes bytes, longest line $longest")
        $tl += $lines.Count; $tw += $words; $tc += $t.Length; $tb += $bytes; $n++
        if ($rows.Count -ge 500) { $rows.Add('[stopped at 500 files]'); break }
    }
    if ($n -gt 1) { $rows.Add("total ($n files): $tl lines, $tw words, $tc characters, $tb bytes") }
    return ($rows -join "`n")
}

# ---------------------------------------------------------------------------
# diff_files (Myers' algorithm, unified output)
# ---------------------------------------------------------------------------
function Get-EditScript($A, $B, [int]$MaxD) {
    $n = $A.Count; $m = $B.Count
    $off = $MaxD + 1
    $v = New-Object int[] (2 * $MaxD + 3)
    $trace = New-Object System.Collections.Generic.List[object]
    $found = -1
    for ($d = 0; $d -le $MaxD; $d++) {
        $trace.Add($v.Clone())
        for ($k = -$d; $k -le $d; $k += 2) {
            if ($k -eq -$d -or ($k -ne $d -and $v[$off + $k - 1] -lt $v[$off + $k + 1])) { $x = $v[$off + $k + 1] } else { $x = $v[$off + $k - 1] + 1 }
            $y = $x - $k
            while ($x -lt $n -and $y -lt $m -and [string]::Equals($A[$x], $B[$y])) { $x++; $y++ }
            $v[$off + $k] = $x
            if ($x -ge $n -and $y -ge $m) { $found = $d; break }
        }
        if ($found -ge 0) { break }
    }
    if ($found -lt 0) { return $null }
    # Walk back through the trace: ops are ' ', '-', '+' with indexes into A and B.
    $ops = New-Object System.Collections.Generic.List[object]
    $x = $n; $y = $m
    for ($d = $found; $d -ge 0; $d--) {
        $vv = $trace[$d]; $k = $x - $y
        if ($k -eq -$d -or ($k -ne $d -and $vv[$off + $k - 1] -lt $vv[$off + $k + 1])) { $pk = $k + 1 } else { $pk = $k - 1 }
        $px = $vv[$off + $pk]; $py = $px - $pk
        while ($x -gt $px -and $y -gt $py) { $ops.Add(@(' ', ($x - 1), ($y - 1))); $x--; $y-- }
        if ($d -gt 0) { if ($x -eq $px) { $ops.Add(@('+', $px, $py)) } else { $ops.Add(@('-', $px, $py)) } }
        $x = $px; $y = $py
    }
    $ops.Reverse()
    return , $ops
}

function Get-UnifiedDiff($A, $B, [int]$Context, [string]$NameA, [string]$NameB) {
    # Common head and tail are trimmed first, so the search only covers what changed.
    $pre = 0
    while ($pre -lt $A.Count -and $pre -lt $B.Count -and [string]::Equals($A[$pre], $B[$pre])) { $pre++ }
    $suf = 0
    while ($suf -lt ($A.Count - $pre) -and $suf -lt ($B.Count - $pre) -and [string]::Equals($A[$A.Count - 1 - $suf], $B[$B.Count - 1 - $suf])) { $suf++ }
    if ($pre -eq $A.Count -and $pre -eq $B.Count) { return '' }
    $ma = New-Object System.Collections.Generic.List[string]; for ($i = $pre; $i -lt $A.Count - $suf; $i++) { $ma.Add($A[$i]) }
    $mb = New-Object System.Collections.Generic.List[string]; for ($i = $pre; $i -lt $B.Count - $suf; $i++) { $mb.Add($B[$i]) }
    $maxD = [Math]::Min($ma.Count + $mb.Count, 3000)
    $mid = Get-EditScript $ma $mb $maxD
    if ($null -eq $mid) { throw 'The files differ in too many places to compare (over 3000 changes).' }
    $ops = New-Object System.Collections.Generic.List[object]
    for ($i = 0; $i -lt $pre; $i++) { $ops.Add(@(' ', $i, $i)) }
    foreach ($o in $mid) { $ops.Add(@($o[0], ($o[1] + $pre), ($o[2] + $pre))) }
    for ($i = 0; $i -lt $suf; $i++) { $ops.Add(@(' ', ($A.Count - $suf + $i), ($B.Count - $suf + $i))) }
    # Group changes into hunks with context.
    $out = New-Object System.Collections.Generic.List[string]
    $out.Add("--- $NameA"); $out.Add("+++ $NameB")
    $idx = 0; $cnt = $ops.Count
    while ($idx -lt $cnt) {
        while ($idx -lt $cnt -and $ops[$idx][0] -eq ' ') { $idx++ }
        if ($idx -ge $cnt) { break }
        $start = [Math]::Max(0, $idx - $Context)
        $end = $idx
        $lastChange = $idx
        while ($end -lt $cnt) {
            if ($ops[$end][0] -ne ' ') { $lastChange = $end }
            elseif ($end - $lastChange -gt 2 * $Context) { break }
            $end++
        }
        $end = [Math]::Min($cnt, $lastChange + $Context + 1)
        $aStart = -1; $bStart = -1; $aLen = 0; $bLen = 0
        $body = New-Object System.Collections.Generic.List[string]
        for ($j = $start; $j -lt $end; $j++) {
            $o = $ops[$j]
            switch ($o[0]) {
                ' ' { if ($aStart -lt 0) { $aStart = $o[1] }; if ($bStart -lt 0) { $bStart = $o[2] }; $aLen++; $bLen++; $body.Add(' ' + $A[$o[1]]) }
                '-' { if ($aStart -lt 0) { $aStart = $o[1] }; if ($bStart -lt 0) { $bStart = $o[2] }; $aLen++; $body.Add('-' + $A[$o[1]]) }
                '+' { if ($aStart -lt 0) { $aStart = $o[1] }; if ($bStart -lt 0) { $bStart = $o[2] }; $bLen++; $body.Add('+' + $B[$o[2]]) }
            }
        }
        $as = $aStart + 1; if ($aLen -eq 0) { $as = $aStart }
        $bs = $bStart + 1; if ($bLen -eq 0) { $bs = $bStart }
        $out.Add("@@ -$as,$aLen +$bs,$bLen @@")
        $out.AddRange($body)
        $idx = $end
    }
    return ($out -join "`n")
}

function Invoke-DiffFolders([string]$Root, [string]$DirA, [string]$DirB, [int]$Ctx, [string]$NameFilter) {
    if (-not $NameFilter) { $NameFilter = '*' }
    $rels = New-Object 'System.Collections.Generic.SortedSet[string]' ([System.StringComparer]::Ordinal)
    foreach ($d in @($DirA, $DirB)) {
        foreach ($f in [System.IO.Directory]::GetFiles($d, $NameFilter, [System.IO.SearchOption]::AllDirectories)) { if (-not $f.EndsWith('.tmp')) { [void]$rels.Add($f.Substring($d.Length + 1).Replace('\', '/')) } }
    }
    $ra = Get-ScratchRel $Root $DirA; $rb = Get-ScratchRel $Root $DirB
    $out = New-Object System.Collections.Generic.List[string]
    $same = 0; $diffs = 0
    foreach ($r in $rels) {
        $fa = [System.IO.Path]::Combine($DirA, $r); $fb = [System.IO.Path]::Combine($DirB, $r)
        $ea = [System.IO.File]::Exists($fa); $eb = [System.IO.File]::Exists($fb)
        if (-not $eb) { $out.Add("Only in ${ra}: $r"); $diffs++; continue }
        if (-not $ea) { $out.Add("Only in ${rb}: $r"); $diffs++; continue }
        try { $ta = Read-ScratchText $fa; $tb = Read-ScratchText $fb } catch { $out.Add("Binary: $r"); continue }
        if ($ta -eq $tb) { $same++; continue }
        $diffs++
        $d = Get-UnifiedDiff (Split-TextLines $ta).Lines (Split-TextLines $tb).Lines $Ctx "$ra/$r" "$rb/$r"
        if (-not $d) { $d = "$r differs only in the newline at the end." }
        $out.Add($d)
        if ($out.Count -gt 400) { $out.Add('[stopped: too many differences; narrow with name_filter]'); break }
    }
    if (-not $diffs) { return "The folders are identical ($same file(s))." }
    $out.Insert(0, "$diffs file(s) differ, $same identical.")
    return ($out -join "`n")
}

function Invoke-DiffFiles([string]$Root, $A) {
    $fa = Resolve-ScratchPath $Root ([string](Get-Prop $A 'path'))
    $ctx0 = Get-IntArg $A 'context' 3 0 20
    if ([System.IO.Directory]::Exists($fa)) {
        $fbd = Resolve-ScratchPath $Root ([string](Get-Prop $A 'other_path')) -AllowRoot
        if (-not [System.IO.Directory]::Exists($fbd)) { throw 'To compare a folder, other_path must be a folder too.' }
        return (Invoke-DiffFolders $Root $fa $fbd $ctx0 ([string](Get-Prop $A 'name_filter')))
    }
    if (-not [System.IO.File]::Exists($fa)) { throw "No file '$(Get-Prop $A 'path')'." }
    $ta = Read-ScratchText $fa
    $op = [string](Get-Prop $A 'other_path'); $ot = Get-Prop $A 'other_text'
    if ($op -and $null -ne $ot) { throw 'Give other_path or other_text, not both.' }
    if ($op) {
        $fb = Resolve-ScratchPath $Root $op
        if (-not [System.IO.File]::Exists($fb)) { throw "No file '$op'." }
        $tb = Read-ScratchText $fb; $nb = Get-ScratchRel $Root $fb
    } elseif ($null -ne $ot) { $tb = ConvertTo-Lf ([string]$ot); $nb = '(text)' }
    else { throw 'Give other_path or other_text.' }
    $ctx = Get-IntArg $A 'context' 3 0 20
    $la = (Split-TextLines $ta).Lines; $lb = (Split-TextLines $tb).Lines
    $d = Get-UnifiedDiff $la $lb $ctx (Get-ScratchRel $Root $fa) $nb
    if (-not $d) {
        if ($ta -ne $tb) { return 'Same lines; the files differ only in the newline at the end.' }
        return 'The files are identical.'
    }
    return $d
}

# ---------------------------------------------------------------------------
# copy_path
# ---------------------------------------------------------------------------
function Invoke-CopyPath($S, [string]$Root, $A) {
    $src = Resolve-ScratchPath $Root ([string](Get-Prop $A 'from'))
    $dst = Resolve-ScratchPath $Root ([string](Get-Prop $A 'to'))
    $over = Get-Flag $A 'overwrite'
    if ([System.IO.File]::Exists($src)) {
        if ([System.IO.Directory]::Exists($dst)) { $dst = [System.IO.Path]::Combine($dst, [System.IO.Path]::GetFileName($src)); $dst = Resolve-ScratchPath $Root (Get-ScratchRel $Root $dst) }
        if ([System.IO.File]::Exists($dst) -and -not $over) { throw "'$(Get-ScratchRel $Root $dst)' already exists; set overwrite to replace it." }
        Assert-ScratchQuota $S $Root (New-Object System.IO.FileInfo $src).Length
        $pd = [System.IO.Path]::GetDirectoryName($dst); if (-not [System.IO.Directory]::Exists($pd)) { [void][System.IO.Directory]::CreateDirectory($pd) }
        [System.IO.File]::Copy($src, $dst, $over)
        return "Copied $(Get-ScratchRel $Root $src) to $(Get-ScratchRel $Root $dst)."
    }
    if ([System.IO.Directory]::Exists($src)) {
        if ([System.IO.File]::Exists($dst) -or [System.IO.Directory]::Exists($dst)) { throw "'$(Get-Prop $A 'to')' already exists." }
        $sep = [System.IO.Path]::DirectorySeparatorChar
        if ($dst.StartsWith($src + $sep)) { throw 'A folder cannot be copied into itself.' }
        Assert-ScratchQuota $S $Root (Get-ScratchUsage $src)
        $count = 0
        foreach ($d in [System.IO.Directory]::GetDirectories($src, '*', [System.IO.SearchOption]::AllDirectories)) { [void][System.IO.Directory]::CreateDirectory($dst + $d.Substring($src.Length)) }
        [void][System.IO.Directory]::CreateDirectory($dst)
        foreach ($f in [System.IO.Directory]::GetFiles($src, '*', [System.IO.SearchOption]::AllDirectories)) { [System.IO.File]::Copy($f, $dst + $f.Substring($src.Length)); $count++ }
        return "Copied folder $(Get-ScratchRel $Root $src) to $(Get-ScratchRel $Root $dst) ($count files)."
    }
    throw "No file or folder '$(Get-Prop $A 'from')'."
}

# ---------------------------------------------------------------------------
# json_query / json_edit
# ---------------------------------------------------------------------------
function ConvertTo-JsonPath([string]$Query) {
    $q = ([string]$Query).Trim()
    if ($q.StartsWith('$')) { $q = $q.Substring(1) }
    $segs = New-Object System.Collections.Generic.List[object]
    $i = 0
    while ($i -lt $q.Length) {
        $c = $q[$i]
        if ($c -eq '.') { $i++; continue }
        if ($c -eq '[') {
            $close = $q.IndexOf(']', $i)
            if ($close -lt 0) { throw "query '$Query': missing ]" }
            $inner = $q.Substring($i + 1, $close - $i - 1).Trim()
            if ($inner -match '^-?\d+$') { $segs.Add([int]$inner) }
            elseif ($inner -match '^"(.*)"$' -or $inner -match "^'(.*)'$") {
                # A quoted key may contain ], so look for the closing quote and bracket together.
                $quote = $inner[0]; $endq = $q.IndexOf("$quote]", $i + 2)
                $segs.Add($q.Substring($i + 2, $endq - $i - 2)); $close = $endq + 1
            }
            else { throw "query '$Query': use [number] or [""key""]" }
            $i = $close + 1; continue
        }
        $j = $i
        while ($j -lt $q.Length -and $q[$j] -ne '.' -and $q[$j] -ne '[') { $j++ }
        $segs.Add($q.Substring($i, $j - $i)); $i = $j
    }
    return , $segs
}

function Read-JsonDoc([string]$Text) {
    if (-not $Text.Trim()) { return $null }
    $cmd = Get-Command ConvertFrom-Json
    try {
        if ($cmd.Parameters.ContainsKey('DateKind')) { return , (ConvertFrom-Json -InputObject $Text -DateKind String) }
        return , (ConvertFrom-Json -InputObject $Text)
    } catch { throw "The file is not valid JSON: $($_.Exception.Message)" }
}

function Get-JsonProp($Obj, [string]$Key) {
    foreach ($p in $Obj.PSObject.Properties) { if ($p.Name -ceq $Key) { return $p } }
    return $null
}

function Format-JsonSeg($Seg) { if ($Seg -is [int]) { return "[$Seg]" }; return ".$Seg" }

function Get-JsonValue($Doc, $Segs) {
    $cur = $Doc; $where = '$'
    foreach ($s in $Segs) {
        if ($s -is [int]) {
            if (-not ($cur -is [System.Array])) { throw "$where is not an array." }
            $ix = $s; if ($ix -lt 0) { $ix = $cur.Length + $ix }
            if ($ix -lt 0 -or $ix -ge $cur.Length) { throw "$where has $($cur.Length) items; index $s is out of range." }
            $cur = $cur[$ix]
        } else {
            if ($null -eq $cur -or $cur -is [System.Array] -or $cur -is [string] -or $cur -is [ValueType]) { throw "$where is not an object." }
            $p = Get-JsonProp $cur $s
            if (-not $p) { throw "$where has no key '$s'." }
            $cur = $p.Value
        }
        $where += (Format-JsonSeg $s)
    }
    return , $cur
}

# Returns the node with the change applied (arrays are rebuilt, so the caller stores the result).
function Set-JsonValue($Node, $Segs, [int]$At, $Value, [bool]$Delete, [string]$Where) {
    $s = $Segs[$At]; $lastSeg = ($At -eq $Segs.Count - 1)
    if ($s -is [int]) {
        if ($null -eq $Node) { $Node = @() }
        if (-not ($Node -is [System.Array])) { throw "$Where is not an array." }
        $list = New-Object System.Collections.Generic.List[object]; foreach ($e in $Node) { $list.Add($e) }
        $ix = $s; if ($ix -lt 0) { $ix = $list.Count + $ix }
        if ($ix -lt 0 -or $ix -gt $list.Count -or ($Delete -and $ix -eq $list.Count)) { throw "$Where has $($list.Count) items; index $s is out of range." }
        if ($lastSeg) {
            if ($Delete) { $list.RemoveAt($ix) } elseif ($ix -eq $list.Count) { $list.Add($Value) } else { $list[$ix] = $Value }
        } else {
            $child = $null; if ($ix -lt $list.Count) { $child = $list[$ix] }
            $newChild = Set-JsonValue $child $Segs ($At + 1) $Value $Delete ($Where + (Format-JsonSeg $s))
            if ($ix -eq $list.Count) { $list.Add($newChild) } else { $list[$ix] = $newChild }
        }
        return , ([object[]]$list.ToArray())
    }
    if ($null -eq $Node) { $Node = New-Object psobject }
    if ($Node -is [System.Array] -or $Node -is [string] -or $Node -is [ValueType]) { throw "$Where is not an object." }
    $p = Get-JsonProp $Node $s
    if ($lastSeg) {
        if ($Delete) { if (-not $p) { throw "$Where has no key '$s'." }; $Node.PSObject.Properties.Remove($p.Name) }
        elseif ($p) { $p.Value = $Value }
        else { $Node | Add-Member -NotePropertyName $s -NotePropertyValue $Value }
    } else {
        $child = $null; if ($p) { $child = $p.Value } elseif ($Delete) { throw "$Where has no key '$s'." }
        $newChild = Set-JsonValue $child $Segs ($At + 1) $Value $Delete ($Where + (Format-JsonSeg $s))
        if ($p) { $p.Value = $newChild } else { $Node | Add-Member -NotePropertyName $s -NotePropertyValue $newChild }
    }
    return , $Node
}

function ConvertTo-PrettyJson($Value) {
    if ($null -eq $Value) { return 'null' }
    return (ConvertTo-Json -InputObject $Value -Depth 100)
}

function Invoke-JsonQuery([string]$Root, $A) {
    $files = Get-ScopeFiles $Root $A
    $segs = ConvertTo-JsonPath ([string](Get-Prop $A 'query'))
    if ($files.Count -eq 1) { return (Get-JsonQueryText (Read-JsonDoc (Read-ScratchText $files[0])) $segs (Get-Flag $A 'keys') 100000) }
    if ($files.Count -gt 500) { throw "$($files.Count) files are in scope; narrow it to 500 or fewer." }
    $out = New-Object System.Collections.Generic.List[string]
    foreach ($f in $files) {
        $rel = Get-ScratchRel $Root $f
        try { $v = Get-JsonQueryText (Read-JsonDoc (Read-ScratchText $f)) $segs (Get-Flag $A 'keys') 2000; $out.Add("${rel}: $v") }
        catch { $out.Add("${rel}: ($($_.Exception.Message))") }
    }
    return (Limit-Text ($out -join "`n") 100000)
}

function Get-JsonQueryText($Doc, $Segs, [bool]$Keys, [int]$Max) {
    $v = Get-JsonValue $Doc $Segs
    if ($Keys) {
        if ($v -is [System.Array]) { return "An array of $($v.Length) items." }
        if ($null -eq $v -or $v -is [string] -or $v -is [ValueType]) { return 'Not an object or array.' }
        $names = @($v.PSObject.Properties | ForEach-Object { $_.Name })
        if (-not $names.Count) { return '(no keys)' }
        if ($Max -lt 100000) { return ($names -join ', ') }
        return ($names -join "`n")
    }
    if ($Max -lt 100000) { return (Limit-Text (ConvertTo-Json -InputObject $v -Depth 100 -Compress) $Max) }
    return (Limit-Text (ConvertTo-PrettyJson $v) $Max)
}

function Edit-OneJson($S, [string]$Root, [string]$Full, $Segs, $Value, [bool]$Delete) {
    $doc = $null
    if ([System.IO.File]::Exists($Full)) { $doc = Read-JsonDoc (Read-ScratchText $Full) }
    elseif ($Delete) { throw "No file '$(Get-ScratchRel $Root $Full)'." }
    $doc = Set-JsonValue $doc $Segs 0 $Value $Delete '$'
    $text = (ConvertTo-PrettyJson $doc) + "`n"
    if ($text.Length -gt $script:ScratchMaxFileChars) { throw 'The file would grow past the size limit.' }
    $old = 0; if ([System.IO.File]::Exists($Full)) { $old = (New-Object System.IO.FileInfo $Full).Length }
    if ($text.Length -gt $old) { Assert-ScratchQuota $S $Root ($text.Length - $old) }
    Write-TextFile $Full $text
}

function Invoke-JsonEdit($S, [string]$Root, $A) {
    $delete = Get-Flag $A 'delete'
    $segs = ConvertTo-JsonPath ([string](Get-Prop $A 'query'))
    if (-not $segs.Count) { throw 'query is empty: name the value to change (use write_file to replace the whole document).' }
    $value = $null
    if (-not $delete) {
        $raw = Get-Prop $A 'value'
        if ($null -eq $raw) { throw 'value is missing (or set delete to true).' }
        try { $value = Read-JsonDoc ([string]$raw); if (-not ([string]$raw).Trim()) { $value = '' } } catch { $value = [string]$raw }
    }
    $p = [string](Get-Prop $A 'path')
    if ($p -and -not (Test-HasWildcard $p)) {
        $one = Resolve-ScratchPath $Root $p
        if (-not [System.IO.Directory]::Exists($one)) { $files = @($one) } else { $files = Get-ScopeFiles $Root $A }
    } else { $files = Get-ScopeFiles $Root $A }
    if ($files.Count -gt 500) { throw "$($files.Count) files are in scope; narrow it to 500 or fewer." }
    $q = [string](Get-Prop $A 'query')
    $what = "to $(Limit-Text (ConvertTo-Json -InputObject $value -Depth 5 -Compress) 300)"; if ($delete) { $what = '' }
    $verb = 'Set'; if ($delete) { $verb = 'Deleted' }
    if ($files.Count -eq 1) {
        Edit-OneJson $S $Root $files[0] $segs $value $delete
        return "$verb $q in $(Get-ScratchRel $Root $files[0]) $what".TrimEnd() + '.'
    }
    $out = New-Object System.Collections.Generic.List[string]; $ok = 0
    foreach ($f in $files) {
        try { Edit-OneJson $S $Root $f $segs $value $delete; $ok++; $out.Add("$(Get-ScratchRel $Root $f): done") }
        catch { $out.Add("$(Get-ScratchRel $Root $f): skipped ($($_.Exception.Message))") }
    }
    return "$verb $q $what in $ok of $($files.Count) files.".Replace('  ', ' ') + "`n" + ($out -join "`n")
}

# ---------------------------------------------------------------------------
# Dispatch: $null when the name isn't a text tool.
# ---------------------------------------------------------------------------
function Invoke-TextTool($S, [string]$Root, [string]$Name, $A) {
    switch ($Name) {
        'search_files'     { return (Invoke-SearchFiles $Root $A) }
        'replace_in_files' { return (Invoke-ReplaceInFiles $S $Root $A) }
        'edit_lines'       { return (Invoke-EditLines $S $Root $A) }
        'transform_text'   { return (Invoke-TransformText $S $Root $A) }
        'file_stats'       { return (Invoke-FileStats $Root $A) }
        'diff_files'       { return (Invoke-DiffFiles $Root $A) }
        'copy_path'        { return (Invoke-CopyPath $S $Root $A) }
        'json_query'       { return (Invoke-JsonQuery $Root $A) }
        'json_edit'        { return (Invoke-JsonEdit $S $Root $A) }
    }
    return $null
}
