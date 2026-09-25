#Requires -Version 5.1

$ModuleMeta = @{
    Name             = 'Export Platform Details'
    Category         = 'Custom'
    Action           = 'ExportPlatformDetails'
    Description      = 'Downloads every active platform (any type) and builds a spreadsheet summarizing each Policy-<id>.ini and Policy-<id>.xml, plus a column listing any bundled files that are not the two policy files (a META-INF folder, if present, is excluded from that list).'
    SupportedSystems = @('ISPSS', 'SelfHosted')
    SupportsWhatIf   = $false
    AcceptsInputFile = $false
    ProducesOutput   = $true
    HasCustomInput   = $false
    InputSchema      = @()
    AutoSaveCsv      = $true
    # No date in the saved filename - matches Custom/ExportAll's own fixed-name convention, so
    # every Custom export tool behaves the same (always the latest snapshot, overwritten on the
    # next run - use automation mode's -FilenameFormat with {Date} for dated snapshots instead).
    CsvFilenameNoDate = $true
    Priority         = 84
    Version          = '1.1.0'
}

function script:ConvertFrom-PlatformIni {
    <#
        Parses a CyberArk platform Policy-<id>.ini file's text into a flat hashtable, one entry
        per setting, keyed "Ini.<Key>" for top-level settings or "Ini.<Section>.<Key>" for
        settings under a [Section] header (e.g. [ExtraInfo]) - this keeps every distinct setting
        addressable as its own spreadsheet column without name collisions between sections.
        Comments (leading ';') and blank lines are skipped; a trailing inline ';comment' on a
        value line is stripped.
    #>
    param([string]$IniText)

    $result  = @{}
    $section = ''

    foreach ($line in ($IniText -split "`r?`n")) {
        $trimmed = $line.Trim()
        if (-not $trimmed -or $trimmed.StartsWith(';')) { continue }

        if ($trimmed -match '^\[(.+)\]$') {
            $section = $Matches[1].Trim()
            continue
        }

        $eqIndex = $trimmed.IndexOf('=')
        if ($eqIndex -lt 0) { continue }

        $key   = $trimmed.Substring(0, $eqIndex).Trim()
        $value = $trimmed.Substring($eqIndex + 1)
        # Strip a trailing inline comment (";..." after the value) - every sample seen uses ';'
        # only as a comment marker, never as literal value content.
        $commentIndex = $value.IndexOf(';')
        if ($commentIndex -ge 0) { $value = $value.Substring(0, $commentIndex) }
        $value = $value.Trim()

        if (-not $key) { continue }
        $columnName = if ($section) { "Ini.$section.$key" } else { "Ini.$key" }
        $result[$columnName] = $value
    }

    return $result
}

