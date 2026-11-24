
$url = "http://127.0.0.1:30080/fortune"
$results = @()

Write-Host "Starting failover test..."
Write-Host "Delete the leader pod in another terminal."


# Verify that the service is available before testing
Write-Host "Checking service availability..."

$preflightSuccess = $false

for ($attempt = 1; $attempt -le 5; $attempt++) {
    try {
        $response = Invoke-WebRequest `
            -Uri $url `
            -TimeoutSec 3 `
            -DisableKeepAlive `
            -ErrorAction Stop

        if ($response.StatusCode -eq 200) {
            $preflightSuccess = $true
            break
        }
    }
    catch {
        Write-Host "Preflight attempt $attempt failed"
    }

    Start-Sleep -Seconds 1
}

if (-not $preflightSuccess) {
    throw "Service is unavailable before failover. Test aborted."
}

Write-Host "Preflight passed. Starting test."


$start = Get-Date

# Run the test for 120 seconds
while (((Get-Date) - $start).TotalSeconds -lt 120) {

    $timestamp = Get-Date
    $timer = [System.Diagnostics.Stopwatch]::StartNew()

    try {
        $response = Invoke-WebRequest `
            -Uri $url `
            -TimeoutSec 2 `
            -UseBasicParsing

        $success = ($response.StatusCode -eq 200)
    }
    catch {
        $success = $false
    }

    $timer.Stop()

    $results += [PSCustomObject]@{
        Timestamp = $timestamp.ToString("o")
        ElapsedSeconds = [math]::Round(
            ($timestamp - $start).TotalSeconds, 3
        )
        ResponseTimeMs = [math]::Round(
            $timer.Elapsed.TotalMilliseconds, 3
        )
        Success = $success
    }

    Write-Host "Success: $success | Time: $([math]::Round($timer.Elapsed.TotalMilliseconds, 2)) ms"

    Start-Sleep -Milliseconds 200
}

# Save results
$results | Export-Csv "failover_results.csv" -NoTypeInformation

Write-Host "Test completed!"
Write-Host "Results saved to failover_results.csv"
