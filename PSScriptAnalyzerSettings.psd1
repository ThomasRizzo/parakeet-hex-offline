@{
    # Installer output is meant for a person at a console.
    ExcludeRules = @(
        'PSAvoidUsingWriteHost',
        'PSAvoidUsingEmptyCatchBlock',
        'PSUseShouldProcessForStateChangingFunctions',
        'PSAvoidUsingPositionalParameters'
    )
    Rules = @{
        PSUseCompatibleSyntax = @{
            Enable = $true
            TargetVersions = @('5.1', '7.0')
        }
    }
}
