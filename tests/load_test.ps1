
$url = "http://127.0.0.1:30080/fortune"
$results = @()

for ($i = 1; $i -le 100; $i++) {
    $timer = [System.Diagnostics.Stopwatch]::StartNew()

    try {
        $response = Invoke-WebRequest `
            -Uri $url `
            -TimeoutSec 5 `
            -UseBasicParsing

        $timer.Stop()

        $results += [PSCustomObject]@{
            Request = $i
            ResponseTimeMs = $timer.Elapsed.TotalMilliseconds
            Status = $response.StatusCode
        }

    } catch {
        $timer.Stop()

        $results += [PSCustomObject]@{
            Request = $i
            ResponseTimeMs = $timer.Elapsed.TotalMilliseconds
            Status = "Error"
        }
    }
}

$results | Export-Csv "load_results.csv" -NoTypeInformation

$successful = @($results | Where-Object { $_.Status -eq 200 })
$failed = @($results | Where-Object { $_.Status -ne 200 })

Write-Host "Successful: $($successful.Count)"
Write-Host "Failed: $($failed.Count)"

if ($successful.Count -gt 0) {
    $stats = $successful |
        Measure-Object -Property ResponseTimeMs -Average -Minimum -Maximum

    Write-Host "Average (ms): $($stats.Average)"
    Write-Host "Minimum (ms): $($stats.Minimum)"
    Write-Host "Maximum (ms): $($stats.Maximum)"
}
