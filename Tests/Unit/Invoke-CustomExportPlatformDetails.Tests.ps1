#Requires -Version 5.1
<#
.SYNOPSIS
    Pester v6 unit tests for APIModules\Custom\Invoke-CustomExportPlatformDetails.ps1.
    No CyberArk connection required - Invoke-CyberArkAPI is fully mocked, but the mocked
    export responses contain real, in-memory-built .zip archives so the actual zip-extraction
    and INI/XML parsing logic is exercised end-to-end, not just the surrounding plumbing.
#>

BeforeAll {
    $script:LoggingPath = Join-Path $PSScriptRoot '..\..\Modules\CyberArkLogging.psm1'
    $script:CommsPath   = Join-Path $PSScriptRoot '..\..\Modules\CyberArkComms.psm1'
    $script:ModulePath  = Join-Path $PSScriptRoot '..\..\APIModules\Custom\Invoke-CustomExportPlatformDetails.ps1'

    Import-Module $script:LoggingPath -Force -ErrorAction Stop
    Import-Module $script:CommsPath   -Force -ErrorAction Stop

    . $script:ModulePath

    Initialize-CyberArkLog -Destination 'Console' -ProfileName 'ExportPlatformDetailsTests' -MinLevel 'ERROR'

    $script:MockToken = [PSCustomObject]@{
        Token      = 'mock-token'
        TokenType  = 'Bearer'
        Headers    = @{ Authorization = 'Bearer mock-token'; 'Content-Type' = 'application/json' }
        Expiry     = (Get-Date).AddHours(1).ToUniversalTime()
        SystemType = 'SelfHosted'
        AuthMethod = 'CyberArk'
        BaseURL    = 'https://pvwa.company.com/PasswordVault'
    }

    Add-Type -AssemblyName System.IO.Compression -ErrorAction SilentlyContinue

    function script:New-TestPlatformZipBytes {
        <#
            Builds a real, in-memory .zip (as psPAS/CyberArk actually ship one) containing
            Policy-<id>.ini, Policy-<id>.xml, and any extra entries requested - so tests exercise
            the module's real zip-extraction path, not a shortcut around it.
        #>
        param(
            [string]$PlatformId,
            [string]$IniText,
            [string]$XmlText,
            [hashtable]$ExtraEntries = @{}   # entryPath -> content
        )
        $ms  = New-Object System.IO.MemoryStream
        $zip = New-Object System.IO.Compression.ZipArchive($ms, [System.IO.Compression.ZipArchiveMode]::Create, $true)
        try {
            $writeEntry = {
                param($Name, $Content)
                $entry  = $zip.CreateEntry($Name)
                $stream = $entry.Open()
                $writer = New-Object System.IO.StreamWriter($stream)
                $writer.Write($Content)
                $writer.Dispose()
                $stream.Dispose()
            }
            & $writeEntry "Policy-$PlatformId.ini" $IniText
            & $writeEntry "Policy-$PlatformId.xml" $XmlText
            foreach ($path in $ExtraEntries.Keys) { & $writeEntry $path $ExtraEntries[$path] }
        } finally {
            $zip.Dispose()
        }
        return $ms.ToArray()
    }

    function script:New-TestPlatformListEntry {
        param([string]$Id, [bool]$Active, [string]$PlatformType = 'regular')
        [PSCustomObject]@{
            general = [PSCustomObject]@{ id = $Id; active = $Active; platformType = $PlatformType; name = $Id }
        }
    }

    $script:SampleIni = @"
; comment line, ignored
PolicyID=SamplePlatform                 ;Mandatory
PolicyName=Sample Platform
Timeout=90                          ;In Seconds

[ExtraInfo]
Port=22
PluginName=Sample Plugin
"@

    $script:SampleXml = @'
<?xml version="1.0" encoding="utf-8"?><Device Name="Operating System"><Policies><Policy ID="SamplePlatform" AutoChangeOnAdd="No" AutoVerifyOnAdd="No" PlatformBaseID="SamplePlatform" PlatformBaseType="Unix" PlatformBaseProtocol="SSH">
  <Properties>
    <Required><Property Name="Address" /><Property Name="Username" /></Required>
    <Optional><Property Name="Port" /></Optional>
  </Properties>
  <LinkedPasswords><Link Name="LogonAccount" PropertyIndex="1" /></LinkedPasswords>
  <Usages><Usage Name="PrivateSSHKey" /></Usages>
  <ConnectionComponents><ConnectionComponent Id="PSM-SSH" /><ConnectionComponent Id="PuTTY" Enable="No" /></ConnectionComponents>
</Policy></Policies></Device>
'@
}

