# Fix: remove the duplicate AGW block that was injected inside the trace-table object
# (caused by the earlier script replacing "name": "trace-table" without including its closing brace)

$file = "$PSScriptRoot\..\observability\workbooks\e2e-trace.workbook.json"
$content = [System.IO.File]::ReadAllText($file)

# The broken pattern: "name": "trace-table",  { ...duplicate agw... }  }
# Replace with just the correct closing of trace-table: "name": "trace-table"  }
$opts = [System.Text.RegularExpressions.RegexOptions]::Singleline
$content = [regex]::Replace(
    $content,
    '"name": "trace-table",\s*\{.*?"name": "agw-table"\s*\}\s*\}',
    '"name": "trace-table"' + "`n    }",
    $opts
)

$agwCount = [regex]::Matches($content, '"name": "agw-table"').Count
$traceClose = $content.Contains('"name": "trace-table"' + "`n    }")
Write-Host "AGW table occurrences after fix: $agwCount (expected 1)"
Write-Host "trace-table properly closed: $traceClose"

[System.IO.File]::WriteAllText($file, $content, [System.Text.Encoding]::UTF8)
Write-Host "Saved." -ForegroundColor Cyan

