using namespace System
using namespace System.IO
using namespace System.Net
using namespace System.Collections.Generic

Function Sync-LrListItems {
    <#
    .SYNOPSIS
        Synchronizes the provided value(s) to the specified list from LogRhythm.
    .DESCRIPTION
        New items from the provided value(s) are added to the specifified list.

        Items that exist on the provided value(s) and in the specified list are unchanged.

        Items that are not provided in the value(s) are removed from the specified list.
    .PARAMETER Name
        [System.String] (Name or Guid) or [System.Guid]
        Specifies a LogRhythm list object by providing one of the following property values:
          + List Name (as System.String), e.g. "LogRhythm: Suspicious Hosts"
          + List Guid (as System.String or System.Guid), e.g. D378A76F-1D83-4714-9A7C-FC04F9A2EB13
    .PARAMETER Value
        The value to be added to the specified LogRhythm List Identity.
    .PARAMETER ItemType
        For use with Lists that support multiple item types.  Add-LrListItem will attempt to auto-define
        this value.  This parameter enables setting the ItemType.
    .INPUTS

    .OUTPUTS
        PSCustomObject representing the specified LogRhythm List.

        If a Value parameter error is identified, a PSCustomObject is returned providing details
        associated to the error.
    .EXAMPLE

    .NOTES
        LogRhythm-API        
    .LINK
        https://github.com/LogRhythm-Tools/LogRhythm.Tools
    #>

    [CmdletBinding()]
    Param(
        [Parameter(Mandatory = $true, Position = 0)]
        [ValidateNotNull()]
        [object] $Name,

        
        [Parameter(Mandatory = $false, ValueFromPipeline = $true, Position = 1)]
        [string[]] $Value,


        [Parameter(Mandatory = $false, Position = 2)]
        [string] $ItemType,


        [Parameter(Mandatory = $false, Position = 3)]
        [string] $UseContext,


        [Parameter(Mandatory = $false, Position = 4)]
        [ValidateNotNull()]
        [pscredential] $Credential = $LrtConfig.LogRhythm.ApiKey
    )
                                                                   
    Begin {
        # Check preference requirements for self-signed certificates and set enforcement for Tls1.2 
        Enable-TrustAllCertsPolicy
    }

    Process {
        # Establish General Error object Output
        $ErrorObject = [PSCustomObject]@{
            Error                 =   $false
            Value                 =   $Value
            Note                  =   $null
            ListGuid              =   $null
            ListName              =   $null
            FieldType             =   $null
        }

        # Process Name
        if (($Name.GetType() -eq [System.Guid]) -Or (Test-Guid $Name)) {
            $Guid = $Name.ToString()
            $ErrorObject.ListName = (Get-LrList -Name $Guid | Select-Object -ExpandProperty Name)
            $ErrorObject.ListGuid = $Guid
        } else {
            $Guid = Get-LRListGuidByName -Name $Name.ToString() -Exact
            if ($Guid -is [array]) {
                throw [Exception] "Get-LrListGuidbyName returned an array of GUID.  Provide specific List Name."
            } else {
                $LrListDetails = Get-LrList -Name $Guid
                $LrListType = $LrListDetails.ListType
                $ErrorObject.ListName = $Name.ToString()
                $ErrorObject.ListGuid = $Guid
            }
        }

        if ($($ErrorObject.ListGuid) -or $($ErrorObject.ListName)) {
            Write-Host "$(Get-TimeStamp) - Retrieving List Values for: $($ErrorObject.ListName)"
            $ListValues = Get-LrListItems -Name $ErrorObject.ListName -ValuesOnly
            if ($Value.Count -ge 1 -And $ListValues.Count -ge 1) {
                Write-Host "$(Get-TimeStamp) - Number of ListValues: $($ListValues.Count) - Number of Values: $($Value.Count)"
                #$ComparisonResults = Compare-Object $Value $ListValues
                $ComparisonResults = Compare-StringArrays $Value $ListValues -Unsorted
                Write-Host "$(Get-TimeStamp) - Comparison Complete"
                $RemoveList = $ComparisonResults | Where-Object SideIndicator -eq "=>" | Select-Object -ExpandProperty InputObject
                Write-Verbose "$(Get-TimeStamp) - RemoveList Count: $($RemoveList.Count)"
                $AddList = $ComparisonResults | Where-Object SideIndicator -eq "<=" | Select-Object -ExpandProperty InputObject
                Write-Verbose "$(Get-TimeStamp) - AddList Count: $($AddList.Count)"
            } elseif ($Value.Count -eq 0 -And $ListValues.Count -ge 1) {
                $RemoveList = $ListValues
            } else {
                $AddList = $Value
            }


            # Bulk remove of the RemoveList items
            if ($RemoveList) {
                Write-Host "$(Get-TimeStamp) - Remove Count: $($RemoveList.Count)"
                # For large number of removals, break the additions into 10,000 items per API call
                if ($RemoveList.Count -ge 1000) {
                    Write-Host "$(Get-TimeStamp) - Enter Removal Segmentation"
                    $SegmentCount = ([Math]::Round(($($RemoveList.Count) / 1000), 0)) + 1
                    $SegmentedRemoveList = Create-LrPsArraySegments -InputArray $RemoveList -Segments $SegmentCount
                    foreach ($RemoveArray in $SegmentedRemoveList) {
                        Write-Verbose "$(Get-TimeStamp) - Submitting $($RemoveArray.count)"
                        Try {
                            Remove-LrListItem -name $ErrorObject.ListName -Value $RemoveArray -ItemType $ItemType | Out-Null
                        } Catch {
                            Write-Host "$(Get-TimeStamp) - Failed to submit entries.  Entry Dump:"
                            Write-Host "$RemoveArray"
                        }
                        start-sleep .2
                    }
                    $RemovalResults = "$(Get-TimeStamp) - Removal Summary - List: $($ErrorObject.ListName) Quantity: $($RemoveList.Count)"
                } else {
                    if ($ItemType) {
                        $RemovalResults = Remove-LrListItem -name $ErrorObject.ListName -Value $RemoveList -ItemType $ItemType
                    } else {
                        $RemovalResults = Remove-LrListItem -name $ErrorObject.ListName -Value $RemoveList
                    } 
                }
            }

            # Bulk addition of the AddList items
            if ($AddList) {
                Write-Host "$(Get-TimeStamp) - Addition Count: $($AddList.Count)"
                # For large number of additions, break the additions into 10,000 items per API call
                if ($AddList.Count -ge 1000) {
                    Write-Verbose "$(Get-TimeStamp) - Enter Addition Segmentation"
                    $SegmentCount = ([Math]::Round(($($AddList.Count) / 1000), 0)) +1
                    $SegmentedAddList = Create-LrPsArraySegments -InputArray $AddList -Segments $SegmentCount
                    foreach ($AddArray in $SegmentedAddList) {
                        Write-Verbose "$(Get-TimeStamp) - Submitting $($AddArray.count)"
                        Try {
                            Add-LrListItem -name $ErrorObject.ListName -Value $AddArray -ItemType $ItemType | Out-Null
                        } Catch {
                            Write-Host "$(Get-TimeStamp) - Failed to submit entries.  Entry Dump:"
                            Write-Host "$AddArray"
                        }
                        start-sleep .2
                    }
                    $RemovalResults = "$(Get-TimeStamp) - Addition Summary - List: $($ErrorObject.ListName) Quantity: $($AddList.Count)"
                } else {
                    if ($ItemType) {
                        $AdditionResults = Add-LrListItem -Name $ErrorObject.ListName -Value $AddList -ItemType $ItemType
                    } else {
                        $AdditionResults = Add-LrListItem -Name $ErrorObject.ListName -Value $AddList
                    }
                }
            }
            $Results = @($RemovalResults, $AdditionResults)
        }
        return $Results
    }
    
    End { }
}