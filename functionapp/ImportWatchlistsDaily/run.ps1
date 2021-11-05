# Input bindings are passed in via param block.
param($Timer)

Import-Module Import-Watchlist

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
        $sha256_hash = Get-FileHash -InputStream ([System.IO.MemoryStream]::New([System.Text.Encoding]::UTF8.GetBytes($contents))) -Algorithm SHA256 | Select-Object -ExpandProperty Hash
    
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

function Import-FromFileStorage
{
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [Microsoft.WindowsAzure.Commands.Storage.AzureStorageContext] $Context,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [String] $WatchlistStorageAccountFileShareName,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [String] $WatchlistStorageAccountIncomingDirectoryName,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [String] $WatchlistStorageAccountCompletedDirectoryName,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [String] $WorkspaceId,
        
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [String] $WorkspaceSharedKey
    )

     Get-AzStorageFile -context $context -ShareName $WatchlistStorageAccountFileShareName -Path $WatchlistStorageAccountIncomingDirectoryName | Get-AzStorageFile | where {$_.Name -like "watchlist_*.csv"} | ForEach-Object { 
        Write-Host "Processing file '$($_.name)'"
    
        # Log type only supports alpha characters. It does not support numerics or special characters
        $WatchlistName = [System.IO.Path]::GetFileNameWithoutExtension($_.Name) -replace 'watchlist_','' -replace '[^a-zA-Z]', ''
    
        # Get the Contents of the CSV file from Azure Storage
        $contents = $_.CloudFile.DownloadText()
    
        # Compute a hash which we will use to identify related records once imported
        $sha256_hash = Get-FileHash -InputStream ([System.IO.MemoryStream]::New([System.Text.Encoding]::UTF8.GetBytes($contents))) -Algorithm SHA256 | Select-Object -ExpandProperty Hash
    
        # Import the Watchlist CSV contents into custom log analytics table for use later
        $contents | Import-Watchlist -WatchlistName $WatchlistName -WorkspaceId $WorkspaceId -WorkspaceSharedKey $WorkspaceSharedKey -FileContentSHA256 $sha256_hash
       
        $created_date = [DateTime]::UtcNow.ToString("yyyyMMdd")
    
        if($_.CloudFile.Properties.Created.HasValue)
        {
            $created_date = $_.CloudFile.Properties.Created.Value.ToString("yyyyMMdd")
        }
    
        $fileCopyAction = Start-AzStorageFileCopy `
            -SrcShareName $WatchlistStorageAccountFileShareName `
            -SrcFilePath  "$($WatchlistStorageAccountIncomingDirectoryName)\\$($_.Name)" `
            -DestShareName $WatchlistStorageAccountFileShareName `
            -DestFilePath "$($WatchlistStorageAccountCompletedDirectoryName)\\$($_.Name).$($created_date)" `
            -Context $context `
            -Force
      
        $status = $fileCopyAction | Get-AzStorageFileCopyState -WaitForComplete
     
        if($status.Status -eq 'Success')
        {
            $_ | Remove-AzStorageFile
            Write-Host "Moved file '$($_.name)' from '$($WatchlistStorageAccountIncomingDirectoryName)' to '$($WatchlistStorageAccountCompletedDirectoryName)'."
        }
    
        Write-Host "Completed Processing file '$($_.name)'"
    }    
}

# Main Entrypoint
# Connect-AzAccount -Identity
Set-AzContext -Subscription $env:APPSETTING_WATCHLIST_STORAGE_SUBSCRIPTION_ID

if(Test-Path env:APPSETTING_WATCHLIST_STORAGE_ACCOUNT_FILE_SHARE_NAME)
{
    # do we have an acess key? or have we enabled identity auth - https://docs.microsoft.com/en-us/azure/storage/files/storage-files-identity-ad-ds-assign-permissions?tabs=azure-portal
    if(Test-Path env:APPSETTING_WATCHLIST_STORAGE_ACCOUNT_FILE_SHARE_ACCESS_KEY)
    {
        $context = New-AzStorageContext -StorageAccountName $env:APPSETTING_WATCHLIST_STORAGE_ACCOUNT_NAME -StorageAccountKey $env:APPSETTING_WATCHLIST_STORAGE_ACCOUNT_FILE_SHARE_ACCESS_KEY 
    }
    else {
        $context = New-AzStorageContext -StorageAccountName $env:APPSETTING_WATCHLIST_STORAGE_ACCOUNT_NAME -UseConnectedAccount
    }

    Import-FromFileStorage -Context $context -WorkspaceSharedKey $env:APPSETTING_WATCHLIST_WORKSPACE_SHARED_KEY `
                            -WorkspaceId $env:APPSETTING_WATCHLIST_WORKSPACE_ID -WatchlistStorageAccountIncomingDirectoryName $env:APPSETTING_WATCHLIST_STORAGE_INCOMING_DIRECTORY_NAME `
                            -WatchlistStorageAccountCompletedDirectoryName $env:APPSETTING_WATCHLIST_STORAGE_COMPLETED_DIRECTORY_NAME -WatchlistStorageAccountFileShareName $env:APPSETTING_WATCHLIST_STORAGE_ACCOUNT_FILE_SHARE_NAME
}
else
{
    $context = New-AzStorageContext -StorageAccountName $env:APPSETTING_WATCHLIST_STORAGE_ACCOUNT_NAME -UseConnectedAccount
    
    Import-FromBlobStorage -Context $context -WorkspaceSharedKey $env:APPSETTING_WATCHLIST_WORKSPACE_SHARED_KEY `
                            -WorkspaceId $env:APPSETTING_WATCHLIST_WORKSPACE_ID -WatchlistStorageAccountIncomingContainerName $env:APPSETTING_WATCHLIST_STORAGE_INCOMING_CONTAINER_NAME `
                            -WatchlistStorageAccountCompletedContainerName $env:APPSETTING_WATCHLIST_STORAGE_COMPLETED_CONTAINER_NAME
}

