param(
    $FileName
)

Import-Module Import-Watchlist 

# do we have an acess key? or have we enabled identity auth - https://docs.microsoft.com/en-us/azure/storage/files/storage-files-identity-ad-ds-assign-permissions?tabs=azure-portal
if(Test-Path env:APPSETTING_WATCHLIST_STORAGE_ACCOUNT_FILE_SHARE_ACCESS_KEY)
{
    $storageContext = New-AzStorageContext -StorageAccountName $env:APPSETTING_WATCHLIST_STORAGE_ACCOUNT_NAME -StorageAccountKey $env:APPSETTING_WATCHLIST_STORAGE_ACCOUNT_FILE_SHARE_ACCESS_KEY 
}
else {
    $storageContext = New-AzStorageContext -StorageAccountName $env:APPSETTING_WATCHLIST_STORAGE_ACCOUNT_NAME -UseConnectedAccount
}

$file = Get-AzStorageFile -context $storageContext -ShareName $env:APPSETTING_WATCHLIST_STORAGE_ACCOUNT_FILE_SHARE_NAME -Path "$($env:APPSETTING_WATCHLIST_STORAGE_INCOMING_DIRECTORY_NAME)\\$($FileName)" 

Write-Host "Processing file '$($file.name)'."

# Log type only supports alpha characters. It does not support numerics or special characters
$WatchlistName = [System.IO.Path]::GetFileNameWithoutExtension($file.Name) -replace '^watchlist_','' -replace '[^a-zA-Z_]', ''

Write-Host "Watchlist name '$($WatchlistName)'."

# Get the Contents of the CSV file from Azure Storage
$contents = $file.CloudFile.DownloadText()

# Compute a hash which we will use to identify related records once imported
$sha256_hash = Get-FileHash -InputStream ([System.IO.MemoryStream]::New([System.Text.Encoding]::UTF8.GetBytes($contents))) -Algorithm SHA256 | Select-Object -ExpandProperty Hash

Write-Host "File contents hash '$($sha256_hash)'."

# Import the Watchlist CSV contents into custom log analytics table for use later
$contents | Import-Watchlist -WatchlistName $WatchlistName -WorkspaceId $env:APPSETTING_WATCHLIST_WORKSPACE_ID -WorkspaceSharedKey $env:APPSETTING_WATCHLIST_WORKSPACE_SHARED_KEY -FileContentSHA256 $sha256_hash

$created_date = [DateTime]::UtcNow.ToString("yyyyMMdd")

if($file.CloudFile.Properties.Created.HasValue)
{
    $created_date = $file.CloudFile.Properties.Created.Value.ToString("yyyyMMdd")
}

Write-Host "File created date '$($created_date)'."

$fileCopyAction = Start-AzStorageFileCopy `
    -SrcShareName $env:APPSETTING_WATCHLIST_STORAGE_ACCOUNT_FILE_SHARE_NAME `
    -SrcFilePath "$($env:APPSETTING_WATCHLIST_STORAGE_INCOMING_DIRECTORY_NAME)\\$($file.Name)" `
    -DestShareName $env:APPSETTING_WATCHLIST_STORAGE_ACCOUNT_FILE_SHARE_NAME `
    -DestFilePath "$($env:APPSETTING_WATCHLIST_STORAGE_COMPLETED_DIRECTORY_NAME)\\$($file.Name).$($created_date)" `
    -Context $storageContext `
    -Force

$status = $fileCopyAction | Get-AzStorageFileCopyState -WaitForComplete

Write-Host "File copy status '$($status.Status)'."

if($status.Status -eq 'Success')
{
    $file | Remove-AzStorageFile
    Write-Host "Moved file '$($file.name)' from '$($env:APPSETTING_WATCHLIST_STORAGE_INCOMING_DIRECTORY_NAME)' to '$($env:APPSETTING_WATCHLIST_STORAGE_COMPLETED_DIRECTORY_NAME)'."
}

Write-Host "Completed Processing file '$($file.name)'"
