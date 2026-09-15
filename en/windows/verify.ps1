$ErrorActionPreference = 'Stop'
$taskOut = Join-Path $PSScriptRoot 'build/verification'
New-Item -ItemType Directory -Force $taskOut | Out-Null
foreach ($taskKind in @('core','ui')) {
    $taskExe = Join-Path $taskOut ($taskKind + '.exe')
    & "$PSScriptRoot/build.ps1" -OutputPath $taskExe -Regression:($taskKind -eq 'ui')
    $taskArguments = if ($taskKind -eq 'core') { '--self-test' } else { '--verify' }
    $taskProcess = Start-Process $taskExe -ArgumentList $taskArguments -WindowStyle Hidden -PassThru
    if (-not $taskProcess.WaitForExit(30000)) {
        Stop-Process -Id $taskProcess.Id
        throw "Verification timed out: $taskKind"
    }
    $taskResult = Join-Path $taskOut $(if ($taskKind -eq 'core') { 'test-result.txt' } else { 'ui-test-result.txt' })
    if ($taskProcess.ExitCode -ne 0) { throw "Verification failed: $taskKind" }
    $taskText = Get-Content $taskResult -Raw
    if (-not $taskText.StartsWith('PASS:')) { throw $taskText }
    Write-Output $taskText.Trim()
}
