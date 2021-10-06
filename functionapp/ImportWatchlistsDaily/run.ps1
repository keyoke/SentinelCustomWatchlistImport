# Input bindings are passed in via param block.
param($Timer)

# Service limits which may change over time
$MAX_FIELD_LIMIT = 49
$MAX_JSON_PAYLOAD_SIZE_MB = 30MB
$MAX_JSON_FIELD_VALUE_SIZE_KB = 32KB

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

    Write-Host "Importing Watchlist '$WatchlistName'."

    # Parse the file contents as CSV
    $csv = $FileContents | ConvertFrom-Csv -Delim ','

    # Recommended maximum number of fields for a given type is 50. This is a practical limit from a usability and search experience perspective.
    $field_count = ($csv | get-member -type NoteProperty).count
    if($field_count -gt $MAX_FIELD_LIMIT)
    {
        Write-Warning "Recommended maximum number of fields for a given type is $MAX_FIELD_LIMIT."
    }

    # Array for buffering records
    $records = @()

    # Loop through each row in the csv
    for ($i = 0 ; $i -lt $csv.length ; $i++) { 
        # Get our current record
        $current_record = Get-Record -records $csv -index $i -FileContentSHA256 $FileContentSHA256

        # Maximum of 30 MB per post to Log Analytics Data Collector API. This is a size limit for a single post. If the data from a single post that exceeds 30 MB, you should split the data up to smaller sized chunks and send them concurrently.
        if(([System.Text.Encoding]::UTF8.GetByteCount(($records + $current_record  | ConvertTo-Json -Depth 99 -Compress)) / 1MB) -ge $MAX_JSON_PAYLOAD_SIZE_MB)
        {
            Write-Information "Maximum of $($MAX_JSON_PAYLOAD_SIZE_MB) MB per post to Log Analytics Data Collector API automatically batching requests."

            # Create records from current buffer
            Send-DataCollectorRequest -records $records -WatchlistName $WatchlistName -WorkspaceId $WorkspaceId -WorkspaceSharedKey $WorkspaceSharedKey

            # Clear the buffer in preperation for next iteration
            $records = @()
        }

        # Add current record to the buffer
        $records +=  $current_record
    
    }

    # Do we have any records left to create
    if($records.Length -gt 0)
    {
        # Create remaining records
        Send-DataCollectorRequest -records $records -WatchlistName $WatchlistName -WorkspaceId $WorkspaceId -WorkspaceSharedKey $WorkspaceSharedKey
    }

    Write-Host "Completed Watchlist '$WatchlistName' import."
}

function Get-Record
{
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [Array] $records,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [int] $index,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [String] $FileContentSHA256
    )
    if(($index -ge 0) -and 
        ($index -lt $records.Length))
    {
        $record = @{}

        $records[$index].PSObject.Properties | ForEach-Object {
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
        [String] $WorkspaceSharedKey
    )
    $json_body = $records | ConvertTo-Json -Depth 99 -Compress

    $Xmsdate = [DateTime]::UtcNow

    $signature = Get-DataCollectorSignature -WorkspaceSharedKey $WorkspaceSharedKey -Xmsdate $Xmsdate -ContentLength $json_body.length

    $Headers = @{
        "Authorization"        = "SharedKey {0}:{1}" -f  $WorkspaceId, $signature;
        "Log-Type"             = $WatchlistName;
        "x-ms-date"            = $($Xmsdate.ToString("r"));
        "time-generated-field" = $(Get-Date)
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

function Import-FromBlobStorage
{
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [Microsoft.WindowsAzure.Commands.Storage.AzureStorageContext] $Context,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [String] $WatchlistStorageAccountIncomingContainerName,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [String] $WatchlistStorageAccountCompletedContainerName,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [String] $WorkspaceId,
        
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [String] $WorkspaceSharedKey
    )

    Get-AzStorageBlob -Container $WatchlistStorageAccountIncomingContainerName -Blob watchlist_*.csv -Context $context | ForEach-Object { 
        Write-Host "Processing file '$($_.name)'"
    
        # Log type only supports alpha characters. It does not support numerics or special characters
        $WatchlistName = [System.IO.Path]::GetFileNameWithoutExtension($_.Name) -replace 'watchlist_','' -replace '[^a-zA-Z]', ''
    
        # Get the Contents of the CSV file from Azure Storage
        $contents = $_.ICloudBlob.DownloadText() # or this ? $_ | Get-AzStorageBlobContent
    
        # Get the content hash from storage
        # $md5_hash = $_.ICloudBlob.Properties.ContentMD5
        # or Compute a hash which we will use to identify related records once imported
        $sha256_hash = Get-FileHash -InputStream ([System.IO.MemoryStream]::New([System.Text.Encoding]::UTF8.GetBytes($contents))) -Algorithm SHA256 | Select -ExpandProperty Hash
    
        # Import the Watchlist CSV contents into custom log analytics table for use later
        $contents | Import-Watchlist -WatchlistName $WatchlistName -WorkspaceId $WorkspaceId -WorkspaceSharedKey $WorkspaceSharedKey -FileContentSHA256 $sha256_hash
    
        # Move the blob to the completed container - works only for block blobs
        # $_ | Copy-AzStorageBlob -DestContainer $env:APPSETTING_WATCHLIST_STORAGE_COMPLETED_CONTAINER_NAME -DestBlob $_.Name -Context $context -Force
        
        # Remove the incoming blob as we have completed the import
        # Remove-AzStorageBlob -Blob $_.name -Container $env:APPSETTING_WATCHLIST_STORAGE_INCOMING_CONTAINER_NAME -Context $context -Force
    
        $created_date = [DateTime]::UtcNow.ToString("yyyyMMdd")
    
        if($_.ICloudBlob.Properties.Created.HasValue)
        {
            $created_date = $_.ICloudBlob.Properties.Created.Value.ToString("yyyyMMdd")
        }
    
        $blobCopyAction = Start-AzStorageBlobCopy `
            -CloudBlob  $_.ICloudBlob `
            -DestBlob "$($_.Name).$($created_date)" `
            -Context $context `
            -DestContainer $WatchlistStorageAccountCompletedContainerName `
            -Force
      
        $status = $blobCopyAction | Get-AzStorageBlobCopyState -Context $context -WaitForComplete
     
        if($status.Status -eq 'Success')
        {
            $_ | Remove-AzStorageBlob -Force
            Write-Host "Moved file '$($_.name)' from '$($WatchlistStorageAccountIncomingContainerName)' to '$($WatchlistStorageAccountCompletedContainerName)'."
        }
    
        Write-Host "Completed Processing file '$($_.name)'"
    }    
}


# Main Entrypoint
# Connect-AzAccount -Identity
Set-AzContext -Subscription $env:APPSETTING_WATCHLIST_STORAGE_SUBSCRIPTION_ID

$context = New-AzStorageContext -StorageAccountName $env:APPSETTING_WATCHLIST_STORAGE_ACCOUNT_NAME -UseConnectedAccount

Import-FromBlobStorage -Context $context -WorkspaceSharedKey $env:APPSETTING_WATCHLIST_WORKSPACE_SHARED_KEY `
                        -WorkspaceId $env:APPSETTING_WATCHLIST_WORKSPACE_ID -WatchlistStorageAccountIncomingContainerName $env:APPSETTING_WATCHLIST_STORAGE_INCOMING_CONTAINER_NAME `
                        -WatchlistStorageAccountCompletedContainerName $env:APPSETTING_WATCHLIST_STORAGE_COMPLETED_CONTAINER_NAME

