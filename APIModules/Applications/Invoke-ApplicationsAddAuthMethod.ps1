#Requires -Version 5.1

$ModuleMeta = @{
    Name             = 'Add Application Authentication Method'
    Category         = 'Applications'
    Action           = 'AddAuthMethod'
    Description      = 'Add an authentication method to a CyberArk application.'
    SupportedSystems = @('ISPSS', 'SelfHosted')
    SupportsWhatIf   = $true
    AcceptsInputFile = $true
    ProducesOutput   = $false
    HasCustomInput   = $true
    InputSchema      = @(
        # Example values form one coherent certificateattr row, written beneath the header by
        # "Generate Template" so the semicolon-separated Attribute=value syntax is shown by example
        # (same approach as ExtraMembers in Safes/AddFromTemplate).
        @{ Column = 'AppID';                Required = $true;  Description = 'Application ID, or leave blank to search.'; Example = 'MyApp' }
        @{ Column = 'AuthType';             Required = $true;  Description = 'Auth type: path, certificateSN, certificateattr, hash, machineAddress, osUser.'; Example = 'certificateattr' }
        @{ Column = 'AuthValue';            Required = $false; Description = 'Authentication value (path, cert serial, hash value, IP/hostname, or OS user). Required for every type except certificateattr.' }
        @{ Column = 'IsFolder';             Required = $false; Description = 'For path auth type: match folder and subfolders. (true/false)' }
        @{ Column = 'AllowInternalScripts'; Required = $false; Description = 'For path auth type: allow scripts in the path. (true/false)' }
        @{ Column = 'Subject';              Required = $false; Description = 'For certificateattr: subject attributes as Attribute=value pairs separated by semicolons, in the same order as in the certificate (e.g. CN=app01;OU=IT).'; Example = 'CN=app01;OU=IT;C=US' }
        @{ Column = 'Issuer';               Required = $false; Description = 'For certificateattr: issuer attributes as Attribute=value pairs separated by semicolons, in the same order as in the certificate (e.g. CN=Corp CA;O=Corp).'; Example = 'CN=Corp Issuing CA' }
        @{ Column = 'SubjectAlternativeName'; Required = $false; Description = 'For certificateattr: SAN entries separated by semicolons, in the same order as in the certificate; names are DNS Name, IP Address, URI or RFC822 Name (e.g. DNS Name=app01.corp.com).'; Example = 'DNS Name=app01.corp.com;IP Address=10.0.0.5' }
        @{ Column = 'Comment';              Required = $false; Description = 'Optional comment.'; Example = 'Example row - delete before running' }
    )
    Priority         = 90
    Version          = '1.1.0'
}