function script:ConvertFrom-PlatformXml {
    <#
        Parses a CyberArk platform Policy-<id>.xml file's text into a flat hashtable, one entry
        per column, keyed "Xml.<Field>". Uses XPath (SelectNodes/SelectSingleNode) throughout,
        never direct property/attribute dot-access - an XML element that occurs exactly once
        becomes a scalar (not a one-element array) under PowerShell's XML adapter, and a missing
        attribute can throw under Set-StrictMode via dot notation, both of which XPath avoids
        (see Claude_Docs\Reference_Lessons-Learned-PowerShell.md Section 17).

        The deeply-nested OnDemandPrivilegesManager/CommandsGroups structure (Unix-type platforms
        only) is summarized as a single command count rather than fully flattened - expanding it
        would add potentially hundreds of one-off columns unique to a handful of platforms.
    #>
    param([string]$XmlText)

    $result = @{}
    try {
        [xml]$doc = $XmlText
    } catch {
        return $result
    }

    $policy = $doc.SelectSingleNode('//Policy')
    if (-not $policy) { return $result }

    $result['Xml.PolicyID']            = $policy.GetAttribute('ID')
    $result['Xml.AutoChangeOnAdd']     = $policy.GetAttribute('AutoChangeOnAdd')
    $result['Xml.AutoVerifyOnAdd']     = $policy.GetAttribute('AutoVerifyOnAdd')
    $result['Xml.PlatformBaseID']      = $policy.GetAttribute('PlatformBaseID')
    $result['Xml.PlatformBaseType']    = $policy.GetAttribute('PlatformBaseType')
    $result['Xml.PlatformBaseProtocol'] = $policy.GetAttribute('PlatformBaseProtocol')

    $requiredProps = @($policy.SelectNodes('.//Properties/Required/Property') | ForEach-Object { $_.GetAttribute('Name') })
    $optionalProps = @($policy.SelectNodes('.//Properties/Optional/Property')  | ForEach-Object { $_.GetAttribute('Name') })
    $result['Xml.RequiredProperties'] = $requiredProps -join ';'
    $result['Xml.OptionalProperties'] = $optionalProps -join ';'

    $linkedPasswords = @($policy.SelectNodes('.//LinkedPasswords/Link') | ForEach-Object {
        "$($_.GetAttribute('Name'))=$($_.GetAttribute('PropertyIndex'))"
    })
    $result['Xml.LinkedPasswords'] = $linkedPasswords -join ';'

    $usages = @($policy.SelectNodes('.//Usages/Usage') | ForEach-Object { $_.GetAttribute('Name') })
    $result['Xml.Usages'] = $usages -join ';'

    $ticketing = $policy.SelectSingleNode('.//TicketingSystem')
    if ($ticketing) {
        $result['Xml.TicketingEnterTicketingInfo']  = $ticketing.GetAttribute('EnterTicketingInfo')
        $result['Xml.TicketingValidateTicketNumber'] = $ticketing.GetAttribute('ValidateTicketNumber')
    }

    $psm = $policy.SelectSingleNode('.//PrivilegedSessionManagement')
    if ($psm) {
        $result['Xml.PSMEnable']   = $psm.GetAttribute('Enable')
        $result['Xml.PSMServerID'] = $psm.GetAttribute('ID')
    }

    $components = @($policy.SelectNodes('.//ConnectionComponents/ConnectionComponent') | ForEach-Object {
        $id = $_.GetAttribute('Id')
        if ($_.GetAttribute('Enable') -eq 'No') { "$id[disabled]" } else { $id }
    })
    $result['Xml.ConnectionComponents'] = $components -join ';'

    $commandCount = @($policy.SelectNodes('.//OnDemandPrivilegesManager//Command')).Count
    if ($commandCount -gt 0) { $result['Xml.OnDemandPrivilegesManagerCommandCount'] = "$commandCount" }

    return $result
}

function script:Get-PlatformListField {
    <#
        Reads a field from a /API/Platforms list entry. Fields live under a "general"
        sub-object on this endpoint (confirmed live) - falls back to a root-level field
        defensively, matching Invoke-PlatformsGet.ps1's own established multi-shape pattern.
    #>
    param($Platform, [string]$Field)
    if ($Platform.PSObject.Properties['general'] -and $Platform.general.PSObject.Properties[$Field]) {
        return $Platform.general.$Field
    } elseif ($Platform.PSObject.Properties[$Field]) {
        return $Platform.$Field
    }
    return $null
}

function script:Get-PlatformZipOtherFiles {
    <#
        Returns a semicolon-joined list of every file in the zip that is NOT one of the two
        expected Policy-<id>.ini/.xml files, excluding anything under a META-INF folder and
        excluding bare directory entries. Per user direction: "the meta-inf folder can be
        excluded as well."
    #>
    param(
        [System.IO.Compression.ZipArchive]$Zip,
        [string]$IniName,
        [string]$XmlName
    )

    $others = @($Zip.Entries | Where-Object {
        $_.Name -and                                                              # not a bare directory entry
        $_.FullName -notlike 'META-INF/*' -and $_.FullName -notlike 'META-INF\*' -and
        $_.FullName -ne $IniName -and $_.FullName -ne $XmlName
    } | ForEach-Object { $_.FullName })

    return ($others -join ';')
}

