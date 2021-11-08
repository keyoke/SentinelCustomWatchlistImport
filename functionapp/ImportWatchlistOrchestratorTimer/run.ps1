using namespace System.Net

param($Timer)

$InstanceId = Start-DurableOrchestration -FunctionName "ImportWatchlistOrchestrator"
Write-Host "Started orchestration with ID = '$InstanceId'"
