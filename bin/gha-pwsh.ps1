param (
    [Parameter(Mandatory = $true)]
    [string] $ScriptPath
)

# Match the error preference configured by GitHub's built-in PowerShell shell.
$ErrorActionPreference = 'Stop'

try {
    ########################################################################

    function Get-CallerLineNumber {
        $MyInvocation.ScriptLineNumber
    }

    # IMPORTANT: GitHub does not assign a .ps1 extension when using a custom shell. PowerShell
    #   only executes dot-sourced script files with a recognized PowerShell extension.
    #   Files without such an extension are simply ignored - not error is logged.
    $hasPowerShellExtension = [IO.Path]::GetExtension($ScriptPath) -ieq '.ps1'
    $powershellScriptPath = if ($hasPowerShellExtension) { $ScriptPath } else { "$ScriptPath.ps1" }

    if (-not $hasPowerShellExtension) {
        Copy-Item -LiteralPath $ScriptPath -Destination $powershellScriptPath
    }

    try {
        # Dot source (import) the script.
        # IMPORTANT: Keep this assignment directly above the dot-source statement.
        $dotSourceLineNumber = (Get-CallerLineNumber) + 1
        . $powershellScriptPath
    }
    finally {
        if (-not $hasPowerShellExtension) {
            Remove-Item -LiteralPath $powershellScriptPath -Force -ErrorAction SilentlyContinue
        }
    }

    # A step whose only command is a failing native command is expected to fail. However, when a
    # script handles a native failure, $LASTEXITCODE still remains nonzero because successful
    # PowerShell commands do not reset it. The wrapper cannot reliably distinguish an overlooked
    # native failure from an intentionally handled one, so we match GitHub's built-in PowerShell shell
    # behavior and propagate $LASTEXITCODE.
    #
    # Do NOT replace this with `exit 0`; a script that intentionally handles a native failure must
    # explicitly reset the exit code itself (for example, with `exit 0`). This can't be done centrally here.
    #
    # NOTE: The "Test-Path" condition exists for when the script enables strict mode - which wouldn't
    #   allow us to use $LASTEXITCODE in case it was never set.
    if (Test-Path -LiteralPath variable:\LASTEXITCODE) {
        exit $LASTEXITCODE
    }

    ########################################################################
}
catch {
    function Get-CleanedScriptStackTrace(
        [string] $scriptStackTrace,
        [int] $dotSourceLineNumber,
        [string] $stepScriptPath
    ) {
        if ([string]::IsNullOrWhiteSpace($scriptStackTrace)) {
            return $scriptStackTrace
        }

        # The final frame normally points to the dot-sourcing statement in this wrapper and does
        # not help diagnose the user's script. Preserve single-frame traces because those can
        # represent errors originating in the wrapper itself.
        $scriptStackTraceLines = @($scriptStackTrace -split '\r\n|\n')
        $finalFrameLineNumber = if ($scriptStackTraceLines[-1] -match ': line (\d+)$') {
            [int] $Matches[1]
        }

        if ($scriptStackTraceLines.Count -gt 1 -And $finalFrameLineNumber -eq $dotSourceLineNumber) {
            $scriptStackTraceLines = @($scriptStackTraceLines[0..($scriptStackTraceLines.Count - 2)])
        }

        # GitHub Actions stores the inline step in a temporary script. Replace that implementation
        # detail with a recognizable label while retaining the useful line number. Only rewrite
        # ScriptBlock frames that point to the exact script passed to this wrapper.
        $normalizedStepScriptPath = [IO.Path]::GetFullPath($stepScriptPath)
        for ($index = 0; $index -lt $scriptStackTraceLines.Count; $index++) {
            if ($scriptStackTraceLines[$index] -notmatch '^at <ScriptBlock>, (?<path>.+): line (?<lineNumber>\d+)$') {
                continue
            }

            $normalizedFramePath = [IO.Path]::GetFullPath($Matches.path)
            $pathsMatch = if ($IsWindows) {
                $normalizedFramePath -ieq $normalizedStepScriptPath
            }
            else {
                $normalizedFramePath -ceq $normalizedStepScriptPath
            }

            if ($pathsMatch) {
                $scriptStackTraceLines[$index] = "at GitHub Actions step, line $($Matches.lineNumber)"
            }
        }

        return $scriptStackTraceLines -join [Environment]::NewLine
    }

    function Write-GitHubJobSummary([string] $diagnostic) {
        if ([string]::IsNullOrWhiteSpace($env:GITHUB_STEP_SUMMARY)) {
            return
        }

        # Use a fence longer than any sequence in the diagnostic so arbitrary exception text
        # cannot end the code block early.
        $longestFence = 2
        foreach ($match in [regex]::Matches($diagnostic, '`+')) {
            $longestFence = [Math]::Max($longestFence, $match.Length)
        }
        $fence = '`' * ($longestFence + 1)

        $summary = [string]::Join([Environment]::NewLine, @(
            ''
            '### ❌ PowerShell error'
            ''
            "${fence}text"
            $diagnostic
            $fence
        ))

        try {
            Add-Content -LiteralPath $env:GITHUB_STEP_SUMMARY -Value $summary -Encoding utf8
        }
        catch {
            Write-Warning "Could not add the PowerShell error to the GitHub job summary: $($_.Exception.Message)"
        }
    }

    # Type of $_: System.Management.Automation.ErrorRecord

    # NOTE: According to https://docs.microsoft.com/en-us/powershell/scripting/developer/cmdlet/windows-powershell-error-records
    #   we should always use '$_.ErrorDetails.Message' instead of '$_.Exception.Message' for displaying the message.
    #   In fact, there are cases where '$_.ErrorDetails.Message' actually contains more/better information than '$_.Exception.Message'.
    if ($_.ErrorDetails -And $_.ErrorDetails.Message) {
        $unhandledExceptionMessage = $_.ErrorDetails.Message
    }
    elseif ($_.Exception -And $_.Exception.Message) {
        $unhandledExceptionMessage = $_.Exception.Message
    }
    else {
        $unhandledExceptionMessage = 'Could not determine error message from ErrorRecord'
    }

    # IMPORTANT: We compare type names(!) here - not actual types. This is important because - for example -
    #   the type 'Microsoft.PowerShell.Commands.WriteErrorException' is not always available (most likely
    #   when Write-Error has never been called).
    if ($_.Exception.GetType().FullName -eq 'Microsoft.PowerShell.Commands.WriteErrorException') {
        # Print error messages without a stack trace.
        $errorHeadline = $unhandledExceptionMessage
        $scriptStackTrace = $null
    }
    else {
        # Print proper exception message (including stack trace).
        # NOTE: We can't create a catch block for "RuntimeException" as every exception
        #   seems to be interpreted as RuntimeException.
        if ($_.Exception.GetType().FullName -eq 'System.Management.Automation.RuntimeException') {
            $errorHeadline = $unhandledExceptionMessage
        }
        else {
            $errorHeadline = "$($_.Exception.GetType().Name): $unhandledExceptionMessage"
        }

        $scriptStackTrace = Get-CleanedScriptStackTrace $_.ScriptStackTrace $dotSourceLineNumber $powershellScriptPath
    }

    $diagnostic = $errorHeadline
    if (-not [string]::IsNullOrWhiteSpace($scriptStackTrace)) {
        $diagnostic += "$([Environment]::NewLine)$scriptStackTrace"
    }

    Write-Host $diagnostic
    Write-GitHubJobSummary $diagnostic

    # NOTE: Linux only allows exit codes 0 - 255.
    exit 255
}