function Invoke-CustomExportPlatformDetails {
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

    Write-CyberArkLog -Level 'INFO' -Message 'Starting Export Platform Details.'

    $listResponse = Invoke-CyberArkAPI -Token $Token -Method 'GET' -Endpoint '/API/Platforms'
    if (-not $listResponse.IsSuccess) {
        $msg = "Platform list failed (HTTP $($listResponse.StatusCode)): $($listResponse.ErrorMessage)"
        Write-CyberArkLog -Level 'ERROR' -Message $msg
        $result.Errors.Add([PSCustomObject]@{ InputData = $InputData; ErrorMessage = $msg; ErrorDetails = $listResponse.ErrorDetails })
        $result.Failures++
        $result.ItemsProcessed++
        $result.IsFatal = ($listResponse.StatusCode -in @(401, 0))
        return $result
    }

    # Same multi-shape fallback other Platforms modules already use for this endpoint.
    [array]$allPlatforms = if ($listResponse.Data -and $listResponse.Data.PSObject.Properties['Platforms']) {
        @($listResponse.Data.Platforms)
    } elseif ($listResponse.Data) {
        @($listResponse.Data)
    } else {
        @()
    }

    $activePlatforms = @($allPlatforms | Where-Object { [bool](script:Get-PlatformListField -Platform $_ -Field 'active') })
    Write-CyberArkLog -Level 'INFO' -Message "Found $($allPlatforms.Count) platform(s), $($activePlatforms.Count) active."

    if ($activePlatforms.Count -eq 0) {
        Add-CyberArkLogSummaryEntry -ModuleName $ModuleMeta.Name -ItemsProcessed 0 -Successes 0 -Failures 0
        return $result
    }

    Add-Type -AssemblyName System.IO.Compression -ErrorAction SilentlyContinue

    # Per-platform data is collected as hashtables first, then reconciled into a single, uniform
    # column set (the union of every Ini.*/Xml.* key seen across all platforms) once every
    # platform has been processed - Export-Csv needs the same properties on every row.
    $rows        = [System.Collections.Generic.List[hashtable]]::new()
    $dynamicCols = [System.Collections.Generic.List[string]]::new()

    foreach ($platform in $activePlatforms) {
        $platformId   = script:Get-PlatformListField -Platform $platform -Field 'id'
        $platformType = script:Get-PlatformListField -Platform $platform -Field 'platformType'
        $result.ItemsProcessed++

        if (-not $platformId) {
            $msg = 'A platform in the list had no id/PlatformID field - skipped.'
            Write-CyberArkLog -Level 'WARN' -Message $msg
            $result.Errors.Add([PSCustomObject]@{ InputData = $null; ErrorMessage = $msg; ErrorDetails = $null })
            $result.Failures++
            continue
        }

        Write-CyberArkLog -Level 'DEBUG' -Message "Exporting platform '$platformId' for detail extraction."
        $exportResponse = Invoke-CyberArkAPI -Token $Token -Method 'POST' `
            -Endpoint "/API/Platforms/$([Uri]::EscapeDataString($platformId))/Export" `
            -QueryParams @{ platformID = $platformId }

        if (-not $exportResponse.IsSuccess -or $exportResponse.DataType -ne 'File' -or -not $exportResponse.Data) {
            # Non-fatal per-platform failure (confirmed live that some platforms can 500 on
            # export) - record and continue with the rest rather than aborting the whole batch.
            $msg = "Export failed for platform '$platformId' (HTTP $($exportResponse.StatusCode)): $($exportResponse.ErrorMessage)"
            Write-CyberArkLog -Level 'WARN' -Message $msg
            $result.Errors.Add([PSCustomObject]@{ InputData = @{ PlatformID = $platformId }; ErrorMessage = $msg; ErrorDetails = $exportResponse.ErrorDetails })
            $result.Failures++
            continue
        }

        $row = @{
            PlatformID   = $platformId
            PlatformType = "$platformType"
            Active       = $true
        }

        # $ms/$zip/$reader are pre-declared $null so the single finally below can safely check
        # "if ($x)" even if construction itself throws partway through (e.g. a corrupt zip) -
        # referencing a variable that was never assigned at all throws under Set-StrictMode.
        $ms     = $null
        $zip    = $null
        $reader = $null
        try {
            $ms  = New-Object System.IO.MemoryStream(, [byte[]]$exportResponse.Data)
            $zip = New-Object System.IO.Compression.ZipArchive($ms, [System.IO.Compression.ZipArchiveMode]::Read)

            $iniEntry = $zip.Entries | Where-Object { $_.Name -eq "Policy-$platformId.ini" } | Select-Object -First 1
            $xmlEntry = $zip.Entries | Where-Object { $_.Name -eq "Policy-$platformId.xml" } | Select-Object -First 1

            if ($iniEntry) {
                $reader = New-Object System.IO.StreamReader($iniEntry.Open())
                $iniFields = script:ConvertFrom-PlatformIni -IniText $reader.ReadToEnd()
                $reader.Dispose(); $reader = $null
                foreach ($k in $iniFields.Keys) {
                    $row[$k] = $iniFields[$k]
                    if (-not $dynamicCols.Contains($k)) { $dynamicCols.Add($k) }
                }
            } else {
                Write-CyberArkLog -Level 'WARN' -Message "Platform '$platformId': no Policy-$platformId.ini found in the export."
            }

            if ($xmlEntry) {
                $reader = New-Object System.IO.StreamReader($xmlEntry.Open())
                $xmlFields = script:ConvertFrom-PlatformXml -XmlText $reader.ReadToEnd()
                $reader.Dispose(); $reader = $null
                foreach ($k in $xmlFields.Keys) {
                    $row[$k] = $xmlFields[$k]
                    if (-not $dynamicCols.Contains($k)) { $dynamicCols.Add($k) }
                }
            } else {
                Write-CyberArkLog -Level 'WARN' -Message "Platform '$platformId': no Policy-$platformId.xml found in the export."
            }

            $iniName = if ($iniEntry) { $iniEntry.FullName } else { "Policy-$platformId.ini" }
            $xmlName = if ($xmlEntry) { $xmlEntry.FullName } else { "Policy-$platformId.xml" }
            $row['OtherFiles'] = script:Get-PlatformZipOtherFiles -Zip $zip -IniName $iniName -XmlName $xmlName
        } finally {
            if ($reader) { $reader.Dispose() }
            if ($zip)    { $zip.Dispose() }
            if ($ms)     { $ms.Dispose() }
        }

        $rows.Add($row)
        $result.Successes++
    }

    # Build the final, uniform-column rows now that every dynamic Ini.*/Xml.* key seen across
    # all platforms is known - a column a given platform doesn't have is left blank on its row.
    $sortedDynamicCols = $dynamicCols | Sort-Object
    foreach ($row in $rows) {
        $ordered = [ordered]@{
            PlatformID   = $row['PlatformID']
            PlatformType = $row['PlatformType']
            Active       = $row['Active']
        }
        foreach ($col in $sortedDynamicCols) {
            $ordered[$col] = if ($row.ContainsKey($col)) { $row[$col] } else { '' }
        }
        $ordered['OtherFiles'] = $row['OtherFiles']
        $result.Results.Add([PSCustomObject]$ordered)
    }

    Write-CyberArkLog -Level 'INFO' -Message "Export Platform Details complete. Platforms processed: $($result.ItemsProcessed), succeeded: $($result.Successes), failed: $($result.Failures)."

    Add-CyberArkLogSummaryEntry -ModuleName $ModuleMeta.Name -ItemsProcessed $result.ItemsProcessed -Successes $result.Successes -Failures $result.Failures

    return $result
}
