# SentinelWatchlistImport
Sentinel Watchlist Import

# Requirements
- Azure CLI 2.x
- Bicep CLI 0.4.x


# Deployment Steps

1. az group create --name [RESOURCE_GROUP] --location [LOCATION]
2. az bicep build --file .\main.bicep
3. az deployment group create --name [DEPLOYMENT_NAME] --resource-group [RESOURCE_GROUP] --template-file main.json --parameters watchlistStorageAccountName=[STORAGE_ACCOUNT_NAME] --parameters watchlistStorageSubscriptionId=[STORAGE_ACCOUNT_SUBSCRIPTION_ID]  --parameters watchlistWorkspaceId=[WATCHLIST_WORKSPACE_ID] --parameters workspaceSharedKey=[WATCHLIST_WORKSPACE_SHARED_KEY] 
4. Deploy Function