function script:ConvertTo-CertAttrList {
    <#
    .SYNOPSIS
        Splits a semicolon-separated certificateattr value into a trimmed, non-empty array of
        Attribute=value strings. Returns an empty array for blank input.
    #>
    param([AllowNull()] [object]$Value)

    if ($null -eq $Value) { return ,@() }
    # Interactive Defaults or -InputJson may already supply an array; join it back so both
    # shapes go through the same split/trim path.
    $text = if ($Value -is [array]) { ($Value | ForEach-Object { "$_" }) -join ';' } else { "$Value" }
    $items = @($text -split ';' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    return ,$items
}

function script:Test-CertAttrList {
    <#
    .SYNOPSIS
        Returns an error message for the first malformed entry in a certificateattr list, or an
        empty string when every entry is a valid Attribute=value pair.
    #>
    param(
        [string]$FieldName,
        [string[]]$Items,
        [string[]]$AllowedNames = @()
    )

    foreach ($item in @($Items)) {
        $parts = $item -split '=', 2
        $name  = $parts[0].Trim()
        $value = if ($parts.Count -gt 1) { $parts[1].Trim() } else { '' }
        if ((-not $name) -or (-not $value)) {
            return "$FieldName entry '$item' must be in Attribute=value form."
        }
        if ($AllowedNames.Count -gt 0 -and ($name -notin $AllowedNames)) {
            return "$FieldName entry '$item' has an unsupported attribute name '$name'. Valid names: $($AllowedNames -join ', ')."
        }
    }
    return ''
}

function Get-ApplicationsAddAuthMethodInput {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]  [PSCustomObject]$Token,
        [Parameter(Mandatory = $false)] [hashtable]$Defaults
    )

    if (-not $Defaults) { $Defaults = @{} }

    Write-Host '  Add Application Authentication Method  (press Enter to skip optional fields)' -ForegroundColor DarkGray
    Write-Host ''

    $appId = Show-FieldPrompt -Label 'App ID' `
        -Default $(if ($Defaults['AppID']) { $Defaults['AppID'] } else { '' }) `
        -Description 'Application ID, or leave blank to search by name.'

    if (-not $appId) {
        $searchTerm = Show-FieldPrompt -Label 'Search' `
            -Description 'Partial Application ID to search for.'
        if ($searchTerm) {
            $ignoreSSL = if ($script:ActiveProfile) { [bool]$script:ActiveProfile.IgnoreSSL } else { $false }
            $appId = Invoke-EntitySearch -Token $Token `
                -Endpoint           '/WebServices/PIMServices.svc/Applications/' `
                -SearchTerm         $searchTerm `
                -ResponseProperty   'application' `
                -IdProperty         'AppID' `
                -DisplayProperties  @('AppID', 'Description', 'Location') `
                -EntityLabel        'application' `
                -ClientSideFilter `
                -IgnoreSSL          $ignoreSSL
        }
        if (-not $appId) { return $null }
    }

    Write-Host ''
    Write-Host '  Auth Types: path | certificateSN | certificateattr | hash | machineAddress | osUser' -ForegroundColor DarkGray

    $authType = Show-FieldPrompt -Label 'Auth Type' `
        -Default $(if ($Defaults['AuthType']) { $Defaults['AuthType'] } else { '' }) `
        -Required $true `
        -Description 'Authentication method type (required).'

    $authValue = ''
    $subject   = ''
    $issuer    = ''
    $san       = ''
    if ($authType -eq 'certificateattr') {
        Write-Host '  Enter Attribute=value pairs separated by semicolons. List them in the same order as in the certificate. At least one of Subject, Issuer or SAN is required.' -ForegroundColor DarkGray
        $subject = Show-FieldPrompt -Label 'Subject' `
            -Default $(if ($Defaults['Subject']) { $Defaults['Subject'] } else { '' }) `
            -Description 'Subject attributes, e.g. CN=app01;OU=IT;C=US'
        $issuer = Show-FieldPrompt -Label 'Issuer' `
            -Default $(if ($Defaults['Issuer']) { $Defaults['Issuer'] } else { '' }) `
            -Description 'Issuer attributes, e.g. CN=Corp Issuing CA;O=Corp'
        $san = Show-FieldPrompt -Label 'Subject Alternative Name' `
            -Default $(if ($Defaults['SubjectAlternativeName']) { $Defaults['SubjectAlternativeName'] } else { '' }) `
            -Description 'SAN entries (DNS Name, IP Address, URI, RFC822 Name), e.g. DNS Name=app01.corp.com;IP Address=10.0.0.5'
    } else {
        $authValue = Show-FieldPrompt -Label 'Auth Value' `
            -Default $(if ($Defaults['AuthValue']) { $Defaults['AuthValue'] } else { '' }) `
            -Required $true `
            -Description 'Authentication value (required).'
    }

    $isFolder             = $false
    $allowInternalScripts = $false
    if ($authType -eq 'path') {
        $isFolderStr = Show-FieldPrompt -Label 'Is Folder' `
            -Default $(if ($Defaults['IsFolder']) { 'Y' } else { 'N' }) `
            -Description 'Match folder and all subfolders? (Y/N)'
        $allowScriptsStr = Show-FieldPrompt -Label 'Allow Internal Scripts' `
            -Default $(if ($Defaults['AllowInternalScripts']) { 'Y' } else { 'N' }) `
            -Description 'Allow scripts inside the path? (Y/N)'
        $isFolder             = ($isFolderStr -match '^[Yy]$')
        $allowInternalScripts = ($allowScriptsStr -match '^[Yy]$')
    }

    $comment = Show-FieldPrompt -Label 'Comment' `
        -Default $(if ($Defaults['Comment']) { $Defaults['Comment'] } else { '' }) `
        -Description 'Optional comment.'

    return @{
        AppID                = $appId
        AuthType             = $authType
        AuthValue            = $authValue
        IsFolder             = $isFolder
        AllowInternalScripts = $allowInternalScripts
        Subject              = $subject
        Issuer               = $issuer
        SubjectAlternativeName = $san
        Comment              = $comment
    }
}

function Invoke-ApplicationsAddAuthMethod {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [PSCustomObject]$Token,

        [Parameter(Mandatory = $false)]
        [hashtable]$InputData,

        [Parameter(Mandatory = $false)]
        [switch]$WhatIf
    )

    $result = [PSCustomObject]@{
        ModuleName     = $ModuleMeta.Name
        Category       = $ModuleMeta.Category
        Action         = $ModuleMeta.Action
        ItemsProcessed = 0
        Successes      = 0
        Failures       = 0
        IsFatal        = $false
        Results        = [System.Collections.Generic.List[PSCustomObject]]::new()
        Errors         = [System.Collections.Generic.List[PSCustomObject]]::new()
    }

    if (-not $InputData) { $InputData = @{} }

    $appId     = if ($InputData['AppID'])     { "$($InputData['AppID'])".Trim()     } else { '' }
    $authType  = if ($InputData['AuthType'])  { "$($InputData['AuthType'])".Trim()  } else { '' }
    $authValue = if ($InputData['AuthValue']) { "$($InputData['AuthValue'])".Trim() } else { '' }

    if (-not $appId) {
        $msg = 'Invoke-ApplicationsAddAuthMethod: AppID is required.'
        Write-CyberArkLog -Level 'ERROR' -Message $msg
        $result.Errors.Add([PSCustomObject]@{ InputData = $InputData; ErrorMessage = 'AppID is required.'; ErrorDetails = $null })
        $result.Failures++; $result.ItemsProcessed++
        return $result
    }
    if (-not $authType) {
        $msg = 'Invoke-ApplicationsAddAuthMethod: AuthType is required.'
        Write-CyberArkLog -Level 'ERROR' -Message $msg
        $result.Errors.Add([PSCustomObject]@{ InputData = $InputData; ErrorMessage = 'AuthType is required.'; ErrorDetails = $null })
        $result.Failures++; $result.ItemsProcessed++
        return $result
    }

    # certificateattr has no AuthValue: it sends separate Subject/Issuer/SubjectAlternativeName
    # arrays instead, and the API needs at least one of them.
    $isCertAttr = ($authType -eq 'certificateattr')
    $subject    = @()
    $issuer     = @()
    $san        = @()
    if ($isCertAttr) {
        $authType = 'certificateattr'
        $subject  = script:ConvertTo-CertAttrList -Value $InputData['Subject']
        $issuer   = script:ConvertTo-CertAttrList -Value $InputData['Issuer']
        $san      = script:ConvertTo-CertAttrList -Value $InputData['SubjectAlternativeName']

        $certAttrError = ''
        if ($subject.Count -eq 0 -and $issuer.Count -eq 0 -and $san.Count -eq 0) {
            $certAttrError = 'certificateattr requires at least one of Subject, Issuer or SubjectAlternativeName.'
        }
        if (-not $certAttrError) { $certAttrError = script:Test-CertAttrList -FieldName 'Subject' -Items $subject }
        if (-not $certAttrError) { $certAttrError = script:Test-CertAttrList -FieldName 'Issuer'  -Items $issuer }
        if (-not $certAttrError) {
            # Valid SAN attribute names per the PVWA "Add application authentication method" reference.
            $certAttrError = script:Test-CertAttrList -FieldName 'SubjectAlternativeName' -Items $san `
                -AllowedNames @('DNS Name', 'IP Address', 'URI', 'RFC822 Name')
        }
        if ($certAttrError) {
            Write-CyberArkLog -Level 'ERROR' -Message "Invoke-ApplicationsAddAuthMethod: $certAttrError"
            $result.Errors.Add([PSCustomObject]@{ InputData = $InputData; ErrorMessage = $certAttrError; ErrorDetails = $null })
            $result.Failures++; $result.ItemsProcessed++
            return $result
        }
    } elseif (-not $authValue) {
        $msg = 'Invoke-ApplicationsAddAuthMethod: AuthValue is required.'
        Write-CyberArkLog -Level 'ERROR' -Message $msg
        $result.Errors.Add([PSCustomObject]@{ InputData = $InputData; ErrorMessage = 'AuthValue is required.'; ErrorDetails = $null })
        $result.Failures++; $result.ItemsProcessed++
        return $result
    }

    # [bool]$x on a CSV string casts ANY non-empty string to $true, including the literal text
    # "false"/"no"/"0" - only a truly empty string casts to $false. Match against known truthy
    # tokens instead (also handles a real interactive-mode [bool] input, since PowerShell
    # stringifies $true/$false to "True"/"False").
    $isFolder             = "$($InputData['IsFolder'])".Trim() -match '(?i)^(true|yes|y|1)$'
    $allowInternalScripts = "$($InputData['AllowInternalScripts'])".Trim() -match '(?i)^(true|yes|y|1)$'
    $comment              = if ($InputData['Comment']) { "$($InputData['Comment'])".Trim() } else { '' }

    $encodedId = [Uri]::EscapeDataString($appId)

    Write-CyberArkLog -Level 'INFO'  -Message "Starting add auth method ($authType) for App ID: $appId"
    Write-CyberArkLog -Level 'DEBUG' -Message "POST /WebServices/PIMServices.svc/Applications/$appId/Authentications"

    if ($WhatIf.IsPresent) {
        Write-CyberArkLog -Level 'INFO' -Message "WhatIf: POST auth method '$authType' for App '$appId' would be performed."
        $result.Successes++
        $result.ItemsProcessed++
        Add-CyberArkLogSummaryEntry -ModuleName $ModuleMeta.Name -ItemsProcessed $result.ItemsProcessed -Successes $result.Successes -Failures $result.Failures
        return $result
    }

    $authBody = @{ AuthType = $authType }
    if ($isCertAttr) {
        # Wrap in @() at assignment so a single entry still serializes as a JSON array.
        if ($subject.Count -gt 0) { $authBody['Subject']                = @($subject) }
        if ($issuer.Count  -gt 0) { $authBody['Issuer']                 = @($issuer) }
        if ($san.Count     -gt 0) { $authBody['SubjectAlternativeName'] = @($san) }
    } else {
        $authBody['AuthValue'] = $authValue
    }
    if ($authType -eq 'path') {
        $authBody['IsFolder']             = $isFolder
        $authBody['AllowInternalScripts'] = $allowInternalScripts
    }
    if ($comment) { $authBody['Comment'] = $comment }

    $response = Invoke-CyberArkAPI `
        -Token    $Token `
        -Method   'POST' `
        -Endpoint "/WebServices/PIMServices.svc/Applications/$encodedId/Authentications/" `
        -Body     @{ authentication = $authBody } `
        -WhatIf:  $WhatIf.IsPresent

    if (-not $response.IsSuccess) {
        $msg = "Add Auth Method failed (HTTP $($response.StatusCode)): $($response.ErrorMessage)"
        Write-CyberArkLog -Level 'ERROR' -Message $msg
        $result.Errors.Add([PSCustomObject]@{
            InputData    = $InputData
            ErrorMessage = $response.ErrorMessage
            ErrorDetails = $response.ErrorDetails
        })
        $result.Failures++
        $result.ItemsProcessed++
        $result.IsFatal = ($response.StatusCode -in @(401, 0))
        return $result
    }

    $result.Results.Add([PSCustomObject]@{
        AppID    = $appId
        AuthType = $authType
        Status   = 'Added'
    })
    $result.Successes++
    $result.ItemsProcessed++

    Write-CyberArkLog -Level 'INFO' -Message "Add Auth Method complete for App ID: $appId, type: $authType."
    Add-CyberArkLogSummaryEntry -ModuleName $ModuleMeta.Name -ItemsProcessed $result.ItemsProcessed -Successes $result.Successes -Failures $result.Failures
    return $result
}
