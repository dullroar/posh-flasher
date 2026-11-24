@{
    Severity     = @('Error', 'Warning')
    ExcludeRules = @(
        # Interactive tool: Write-Host is the intended UX for prompts and the audit line.
        'PSAvoidUsingWriteHost',
        # Lock-/Set- helpers wrap Win32 calls behind an explicit confirmation phrase, not ShouldProcess.
        'PSUseShouldProcessForStateChangingFunctions',
        # 'Fail' and 'Show-Disk' are deliberate short internal names.
        'PSUseSingularNouns',
        'PSUseApprovedVerbs'
    )
    # Unused variables, ambiguous assignments, and the like stay enabled via the default rule set.
}
