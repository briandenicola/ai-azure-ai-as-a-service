$path = 'c:\gitrepos\ai-azure-ai-as-a-service\observability\workbooks\e2e-trace.workbook.json'
$c = [System.IO.File]::ReadAllText($path, [System.Text.Encoding]::UTF8)
$orig = $c.Length

# IMPORTANT: The query strings in JSON use LITERAL escape sequences (\n, \")
# so replacements must use PS single-quoted strings to match them verbatim.

# Fix 1: Tiles union type mismatch — count() returns long, round(avg()) returns real → cast to toreal()
$c = $c.Replace('Value = count(),\n       Sub   = strcat(\"avg \"', 'Value = toreal(count()),\n       Sub   = strcat(\"avg \"')
$c = $c.Replace('Value = count(),\n       Sub   = \"errors\"',       'Value = toreal(count()),\n       Sub   = \"errors\"')

# Fix 2: Waterfall — AGWAccessLogs PascalCase (case-sensitive in this workspace)
$c = $c.Replace('tostring(requestUri)   // transactionId', 'tostring(RequestUri)   // transactionId')

# Fix 3: timeTaken appears in BOTH waterfall appgwLogs AND trace table agwRows
$c = $c.Replace('toreal(timeTaken) * 1000', 'toreal(TimeTaken) * 1000')

# Fix 4: Trace table agwRows — remaining case-sensitive AGWAccessLogs columns
$c = $c.Replace('agwClientIp      = tostring(clientIp)', 'agwClientIp      = ClientIp')
$c = $c.Replace('agwKey           = strcat(tostring(clientIp)', 'agwKey           = strcat(ClientIp')
$c = $c.Replace('agwHttpStatus    = toint(httpStatus)', 'agwHttpStatus    = HttpStatus')
$c = $c.Replace('agwSentBytes     = toreal(sentBytes)', 'agwSentBytes     = SentBytes')
$c = $c.Replace('agwReceivedBytes = toreal(receivedBytes)', 'agwReceivedBytes = ReceivedBytes')

# Fix 5: WAF table — AGWFirewallLogs PascalCase, ruleGroup doesn't exist in schema
$c = $c.Replace('countif(action == \"Blocked\")', 'countif(Action == \"Blocked\")')
$c = $c.Replace('countif(action == \"Matched\")', 'countif(Action == \"Matched\")')
$c = $c.Replace('by ruleSetType, ruleId, ruleGroup, message', 'by RuleSetType, RuleId, Message')
$c = $c.Replace(
    "    ['Rule Set']  = ruleSetType,\n    ['Rule ID']   = ruleId,\n    ['Rule Group']= ruleGroup,\n    Message       = message,",
    "    ['Rule Set']  = RuleSetType,\n    ['Rule ID']   = RuleId,\n    Message,"
)

[System.IO.File]::WriteAllText($path, $c, [System.Text.Encoding]::UTF8)
Write-Host "Written: $orig -> $($c.Length) bytes"

# Verify
$checks = @(
    @{ pat = 'Value = count(),'; label = "tiles count() not cast" }
    @{ pat = 'tostring(requestUri)'; label = "lowercase requestUri" }
    @{ pat = 'toreal(timeTaken)';    label = "lowercase timeTaken" }
    @{ pat = 'tostring(clientIp)';   label = "lowercase clientIp" }
    @{ pat = 'toint(httpStatus)';    label = "lowercase httpStatus" }
    @{ pat = 'toreal(sentBytes)';    label = "lowercase sentBytes" }
    @{ pat = 'toreal(receivedBytes)';label = "lowercase receivedBytes" }
    @{ pat = 'countif(action';       label = "lowercase action" }
    @{ pat = 'ruleGroup';            label = "ruleGroup still present" }
    @{ pat = '= ruleSetType';        label = "lowercase ruleSetType" }
    @{ pat = '= ruleId';             label = "lowercase ruleId" }
    @{ pat = 'message,';             label = "lowercase message in project" }
)
$fail = 0
foreach ($ck in $checks) {
    $n = ([regex]::Matches($c, [regex]::Escape($ck.pat))).Count
    if ($n -gt 0) { Write-Host "STILL PRESENT ($n): $($ck.label) [$($ck.pat)]"; $fail++ }
}
if ($fail -eq 0) { Write-Host "All checks passed" } else { Write-Host "$fail check(s) failed" }
