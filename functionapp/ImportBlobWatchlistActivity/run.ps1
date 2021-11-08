param(
    $BlobName
)

Import-Module Import-Watchlist

$storageContext = New-AzStorageContext -StorageAccountName $env:APPSETTING_WATCHLIST_STORAGE_ACCOUNT_NAME -UseConnectedAccount

$blob = Get-AzStorageBlob -Container $env:APPSETTING_WATCHLIST_STORAGE_INCOMING_CONTAINER_NAME -Blob $BlobName -Context $storageContext 

Write-Host "Processing blob '$($blob.name)'."

# Log type only supports alpha characters. It does not support numerics or special characters
$WatchlistName = [System.IO.Path]::GetFileNameWithoutExtension($blob.Name) -replace '^watchlist_','' -replace '[^a-zA-Z_]', ''

Write-Host "Watchlist name '$($WatchlistName)'."

# Get the Contents of the CSV file from Azure Storage
$contents = $blob.ICloudBlob.DownloadText() # or this ? $blob | Get-AzStorageBlobContent

# Get the content hash from storage
# $md5_hash = $blob.ICloudBlob.Properties.ContentMD5
# or Compute a hash which we will use to identify related records once imported
$sha256_hash = Get-FileHash -InputStream ([System.IO.MemoryStream]::New([System.Text.Encoding]::UTF8.GetBytes($contents))) -Algorithm SHA256 | Select-Object -ExpandProperty Hash

Write-Host "Blob contents hash '$($sha256_hash)'."

# Import the Watchlist CSV contents into custom log analytics table for use later
$contents | Import-Watchlist -WatchlistName $WatchlistName -WorkspaceId $env:APPSETTING_WATCHLIST_WORKSPACE_ID -WorkspaceSharedKey $env:APPSETTING_WATCHLIST_WORKSPACE_SHARED_KEY -FileContentSHA256 $sha256_hash

$created_date = [DateTime]::UtcNow.ToString("yyyyMMdd")

if($blob.ICloudBlob.Properties.Created.HasValue)
{
    $created_date = $blob.ICloudBlob.Properties.Created.Value.ToString("yyyyMMdd")
}

Write-Host "Blob created date '$($created_date)'."

$blobCopyAction = Start-AzStorageBlobCopy `
    -CloudBlob  $blob.ICloudBlob `
    -DestBlob "$($blob.Name).$($created_date)" `
    -Context $storageContext `
    -DestContainer $env:APPSETTING_WATCHLIST_STORAGE_COMPLETED_CONTAINER_NAME `
    -Force

$status = $blobCopyAction | Get-AzStorageBlobCopyState -Context $storageContext -WaitForComplete

Write-Host "Blob copy status '$($status.Status)'."

if($status.Status -eq 'Success')
{
    $blob | Remove-AzStorageBlob -Force
    Write-Host "Moved blob '$($blob.name)' from '$($env:APPSETTING_WATCHLIST_STORAGE_INCOMING_CONTAINER_NAME )' to '$($env:APPSETTING_WATCHLIST_STORAGE_COMPLETED_CONTAINER_NAME)'."
}

Write-Host "Completed Processing blob '$($blob.name)'."
