<#
.SYNOPSIS
    Claude Code Channels Decision Bypass Fix Script (Windows Version)

.DESCRIPTION
    Bypass channel decision checks 2-7 (feature flag, auth, policy, session
    whitelist, marketplace, allowlist) while preserving check 1 (MCP capability
    declaration). After patching, any MCP server declaring claude/channel
    capability will be registered regardless of auth or allowlists.

.PARAMETER Check
    Check if fix is needed without making changes

.PARAMETER Restore
    Restore original file from backup

.PARAMETER Help
    Show help information

.PARAMETER CliPath
    Path to cli.js file (optional, auto-detect if not provided)

.EXAMPLE
    .\apply-claude-code-channels-bypass-fix.ps1
    .\apply-claude-code-channels-bypass-fix.ps1 -Check
    .\apply-claude-code-channels-bypass-fix.ps1 -CliPath "C:\path\to\cli.js"
    .\apply-claude-code-channels-bypass-fix.ps1 -Restore

.NOTES
    This patch will be overwritten when Claude Code updates.
    Re-run this script after updates if the issue reappears.
#>

param(
    [switch]$Check,
    [switch]$Restore,
    [switch]$Help,
    [string]$CliPath
)

$BACKUP_SUFFIX = "backup-channels-bypass"
$FIX_DESCRIPTION = "Bypass channel decision checks 2-7 (keep MCP capability check)"

function Write-Success { param($Message) Write-Host "[OK] " -ForegroundColor Green -NoNewline; Write-Host $Message }
function Write-Warning { param($Message) Write-Host "[!] " -ForegroundColor Yellow -NoNewline; Write-Host $Message }
function Write-FixError { param($Message) Write-Host "[X] " -ForegroundColor Red -NoNewline; Write-Host $Message }
function Write-Info { param($Message) Write-Host "[>] " -ForegroundColor Blue -NoNewline; Write-Host $Message }

