# Sentinel Custom Watchlist Import

## Overview

# Requirements
- Azure CLI 2.x
- Azure Functions Core Tools 3.x
- Bicep CLI 0.4.x


# Deployment Steps
Run the provided Shell script

- ./deploy.sh [RESOURCE_GROUP] [LOCATION] [STORAGE_ACCOUNT_NAME] [STORAGE_ACCOUNT_SUBSCRIPTION_ID] [WATCHLIST_WORKSPACE_ID] [WATCHLIST_WORKSPACE_SHARED_KEY] 

or manually execute the deployment using the steps below:

1. az group create --name [RESOURCE_GROUP] --location [LOCATION]
2. az bicep build --file .\main.bicep
3. az deployment group create --name [DEPLOYMENT_NAME] --resource-group [RESOURCE_GROUP] --template-file main.json --parameters watchlistStorageAccountName=[STORAGE_ACCOUNT_NAME] --parameters watchlistStorageSubscriptionId=[STORAGE_ACCOUNT_SUBSCRIPTION_ID]  --parameters watchlistWorkspaceId=[WATCHLIST_WORKSPACE_ID] --parameters workspaceSharedKey=[WATCHLIST_WORKSPACE_SHARED_KEY] 
4. cd functionapp/
5. func azure functionapp publish [FUNCTION_APP_NAME]