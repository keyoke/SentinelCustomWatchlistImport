#Requires -Version 7

# Service limits which may change over time
$MAX_FIELD_LIMIT = 49
$MAX_JSON_PAYLOAD_SIZE_MB = 25 # Theoretical Maximum supported value is 30MB
$MAX_JSON_FIELD_VALUE_SIZE_KB = 32

function Import-Watchlist
{
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, ValueFromPipeline = $true)]
        [ValidateNotNullOrEmpty()]
        [String] $FileContents,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [String] $FileContentSHA256,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [String] $WatchlistName,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [String] $WorkspaceId,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [String] $WorkspaceSharedKey
    )

    #optimzation for running non-interactively
    $progressPreference = 'silentlyContinue'

    Write-Host "Importing Watchlist '$WatchlistName'."

    # Parse the file contents as CSV
    # $csv = $FileContents | ConvertFrom-Csv -Delim ','

    $stream = [IO.MemoryStream]::new([Text.Encoding]::UTF8.GetBytes($FileContents))
    $reader = [IO.StreamReader]::new($stream)
    $header = $reader.ReadLine()

    # Recommended maximum number of fields for a given type is 50. This is a practical limit from a usability and search experience perspective.
    if($header.Length -gt $MAX_FIELD_LIMIT)
    {
        Write-Warning "Recommended maximum number of fields for a given type is $MAX_FIELD_LIMIT."
    }

    # Array for buffering records
    $records = [System.Collections.ArrayList]@()
    $padding = "".PadLeft($csv.length - 1, ",")
    $startingBatchSize = [System.Text.Encoding]::UTF8.GetByteCount("[$($padding)]") / 1MB
    $estBatchSizeInMB = $startingBatchSize

    # Ensure all imported records from same file have the same time generated
    $timeGenerated = Get-Date

    $measured = Measure-Command {
        while ( $line = $reader.ReadLine() ) {

            # Get our current record
            $current_record = "$header`n$line" | ConvertFrom-Csv -Delim ',' | Get-Record -FileContentSHA256 $FileContentSHA256

            if($null -ne $current_record)
            {
                $estFieldSizeInMB =  [System.Text.Encoding]::UTF8.GetByteCount("$current_record," )/ 1MB
                Write-Debug "RecordsInBatch : $($records.Count), EstimatedBatchSizeMB : $estBatchSizeInMB, EstimatedRecordSizeMB : $($estFieldSizeInMB)"

                # Maximum of 30 MB per post to Log Analytics Data Collector API. This is a size limit for a single post. If the data from a single post that exceeds 30 MB, you should split the data up to smaller sized chunks and send them concurrently.
                if( ($estBatchSizeInMB + $estFieldSizeInMB) -ge $MAX_JSON_PAYLOAD_SIZE_MB)
                {
                    Write-Host "Maximum of $($MAX_JSON_PAYLOAD_SIZE_MB) MB per post to Log Analytics Data Collector API automatically batching requests."

                    # Create records from current buffer
                    Send-DataCollectorRequest -records $records -WatchlistName $WatchlistName -WorkspaceId $WorkspaceId -WorkspaceSharedKey $WorkspaceSharedKey -TimeGenerated $timeGenerated

                    # Clear the buffer in preperation for next iteration
                    $records.Clear()
                    $estBatchSizeInMB = $startingBatchSize
                }

                # Add current record to the buffer
                $records.Add($current_record) | Out-Null
                $estBatchSizeInMB += $estFieldSizeInMB
            }
        }

        # Do we have any records left to create
        if($records.Count -gt 0)
        {
            Write-Host "Flushing remainder of batched requests $($records.Count)."
            # Create remaining records
            Send-DataCollectorRequest -records $records -WatchlistName $WatchlistName -WorkspaceId $WorkspaceId -WorkspaceSharedKey $WorkspaceSharedKey -TimeGenerated $timeGenerated
        }

        $reader.Dispose()
        $stream.Dispose()
    }

    Write-Host "Completed Watchlist '$WatchlistName' import in $($measured.TotalSeconds)s."
}

