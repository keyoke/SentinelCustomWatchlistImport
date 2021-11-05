param($filter)

$blobs = @()
# Set-AzContext -Subscription $env:APPSETTING_WATCHLIST_STORAGE_SUBSCRIPTION_ID  | Out-Null

$storageContext = New-AzStorageContext -StorageAccountName $env:APPSETTING_WATCHLIST_STORAGE_ACCOUNT_NAME -UseConnectedAccount

Write-Host "Polling for incoming blobs"
Get-AzStorageBlob -Container $env:APPSETTING_WATCHLIST_STORAGE_INCOMING_CONTAINER_NAME -Blob $filter -Context $storageContext | ForEach-Object { 
    Write-Host "Found incoming blob '$($_.name)'"
    $blobs += $_.Name
}
Write-Host "Ended polling for incoming blobs"

return $blobs