AfterAll {
    Close-CyberArkLog -ErrorAction SilentlyContinue
}

Describe 'ModuleMeta' {
    It 'PPD01 - Name/Category/Action are correct' {
        $ModuleMeta.Name     | Should -Be 'Export Platform Details'
        $ModuleMeta.Category | Should -Be 'Custom'
        $ModuleMeta.Action   | Should -Be 'ExportPlatformDetails'
    }
    It 'PPD02 - AutoSaveCsv=$true, HasCustomInput=$false, SupportsWhatIf=$false' {
        $ModuleMeta.AutoSaveCsv    | Should -BeTrue
        $ModuleMeta.HasCustomInput | Should -BeFalse
        $ModuleMeta.SupportsWhatIf | Should -BeFalse
    }
    It 'PPD12 - CsvFilenameNoDate is true (matches Custom/ExportAll''s fixed-name convention)' {
        $ModuleMeta.CsvFilenameNoDate | Should -BeTrue
    }
}

Describe 'Invoke-CustomExportPlatformDetails - success' {

    BeforeEach {
        Mock Write-CyberArkLog { }
        Mock Add-CyberArkLogSummaryEntry { }
    }

    It 'PPD03 - only active platforms are exported; inactive ones are skipped entirely' {
        $zipBytes = script:New-TestPlatformZipBytes -PlatformId 'ActiveOne' -IniText $script:SampleIni -XmlText $script:SampleXml
        Mock Invoke-CyberArkAPI {
            param($Method, $Endpoint)
            if ($Method -eq 'GET') {
                [PSCustomObject]@{ IsSuccess = $true; StatusCode = 200; Data = [PSCustomObject]@{ Platforms = @(
                    script:New-TestPlatformListEntry -Id 'ActiveOne' -Active $true
                    script:New-TestPlatformListEntry -Id 'InactiveOne' -Active $false
                ) } }
            } else {
                [PSCustomObject]@{ IsSuccess = $true; StatusCode = 200; DataType = 'File'; Data = $zipBytes; SuggestedFileName = 'ActiveOne.zip' }
            }
        }
        $r = Invoke-CustomExportPlatformDetails -Token $script:MockToken -InputData @{}
        $r.ItemsProcessed | Should -Be 1
        $r.Successes      | Should -Be 1
        $r.Results.Count  | Should -Be 1
        $r.Results[0].PlatformID | Should -Be 'ActiveOne'
        Should -Invoke Invoke-CyberArkAPI -Times 1 -ParameterFilter { $Method -eq 'POST' }
    }

    It 'PPD04 - INI top-level and [ExtraInfo]-section settings are both parsed into their own columns' {
        $zipBytes = script:New-TestPlatformZipBytes -PlatformId 'P1' -IniText $script:SampleIni -XmlText $script:SampleXml
        Mock Invoke-CyberArkAPI {
            param($Method)
            if ($Method -eq 'GET') { [PSCustomObject]@{ IsSuccess = $true; StatusCode = 200; Data = [PSCustomObject]@{ Platforms = @(script:New-TestPlatformListEntry -Id 'P1' -Active $true) } } }
            else { [PSCustomObject]@{ IsSuccess = $true; StatusCode = 200; DataType = 'File'; Data = $zipBytes; SuggestedFileName = $null } }
        }
        $r = Invoke-CustomExportPlatformDetails -Token $script:MockToken -InputData @{}
        $row = $r.Results[0]
        $row.'Ini.PolicyID'          | Should -Be 'SamplePlatform'
        $row.'Ini.Timeout'           | Should -Be '90'
        $row.'Ini.ExtraInfo.Port'    | Should -Be '22'
        $row.'Ini.ExtraInfo.PluginName' | Should -Be 'Sample Plugin'
    }

    It 'PPD05 - XML fields (PlatformBase*, RequiredProperties, ConnectionComponents with disabled marker) are parsed' {
        $zipBytes = script:New-TestPlatformZipBytes -PlatformId 'P1' -IniText $script:SampleIni -XmlText $script:SampleXml
        Mock Invoke-CyberArkAPI {
            param($Method)
            if ($Method -eq 'GET') { [PSCustomObject]@{ IsSuccess = $true; StatusCode = 200; Data = [PSCustomObject]@{ Platforms = @(script:New-TestPlatformListEntry -Id 'P1' -Active $true) } } }
            else { [PSCustomObject]@{ IsSuccess = $true; StatusCode = 200; DataType = 'File'; Data = $zipBytes; SuggestedFileName = $null } }
        }
        $r = Invoke-CustomExportPlatformDetails -Token $script:MockToken -InputData @{}
        $row = $r.Results[0]
        $row.'Xml.PlatformBaseID'       | Should -Be 'SamplePlatform'
        $row.'Xml.PlatformBaseType'     | Should -Be 'Unix'
        $row.'Xml.PlatformBaseProtocol' | Should -Be 'SSH'
        $row.'Xml.RequiredProperties'   | Should -Be 'Address;Username'
        $row.'Xml.ConnectionComponents' | Should -Be 'PSM-SSH;PuTTY[disabled]'
    }

    It 'PPD06 - OtherFiles lists extra bundled files, excluding META-INF and the two policy files themselves' {
        $zipBytes = script:New-TestPlatformZipBytes -PlatformId 'P1' -IniText $script:SampleIni -XmlText $script:SampleXml -ExtraEntries @{
            'icon.png'                 = 'fake-binary-content'
            'README.txt'                = 'notes'
            'META-INF/MANIFEST.MF'      = 'manifest content'
        }
        Mock Invoke-CyberArkAPI {
            param($Method)
            if ($Method -eq 'GET') { [PSCustomObject]@{ IsSuccess = $true; StatusCode = 200; Data = [PSCustomObject]@{ Platforms = @(script:New-TestPlatformListEntry -Id 'P1' -Active $true) } } }
            else { [PSCustomObject]@{ IsSuccess = $true; StatusCode = 200; DataType = 'File'; Data = $zipBytes; SuggestedFileName = $null } }
        }
        $r = Invoke-CustomExportPlatformDetails -Token $script:MockToken -InputData @{}
        $otherFiles = $r.Results[0].OtherFiles -split ';'
        $otherFiles | Should -Contain 'icon.png'
        $otherFiles | Should -Contain 'README.txt'
        $otherFiles | Should -Not -Contain 'META-INF/MANIFEST.MF'
        ($otherFiles | Where-Object { $_ -like 'META-INF*' }) | Should -BeNullOrEmpty
    }

    It 'PPD07 - a platform with no extra files gets an empty OtherFiles value' {
        $zipBytes = script:New-TestPlatformZipBytes -PlatformId 'P1' -IniText $script:SampleIni -XmlText $script:SampleXml
        Mock Invoke-CyberArkAPI {
            param($Method)
            if ($Method -eq 'GET') { [PSCustomObject]@{ IsSuccess = $true; StatusCode = 200; Data = [PSCustomObject]@{ Platforms = @(script:New-TestPlatformListEntry -Id 'P1' -Active $true) } } }
            else { [PSCustomObject]@{ IsSuccess = $true; StatusCode = 200; DataType = 'File'; Data = $zipBytes; SuggestedFileName = $null } }
        }
        $r = Invoke-CustomExportPlatformDetails -Token $script:MockToken -InputData @{}
        $r.Results[0].OtherFiles | Should -BeNullOrEmpty
    }

    It 'PPD08 - columns are a union across platforms: a setting only one platform has is blank (not missing/erroring) on the others' {
        # Insert KeySize before the [ExtraInfo] header so it lands as a top-level "Ini.KeySize"
        # column (not "Ini.ExtraInfo.KeySize") - the sample INI's last section stays open otherwise.
        $iniWithKeySize = $script:SampleIni -replace '(?m)^\[ExtraInfo\]', "KeySize=2048`n`n[ExtraInfo]"
        $iniPlain       = $script:SampleIni
        $zipA = script:New-TestPlatformZipBytes -PlatformId 'HasKeySize' -IniText $iniWithKeySize -XmlText $script:SampleXml
        $zipB = script:New-TestPlatformZipBytes -PlatformId 'NoKeySize'  -IniText $iniPlain       -XmlText $script:SampleXml
        Mock Invoke-CyberArkAPI {
            param($Method, $Endpoint)
            if ($Method -eq 'GET') {
                [PSCustomObject]@{ IsSuccess = $true; StatusCode = 200; Data = [PSCustomObject]@{ Platforms = @(
                    script:New-TestPlatformListEntry -Id 'HasKeySize' -Active $true
                    script:New-TestPlatformListEntry -Id 'NoKeySize'  -Active $true
                ) } }
            } elseif ($Endpoint -like '*HasKeySize*') {
                [PSCustomObject]@{ IsSuccess = $true; StatusCode = 200; DataType = 'File'; Data = $zipA; SuggestedFileName = $null }
            } else {
                [PSCustomObject]@{ IsSuccess = $true; StatusCode = 200; DataType = 'File'; Data = $zipB; SuggestedFileName = $null }
            }
        }
        $r = Invoke-CustomExportPlatformDetails -Token $script:MockToken -InputData @{}
        $r.Results.Count | Should -Be 2
        ($r.Results | Where-Object { $_.PlatformID -eq 'HasKeySize' }).'Ini.KeySize' | Should -Be '2048'
        ($r.Results | Where-Object { $_.PlatformID -eq 'NoKeySize' }).'Ini.KeySize'  | Should -Be ''
        # Both rows must have the exact same set of columns for Export-Csv to work correctly.
        $colsA = ($r.Results | Where-Object { $_.PlatformID -eq 'HasKeySize' })[0].PSObject.Properties.Name
        $colsB = ($r.Results | Where-Object { $_.PlatformID -eq 'NoKeySize' })[0].PSObject.Properties.Name
        Compare-Object $colsA $colsB | Should -BeNullOrEmpty
    }
}

