# Robocurse GUI Resource Loading
# XAML resources are stored in the Resources folder for maintainability.
# The Get-XamlResource function loads them at runtime with fallback to embedded content.

function Get-XamlResource {
    <#
    .SYNOPSIS
        Loads XAML content from a resource file or falls back to embedded content
    .PARAMETER ResourceName
        Name of the XAML resource file (without path)
    .PARAMETER FallbackContent
        Optional embedded XAML content to use if file not found
    .OUTPUTS
        XAML string content
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$ResourceName,

        [string]$FallbackContent
    )

    # Try to load from Resources folder
    $resourcePath = Join-Path $PSScriptRoot "..\Resources\$ResourceName"
    if (Test-Path $resourcePath) {
        try {
            return Get-Content -Path $resourcePath -Raw -ErrorAction Stop
        }
        catch {
            Write-Verbose "Failed to load XAML resource '$ResourceName': $_"
        }
    }

    # Fall back to embedded content if provided
    if ($FallbackContent) {
        return $FallbackContent
    }

    throw "XAML resource '$ResourceName' not found and no fallback provided"
}
