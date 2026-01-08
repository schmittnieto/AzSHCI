<#
.Synopsis
   Compresses all the VHDX files from a specified location
.DESCRIPTION
   Compress-Vhdx retrieves each VHDX files from a specified location and compacts each using the native command Optimize-VHD
.EXAMPLE
   Compress-Vhdx -Path "C:\MyVMs" -Recurse
   Compacts all the VHDX files from the specified path, including subfolders
.NOTES
   Last updated on 2021.11.05
#>

#region function definitions
function Compress-Vhdx {
    [CmdletBinding()]
    Param
    (
        # Path to the VHDX files
        [Parameter(ValueFromPipelineByPropertyName,Position=0)]$Path = (Get-Location).Path,

        # Go through subfolders, if selected
        [Parameter(Position=1)][switch]$IncludeSubfolders
    )

    Begin {
        $StartTime = Get-Date
 
        # Search for VHDX files in subfolders?
        if ($IncludeSubfolders) {
            $AllVhdx = Get-ChildItem *.vhdx -Path $Path -Recurse -ErrorAction SilentlyContinue
            }
        else {
            $AllVhdx = Get-ChildItem *.vhdx -Path $Path -ErrorAction SilentlyContinue
            }

        # Are there any VHDX files in the location?
        if ($AllVhdx.Count -lt 1) {
            Write-Warning "There is no VHDX file to compress in `"$Path`". Make sure that the path is correct and it contains VHDX files"
            break
            }
        #Clear-Host
        Write-Verbose "Compacting $($AllVhdx.Count) VHDX files, please wait"
        } #Begin
    
    Process {

        $Stats = foreach ($v in $AllVhdx) {
            
            $OldSize = $v.Length

            try {
                Optimize-VHD -Path $v.FullName -Mode Full -ErrorAction Stop
                Write-Verbose "Compressing $($v.Name)"
                $NewSize = (Get-ChildItem -Path $v.FullName).Length                
                $Saved = $OldSize - $NewSize
                          
                [PSCustomObject] @{
                    #Name = $v.Name
                    Path = $v.FullName
                    "Initial Size [GB]" = [math]::round($OldSize /1Gb, 2)
                    "Current Size [GB]" = [math]::round($NewSize /1Gb, 2)
                    "Saved [GB]" = [math]::round($Saved /1Gb, 2)
                    }
                 }

             catch {
                Write-Verbose "Skipping $($v.Name). File may be in use "
                }   
            
            $TotalSaved += $Saved  

            } #$Stats

        } #Process

    End {
        $Duration = New-TimeSpan -Start $StartTime -End (Get-Date)
        $DurationPretty = $($Duration.Hours).ToString() + "h:" + $($Duration.Minutes).ToString() + "m:" + $($Duration.Seconds).ToString() + "s"
        $Stats | Format-Table -Wrap -AutoSize

        Write-Verbose "The operation completed in $DurationPretty"
        Write-Verbose "Disk space saved: $([math]::round($TotalSaved /1Gb, 2)) GB"
        } #End

}
#endregion function definitions

#region usage example
Compress-Vhdx -Path E:\AzureLocalLab -IncludeSubfolders -Verbose 
#endregion usage example
