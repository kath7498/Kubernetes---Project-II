# Experiment runner for the Fortune Cookie / Bully Kubernetes project.
# Run from the tests directory:
#   .\experiment_test.ps1 -Scenario Baseline
#   .\experiment_test.ps1 -Scenario FollowerFailure
#   .\experiment_test.ps1 -Scenario LeaderFailure

param(
    [ValidateSet("Baseline", "FollowerFailure", "LeaderFailure")]
    [string]$Scenario = "Baseline",
    [int]$RequestCount = 100,
    [int]$DurationSeconds = 40,
    [int]$DeleteAfterSeconds = 5
)

$ErrorActionPreference = "Stop"
$url = "http://127.0.0.1:30080/fortune"
$resultsDir = Join-Path $PSScriptRoot "results"
New-Item -ItemType Directory -Force -Path $resultsDir | Out-Null
$runId = (Get-Date).ToString("yyyyMMdd_HHmmss")
$stem = Join-Path $resultsDir "${Scenario}_${runId}"

function Test-FortuneHttp {
    $requestTimestamp = Get-Date
    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    $status = "Error"
    $errorMessage = ""
    $ok = $false
    try {
        $response = Invoke-WebRequest -Uri $url -TimeoutSec 2 -UseBasicParsing -DisableKeepAlive -ErrorAction Stop
        $status = [int]$response.StatusCode
        $ok = ($status -eq 200)
    }
    catch {
        $errorMessage = $_.Exception.Message
        if ($null -ne $_.Exception.Response) {
            try { $status = [int]$_.Exception.Response.StatusCode }
            catch { $status = "Error" }
        }
    }
    $stopwatch.Stop()
    return [PSCustomObject]@{
        StartTime = $requestTimestamp.ToString("o")
        EndTime = (Get-Date).ToString("o")
        ResponseTimeMs = [math]::Round($stopwatch.Elapsed.TotalMilliseconds, 3)
        Success = $ok
        Status = $status
        ErrorMessage = $errorMessage
    }
}

# Verify the user-facing service before collecting data.
Write-Host "Checking the service..."
$preflight = Test-FortuneHttp
if (-not $preflight.Success) {
    throw "Preflight failed (status $($preflight.Status)): $($preflight.ErrorMessage). No experiment was started."
}

# Identify the leader. We check every running pod directly.
$podString = kubectl get pods -l app=bully-app -o jsonpath='{.items[*].metadata.name}'
if ($LASTEXITCODE -ne 0) { throw "Could not list Kubernetes pods." }
$pods = @($podString -split '\s+' | Where-Object { $_ })
if ($pods.Count -ne 3) { throw "Expected three pods, found $($pods.Count): $podString" }
$leaders = [System.Collections.Generic.List[string]]::new()
foreach ($pod in $pods) {
    $podStatusJson = kubectl exec $pod -- python -c "import urllib.request; print(urllib.request.urlopen('http://127.0.0.1:8080/status', timeout=3).read().decode())" 2>$null
    if ($LASTEXITCODE -ne 0) { throw "Could not check $pod before experiment." }
    $podStatus = $podStatusJson | ConvertFrom-Json
    if ($podStatus.is_leader) { $leaders.Add($pod) }
}
if ($leaders.Count -ne 1) { throw "Expected one leader, found $($leaders.Count)." }
$leaderPod = $leaders[0]
$podToDelete = $null
if ($Scenario -eq "LeaderFailure") { $podToDelete = $leaderPod }
if ($Scenario -eq "FollowerFailure") {
    $followers = @($pods | Where-Object { $_ -ne $leaderPod } | Sort-Object)
    $podToDelete = $followers[0]
}

Write-Host "Scenario: $Scenario; leader before test: $leaderPod"
if ($podToDelete) { Write-Host "Pod to delete: $podToDelete (after $DeleteAfterSeconds seconds)" }

$results = [System.Collections.Generic.List[object]]::new()
$experimentStart = Get-Date
$timer = [System.Diagnostics.Stopwatch]::StartNew()
$deletionTime = $null
$deletionElapsed = $null
$didDelete = $false
$number = 0

while ($true) {
    if ($Scenario -eq "Baseline") {
        if ($number -ge $RequestCount) { break }
    }
    elseif ($timer.Elapsed.TotalSeconds -ge $DurationSeconds) { break }

    if ($podToDelete -and -not $didDelete -and $timer.Elapsed.TotalSeconds -ge $DeleteAfterSeconds) {
        $deletionTime = Get-Date
        $deletionElapsed = [math]::Round($timer.Elapsed.TotalSeconds, 3)
        Write-Host "DELETING $podToDelete at $deletionElapsed s"
        kubectl delete pod $podToDelete --wait=false
        if ($LASTEXITCODE -ne 0) { throw "Pod deletion failed." }
        $didDelete = $true
    }

    $number++
    $startElapsed = [math]::Round($timer.Elapsed.TotalSeconds, 3)
    $measurement = Test-FortuneHttp
    $endElapsed = [math]::Round($timer.Elapsed.TotalSeconds, 3)
    $results.Add([PSCustomObject]@{
        Request = $number
        RequestStartElapsedSec = $startElapsed
        RequestEndElapsedSec = $endElapsed
        StartTime = $measurement.StartTime
        EndTime = $measurement.EndTime
        ResponseTimeMs = $measurement.ResponseTimeMs
        Success = $measurement.Success
        Status = $measurement.Status
        ErrorMessage = $measurement.ErrorMessage
        DeleteRequested = $didDelete
    })
    Write-Host "Request $number | HTTP $($measurement.Status) | Response time: $($measurement.ResponseTimeMs) ms | Success: $($measurement.Success)"
    if ($Scenario -ne "Baseline") { Start-Sleep -Milliseconds 200 }
}
$timer.Stop()

$csvPath = "${stem}.csv"
$results | Export-Csv -Path $csvPath -NoTypeInformation -Encoding UTF8
$okRows = @($results | Where-Object { $_.Success })
$failedRows = @($results | Where-Object { -not $_.Success })
$times = @($okRows | ForEach-Object { $_.ResponseTimeMs })
$meanMs = $null; $minMs = $null; $maxMs = $null
if ($times.Count -gt 0) {
    $statistics = $times | Measure-Object -Average -Minimum -Maximum
    $meanMs = [math]::Round($statistics.Average, 3)
    $minMs = [math]::Round($statistics.Minimum, 3)
    $maxMs = [math]::Round($statistics.Maximum, 3)
}
$deletionTimeString = $null
if ($deletionTime) { $deletionTimeString = $deletionTime.ToString("o") }
$intervalBetweenRequestsMs = 0
if ($Scenario -ne "Baseline") { $intervalBetweenRequestsMs = 200 }
$metadata = [ordered]@{
    Scenario = $Scenario
    StartTime = $experimentStart.ToString("o")
    InitialLeader = $leaderPod
    PodDeleted = $podToDelete
    DeletionRequestedAt = $deletionTimeString
    DeletionRequestedElapsedSec = $deletionElapsed
    NumberOfRequests = $results.Count
    SuccessfulRequests = $okRows.Count
    FailedRequests = $failedRows.Count
    MeanSuccessfulResponseMs = $meanMs
    MinSuccessfulResponseMs = $minMs
    MaxSuccessfulResponseMs = $maxMs
    HttpTimeoutSeconds = 2
    IntervalBetweenRequestsMs = $intervalBetweenRequestsMs
    ResultsFile = $csvPath
}