function Get-Record
{
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, ValueFromPipeline = $true)]
        [ValidateNotNullOrEmpty()]
        [PSCustomObject] $row,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [String] $FileContentSHA256
    )
    $record = [ordered]@{}

    $row.PSObject.Properties | ForEach-Object {
        # Maximum of 32 KB limit for field values. If the field value is greater than 32 KB, the data will be truncated.
        $sizeInKB = ([System.Text.Encoding]::UTF8.GetByteCount($_.Value) / 1KB)
        if($sizeInKB -gt $MAX_JSON_FIELD_VALUE_SIZE_KB)
        {
            Write-Warning "Field '$($_.Name)' has a value which is larger than the Maximum of $($MAX_JSON_FIELD_VALUE_SIZE_KB) KB, the data will be truncated."
            $record.Add($_.Name,[System.String]::new([System.Text.Encoding]::UTF8.GetBytes($_.Value), 0, $MAX_JSON_FIELD_VALUE_SIZE_KB))
        }
        else
        {
            $record.Add($_.Name,$_.Value)
        }
    }

    # Add the File Hash to the record object
    $record.Add("FileContentSHA256", $FileContentSHA256)

    return ([PSCustomObject]$record | ConvertTo-Json -Compress)
}

function Send-DataCollectorRequest
{
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [Array] $records,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [String] $WatchlistName,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [String] $WorkspaceId,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [String] $WorkspaceSharedKey,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [String] $TimeGenerated
    )
    $json_body = "[$(($records -join ",").Trim(","))]"

    $bodySizeInMB = ([System.Text.Encoding]::UTF8.GetByteCount($json_body) / 1MB)

    Write-Debug "ActualBatchSizeMB : $($bodySizeInMB)"

    if($bodySizeInMB -ge $MAX_JSON_PAYLOAD_SIZE_MB)
    {
        Write-Error "Maximum of $($MAX_JSON_PAYLOAD_SIZE_MB) MB per request for Log Analytics Data Collector API."
    }

    $Xmsdate = [DateTime]::UtcNow

    $signature = Get-DataCollectorSignature -WorkspaceSharedKey $WorkspaceSharedKey -Xmsdate $Xmsdate -ContentLength $json_body.length

    $Headers = @{
        "Authorization"        = "SharedKey {0}:{1}" -f  $WorkspaceId, $signature;
        "Log-Type"             = $WatchlistName;
        "x-ms-date"            = $($Xmsdate.ToString("r"));
        "time-generated-field" = $TimeGenerated
    }

    try {
        # Data Collector - https://docs.microsoft.com/en-us/rest/api/loganalytics/create-request
        #
        # Data limits
        # There are some constraints around the data posted to the Log Analytics Data collection API.
        # POST https://{CustomerID}.ods.opinsights.azure.com/?api-version=2016-04-01
        $response = Invoke-WebRequest -UseBasicParsing -Method POST -Uri "https://$($WorkspaceId).ods.opinsights.azure.com/api/logs?api-version=2016-04-01" -Body $json_body -ContentType "application/json" -Headers $Headers
        Write-Debug "POST https://$($WorkspaceId).ods.opinsights.azure.com/api/logs?api-version=2016-04-01 StatusCode $($response.StatusCode)"
        Write-Host "Importing '$($records.Length)' records."
    }
    catch {
        Write-Host "Failed to execute data collector create request for '$WatchlistName'."
        Write-Host "StatusCode:" $_.Exception.Response.StatusCode.value__
        Write-Host "StatusDescription:" $_.Exception.Response.StatusDescription
    }
}

function Get-DataCollectorSignature
{
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [String] $WorkspaceSharedKey,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [DateTime] $Xmsdate,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [int] $ContentLength
    )

    # Generate Signature - https://docs.microsoft.com/en-us/rest/api/loganalytics/create-request#constructing-the-signature-string
    $hmacsha = New-Object System.Security.Cryptography.HMACSHA256
    $hmacsha.key = [Convert]::FromBase64String($WorkspaceSharedKey)
    $stringToSign = "POST`n$($ContentLength)`napplication/json`nx-ms-date:$($Xmsdate.ToString("r"))`n/api/logs"
    $signature = $hmacsha.ComputeHash([Text.Encoding]::UTF8.GetBytes($stringToSign))
    return [Convert]::ToBase64String($signature)

}

Export-ModuleMember -Function "Import-Watchlist"