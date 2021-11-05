param($filter)

$files = @()

# Set-AzContext -Subscription $env:APPSETTING_WATCHLIST_STORAGE_SUBSCRIPTION_ID  | Out-Null

# do we have an acess key? or have we enabled identity auth - https://docs.microsoft.com/en-us/azure/storage/files/storage-files-identity-ad-ds-assign-permissions?tabs=azure-portal
if(Test-Path env:APPSETTING_WATCHLIST_STORAGE_ACCOUNT_FILE_SHARE_ACCESS_KEY)
{
    $storageContext = New-AzStorageContext -StorageAccountName $env:APPSETTING_WATCHLIST_STORAGE_ACCOUNT_NAME -StorageAccountKey $env:APPSETTING_WATCHLIST_STORAGE_ACCOUNT_FILE_SHARE_ACCESS_KEY 
}
else {
    $storageContext = New-AzStorageContext -StorageAccountName $env:APPSETTING_WATCHLIST_STORAGE_ACCOUNT_NAME -UseConnectedAccount
}

Write-Host "Polling for incoming files"
Get-AzStorageFile -context $storageContext -ShareName $env:APPSETTING_WATCHLIST_STORAGE_ACCOUNT_FILE_SHARE_NAME -Path $env:APPSETTING_WATCHLIST_STORAGE_INCOMING_DIRECTORY_NAME | Get-AzStorageFile | Where-Object {$_.Name -like $filter} | ForEach-Object { 
    Write-Host "Found incoming file '$($_.name)'"
    $files += $_.Name
}
Write-Host "Ended polling for incoming files"

return $files
