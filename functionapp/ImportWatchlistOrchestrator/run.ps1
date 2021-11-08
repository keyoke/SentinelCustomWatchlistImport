param(
    $context
)

# Main Entrypoint
$ParallelTasks = @()

if(Test-Path env:APPSETTING_WATCHLIST_STORAGE_ACCOUNT_FILE_SHARE_NAME)
{
    $files = Invoke-DurableActivity -FunctionName 'GetFilesWatchlistActivity' -input "watchlist_*.csv"

    $files 
    | Where-Object { ![string]::IsNullOrEmpty($_) }
    | ForEach-Object { 
        $ParallelTasks += Invoke-DurableActivity -FunctionName 'ImportFileWatchlistActivity' -Input $_ -NoWait 
    }
}
else
{
    $blobs = Invoke-DurableActivity -FunctionName 'GetBlobsWatchlistActivity' -input "watchlist_*.csv"
    $blobs
    | Where-Object { ![string]::IsNullOrEmpty($_) }
    | ForEach-Object { 
        $ParallelTasks += Invoke-DurableActivity -FunctionName 'ImportBlobWatchlistActivity' -Input $_ -NoWait 
    }
}

$outputs = @();
if($ParallelTasks.count -gt 0)
{
    $outputs = Wait-ActivityFunction -Task $ParallelTasks
}

return $outputs