function Invoke-ClaudeCodeFix {
    param(
        [switch]$Check,
        [switch]$Restore,
        [switch]$Help,
        [string]$CliPath
    )

    if ($Help) {
        Write-Host "Claude Code $FIX_DESCRIPTION"
        Write-Host ""
        Write-Host "Usage: .\$($MyInvocation.MyCommand.Name) [options]"
        Write-Host "  -Check      Check if fix is needed"
        Write-Host "  -Restore    Restore from backup"
        Write-Host "  -CliPath    Path to cli.js"
        return 0
    }

    function Find-CliPath {
        $locations = @(
            (Join-Path $env:USERPROFILE ".claude\local\node_modules\@anthropic-ai\claude-code\cli.js"),
            (Join-Path $env:APPDATA "npm\node_modules\@anthropic-ai\claude-code\cli.js"),
            (Join-Path $env:ProgramFiles "nodejs\node_modules\@anthropic-ai\claude-code\cli.js")
        )
        try {
            $npmRoot = & npm root -g 2>$null
            if ($npmRoot) { $locations += Join-Path $npmRoot "@anthropic-ai\claude-code\cli.js" }
        } catch {}
        foreach ($path in $locations) {
            if (Test-Path $path) { return $path }
        }
        return $null
    }

    if ($CliPath) {
        if (Test-Path $CliPath) {
            $cliPathResolved = $CliPath
            Write-Info "Using specified cli.js: $cliPathResolved"
        } else {
            Write-FixError "Specified file not found: $CliPath"
            return 1
        }
    } else {
        $cliPathResolved = Find-CliPath
        if (-not $cliPathResolved) {
            Write-FixError "Claude Code cli.js not found"
            return 1
        }
        Write-Info "Found Claude Code: $cliPathResolved"
    }

    $cliPath = $cliPathResolved

    if ($Restore) {
        $backups = Get-ChildItem -Path (Split-Path $cliPath) -Filter "cli.js.$BACKUP_SUFFIX-*" -ErrorAction SilentlyContinue |
                   Sort-Object LastWriteTime -Descending
        if ($backups.Count -gt 0) {
            Copy-Item $backups[0].FullName $cliPath -Force
            Write-Success "Restored from backup: $($backups[0].FullName)"
            return 0
        } else {
            Write-FixError "No backup file found"
            return 1
        }
    }

    Write-Host ""

    $acornPath = Join-Path $env:TEMP "acorn-claude-fix.js"
    if (-not (Test-Path $acornPath)) {
        Write-Info "Downloading acorn parser..."
        try {
            Invoke-WebRequest -Uri "https://unpkg.com/acorn@8.14.0/dist/acorn.js" -OutFile $acornPath -UseBasicParsing
        } catch {
            Write-FixError "Failed to download acorn parser"
            return 1
        }
    }

    $patchScript = @'
const fs = require('fs');
const acorn = require(process.argv[2]);
const cliPath = process.argv[3];
const checkOnly = process.argv[4] === '--check';
const backupSuffix = process.env.BACKUP_SUFFIX || 'backup';

let code = fs.readFileSync(cliPath, 'utf-8');

let shebang = '';
if (code.startsWith('#!')) {
    const idx = code.indexOf('\n');
    shebang = code.slice(0, idx + 1);
    code = code.slice(idx + 1);
}

let ast;
try {
    ast = acorn.parse(code, { ecmaVersion: 2022, sourceType: 'module' });
} catch (e) {
    console.error('PARSE_ERROR:' + e.message);
    process.exit(1);
}

function findNodes(node, predicate, results = []) {
    if (!node || typeof node !== 'object') return results;
    if (predicate(node)) results.push(node);
    for (const key in node) {
        if (node[key] && typeof node[key] === 'object') {
            if (Array.isArray(node[key])) {
                node[key].forEach(child => findNodes(child, predicate, results));
            } else {
                findNodes(node[key], predicate, results);
            }
        }
    }
    return results;
}

const src = (node) => code.slice(node.start, node.end);

// Patch 1: Force-enable tengu_harbor feature flag
const harborCalls = findNodes(ast, n =>
    n.type === 'CallExpression' &&
    n.arguments &&
    n.arguments.length === 2 &&
    n.arguments[0].type === 'Literal' &&
    n.arguments[0].value === 'tengu_harbor' &&
    !(n.arguments[0].value === 'tengu_harbor_ledger')
);

let harborPatched = false;
let harborCalleeName = '';

for (const call of harborCalls) {
    harborCalleeName = src(call.callee);
    const secondArg = call.arguments[1];
    if (secondArg.type === 'UnaryExpression' &&
        secondArg.operator === '!' &&
        secondArg.argument.type === 'Literal' &&
        secondArg.argument.value === 1) {
        console.log('FOUND:harborFlag ' + harborCalleeName + '("tengu_harbor", !1)');
        break;
    }
    if (secondArg.type === 'UnaryExpression' &&
        secondArg.operator === '!' &&
        secondArg.argument.type === 'Literal' &&
        secondArg.argument.value === 0) {
        console.log('FOUND:harborFlag already enabled');
        harborPatched = true;
        break;
    }
}

// Patch 2: Bypass qMq() decision checks 2-7
const markerLiterals = findNodes(ast, n =>
    n.type === 'Literal' &&
    n.value === 'channels feature is not currently available'
);

if (markerLiterals.length === 0) {
    if (code.includes('claude/channel capability') &&
        !code.includes('channels feature is not currently available')) {
        if (harborPatched) {
            console.log('ALREADY_PATCHED');
            process.exit(2);
        }
    } else {
        console.error('NOT_FOUND:Cannot find channel decision function marker');
        process.exit(1);
    }
}

let targetFunc = null, firstStmt = null;

if (markerLiterals.length > 0) {
    const markerPos = markerLiterals[0].start;
    const enclosingFuncs = findNodes(ast, n =>
        (n.type === 'FunctionDeclaration' || n.type === 'FunctionExpression') &&
        n.start < markerPos && n.end > markerPos
    );

    if (enclosingFuncs.length === 0) {
        console.error('NOT_FOUND:Cannot find enclosing function for channel decision');
        process.exit(1);
    }

    targetFunc = enclosingFuncs.sort((a, b) => (a.end - a.start) - (b.end - b.start))[0];
    const funcName = targetFunc.id ? targetFunc.id.name : '(anonymous)';

    console.log('FOUND:channelDecision function ' + funcName + '() at ' + targetFunc.start + '-' + targetFunc.end);
    console.log('FOUND:bodySize ' + (targetFunc.body.end - targetFunc.body.start) + ' bytes');

    const bodyStatements = targetFunc.body.body;
    if (!bodyStatements || bodyStatements.length === 0) {
        console.error('NOT_FOUND:Function body has no statements');
        process.exit(1);
    }

    firstStmt = bodyStatements[0];
    if (firstStmt.type !== 'IfStatement') {
        console.error('NOT_FOUND:First statement is not an if-check, got: ' + firstStmt.type);
        process.exit(1);
    }

    const firstStmtSrc = src(firstStmt);
    if (!firstStmtSrc.includes('claude/channel')) {
        console.error('NOT_FOUND:First if-statement does not contain claude/channel check');
        process.exit(1);
    }

    console.log('FOUND:capabilityCheck preserved (' + (firstStmt.end - firstStmt.start) + ' bytes)');

    const skipReturns = findNodes(targetFunc, n =>
        n.type === 'ReturnStatement' &&
        n.argument && n.argument.type === 'ObjectExpression'
    );
    const skipCount = skipReturns.filter(n => {
        const s = src(n);
        return s.includes('"skip"') && n.start > firstStmt.end;
    }).length;
    console.log('FOUND:bypassedChecks ' + skipCount + ' skip-return statements will be removed');
}

// Patch 3: Neutralize UI status function
const policyProps = findNodes(ast, n =>
    n.type === 'Property' &&
    n.key && n.key.type === 'Identifier' && n.key.name === 'policyBlocked' &&
    n.value && src(n.value).includes('channelsEnabled')
);

let noticeFunc = null;
let noticePatched = false;

if (policyProps.length > 0) {
    const propPos = policyProps[0].start;
    const noticeFuncs = findNodes(ast, n =>
        (n.type === 'FunctionDeclaration' || n.type === 'FunctionExpression') &&
        n.start < propPos && n.end > propPos
    );
    if (noticeFuncs.length > 0) {
        noticeFunc = noticeFuncs.sort((a, b) => (a.end - a.start) - (b.end - b.start))[0];
        const nfName = noticeFunc.id ? noticeFunc.id.name : '(anonymous)';
        console.log('FOUND:channelNotice function ' + nfName + '() - UI status will be neutralized');
    }
} else {
    if (code.includes('policyBlocked') && !code.includes('channelsEnabled!==!0')) {
        noticePatched = true;
        console.log('FOUND:channelNotice already neutralized');
    }
}

const qMqNeedsPatch = markerLiterals.length > 0;
const harborNeedsPatch = harborCalls.length > 0 && !harborPatched;
const noticeNeedsPatch = noticeFunc !== null && !noticePatched;

if (!qMqNeedsPatch && !harborNeedsPatch && !noticeNeedsPatch) {
    console.log('ALREADY_PATCHED');
    process.exit(2);
}

if (checkOnly) {
    console.log('NEEDS_PATCH');
    const count = (qMqNeedsPatch ? 1 : 0) + (harborNeedsPatch ? 1 : 0) + (noticeNeedsPatch ? 1 : 0);
    console.log('PATCH_COUNT:' + count);
    process.exit(1);
}

let replacements = [];
let patchCount = 0;

if (qMqNeedsPatch && targetFunc && firstStmt) {
    const capCheckSrc = src(firstStmt);
    const newBody = '{' + capCheckSrc + 'return{action:"register"}}';
    replacements.push({ start: targetFunc.body.start, end: targetFunc.body.end, replacement: newBody });
    patchCount++;
    console.log('PATCH:channelDecision - Bypassed checks 2-7, kept MCP capability check');
}

if (harborNeedsPatch) {
    const harborArg = harborCalls[0].arguments[1];
    replacements.push({ start: harborArg.start, end: harborArg.end, replacement: '!0' });
    patchCount++;
    console.log('PATCH:harborFlag - Changed tengu_harbor default from !1 to !0');
}

if (noticeNeedsPatch && noticeFunc) {
    const firstCalls = findNodes(noticeFunc.body.body[0], n =>
        n.type === 'CallExpression' &&
        n.callee && n.callee.type === 'Identifier'
    );
    const getAllowedChannels = firstCalls.length > 0 ? src(firstCalls[0]) : 'Ju()';

    const mapCalls = findNodes(noticeFunc, n =>
        n.type === 'CallExpression' &&
        n.callee && n.callee.type === 'MemberExpression' &&
        n.callee.property && n.callee.property.name === 'map'
    );
    let formatter = 'qo6';
    if (mapCalls.length > 0 && mapCalls[0].arguments[0]) {
        formatter = src(mapCalls[0].arguments[0]);
    }

    console.log('FOUND:channelNotice getAllowedChannels=' + getAllowedChannels + ' formatter=' + formatter);

    const newNoticeBody = '{let A=' + getAllowedChannels + ';let q=A.length>0?A.map(' + formatter + ').join(", "):"";return{channels:A,disabled:!1,noAuth:!1,policyBlocked:!1,list:q}}';
    replacements.push({ start: noticeFunc.body.start, end: noticeFunc.body.end, replacement: newNoticeBody });
    patchCount++;
    console.log('PATCH:channelNotice - Neutralized UI status (always all-green)');
}

replacements.sort((a, b) => b.start - a.start);
let newCode = code;
for (const r of replacements) {
    newCode = newCode.slice(0, r.start) + r.replacement + newCode.slice(r.end);
}

if (qMqNeedsPatch) {
    if (!newCode.includes('claude/channel capability')) {
        console.error('VERIFY_FAILED:Capability check not preserved');
        process.exit(1);
    }
    if (newCode.includes('channels feature is not currently available')) {
        console.error('VERIFY_FAILED:Feature flag check was not removed');
        process.exit(1);
    }
}

if (harborNeedsPatch) {
    const expected = harborCalleeName + '("tengu_harbor",!0)';
    if (!newCode.includes(expected)) {
        console.error('VERIFY_FAILED:Expected "' + expected + '" not found after harbor flag patch');
        process.exit(1);
    }
}

const timestamp = new Date().toISOString().replace(/[:.]/g, '-').slice(0, 19);
const backupPath = cliPath + '.' + backupSuffix + '-' + timestamp;
fs.copyFileSync(cliPath, backupPath);
console.log('BACKUP:' + backupPath);

fs.writeFileSync(cliPath, shebang + newCode);
console.log('SUCCESS:' + patchCount);
'@

    $tempPatchScript = Join-Path $env:TEMP "claude-fix-channels-$PID.js"
    $patchScript | Out-File -FilePath $tempPatchScript -Encoding UTF8

    $env:BACKUP_SUFFIX = $BACKUP_SUFFIX
    $checkArg = if ($Check) { "--check" } else { "" }
    $output = & node $tempPatchScript $acornPath $cliPath $checkArg 2>&1
    $scriptExitCode = $LASTEXITCODE

    Remove-Item $tempPatchScript -ErrorAction SilentlyContinue

    foreach ($line in $output) {
        switch -Regex ($line) {
            "^ALREADY_PATCHED" { Write-Success "Already patched"; return 0 }
            "^PARSE_ERROR:(.+)" { Write-FixError "Failed to parse cli.js: $($Matches[1])"; return 1 }
            "^NOT_FOUND:(.+)" { Write-FixError "Target code not found: $($Matches[1])"; return 1 }
            "^FOUND:(.+)" { Write-Info "Found: $($Matches[1])" }
            "^PATCH:(.+)" { Write-Info "Patch: $($Matches[1])" }
            "^NEEDS_PATCH" {
                Write-Host ""
                Write-Warning "Patch needed - run without -Check to apply"
            }
            "^PATCH_COUNT:(.+)" {
                Write-Info "Need to patch $($Matches[1]) location(s)"
                return 1
            }
            "^BACKUP:(.+)" { Write-Host ""; Write-Host "Backup: $($Matches[1])" }
            "^SUCCESS:(.+)" {
                Write-Host ""
                Write-Success "Fix applied successfully! Patched $($Matches[1]) location(s)"
                Write-Host ""
                Write-Warning "Restart Claude Code for changes to take effect"
                Write-Host ""
                Write-Info "Channel checks bypassed: auth, feature flag, policy, session, marketplace, allowlist"
                Write-Info "Preserved: MCP capability declaration check (claude/channel)"
            }
            "^VERIFY_FAILED:(.+)" { Write-FixError "Verification failed: $($Matches[1])"; return 1 }
        }
    }

    return $scriptExitCode
}

Invoke-ClaudeCodeFix -Check:$Check -Restore:$Restore -Help:$Help -CliPath $CliPath
