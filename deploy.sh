#!/bin/bash
if [ -z "$1" ] || [ -z "$2" ] || [ -z "$3" ] || [ -z "$4" ] || [ -z "$5" ] || [ -z "$6" ] || [ -z "$7" ]
then
   echo "Arguments required: $0 [RESOURCE_GROUP] [LOCATION] [STORAGE_ACCOUNT_NAME] [STORAGE_ACCOUNT_RESOURCE_GROUP] [STORAGE_ACCOUNT_SUBSCRIPTION_ID] [WATCHLIST_WORKSPACE_ID] [WATCHLIST_WORKSPACE_SHARED_KEY]";
   exit 1
else
    RESOURCE_GROUP="$1"
    LOCATION="$2"
    STORAGE_ACCOUNT_NAME="$3"
    STORAGE_ACCOUNT_RESOURCE_GROUP="$4"
    STORAGE_ACCOUNT_SUBSCRIPTION_ID="$5"
    WATCHLIST_WORKSPACE_ID="$6"
    WATCHLIST_WORKSPACE_SHARED_KEY="$7"
    STORAGE_ACCOUNT_FILE_SHARE_NAME="$8"
    STORAGE_ACCOUNT_FILE_SHARE_ACCESS_KEY="$9"

    # Create the target resource group
    az group create --name $RESOURCE_GROUP --location $LOCATION

    # build our bicep template
    az bicep build --file main.bicep

    # deploy our template to azure and get functionappname
    if [ -z ${STORAGE_ACCOUNT_FILE_SHARE_NAME} ]; then 
        OUTPUT=$(az deployment group create --query '[properties.outputs.functionAppName.value,properties.outputs.functionPrincipalId.value]' --output tsv --resource-group $RESOURCE_GROUP --template-file main.json --parameters watchlistStorageAccountName=$STORAGE_ACCOUNT_NAME --parameters watchlistStorageSubscriptionId=$STORAGE_ACCOUNT_SUBSCRIPTION_ID --parameters watchlistWorkspaceId=$WATCHLIST_WORKSPACE_ID --parameters workspaceSharedKey=$WATCHLIST_WORKSPACE_SHARED_KEY)
    else
        if [ -z ${STORAGE_ACCOUNT_FILE_SHARE_ACCESS_KEY} ]; then 
            OUTPUT=$(az deployment group create --query '[properties.outputs.functionAppName.value,properties.outputs.functionPrincipalId.value]' --output tsv --resource-group $RESOURCE_GROUP --template-file main.json --parameters watchlistStorageAccountName=$STORAGE_ACCOUNT_NAME --parameters watchlistStorageSubscriptionId=$STORAGE_ACCOUNT_SUBSCRIPTION_ID --parameters watchlistWorkspaceId=$WATCHLIST_WORKSPACE_ID --parameters workspaceSharedKey=$WATCHLIST_WORKSPACE_SHARED_KEY --parameters watchlistStorageAccountFileShareName=$STORAGE_ACCOUNT_FILE_SHARE_NAME)
        else
            OUTPUT=$(az deployment group create --query '[properties.outputs.functionAppName.value,properties.outputs.functionPrincipalId.value]' --output tsv --resource-group $RESOURCE_GROUP --template-file main.json --parameters watchlistStorageAccountName=$STORAGE_ACCOUNT_NAME --parameters watchlistStorageSubscriptionId=$STORAGE_ACCOUNT_SUBSCRIPTION_ID --parameters watchlistWorkspaceId=$WATCHLIST_WORKSPACE_ID --parameters workspaceSharedKey=$WATCHLIST_WORKSPACE_SHARED_KEY --parameters watchlistStorageAccountFileShareName=$STORAGE_ACCOUNT_FILE_SHARE_NAME --parameters watchlistStorageAccountFileShareAccessKey=$STORAGE_ACCOUNT_FILE_SHARE_ACCESS_KEY)
        fi
    fi
    IFS=$'\n' read -d '' -ra VARIABLES <<< "$OUTPUT"
    FUNCTION_APP=${VARIABLES[0]} 
    PRINCIPAL_ID=${VARIABLES[1]} 

    SCOPE_ID="/subscriptions/$STORAGE_ACCOUNT_SUBSCRIPTION_ID/resourceGroups/$STORAGE_ACCOUNT_RESOURCE_GROUP/providers/Microsoft.Storage/storageAccounts/$STORAGE_ACCOUNT_NAME"
    
    if [ -z ${STORAGE_ACCOUNT_FILE_SHARE_NAME} ]; then az role assignment create --assignee "$PRINCIPAL_ID" --role "Storage Blob Data Contributor" --scope "$SCOPE_ID"; fi
    if [ -z ${STORAGE_ACCOUNT_FILE_SHARE_ACCESS_KEY} ]; then az role assignment create --assignee "$PRINCIPAL_ID" --role "Storage File Data SMB Share Contributor" --scope "$SCOPE_ID"; fi

    # Finally publish our function app package
    (cd functionapp/; func azure functionapp publish $FUNCTION_APP)
fi