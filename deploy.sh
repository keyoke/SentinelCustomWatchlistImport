#!/bin/bash
if [ -z "$1" ] || [ -z "$2" ] || [ -z "$3" ] || [ -z "$4" ] || [ -z "$5" ] || [ -z "$6" ]
then
   echo "Arguments required: $0 [RESOURCE_GROUP] [LOCATION] [STORAGE_ACCOUNT_NAME] [STORAGE_ACCOUNT_SUBSCRIPTION_ID] [WATCHLIST_WORKSPACE_ID] [WATCHLIST_WORKSPACE_SHARED_KEY]";
   exit 1
else
    RESOURCE_GROUP="$1"
    LOCATION="$2"
    STORAGE_ACCOUNT_NAME="$3"
    STORAGE_ACCOUNT_SUBSCRIPTION_ID="$4"
    WATCHLIST_WORKSPACE_ID="$5"
    WATCHLIST_WORKSPACE_SHARED_KEY="$6"

    # Create the target resource group
    az group create --name $RESOURCE_GROUP --location $LOCATION

    # build our bicep template
    az bicep build --file main.bicep

    # deploy our template to azure and get functionappname
    FUNCTION_APP_NAME=$(az deployment group create --query 'properties.outputs.functionAppName.value' --output tsv --resource-group $RESOURCE_GROUP --template-file main.json --parameters watchlistStorageAccountName=$STORAGE_ACCOUNT_NAME --parameters watchlistStorageSubscriptionId=$STORAGE_ACCOUNT_SUBSCRIPTION_ID --parameters watchlistWorkspaceId=$WATCHLIST_WORKSPACE_ID --parameters workspaceSharedKey=$WATCHLIST_WORKSPACE_SHARED_KEY)

    # Finally publish our function app package
    (cd functionapp/; func azure functionapp publish $FUNCTION_APP_NAME)
fi