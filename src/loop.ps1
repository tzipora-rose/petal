# petal's loop for PowerShell 7 and Windows PowerShell 5.1.
# petal starts the shell with -EncodedCommand ". ([ScriptBlock]::Create($env:PETAL_LOOP))", so this
# text runs in the global scope, and so does every command it is given. Requests arrive on the pipe
# whose handle number is in PETAL_IN and answers go out on the one in PETAL_OUT; the shell's own
# standard input is NUL, so nothing a command starts can read petal's requests. Each message is a
# header line "<op> <id> <length>" followed by <length> bytes of UTF-8 JSON. After each command,
# "\0petal-stray <id>" goes to the shell's own standard output before the answer: what a program
# wrote there before it was written during or before that command.
$ProgressPreference = 'SilentlyContinue'
$OutputEncoding = [System.Text.UTF8Encoding]::new($false)
$__petal = New-Module -Name petal -ScriptBlock {
    $script:In = [System.IO.FileStream]::new([Microsoft.Win32.SafeHandles.SafeFileHandle]::new([IntPtr][long]$env:PETAL_IN, $true), [System.IO.FileAccess]::Read, 1)
    $script:Out = [System.IO.FileStream]::new([Microsoft.Win32.SafeHandles.SafeFileHandle]::new([IntPtr][long]$env:PETAL_OUT, $true), [System.IO.FileAccess]::Write, 1)
    $script:Utf8 = [System.Text.UTF8Encoding]::new($false)
    $script:StdOut = [Console]::OpenStandardOutput()
    $script:IsWindowsPowerShell = $PSVersionTable.PSEdition -ne 'Core'
    $script:Id = '0'
    $script:Writer = $null
    $script:Ok = $true
    $script:SavedExitCode = $null
    $script:LastEnvironment = ''

    function ReadHeader {
        $bytes = [System.Collections.Generic.List[byte]]::new()
        while ($true) {
            $b = $script:In.ReadByte()
            if ($b -lt 0) { return $null }
            if ($b -eq 10) { break }
            $bytes.Add([byte]$b)
        }
        return [System.Text.Encoding]::ASCII.GetString($bytes.ToArray())
    }

    function ReadPayload([int]$length) {
        $buffer = [byte[]]::new($length)
        $at = 0
        while ($at -lt $length) {
            $count = $script:In.Read($buffer, $at, $length - $at)
            if ($count -le 0) { return $null }
            $at += $count
        }
        return $script:Utf8.GetString($buffer)
    }

    function Send([string]$op, $value) {
        $json = Microsoft.PowerShell.Utility\ConvertTo-Json -InputObject $value -Compress -Depth 6
        $payload = $script:Utf8.GetBytes($json)
        $header = [System.Text.Encoding]::ASCII.GetBytes("$op $($script:Id) $($payload.Length)`n")
        $script:Out.Write($header, 0, $header.Length)
        $script:Out.Write($payload, 0, $payload.Length)
        $script:Out.Flush()
    }

    # The next command to run, as a script block whose last line records whether the command's
    # last statement succeeded ($?). Requests that need no command are answered here.
    function __petal_next {
        $ErrorActionPreference = 'Continue'
        Microsoft.PowerShell.Core\Set-StrictMode -Off
        while ($true) {
            $header = ReadHeader
            if ($null -eq $header) { [System.Environment]::Exit(0) }
            $parts = $header.Split(' ')
            $script:Id = $parts[1]
            $text = ReadPayload ([int]$parts[2])
            if ($null -eq $text) { [System.Environment]::Exit(0) }
            try {
                $request = Microsoft.PowerShell.Utility\ConvertFrom-Json -InputObject $text
                if ($parts[0] -ne 'run') {
                    Send 'unknown' @{ op = $parts[0] }
                    continue
                }
                if ($request.check) {
                    $found = Check $request.command
                    if ($found.errors.Count -gt 0 -or $found.findings.Count -gt 0) {
                        Send 'checked' $found
                        continue
                    }
                }
                $block = [ScriptBlock]::Create($request.command + "`n`n__petal_status `$?")
                $script:Writer = [System.IO.StreamWriter]::new($request.out, $false, $script:Utf8)
                $script:SavedExitCode = $global:LASTEXITCODE
                $global:LASTEXITCODE = $null
                $script:Ok = $true
                try { [Console]::OutputEncoding = $script:Utf8 } catch {}
                return $block
            } catch {
                if ($null -ne $script:Writer) { $script:Writer.Dispose(); $script:Writer = $null }
                Send 'failed' @{ message = $_.Exception.Message }
            }
        }
    }

    function __petal_ready {
        Send 'ready' ([ordered]@{ version = $PSVersionTable.PSVersion.ToString(); edition = [string]$PSVersionTable.PSEdition })
    }

    function __petal_status([bool]$ok) { $script:Ok = $ok }

    function __petal_failed { $script:Ok = $false }

    # PowerShell's records reach the output the way its console shows them.
    function __petal_line {
        param([Parameter(ValueFromPipeline = $true)] $Item)
        process {
            if ($Item -is [System.Management.Automation.ErrorRecord] -and $Item.Exception -is [System.Management.Automation.RemoteException]) {
                $Item.Exception.Message
            } elseif ($Item -is [System.Management.Automation.WarningRecord]) {
                'WARNING: ' + $Item.Message
            } elseif ($Item -is [System.Management.Automation.VerboseRecord]) {
                'VERBOSE: ' + $Item.Message
            } elseif ($Item -is [System.Management.Automation.DebugRecord]) {
                'DEBUG: ' + $Item.Message
            } else {
                $Item
            }
        }
    }

    # Windows PowerShell pads table rows to the full width; the spaces at the end of a line go.
    function __petal_write {
        param([Parameter(ValueFromPipeline = $true)] [string]$Line)
        process { $script:Writer.Write($Line.TrimEnd(' ')); $script:Writer.Write("`n") }
    }

    function __petal_caught($record) {
        $script:Ok = $false
        try {
            foreach ($line in (($record | Microsoft.PowerShell.Utility\Out-String -Stream -Width 200))) { __petal_write $line }
        } catch {}
    }

    function __petal_done {
        $ErrorActionPreference = 'Continue'
        Microsoft.PowerShell.Core\Set-StrictMode -Off
        if ($null -ne $script:Writer) { $script:Writer.Dispose(); $script:Writer = $null }
        # A reader the command left open, such as a [IO.File]::ReadLines loop ended by break,
        # holds its file until a garbage collection frees it, which in a shell that lives on can
        # take an hour, and it shares the file only for reading, so no other program can write to
        # it. Claude Code writes the call's result to its transcript right after the reply, and a
        # write refused then stays out of the transcript until the session's next compaction writes
        # it again, or for good if that compaction keeps no newer message or the session ends
        # first, so the collection comes before the reply.
        [System.GC]::Collect()
        [System.GC]::WaitForPendingFinalizers()
        $code = if ($null -ne $global:LASTEXITCODE) { $global:LASTEXITCODE } elseif ($script:Ok) { 0 } else { 1 }
        if ($null -eq $global:LASTEXITCODE) { $global:LASTEXITCODE = $script:SavedExitCode }
        $location = $ExecutionContext.SessionState.Path.CurrentLocation
        $folder = if ($location.Provider.Name -eq 'FileSystem') { $location.ProviderPath } else { '' }
        $done = [ordered]@{ exit = $code; location = $location.Path; folder = $folder }
        $environment = EnvironmentText
        if ($environment -ne $script:LastEnvironment) {
            $script:LastEnvironment = $environment
            $done.environment = $environment
        }
        try {
            $marker = [System.Text.Encoding]::ASCII.GetBytes("`0petal-stray $($script:Id)`n")
            $script:StdOut.Write($marker, 0, $marker.Length)
            $script:StdOut.Flush()
        } catch {}
        Send 'done' $done
    }

    # The process's environment as NAME=VALUE entries, each ending in a NUL, sorted by name.
    function EnvironmentText {
        $variables = [System.Environment]::GetEnvironmentVariables()
        $names = [string[]]@($variables.Keys)
        [System.Array]::Sort($names, [System.StringComparer]::OrdinalIgnoreCase)
        $text = [System.Text.StringBuilder]::new()
        foreach ($name in $names) { [void]$text.Append($name).Append('=').Append($variables[$name]).Append([char]0) }
        return $text.ToString()
    }

    # ---- the check before running ---------------------------------------------------------------

    function Check([string]$command) {
        $tokens = $null
        $errors = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseInput($command, [ref]$tokens, [ref]$errors)
        $result = [ordered]@{ errors = @(); findings = @() }
        if ($errors.Count -gt 0) {
            $result.errors = @(foreach ($e in $errors) { [ordered]@{ line = $e.Extent.StartLineNumber; column = $e.Extent.StartColumnNumber; message = $e.Message } })
            return $result
        }
        $context = @{
            Findings = [System.Collections.Generic.List[object]]::new()
            Assigned = AssignedNames $ast
            ChangesFolder = $false
            Ast = $ast
            Text = $command
            Transcripts = TranscriptFolder
        }
        $commands = @($ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] }, $true))
        $resolvedCommands = @{}
        foreach ($c in $commands) {
            $name = $c.GetCommandName()
            if (-not $name) { continue }
            $resolved = ResolveCommand $name
            $resolvedCommands[$c] = $resolved
            if ($resolved.Name -in @('Set-Location', 'Push-Location', 'Pop-Location')) { $context.ChangesFolder = $true }
        }
        $writes = $false
        $plainReads = [System.Collections.Generic.List[object]]::new()
        foreach ($c in $commands) {
            if (-not $resolvedCommands.ContainsKey($c)) { continue }
            $resolved = $resolvedCommands[$c]
            switch ($resolved.Name) {
                'Remove-Item' { DeletionFindings $c @('Path', 'LiteralPath') $context }
                'Out-File' { if ($script:IsWindowsPowerShell) { $writes = $true; EncodingFinding $c 'Out-File' 'UTF-16' $context } }
                'Set-Content' { if ($script:IsWindowsPowerShell) { $writes = $true; EncodingFinding $c 'Set-Content' 'the ANSI code page' $context } }
                'Add-Content' { if ($script:IsWindowsPowerShell) { $writes = $true; EncodingFinding $c 'Add-Content' 'the ANSI code page' $context } }
                'Export-Csv' { if ($script:IsWindowsPowerShell) { $writes = $true; EncodingFinding $c 'Export-Csv' 'ASCII' $context } }
                'Tee-Object' {
                    if ($script:IsWindowsPowerShell -and (BoundAst $c 'FilePath')) {
                        $writes = $true
                        $context.Findings.Add((Finding 'encoding' $c "Windows PowerShell 5.1's Tee-Object writes its file as UTF-16 and has no -Encoding parameter. Use Out-File -Encoding utf8, or run this in PowerShell 7."))
                    }
                }
                'Get-Content' { if ($script:IsWindowsPowerShell -and -not (BoundAst $c 'Encoding')) { $plainReads.Add($c) } }
                'New-Object' { ReaderFinding $c (NewObjectReader $c) $context }
                'Copy-Item' { CmdletReaderFindings $c 'Copy-Item' $context }
                'Get-FileHash' { CmdletReaderFindings $c 'Get-FileHash' $context }
            }
            if ($resolved.Type -eq 'Application') {
                $program = [System.IO.Path]::GetFileNameWithoutExtension($resolved.Name).ToLowerInvariant()
                if ($program -eq 'cmd') { CmdDeletionFindings $c $context }
                if ($script:IsWindowsPowerShell) { QuoteFindings $c $resolved.Name $context }
            }
        }
        foreach ($r in $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FileRedirectionAst] }, $true)) {
            if (-not $script:IsWindowsPowerShell) { continue }
            if ($r.Location -is [System.Management.Automation.Language.VariableExpressionAst] -and $r.Location.VariablePath.UserPath -eq 'null') { continue }
            $writes = $true
            $context.Findings.Add((Finding 'encoding' $r "Windows PowerShell 5.1 writes a file through '$($r.Extent.Text)' as UTF-16. Pipe to Out-File -Encoding utf8 instead, or run this in PowerShell 7."))
        }
        if ($writes) {
            foreach ($read in $plainReads) {
                $context.Findings.Add((Finding 'encoding' $read "Windows PowerShell 5.1's Get-Content reads a UTF-8 file without a byte-order mark as the ANSI code page, so writing that text back corrupts every non-ASCII character. Add -Encoding UTF8 to Get-Content, or run this in PowerShell 7."))
            }
        }
        foreach ($m in $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.InvokeMemberExpressionAst] }, $true)) {
            if (-not $m.Static -or $m.Expression -isnot [System.Management.Automation.Language.TypeExpressionAst]) { continue }
            $type = $m.Expression.TypeName.GetReflectionType()
            if ($null -eq $type -or ($type -ne [System.IO.File] -and $type -ne [System.IO.Directory])) { continue }
            if ($m.Member.Extent.Text -ne 'Delete' -or $null -eq $m.Arguments -or $m.Arguments.Count -lt 1) { continue }
            TargetFindings $m $m.Arguments[0] $context
        }
        foreach ($m in $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.InvokeMemberExpressionAst] }, $true)) {
            ReaderFinding $m (StaticReader $m) $context
        }
        foreach ($s in $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.SwitchStatementAst] }, $true)) {
            if (($s.Flags -band [System.Management.Automation.Language.SwitchFlags]::File) -eq 0) { continue }
            ReaderFinding $s @{ Name = 'switch -File'; Path = (StatementExpression $s.Condition); Holds = $true; ByPowerShell = $true } $context
        }
        $result.findings = @($context.Findings)
        return $result
    }

    function Finding([string]$rule, $ast, [string]$message, [string]$target) {
        $f = [ordered]@{ rule = $rule; line = $ast.Extent.StartLineNumber; text = $ast.Extent.Text; message = $message }
        if ($target) { $f.target = $target }
        return $f
    }

    # Names this command gives values to itself (assignments, loop variables, parameters), whose
    # value before the command runs says nothing about the value it will have.
    function AssignedNames($ast) {
        $names = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
        foreach ($a in $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.AssignmentStatementAst] }, $true)) {
            foreach ($v in $a.Left.FindAll({ param($n) $n -is [System.Management.Automation.Language.VariableExpressionAst] }, $true)) { [void]$names.Add((VariableName $v)) }
        }
        foreach ($f in $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.ForEachStatementAst] }, $true)) { [void]$names.Add((VariableName $f.Variable)) }
        foreach ($p in $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.ParameterAst] }, $true)) { [void]$names.Add((VariableName $p.Name)) }
        foreach ($automatic in @('_', 'PSItem', 'input', 'args', 'this', 'Matches', 'foreach', 'switch', 'LASTEXITCODE', 'PSCmdlet', 'PSBoundParameters', 'MyInvocation', 'Error', 'sender', 'EventArgs', 'Event')) { [void]$names.Add($automatic) }
        return , $names
    }

    # VariablePath.UnqualifiedPath is not readable from script, so the name is taken from UserPath
    # with its "scope:" or "drive:" prefix removed.
    function VariableName($variableAst) {
        $name = $variableAst.VariablePath.UserPath
        $colon = $name.IndexOf(':')
        if ($colon -ge 0) { $name = $name.Substring($colon + 1) }
        return $name
    }

    function ResolveCommand([string]$name) {
        $command = Microsoft.PowerShell.Core\Get-Command -Name $name -ErrorAction Ignore | Microsoft.PowerShell.Utility\Select-Object -First 1
        for ($hops = 0; $null -ne $command -and $command.CommandType -eq 'Alias' -and $hops -lt 8; $hops++) {
            $command = $command.ResolvedCommand
        }
        if ($null -eq $command) { return @{ Name = $name; Type = 'Unknown' } }
        return @{ Name = $command.Name; Type = [string]$command.CommandType }
    }

    function BoundAst($commandAst, [string]$parameter) {
        try {
            $binding = [System.Management.Automation.Language.StaticParameterBinder]::BindCommand($commandAst, $true)
        } catch {
            return $null
        }
        if ($binding.BoundParameters.ContainsKey($parameter)) {
            $value = $binding.BoundParameters[$parameter].Value
            if ($null -eq $value) { return $binding.BoundParameters[$parameter].Parameter }
            return $value
        }
        return $null
    }

    function EncodingFinding($commandAst, [string]$cmdlet, [string]$default, $context) {
        if (BoundAst $commandAst 'Encoding') { return }
        $context.Findings.Add((Finding 'encoding' $commandAst "Windows PowerShell 5.1's $cmdlet writes $default unless it is given -Encoding. Add -Encoding utf8 (Windows PowerShell 5.1 then writes a byte-order mark), or run this in PowerShell 7."))
    }

    function DeletionFindings($commandAst, [string[]]$parameters, $context) {
        foreach ($parameter in $parameters) {
            $value = BoundAst $commandAst $parameter
            if ($null -eq $value -or $value -isnot [System.Management.Automation.Language.Ast]) { continue }
            $elements = if ($value -is [System.Management.Automation.Language.ArrayLiteralAst]) { $value.Elements } else { @($value) }
            foreach ($element in $elements) { TargetFindings $commandAst $element $context }
        }
    }

    # The two deletion rules: a target built from a variable, and a target given by relative path.
    function TargetFindings($ownerAst, $targetAst, $context) {
        $variables = @($targetAst.FindAll({ param($n) $n -is [System.Management.Automation.Language.VariableExpressionAst] }, $true))
        if ($variables.Count -gt 0) {
            $names = (@($variables | Microsoft.PowerShell.Core\ForEach-Object { '$' + $_.VariablePath.UserPath }) | Microsoft.PowerShell.Utility\Select-Object -Unique) -join ', '
            $setHere = @($variables | Microsoft.PowerShell.Core\Where-Object { $context.Assigned.Contains((VariableName $_)) } | Microsoft.PowerShell.Core\ForEach-Object { '$' + $_.VariablePath.UserPath } | Microsoft.PowerShell.Utility\Select-Object -Unique)
            if ($setHere.Count -gt 0) {
                $context.Findings.Add((Finding 'deletion-variable' $ownerAst "This deletion's target is built from $names, and $($setHere -join ', ') gets its value only as this command runs, so petal cannot show what the target will be."))
                return
            }
            $resolved = ResolveText $targetAst
            if ($null -eq $resolved.Text) {
                $context.Findings.Add((Finding 'deletion-variable' $ownerAst "This deletion's target is built from $names, and working out what it resolves to would mean running code, so petal cannot show it."))
                return
            }
            $absolute = AbsoluteTarget $resolved.Text
            $empty = if ($resolved.Empty.Count -gt 0) { ' ' + (($resolved.Empty | Microsoft.PowerShell.Utility\Select-Object -Unique) -join ', ') + ' is empty.' } else { '' }
            $context.Findings.Add((Finding 'deletion-variable' $ownerAst "This deletion's target is built from $names, and resolves now to: $absolute.$empty$(FolderNote $context $resolved.Text)" $absolute))
            return
        }
        $resolved = ResolveText $targetAst
        if ($null -ne $resolved.Text -and (IsRelative $resolved.Text)) {
            $absolute = AbsoluteTarget $resolved.Text
            $context.Findings.Add((Finding 'deletion-relative' $ownerAst "This deletion's target '$($resolved.Text)' is a relative path, so it depends on the shell's folder; from the shell's folder now it resolves to: $absolute.$(FolderNote $context $resolved.Text)" $absolute))
        }
    }

    function FolderNote($context, [string]$path) {
        if ($context.ChangesFolder -and (IsRelative $path)) { return ' This command also changes the folder, so by the time it deletes, the target may resolve elsewhere.' }
        return ''
    }

    # The text a target expression stands for, reading variables but never running code: Text is
    # null when the expression contains anything other than literal text and plain variables.
    function ResolveText($expression) {
        $empty = [System.Collections.Generic.List[string]]::new()
        $text = ResolvePart $expression $empty
        return @{ Text = $text; Empty = $empty }
    }

    function ResolvePart($expression, $empty) {
        if ($expression -is [System.Management.Automation.Language.StringConstantExpressionAst]) { return $expression.Value }
        if ($expression -is [System.Management.Automation.Language.VariableExpressionAst]) {
            if (-not (CanRead $expression)) { return $null }
            $value = VariableValue $expression
            if ($null -eq $value -or "$value" -eq '') { $empty.Add('$' + $expression.VariablePath.UserPath); return '' }
            return "$value"
        }
        if ($expression -is [System.Management.Automation.Language.ExpandableStringExpressionAst]) { return ExpandableText $expression $empty }
        return $null
    }

    # An expandable string with its plain variables replaced by their values; null when it holds
    # anything else ($(...), $a.b, $a[0]), since those would run code.
    function ExpandableText($expression, $empty) {
        $source = $expression.Extent.Text
        $base = $expression.Extent.StartOffset
        switch ([string]$expression.StringConstantType) {
            'BareWord' { $at = 0; $end = $source.Length; $quoted = $false }
            'DoubleQuoted' { $at = 1; $end = $source.Length - 1; $quoted = $true }
            default { return $null }
        }
        $builder = [System.Text.StringBuilder]::new()
        foreach ($nested in $expression.NestedExpressions) {
            if ($nested -isnot [System.Management.Automation.Language.VariableExpressionAst] -or -not (CanRead $nested)) { return $null }
            $start = $nested.Extent.StartOffset - $base
            [void]$builder.Append((UnescapeLiteral $source.Substring($at, $start - $at) $quoted))
            $value = VariableValue $nested
            if ($null -eq $value -or "$value" -eq '') { $empty.Add('$' + $nested.VariablePath.UserPath) } else { [void]$builder.Append("$value") }
            $at = $nested.Extent.EndOffset - $base
        }
        [void]$builder.Append((UnescapeLiteral $source.Substring($at, $end - $at) $quoted))
        return $builder.ToString()
    }

    # The literal text between variables, with PowerShell's backtick escapes (and, inside double
    # quotes, a doubled quote) turned into the characters they stand for.
    function UnescapeLiteral([string]$text, [bool]$quoted) {
        $builder = [System.Text.StringBuilder]::new()
        for ($i = 0; $i -lt $text.Length; $i++) {
            $c = $text[$i]
            if ($c -eq '`' -and $i + 1 -lt $text.Length) {
                $i++
                $next = $text[$i]
                switch -CaseSensitive ($next) {
                    '0' { [void]$builder.Append([char]0) }
                    'a' { [void]$builder.Append([char]7) }
                    'b' { [void]$builder.Append([char]8) }
                    'e' { [void]$builder.Append([char]27) }
                    'f' { [void]$builder.Append([char]12) }
                    'n' { [void]$builder.Append([char]10) }
                    'r' { [void]$builder.Append([char]13) }
                    't' { [void]$builder.Append([char]9) }
                    'v' { [void]$builder.Append([char]11) }
                    default { [void]$builder.Append($next) }
                }
            } elseif ($quoted -and $c -eq '"' -and $i + 1 -lt $text.Length -and $text[$i + 1] -eq '"') {
                [void]$builder.Append('"')
                $i++
            } else {
                [void]$builder.Append($c)
            }
        }
        return $builder.ToString()
    }

    # Plain and scope-qualified variables and environment variables can be read without running
    # code; a variable on any other drive ($function:x, $variable:x) cannot.
    function CanRead($variableAst) {
        $path = $variableAst.VariablePath
        if ($path.IsDriveQualified) { return $path.DriveName -eq 'env' }
        return (VariableName $variableAst) -ne ''
    }

    function VariableValue($variableAst) {
        $path = $variableAst.VariablePath
        $name = VariableName $variableAst
        if ($path.IsDriveQualified) { return [System.Environment]::GetEnvironmentVariable($name) }
        $variable = Microsoft.PowerShell.Utility\Get-Variable -Name $name -Scope Global -ErrorAction Ignore
        if ($null -eq $variable) { return $null }
        return $variable.Value
    }

    function IsRelative([string]$path) {
        if ($path.StartsWith('~')) { return $false }
        if ($path -match '^[A-Za-z][A-Za-z0-9_.\-]*:') { return $false }
        if ($path.StartsWith('\\') -or $path.StartsWith('//')) { return $false }
        return $true
    }

    function AbsoluteTarget([string]$path) {
        try { return $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($path) } catch { return $path }
    }

    function CmdDeletionFindings($commandAst, $context) {
        $words = @($commandAst.CommandElements | Microsoft.PowerShell.Utility\Select-Object -Skip 1)
        for ($i = 0; $i -lt $words.Count; $i++) {
            $w = $words[$i].Extent.Text.Trim('"', "'").ToLowerInvariant()
            if ($w -ne '/c' -and $w -ne '/k') { continue }
            if ($i + 1 -ge $words.Count) { return }
            $verb = $words[$i + 1].Extent.Text.Trim('"', "'").ToLowerInvariant()
            if ($verb -notin @('del', 'erase', 'rd', 'rmdir')) { return }
            for ($j = $i + 2; $j -lt $words.Count; $j++) {
                $t = $words[$j]
                if ($t.Extent.Text.StartsWith('/')) { continue }
                TargetFindings $commandAst $t $context
            }
            return
        }
    }

    # Windows PowerShell 5.1 does not escape double quotes inside an argument it passes to a
    # program, so the program receives the argument with them removed or split apart.
    function QuoteFindings($commandAst, [string]$program, $context) {
        foreach ($element in @($commandAst.CommandElements | Microsoft.PowerShell.Utility\Select-Object -Skip 1)) {
            if ($element -is [System.Management.Automation.Language.CommandParameterAst]) { continue }
            $text = (ResolveText $element).Text
            if ($null -eq $text -or -not $text.Contains('"')) { continue }
            $context.Findings.Add((Finding 'quotes' $element "Windows PowerShell 5.1 removes the double quotes inside this argument when it passes it to $program, so $program receives something else. Escape each one as \`", or run this in PowerShell 7."))
        }
    }

    # ---- a read of a Claude Code transcript that keeps Claude Code from writing to it -------------
    # Claude Code adds to a session's transcript as the session goes on, and gives up an addition it
    # cannot write until the session's next compaction writes the conversation again, up to the
    # newest message that compaction keeps. These readers, and the cmdlets Copy-Item and
    # Get-FileHash, open their file letting other programs read it but not write to it (File.Open,
    # File.OpenHandle and FileStream unless their share argument allows writing), so whatever Claude
    # Code adds while one holds a transcript is missing from it until then, and lost if that
    # compaction keeps no newer message or the session ends first. Get-Content and Select-String
    # let other programs write.

    # Claude Code's transcripts are the .jsonl files under the projects folder of its configuration
    # folder, which is CLAUDE_CONFIG_DIR when that is set and .claude in the home folder otherwise.
    function TranscriptFolder {
        $config = [System.Environment]::GetEnvironmentVariable('CLAUDE_CONFIG_DIR')
        if ([string]::IsNullOrEmpty($config)) {
            $profileFolder = [System.Environment]::GetEnvironmentVariable('USERPROFILE')
            if ([string]::IsNullOrEmpty($profileFolder)) { $profileFolder = [System.Environment]::GetFolderPath('UserProfile') }
            $config = [System.IO.Path]::Combine($profileFolder, '.claude')
        }
        try { return [System.IO.Path]::GetFullPath([System.IO.Path]::Combine($config, 'projects')).TrimEnd('\') + '\' } catch { return $null }
    }

    function IsTranscript([string]$full, [string]$folder) {
        if ([string]::IsNullOrEmpty($full) -or [string]::IsNullOrEmpty($folder)) { return $false }
        return $full.EndsWith('.jsonl', [System.StringComparison]::OrdinalIgnoreCase) -and $full.StartsWith($folder, [System.StringComparison]::OrdinalIgnoreCase)
    }

    # The file a path names as the reader opens it: .NET resolves a relative path from the process's
    # current folder, PowerShell (switch -File) from the shell's location.
    function ReaderPath([string]$text, [bool]$byPowerShell) {
        if ([string]::IsNullOrEmpty($text)) { return $null }
        $path = $text
        if ($byPowerShell) {
            try { $path = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($text) } catch { return $null }
        }
        try { return [System.IO.Path]::GetFullPath($path) } catch { if ($byPowerShell) { return $path } else { return $null } }
    }

    function MemberName($memberAst) {
        if ($memberAst.Member -is [System.Management.Automation.Language.StringConstantExpressionAst]) { return $memberAst.Member.Value }
        return $null
    }

    # A static call that opens a file to read it: its name as written, its path argument, and
    # whether it keeps other programs from writing to the file. $null for any other call.
    function StaticReader($m) {
        if (-not $m.Static -or $m.Expression -isnot [System.Management.Automation.Language.TypeExpressionAst]) { return $null }
        $member = MemberName $m
        $arguments = @(if ($null -ne $m.Arguments) { $m.Arguments })
        if ($null -eq $member -or $arguments.Count -lt 1) { return $null }
        $type = $m.Expression.TypeName.GetReflectionType()
        $name = '[' + $m.Expression.TypeName.FullName + ']::' + $member
        if ($type -eq [System.IO.File]) {
            if ($member -in @('ReadLines', 'ReadAllLines', 'ReadAllText', 'ReadAllBytes', 'OpenRead', 'OpenText', 'Copy', 'ReadLinesAsync', 'ReadAllLinesAsync', 'ReadAllTextAsync', 'ReadAllBytesAsync')) {
                return @{ Name = $name; Path = $arguments[0]; Holds = $true }
            }
            if ($member -in @('Open', 'OpenHandle')) { return @{ Name = $name; Path = $arguments[0]; Holds = (ShareHolds $arguments 3) } }
        }
        if ($type -eq [System.IO.FileStream] -and $member -eq 'new') { return @{ Name = $name; Path = $arguments[0]; Holds = (ShareHolds $arguments 3) } }
        if ($type -eq [System.IO.StreamReader] -and $member -eq 'new') { return @{ Name = $name; Path = $arguments[0]; Holds = $true } }
        return $null
    }

    function NewObjectReader($commandAst) {
        $typeAst = BoundAst $commandAst 'TypeName'
        if ($typeAst -isnot [System.Management.Automation.Language.StringConstantExpressionAst]) { return $null }
        $type = $typeAst.Value -as [type]
        if ($type -ne [System.IO.FileStream] -and $type -ne [System.IO.StreamReader]) { return $null }
        $arguments = @(ArgumentElements (BoundAst $commandAst 'ArgumentList'))
        if ($arguments.Count -lt 1) { return $null }
        $name = 'New-Object ' + $typeAst.Value
        if ($type -eq [System.IO.FileStream]) { return @{ Name = $name; Path = $arguments[0]; Holds = (ShareHolds $arguments 3) } }
        return @{ Name = $name; Path = $arguments[0]; Holds = $true }
    }

    # The elements of an argument list given as one expression: a, b or (a, b) or @(a, b).
    function ArgumentElements($value) {
        if ($value -isnot [System.Management.Automation.Language.Ast]) { return }
        $node = UnwrapExpression $value
        if ($node -is [System.Management.Automation.Language.ArrayExpressionAst]) {
            $statements = @($node.SubExpression.Statements)
            if ($statements.Count -ne 1) { return }
            $node = StatementExpression $statements[0]
        }
        if ($node -is [System.Management.Automation.Language.ArrayLiteralAst]) { return $node.Elements }
        if ($null -ne $node) { return $node }
    }

    # Whether the share argument at $index keeps other programs from writing. Without one, File.Open
    # shares nothing, and FileStream and File.OpenHandle share only reading. A share petal cannot
    # work out without running code counts as allowing writes: whoever wrote it chose one.
    function ShareHolds($arguments, [int]$index) {
        if ($arguments.Count -le $index) { return $true }
        $share = ShareValue $arguments[$index] 0
        if ($null -eq $share) { return $false }
        return ($share -band [int][System.IO.FileShare]::Write) -eq 0
    }

    function ShareValue($node, [int]$depth) {
        if ($depth -gt 6) { return $null }
        $node = UnwrapExpression $node
        if ($node -is [System.Management.Automation.Language.ConstantExpressionAst]) {
            try { return [int][System.Management.Automation.LanguagePrimitives]::ConvertTo($node.Value, [System.IO.FileShare]) } catch { return $null }
        }
        if ($node -is [System.Management.Automation.Language.MemberExpressionAst] -and $node -isnot [System.Management.Automation.Language.InvokeMemberExpressionAst] -and $node.Static -and $node.Expression -is [System.Management.Automation.Language.TypeExpressionAst]) {
            if ($node.Expression.TypeName.GetReflectionType() -ne [System.IO.FileShare]) { return $null }
            $member = MemberName $node
            if ($null -eq $member) { return $null }
            try { return [int][System.Management.Automation.LanguagePrimitives]::ConvertTo($member, [System.IO.FileShare]) } catch { return $null }
        }
        if ($node -is [System.Management.Automation.Language.ConvertExpressionAst]) {
            if ($node.Type.TypeName.GetReflectionType() -ne [System.IO.FileShare]) { return $null }
            return ShareValue $node.Child ($depth + 1)
        }
        if ($node -is [System.Management.Automation.Language.BinaryExpressionAst] -and [string]$node.Operator -eq 'Bor') {
            $left = ShareValue $node.Left ($depth + 1)
            $right = ShareValue $node.Right ($depth + 1)
            if ($null -eq $left -or $null -eq $right) { return $null }
            return $left -bor $right
        }
        return $null
    }

    # An expression without its parentheses.
    function UnwrapExpression($node) {
        for ($i = 0; $i -lt 8 -and $node -is [System.Management.Automation.Language.ParenExpressionAst]; $i++) { $node = StatementExpression $node.Pipeline }
        return $node
    }

    # The expression or command a statement consists of, when it is a single one.
    function StatementExpression($statement) {
        if ($statement -is [System.Management.Automation.Language.CommandExpressionAst]) { return $statement.Expression }
        if ($statement -is [System.Management.Automation.Language.PipelineAst] -and $statement.PipelineElements.Count -eq 1) {
            $element = $statement.PipelineElements[0]
            if ($element -is [System.Management.Automation.Language.CommandExpressionAst]) { return $element.Expression }
            return $element
        }
        return $null
    }

    # What a reader's path argument is, worked out without running code: 'path', with the text it
    # stands for; 'other', a path whose fixed end names another extension, so it cannot be a
    # transcript; 'open', a stream or handle opened elsewhere, which this rule checks where it is
    # opened; or 'unknown'.
    function ValueKind($node, $context, [int]$depth) {
        $unknown = @{ Kind = 'unknown' }
        if ($depth -gt 6) { return $unknown }
        $node = UnwrapExpression $node
        if ($null -eq $node) { return $unknown }
        if ($node -is [System.Management.Automation.Language.StringConstantExpressionAst]) { return @{ Kind = 'path'; Texts = @($node.Value) } }
        if ($node -is [System.Management.Automation.Language.ExpandableStringExpressionAst]) {
            $texts = ExpandedPath $node $context $depth
            if ($null -ne $texts) { return @{ Kind = 'path'; Texts = $texts } }
            if (OtherExtension (ExpandableTail $node)) { return @{ Kind = 'other' } }
            return $unknown
        }
        if ($node -is [System.Management.Automation.Language.ArrayLiteralAst] -or $node -is [System.Management.Automation.Language.ArrayExpressionAst]) {
            $parts = [System.Collections.Generic.List[object]]::new()
            if ($node -is [System.Management.Automation.Language.ArrayLiteralAst]) {
                foreach ($element in $node.Elements) { $parts.Add($element) }
            } else {
                foreach ($statement in $node.SubExpression.Statements) {
                    $expression = StatementExpression $statement
                    if ($null -eq $expression) { return $unknown }
                    if ($expression -is [System.Management.Automation.Language.ArrayLiteralAst]) { foreach ($element in $expression.Elements) { $parts.Add($element) } } else { $parts.Add($expression) }
                }
            }
            $texts = [System.Collections.Generic.List[string]]::new()
            foreach ($part in $parts) {
                $kind = ValueKind $part $context ($depth + 1)
                if ($kind.Kind -ne 'path') { return $unknown }
                foreach ($text in @($kind.Texts)) { $texts.Add([string]$text) }
            }
            if ($texts.Count -eq 0 -or $texts.Count -gt 64) { return $unknown }
            return @{ Kind = 'path'; Texts = $texts.ToArray() }
        }
        if ($node -is [System.Management.Automation.Language.BinaryExpressionAst] -and [string]$node.Operator -eq 'Plus') {
            $left = ValueKind $node.Left $context ($depth + 1)
            $right = ValueKind $node.Right $context ($depth + 1)
            if ($left.Kind -eq 'path' -and $right.Kind -eq 'path' -and @($left.Texts).Count -eq 1 -and @($right.Texts).Count -eq 1) {
                return @{ Kind = 'path'; Texts = @([string](@($left.Texts)[0]) + [string](@($right.Texts)[0])) }
            }
            if ($right.Kind -eq 'other' -or ($right.Kind -eq 'path' -and @($right.Texts).Count -eq 1 -and (OtherExtension ([string](@($right.Texts)[0]))))) { return @{ Kind = 'other' } }
            return $unknown
        }
        if ($node -is [System.Management.Automation.Language.VariableExpressionAst]) { return VariableKind $node $context $depth }
        if ($node -is [System.Management.Automation.Language.ConvertExpressionAst]) {
            if ($node.Type.TypeName.GetReflectionType() -eq [string]) { return ValueKind $node.Child $context ($depth + 1) }
            return $unknown
        }
        if ($node -is [System.Management.Automation.Language.InvokeMemberExpressionAst] -and $node.Static -and $node.Expression -is [System.Management.Automation.Language.TypeExpressionAst]) {
            $type = $node.Expression.TypeName.GetReflectionType()
            $member = MemberName $node
            if ($type -eq [System.IO.File] -and $member -in @('Open', 'OpenRead', 'OpenWrite', 'OpenHandle', 'Create')) { return @{ Kind = 'open' } }
            if ($type -eq [System.IO.FileStream] -and $member -eq 'new') { return @{ Kind = 'open' } }
            return $unknown
        }
        if ($node -is [System.Management.Automation.Language.CommandAst]) {
            $commandName = $node.GetCommandName()
            if ($commandName -and (ResolveCommand $commandName).Name -eq 'New-Object') {
                $typeAst = BoundAst $node 'TypeName'
                if ($typeAst -is [System.Management.Automation.Language.StringConstantExpressionAst] -and ($typeAst.Value -as [type]) -eq [System.IO.FileStream]) { return @{ Kind = 'open' } }
            }
        }
        return $unknown
    }

    # A variable the command sets is read from the value it is set to, when that can be known: a
    # foreach loop's variable from the list the loop runs over.
    function VariableKind($variable, $context, [int]$depth) {
        if (-not (CanRead $variable)) { return @{ Kind = 'unknown' } }
        $name = VariableName $variable
        if (-not $variable.VariablePath.IsDriveQualified -and $context.Assigned.Contains($name)) {
            $loop = LoopValues $context.Ast $name $variable $context $depth
            if ($null -ne $loop) { return $loop }
            return ValueKind (SingleAssignment $context.Ast $name $variable) $context ($depth + 1)
        }
        $value = VariableValue $variable
        if ($null -eq $value) { return @{ Kind = 'path'; Texts = @('') } }
        if ($value -is [string]) { return @{ Kind = 'path'; Texts = @($value) } }
        if ($value -is [System.IO.FileSystemInfo]) { return @{ Kind = 'path'; Texts = @($value.FullName) } }
        if ($value -is [System.Management.Automation.PathInfo]) { return @{ Kind = 'path'; Texts = @($value.ProviderPath) } }
        if ($value -is [System.IO.Stream] -or $value -is [System.Runtime.InteropServices.SafeHandle]) { return @{ Kind = 'open' } }
        if ($value -is [System.Collections.IList] -and $value.Count -gt 0 -and $value.Count -le 64) {
            $texts = [System.Collections.Generic.List[string]]::new()
            foreach ($item in $value) {
                if ($item -is [string]) { $texts.Add($item) }
                elseif ($item -is [System.IO.FileSystemInfo]) { $texts.Add($item.FullName) }
                elseif ($item -is [System.Management.Automation.PathInfo]) { $texts.Add($item.ProviderPath) }
                else { return @{ Kind = 'unknown' } }
            }
            return @{ Kind = 'path'; Texts = $texts.ToArray() }
        }
        return @{ Kind = 'unknown' }
    }

    # What the command assigns a variable, when it assigns it exactly once, with a plain '=', ahead
    # of the place it is read, and sets it no other way; $null otherwise.
    function SingleAssignment($ast, [string]$name, $use) {
        $found = $null
        foreach ($a in $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.AssignmentStatementAst] }, $true)) {
            $left = $a.Left
            if ($left -is [System.Management.Automation.Language.ConvertExpressionAst]) { $left = $left.Child }
            $targets = if ($left -is [System.Management.Automation.Language.ArrayLiteralAst]) { @($left.Elements) } else { @($left) }
            $sets = $false
            foreach ($t in $targets) {
                if ($t -is [System.Management.Automation.Language.ConvertExpressionAst]) { $t = $t.Child }
                if ($t -is [System.Management.Automation.Language.VariableExpressionAst] -and (VariableName $t) -eq $name) { $sets = $true }
            }
            if (-not $sets) { continue }
            if ($null -ne $found -or $left -isnot [System.Management.Automation.Language.VariableExpressionAst] -or [string]$a.Operator -ne 'Equals') { return $null }
            $found = $a
        }
        if ($null -eq $found -or $found.Extent.EndOffset -gt $use.Extent.StartOffset) { return $null }
        foreach ($f in $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.ForEachStatementAst] }, $true)) { if ((VariableName $f.Variable) -eq $name) { return $null } }
        foreach ($p in $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.ParameterAst] }, $true)) { if ((VariableName $p.Name) -eq $name) { return $null } }
        return StatementExpression $found.Right
    }

    # The values a foreach loop gives its variable where the loop's body reads it, when the loop runs
    # over a list the command writes out and the command sets the variable no other way; $null
    # otherwise. Of loops inside one another, the innermost one around the read counts.
    function LoopValues($ast, [string]$name, $use, $context, [int]$depth) {
        $loop = $null
        foreach ($f in $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.ForEachStatementAst] }, $true)) {
            if ((VariableName $f.Variable) -ne $name) { continue }
            if ($use.Extent.StartOffset -lt $f.Body.Extent.StartOffset -or $use.Extent.EndOffset -gt $f.Body.Extent.EndOffset) { continue }
            if ($null -eq $loop -or $f.Body.Extent.StartOffset -gt $loop.Body.Extent.StartOffset) { $loop = $f }
        }
        if ($null -eq $loop) { return $null }
        foreach ($a in $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.AssignmentStatementAst] }, $true)) {
            foreach ($v in $a.Left.FindAll({ param($n) $n -is [System.Management.Automation.Language.VariableExpressionAst] }, $true)) { if ((VariableName $v) -eq $name) { return $null } }
        }
        foreach ($p in $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.ParameterAst] }, $true)) { if ((VariableName $p.Name) -eq $name) { return $null } }
        $kind = ValueKind (StatementExpression $loop.Condition) $context ($depth + 1)
        if ($kind.Kind -ne 'path') { return $null }
        return $kind
    }

    # The texts an expandable string stands for, its variables read as VariableKind reads them: one
    # text for each combination of their values, at most 64. $null when it holds anything else.
    function ExpandedPath($expression, $context, [int]$depth) {
        $source = $expression.Extent.Text
        $base = $expression.Extent.StartOffset
        switch ([string]$expression.StringConstantType) {
            'BareWord' { $at = 0; $end = $source.Length; $quoted = $false }
            'DoubleQuoted' { $at = 1; $end = $source.Length - 1; $quoted = $true }
            default { return $null }
        }
        $texts = [System.Collections.Generic.List[string]]::new()
        $texts.Add('')
        foreach ($nested in $expression.NestedExpressions) {
            if ($nested -isnot [System.Management.Automation.Language.VariableExpressionAst]) { return $null }
            $kind = VariableKind $nested $context ($depth + 1)
            if ($kind.Kind -ne 'path') { return $null }
            $start = $nested.Extent.StartOffset - $base
            $literal = UnescapeLiteral $source.Substring($at, $start - $at) $quoted
            $next = [System.Collections.Generic.List[string]]::new()
            foreach ($text in $texts) { foreach ($value in @($kind.Texts)) { $next.Add($text + $literal + [string]$value) } }
            if ($next.Count -gt 64) { return $null }
            $texts = $next
            $at = $nested.Extent.EndOffset - $base
        }
        $last = UnescapeLiteral $source.Substring($at, $end - $at) $quoted
        $result = [string[]]::new($texts.Count)
        for ($i = 0; $i -lt $texts.Count; $i++) { $result[$i] = $texts[$i] + $last }
        return , $result
    }

    # The literal end of an expandable string, after its last variable or subexpression.
    function ExpandableTail($expression) {
        $source = $expression.Extent.Text
        $base = $expression.Extent.StartOffset
        switch ([string]$expression.StringConstantType) {
            'BareWord' { $at = 0; $end = $source.Length; $quoted = $false }
            'DoubleQuoted' { $at = 1; $end = $source.Length - 1; $quoted = $true }
            default { return '' }
        }
        foreach ($nested in $expression.NestedExpressions) { $at = [Math]::Max($at, $nested.Extent.EndOffset - $base) }
        if ($at -ge $end) { return '' }
        return UnescapeLiteral $source.Substring($at, $end - $at) $quoted
    }

    # Whether a path's end names a file extension other than .jsonl.
    function OtherExtension([string]$tail) {
        $m = [regex]::Match($tail, '\.([A-Za-z0-9]{1,10})$')
        return $m.Success -and $m.Groups[1].Value -ne 'jsonl'
    }

    # A command whose reader's file petal cannot name is flagged only when the command names a
    # .jsonl file or the transcripts' folder. A .jsonl written as regex text (\.jsonl) names no file,
    # and a path into the folder that goes on to name a file of another kind, such as a memory's .md
    # (the memories live inside the transcripts' folder), names no transcript.
    function TranscriptMention($context) {
        if ($context.Text -match '(?<!\\)\.jsonl') { return 'a .jsonl file' }
        $forms = [System.Collections.Generic.List[string]]::new()
        $forms.Add('\.claude[\\/]+projects')
        if ($context.Transcripts) { $forms.Add([regex]::Escape($context.Transcripts.TrimEnd('\')).Replace('\\', '[\\/]+')) }
        foreach ($form in $forms) {
            foreach ($m in [regex]::Matches($context.Text, '(?i)' + $form + '([^''"`\s;|(){},]*)')) {
                if (-not (OtherExtension $m.Groups[1].Value)) { return "the folder of Claude Code's transcripts" }
            }
        }
        return $null
    }

    function ReaderFinding($ownerAst, $reader, $context) {
        if ($null -eq $reader -or -not $reader.Holds) { return }
        $holds = 'keeps other programs from writing to it while it is open'
        $why = "Claude Code adds to a transcript as its session goes on and gives up an addition it cannot write, so whatever it adds meanwhile is missing from the transcript until the session's next compaction, which writes it again when that compaction keeps any message newer than it; otherwise, or if the session ends first, it is lost"
        $instead = "Read the file with Get-Content or Select-String, which let other programs write, or open it with [IO.FileStream]::new(path, 'Open', 'Read', 'ReadWrite, Delete') and read that stream"
        try {
            $kind = ValueKind $reader.Path $context 0
            if ($kind.Kind -eq 'open' -or $kind.Kind -eq 'other') { return }
            if ($kind.Kind -eq 'path') {
                foreach ($text in @($kind.Texts)) {
                    $full = ReaderPath $text ([bool]$reader.ByPowerShell)
                    if (IsTranscript $full $context.Transcripts) {
                        $context.Findings.Add((Finding 'transcript-read' $ownerAst "$($reader.Name) opens $full, a Claude Code transcript, and $holds. $why. $instead." $full))
                        return
                    }
                }
                return
            }
            $mention = TranscriptMention $context
            if ($null -ne $mention) {
                $context.Findings.Add((Finding 'transcript-read' $ownerAst "$($reader.Name) opens a file petal cannot name before the command runs, and the command names $mention. If that file is a Claude Code transcript, this reader $holds; $why. $instead."))
            }
        } catch {
            $context.Findings.Add((Finding 'transcript-read' $ownerAst "petal could not finish checking whether $($reader.Name) reads a Claude Code transcript: $($_.Exception.Message)"))
        }
    }

    # The file-system paths a cmdlet's path argument stands for, as the cmdlet resolves them: from
    # the shell's location, a -Path's wildcards matched against what the folder holds now. Paths of
    # other providers (Env:, HKLM:) are left out.
    function SourcePaths([string]$text, [bool]$wildcards) {
        if ([string]::IsNullOrEmpty($text)) { return }
        $provider = $null
        if ($wildcards -and [System.Management.Automation.WildcardPattern]::ContainsWildcardCharacters($text)) {
            try { $paths = $ExecutionContext.SessionState.Path.GetResolvedProviderPathFromPSPath($text, [ref]$provider) } catch { return }
            if ($provider.Name -ne 'FileSystem') { return }
            return $paths
        }
        $drive = $null
        try { $path = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($text, [ref]$provider, [ref]$drive) } catch { return }
        if ($provider.Name -ne 'FileSystem') { return }
        try { return [System.IO.Path]::GetFullPath($path) } catch { return $path }
    }

    # Whether a folder Copy-Item -Recurse copies holds transcripts: the projects folder, a folder
    # above it, or a folder inside it with a .jsonl file anywhere in it. The listing is disposed of
    # at once, since a listing left open would hold its folder.
    function HoldsTranscripts([string]$full, [string]$folder) {
        if ([string]::IsNullOrEmpty($full) -or [string]::IsNullOrEmpty($folder)) { return $false }
        if (-not [System.IO.Directory]::Exists($full)) { return $false }
        $dir = $full.TrimEnd('\') + '\'
        if ($folder.StartsWith($dir, [System.StringComparison]::OrdinalIgnoreCase)) { return $true }
        if (-not $dir.StartsWith($folder, [System.StringComparison]::OrdinalIgnoreCase)) { return $false }
        $files = $null
        try {
            $files = [System.IO.Directory]::EnumerateFiles($full, '*.jsonl', [System.IO.SearchOption]::AllDirectories).GetEnumerator()
            return $files.MoveNext()
        } catch {
            return $true
        } finally {
            if ($null -ne $files) { $files.Dispose() }
        }
    }

    # Copy-Item and Get-FileHash read each file they are given, keeping other programs from writing
    # to it meanwhile, and Copy-Item -Recurse every file in a folder it copies. Their files are
    # worked out as the readers' are. A stream given to Get-FileHash -InputStream is checked where
    # it is opened; a Copy-Item -FromSession reads on another computer.
    function CmdletReaderFindings($commandAst, [string]$cmdlet, $context) {
        if ($cmdlet -eq 'Get-FileHash' -and $null -ne (BoundAst $commandAst 'InputStream')) { return }
        if ($cmdlet -eq 'Copy-Item' -and $null -ne (BoundAst $commandAst 'FromSession')) { return }
        $recurse = $false
        if ($cmdlet -eq 'Copy-Item') {
            $flag = BoundAst $commandAst 'Recurse'
            $recurse = $null -ne $flag -and -not ($flag -is [System.Management.Automation.Language.VariableExpressionAst] -and (VariableName $flag) -eq 'false')
        }
        $why = "Claude Code adds to a transcript as its session goes on and gives up an addition it cannot write, so whatever it adds meanwhile is missing from the transcript until the session's next compaction, which writes it again when that compaction keeps any message newer than it; otherwise, or if the session ends first, it is lost"
        $stream = "[IO.FileStream]::new(path, 'Open', 'Read', 'ReadWrite, Delete')"
        $instead = if ($cmdlet -eq 'Copy-Item') { "Copy it from a stream that lets other programs write: open it with $stream and copy that stream into the new file with its CopyTo method" } else { "Hash it from a stream that lets other programs write: open it with $stream and pass that stream to Get-FileHash -InputStream" }
        try {
            $sources = [System.Collections.Generic.List[object]]::new()
            foreach ($parameter in @('Path', 'LiteralPath')) {
                $value = BoundAst $commandAst $parameter
                if ($value -is [System.Management.Automation.Language.ExpressionAst]) { $sources.Add(@{ Ast = $value; Wildcards = ($parameter -eq 'Path') }) }
            }
            $unknown = $sources.Count -eq 0
            foreach ($source in $sources) {
                $kind = ValueKind $source.Ast $context 0
                if ($kind.Kind -eq 'other' -and -not $recurse) { continue }
                if ($kind.Kind -ne 'path') { $unknown = $true; continue }
                foreach ($text in @($kind.Texts)) {
                    if ($context.ChangesFolder -and (IsRelative $text)) { $unknown = $true; continue }
                    foreach ($full in @(SourcePaths $text $source.Wildcards)) {
                        if (IsTranscript $full $context.Transcripts) {
                            $context.Findings.Add((Finding 'transcript-read' $commandAst "$cmdlet reads $full, a Claude Code transcript, and keeps other programs from writing to it while it reads. $why. $instead." $full))
                            return
                        }
                        if ($recurse -and (HoldsTranscripts $full $context.Transcripts)) {
                            $context.Findings.Add((Finding 'transcript-read' $commandAst "Copy-Item -Recurse copies $full with everything in it, Claude Code's transcripts among them, and keeps other programs from writing to each file while it reads it. $why. Copy what you need without the transcripts, or copy each transcript from a stream that lets other programs write: open it with $stream and copy that stream into the new file with its CopyTo method." $full))
                            return
                        }
                    }
                }
            }
            if ($unknown) {
                $mention = TranscriptMention $context
                if ($null -ne $mention) {
                    $verb = if ($cmdlet -eq 'Copy-Item') { 'copies' } else { 'hashes' }
                    $context.Findings.Add((Finding 'transcript-read' $commandAst "$cmdlet $verb files petal cannot name before the command runs, and the command names $mention. If one is a Claude Code transcript, $cmdlet keeps other programs from writing to it while it reads it; $why. $instead."))
                }
            }
        } catch {
            $context.Findings.Add((Finding 'transcript-read' $commandAst "petal could not finish checking whether $cmdlet reads a Claude Code transcript: $($_.Exception.Message)"))
        }
    }

    Export-ModuleMember -Function __petal_ready, __petal_next, __petal_status, __petal_failed, __petal_line, __petal_write, __petal_caught, __petal_done
}
Microsoft.PowerShell.Core\Import-Module $__petal
Microsoft.PowerShell.Utility\Remove-Variable -Name __petal -Scope Global
Microsoft.PowerShell.Management\Remove-Item -Path Env:PETAL_LOOP, Env:PETAL_IN, Env:PETAL_OUT
__petal_ready
while ($true) {
    $__petal_block = $null
    $__petal_block = __petal_next
    if ($null -eq $__petal_block) { continue }
    try {
        . { do { try { . $__petal_block } catch { __petal_failed; $_ } } while ($false) } *>&1 | __petal_line | Microsoft.PowerShell.Utility\Out-String -Stream -Width 200 | __petal_write
    } catch {
        __petal_caught $_
    }
    __petal_done
}
