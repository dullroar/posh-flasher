@{
    Severity     = @('Error', 'Warning')
    ExcludeRules = @(
        # Interactive tool: Write-Host is the intended UX for prompts and the audit line.
        'PSAvoidUsingWriteHost',
        # Lock-/Set- helpers wrap Win32 calls behind an explicit confirmation phrase, not ShouldProcess.
        'PSUseShouldProcessForStateChangingFunctions',
        # 'Fail' and 'Show-Disk' are deliberate short internal names.
        'PSUseSingularNouns',
        'PSUseApprovedVerbs',
        # -WhatIf is a deliberate custom dry-run switch with its own semantics (no ShouldProcess).
        'PSUseSupportsShouldProcess',
        # Test doubles intentionally shadow cmdlets and ignore most parameters.
        'PSAvoidOverwritingBuiltInCmdlets',
        'PSReviewUnusedParameter'
    )
    # Unused variables, ambiguous assignments, and the like stay enabled via the default rule set.
}
