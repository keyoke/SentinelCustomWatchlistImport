# Sentinel Custom Watchlist Import

## Overview
This repository provides a custom watchlist import solution which can be used to work around [Sentinels native watchlist](https://docs.microsoft.com/en-us/azure/sentinel/watchlists#create-a-new-watchlist) file import size limitation of 3.8 MB.

![Solution Overview](images/solution-overview.png)

The custom import process is as follows:
1. A CSV file with the naming convention "watchlist_[LOG_ANALYTICS_TABLE_NAME].csv" is dropped into the "incoming" Blob Storage container or File Share Directory.
1. The Azure Function (ImportWatchlistOrchestratorTimer) is scheduled to run once a day on a CRON schedule "0 * 0 * * *", once triggered the function checks the "incoming" container or directory for new watchlists.
1. When a new watchlist arrives the contents of the file is hashed and the rows are converted to JSON, each row is inserted into a custom table in the Log Analytics Workspace. 
1. Once the file is processed it is moved to the "imported" Blob Storage Container or File Share Directory.
1. When querying the data we can use the TimeGenerated property and optional the file contents hash to group related rows which were imported at the same time.

# Requirements
- Azure CLI 2.x
- Azure Functions Core Tools 3.x
- Bicep CLI 0.4.x
- ARMClient 1.9.x

This solution also requires an existing Azure Storage Account where the CSV will be imported from, use the instructions detailed [here](https://docs.microsoft.com/en-us/azure/storage/blobs/storage-quickstart-blobs-cli) to create one and add two blob containers:
- incoming
- imported

# Deployment Steps
Run the provided Shell script when leveraging Azure Blob Storage

- ./deploy.sh [RESOURCE_GROUP] [LOCATION] [STORAGE_ACCOUNT_NAME] [STORAGE_ACCOUNT_RESOURCE_GROUP] [STORAGE_ACCOUNT_SUBSCRIPTION_ID] [WATCHLIST_WORKSPACE_ID] [WATCHLIST_WORKSPACE_SHARED_KEY] 

or manually execute the deployment using the steps below:

1. az group create --name [RESOURCE_GROUP] --location [LOCATION]
1. az bicep build --file .\main.bicep
1. az deployment group create --name [DEPLOYMENT_NAME] --resource-group [RESOURCE_GROUP] --template-file main.json --parameters watchlistStorageAccountName=[STORAGE_ACCOUNT_NAME] --parameters watchlistStorageSubscriptionId=[STORAGE_ACCOUNT_SUBSCRIPTION_ID]  --parameters watchlistWorkspaceId=[WATCHLIST_WORKSPACE_ID] --parameters workspaceSharedKey=[WATCHLIST_WORKSPACE_SHARED_KEY] 
1. az role assignment create --role "Storage Blob Data Contributor" --assignee [FUNCTION_PRINCIPAL_ID] --scope "/subscriptions/[STORAGE_ACCOUNT_SUBSCRIPTION_ID]/resourceGroups/[STORAGE_ACCOUNT_RESOURCE_GROUP]/providers/Microsoft.Storage/storageAccounts/[STORAGE_ACCOUNT_NAME]"
1. cd functionapp/
1. func azure functionapp publish [FUNCTION_APP_NAME]

Optionally you can leverage an Azure File Share, if you have enabled [Identity-based authentication](https://docs.microsoft.com/en-us/azure/storage/files/storage-files-identity-ad-ds-assign-permissions?tabs=azure-portal) on your Azure File Share you may omit the optional [STORAGE_ACCOUNT_FILE_SHARE_ACCESS_KEY] parameter.

- ./deploy.sh [RESOURCE_GROUP] [LOCATION] [STORAGE_ACCOUNT_NAME] [STORAGE_ACCOUNT_RESOURCE_GROUP] [STORAGE_ACCOUNT_SUBSCRIPTION_ID] [WATCHLIST_WORKSPACE_ID] [WATCHLIST_WORKSPACE_SHARED_KEY] [STORAGE_ACCOUNT_FILE_SHARE_NAME] [STORAGE_ACCOUNT_FILE_SHARE_ACCESS_KEY]


# Azure Sentinel
In Azure Sentinel we are able to leverage [Watchlists in our analytics rules](https://docs.microsoft.com/en-us/azure/sentinel/watchlists#use-watchlists-in-analytics-rules), the queries will look something like the following : 

```sql
let watchlist = (_GetWatchlist('ipwatchlist') | project IPAddress);
Heartbeat
| where ComputerIP in (watchlist)
```

When working with our custom watchlists we are able to perform the same thing although the queries will be slightly different. For example here is the same query but it retrieves its data from our custom table in Log Analytics. We take care to retrieve only the latest imported records, we do this by leveraging the TimeGenerated property.

```sql
let MaxTimeGenerated = toscalar(customipwatchlist_CL | summarize Latest=max(TimeGenerated));
let customwatchlist = (customipwatchlist_CL | where TimeGenerated == MaxTimeGenerated | project IPAddress);
Heartbeat
| where ComputerIP in (customwatchlist)
```

It is also recommended that you set the [data retention on the custom table](https://docs.microsoft.com/en-us/azure/azure-monitor/logs/manage-cost-storage#retention-by-data-type) to a reasonable value to avoid unnecessary data duplication:

```powershell
armclient PUT /subscriptions/[SUBSCRIPTION_ID]/resourceGroups/[RESOURCE_GROUP_NAME]/providers/Microsoft.OperationalInsights/workspaces/[WORKSPACE_NAME]/Tables/[LOG_ANALYTICS_TABLE_NAME]?api-version=2017-04-26-preview "{properties: {retentionInDays: 4}}"
```

# Issues
- "Timeout value of 00:10:00 exceeded by function", when dealing with large CSV files the functions execution time may be exceeding functionTimeout by default this is 5 min on consumption plan. You can configure custom functionTimeout from your host.json file on the consumption plan 10 min is the maximum timeout. In this scenario I would reccomend switching to the [Premium plan](https://docs.microsoft.com/en-us/azure/azure-functions/functions-premium-plan?tabs=portal) and increasing the timeout to a satisfactory value, see the following [link for more details](https://docs.microsoft.com/en-us/azure/azure-functions/functions-host-json#functiontimeout).
- "Your function '[FUNCTION_NAME]' is queuing requests as there are no available runspaces. You may be able to increase your throughput by following the best practices on https://aka.ms/functions-powershell-concurrency.", the durable function version of the import solution allows us to fan out into multiple parallel watchlist imports. Leverage the FUNCTIONS_WORKER_PROCESS_COUNT and PSWorkerInProcConcurrencyUpperBound configuration settings to fine tune the amount of parallelism required.