Describe 'Invoke-CustomExportPlatformDetails - errors' {

    BeforeEach {
        Mock Write-CyberArkLog { }
        Mock Add-CyberArkLogSummaryEntry { }
    }

    It 'PPD09 - Platforms/List failing entirely is a Failure (IsFatal on 401)' {
        Mock Invoke-CyberArkAPI { [PSCustomObject]@{ IsSuccess = $false; StatusCode = 401; ErrorMessage = 'Unauthorized'; ErrorDetails = $null } }
        $r = Invoke-CustomExportPlatformDetails -Token $script:MockToken -InputData @{}
        $r.Failures | Should -Be 1
        $r.IsFatal  | Should -BeTrue
    }

    It 'PPD10 - one platform failing to export (e.g. 500) is recorded as a non-fatal Failure; other platforms still succeed' {
        $zipBytes = script:New-TestPlatformZipBytes -PlatformId 'GoodOne' -IniText $script:SampleIni -XmlText $script:SampleXml
        Mock Invoke-CyberArkAPI {
            param($Method, $Endpoint)
            if ($Method -eq 'GET') {
                [PSCustomObject]@{ IsSuccess = $true; StatusCode = 200; Data = [PSCustomObject]@{ Platforms = @(
                    script:New-TestPlatformListEntry -Id 'BadOne'  -Active $true
                    script:New-TestPlatformListEntry -Id 'GoodOne' -Active $true
                ) } }
            } elseif ($Endpoint -like '*BadOne*') {
                [PSCustomObject]@{ IsSuccess = $false; StatusCode = 500; ErrorMessage = 'Server Error'; ErrorDetails = $null }
            } else {
                [PSCustomObject]@{ IsSuccess = $true; StatusCode = 200; DataType = 'File'; Data = $zipBytes; SuggestedFileName = $null }
            }
        }
        $r = Invoke-CustomExportPlatformDetails -Token $script:MockToken -InputData @{}
        $r.ItemsProcessed | Should -Be 2
        $r.Successes      | Should -Be 1
        $r.Failures       | Should -Be 1
        $r.IsFatal        | Should -BeFalse
        $r.Results.Count  | Should -Be 1
        $r.Results[0].PlatformID | Should -Be 'GoodOne'
    }

    It 'PPD11 - no active platforms at all: Successes=0, Failures=0, empty Results, no crash' {
        Mock Invoke-CyberArkAPI {
            [PSCustomObject]@{ IsSuccess = $true; StatusCode = 200; Data = [PSCustomObject]@{ Platforms = @(
                script:New-TestPlatformListEntry -Id 'InactiveOnly' -Active $false
            ) } }
        }
        $r = Invoke-CustomExportPlatformDetails -Token $script:MockToken -InputData @{}
        $r.Successes     | Should -Be 0
        $r.Failures      | Should -Be 0
        $r.Results.Count | Should -Be 0
        Should -Invoke Invoke-CyberArkAPI -Times 1 -ParameterFilter { $Method -eq 'GET' }
    }
}
