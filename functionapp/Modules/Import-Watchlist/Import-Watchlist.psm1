#Requires -Version 7

# Service limits which may change over time
$MAX_FIELD_LIMIT = 49
$MAX_JSON_PAYLOAD_SIZE_MB = 30 # Maximum supported value is 30MB
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

    $options = [System.Text.Json.JsonSerializerOptions]::new()
    #$options.MaxDepth = 1
    $options.ReferenceHandler = [System.Text.Json.Serialization.ReferenceHandler]::IgnoreCycles

    $stream = [IO.MemoryStream]::new([Text.Encoding]::UTF8.GetBytes($FileContents))
    $reader = [IO.StreamReader]::new($stream)
    $headers = $reader.ReadLine() -split ","

    # Recommended maximum number of fields for a given type is 50. This is a practical limit from a usability and search experience perspective.
    if($headers.Length -gt $MAX_FIELD_LIMIT)
    {
        Write-Warning "Recommended maximum number of fields for a given type is $MAX_FIELD_LIMIT."
    }

    $estHeaderSizeInKB = [System.Text.Encoding]::UTF8.GetByteCount("[]")  / 1KB # include delimiters for json array
    $headers | ForEach-Object {
        $estHeaderSizeInKB += [System.Text.Encoding]::UTF8.GetByteCount("`"$_`":") / 1KB
    }

    # Array for buffering records
    $records = [System.Collections.ArrayList]::new()
    $estBatchSizeInMB = 0

    # Ensure all imported records from same file have the same time generated
    $timeGenerated = Get-Date

    $measured = Measure-Command {
        while ( $line = $reader.ReadLine() ) {
            $fields = ($line -split ",")

            # Get our current record
            $current_record = Get-Record -headers $headers -values $fields -FileContentSHA256 $FileContentSHA256

            if($null -ne $current_record)
            {
                $estFieldSizeInKB = [System.Text.Encoding]::UTF8.GetByteCount("{}")  / 1KB # include delimiters for json object
                $fields | ForEach-Object {
                    $estFieldSizeInKB += [System.Text.Encoding]::UTF8.GetByteCount("`"$_`"") / 1KB
                }

                $estFieldSizeInMB = ($estHeaderSizeInKB + $estFieldSizeInKB) / 1KB
                Write-Debug "RecordsInBatch : $($records.Length), EstimatedBatchSizeMB : $estBatchSizeInMB, EstimatedRecordSizeMB : $($estFieldSizeInMB)"

                # Maximum of 30 MB per post to Log Analytics Data Collector API. This is a size limit for a single post. If the data from a single post that exceeds 30 MB, you should split the data up to smaller sized chunks and send them concurrently.
                if( ($estBatchSizeInMB + $estFieldSizeInMB) -ge $MAX_JSON_PAYLOAD_SIZE_MB)
                {
                    Write-Host "Maximum of $($MAX_JSON_PAYLOAD_SIZE_MB) MB per post to Log Analytics Data Collector API automatically batching requests."

                    # Create records from current buffer
                    # Send-DataCollectorRequest -records $records -WatchlistName $WatchlistName -WorkspaceId $WorkspaceId -WorkspaceSharedKey $WorkspaceSharedKey -TimeGenerated $timeGenerated

                    # Clear the buffer in preperation for next iteration
                    $records.Clear()
                    $estBatchSizeInMB = 0
                }

                # Add current record to the buffer
                $records += $current_record
                $estBatchSizeInMB += $estFieldSizeInMB
            }
        }

        # Do we have any records left to create
        if($records.Length -gt 0)
        {
            Write-Host "Flushing remainder of batched requests $($records.Length)."
            # Create remaining records
            # Send-DataCollectorRequest -records $records -WatchlistName $WatchlistName -WorkspaceId $WorkspaceId -WorkspaceSharedKey $WorkspaceSharedKey -TimeGenerated $timeGenerated
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
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [Array] $headers,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [Array] $values,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [String] $FileContentSHA256
    )
    if(($headers.Length -gt 0) -and
        ($headers.Length -eq $values.Length))
    {
        $record = @{}

        for ($i = 0; $i -lt $headers.Length; $i++) {
            # Maximum of 32 KB limit for field values. If the field value is greater than 32 KB, the data will be truncated.
            $sizeInKB = ([System.Text.Encoding]::UTF8.GetByteCount($values[$i]) / 1KB)

            if($sizeInKB -gt $MAX_JSON_FIELD_VALUE_SIZE_KB)
            {
                Write-Warning "Field '$($headers[$i])' has a value which is larger than the Maximum of $($MAX_JSON_FIELD_VALUE_SIZE_KB) KB, the data will be truncated."
                $record.Add($headers[$i],[System.String]::new([System.Text.Encoding]::UTF8.GetBytes($values[$i]), 0, $MAX_JSON_FIELD_VALUE_SIZE_KB))
            }
            else
            {
                $record.Add($headers[$i],$values[$i])
            }
        }

        # Add the File Hash to the record object
        $record.Add("FileContentSHA256", $FileContentSHA256)

        return $record
    }
    # no record to return we are out if bounds
    return $null
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
    $json_body = $records | ConvertTo-Json -Depth 99 -Compress

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
        Invoke-RestMethod -Method POST -Uri "https://$($WorkspaceId).ods.opinsights.azure.com/api/logs?api-version=2016-04-01" -Body $json_body -ContentType "application/json" -Headers $Headers
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