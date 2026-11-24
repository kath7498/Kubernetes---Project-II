
# Internal Kubernetes HTTP monitoring

$duration = 40
$testId = Get-Date -Format "yyyyMMdd_HHmmss"
$output = "internal_results_$testId.csv"

# Python runs inside bully-app-0
$pythonCode = @'
import urllib.request
import urllib.error
import time
from datetime import datetime, timezone

url = "http://fortune-service/fortune"
duration = 40

start = time.monotonic()

print("TimestampUtc,ElapsedSeconds,ResponseTimeMs,Success,Status,Error", flush=True)

while time.monotonic() - start < duration:
    timestamp = datetime.now(timezone.utc).isoformat()
    elapsed = time.monotonic() - start
    request_start = time.monotonic()

    success = False
    status = "Error"
    error = ""

    try:
        with urllib.request.urlopen(url, timeout=2) as response:
            status = response.status
            success = (status == 200)
            response.read()

    except urllib.error.HTTPError as e:
        status = e.code
        error = str(e)

    except Exception as e:
        error = str(e)

    response_ms = (time.monotonic() - request_start) * 1000

    # Prevent commas from breaking CSV format
    error = error.replace(",", ";").replace("\n", " ")

    print(
        f"{timestamp},{elapsed:.3f},{response_ms:.3f},"
        f"{success},{status},{error}",
        flush=True
    )

    time.sleep(0.2)
'@

Write-Host "Starting internal monitoring from bully-app-0..."
Write-Host "Results: $output"

kubectl exec bully-app-0 -- python -u -c $pythonCode |
    Tee-Object -FilePath $output

Write-Host "Internal monitoring completed."
