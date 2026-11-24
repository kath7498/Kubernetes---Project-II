# Configuration
$url = "http://127.0.0.1:30080/fortune"
$duration = 30
$deleteAfter = 5

$results = [System.Collections.Generic.List[object]]::new()

# Find current leader
$pods = kubectl get pods -l app=bully-app -o jsonpath='{.items[*].metadata.name}'

if ($LASTEXITCODE -ne 0) {
    throw "Failed to retrieve pods from Kubernetes."
}
$leaderPod = $null

foreach ($pod in $pods.Split(" ", [System.StringSplitOptions]::RemoveEmptyEntries)) {
    $json = kubectl exec $pod -- python -c "import urllib.request; print(urllib.request.urlopen('http://127.0.0.1:8080/status', timeout=3).read().decode())" 2>$null

    if ($LASTEXITCODE -eq 0) {
        $status = $json | ConvertFrom-Json

        if ($status.is_leader) {
            $leaderPod = $pod
            break
        }
    }
}

if (-not $leaderPod) {
    throw "No leader found. Check pod status before testing."
}

Write-Host "Current leader: $leaderPod"
Write-Host "Starting HTTP monitoring..."
Write-Host "Leader will be deleted after $deleteAfter seconds."

$start = Get-Date
$deletionTime = $null
$deleted = $false
$requestNumber = 0

while (((Get-Date) - $start).TotalSeconds -lt $duration) {

    # Delete leader after the configured delay
    if (-not $deleted -and
        ((Get-Date) - $start).TotalSeconds -ge $deleteAfter) {

        $deletionTime = Get-Date

        Write-Host "DELETING LEADER: $leaderPod"

        kubectl delete pod $leaderPod --wait=false

        if ($LASTEXITCODE -ne 0) {
            throw "Pod deletion failed"
        }

        $deleted = $true
    }

    $requestNumber++
    $timestamp = Get-Date
    $timer = [System.Diagnostics.Stopwatch]::StartNew()
    $success = $false
    $httpStatus = "Error"
    $errorMessage = ""

    try {
        $response = Invoke-WebRequest `
            -Uri $url `
            -TimeoutSec 2 `
            -UseBasicParsing `
            -DisableKeepAlive

        $httpStatus = $response.StatusCode
        $success = ($httpStatus -eq 200)
    }
    catch {
        $success = $false
        $httpStatus = "Error"
        $errorMessage = $_.Exception.Message

        Write-Host "HTTP ERROR: $errorMessage" -ForegroundColor Red
    }

    $timer.Stop()

    $elapsed = ($timestamp - $start).TotalSeconds

    $results.Add([PSCustomObject]@{
        Request = $requestNumber
        Timestamp = $timestamp.ToString("o")
        ElapsedSeconds = [math]::Round($elapsed, 3)
        ResponseTimeMs = [math]::Round(
            $timer.Elapsed.TotalMilliseconds, 3
        )
        Success = $success
        Status = $httpStatus
        ErrorMessage = $errorMessage
        LeaderDeleted = $deleted
    })

    Write-Host "$([math]::Round($elapsed, 2)) s | Success: $success"

    Start-Sleep -Milliseconds 200
}

# Save data

$testId = Get-Date -Format "yyyyMMdd_HHmmss"

$results | Export-Csv `
    "failover_results_$testId.csv" `
    -NoTypeInformation

if ($deletionTime) {
    [PSCustomObject]@{
        LeaderPod = $leaderPod
        DeletionRequestedAt = $deletionTime.ToString("o")
        DeletionElapsedSeconds = [math]::Round(
            ($deletionTime - $start).TotalSeconds, 3
        )
    } | Export-Csv "failover_event_$testId.csv" -NoTypeInformation
}

Write-Host "Test completed."
Write-Host "Results saved."
