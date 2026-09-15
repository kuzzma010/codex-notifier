param([string]$OutputPath = "$PSScriptRoot\CodexNotifier.exe", [switch]$Regression)
$ErrorActionPreference = 'Stop'
$taskFramework = "$env:WINDIR\Microsoft.NET\Framework64\v4.0.30319"
$taskRefs = @('System.Windows.Forms.dll', 'System.Drawing.dll', 'System.Web.Extensions.dll', 'System.Xaml.dll', "$taskFramework\WPF\WindowsBase.dll", "$taskFramework\WPF\PresentationCore.dll", "$taskFramework\WPF\PresentationFramework.dll", "$taskFramework\WPF\WindowsFormsIntegration.dll")
$taskArgs = @('/nologo', '/optimize+', '/target:winexe', "/out:$OutputPath")
$taskArgs += "/win32icon:$PSScriptRoot\Assets\App.ico"
$taskArgs += "/resource:$PSScriptRoot\Assets\App.ico,App.ico"
$taskRefs += "$taskFramework\WPF\UIAutomationClient.dll"
$taskRefs += "$taskFramework\WPF\UIAutomationTypes.dll"
foreach ($taskRef in $taskRefs) { $taskArgs += "/reference:$taskRef" }
foreach ($taskResource in @('UiTheme.xaml','Notice.xaml','Settings.xaml')) { $taskArgs += "/resource:$PSScriptRoot\$taskResource,$taskResource" }
foreach ($taskFile in @('Watcher.cs','Notifier.cs','SelfTest.cs','AppSettings.cs','DesktopUi.cs','QuickReply.cs')) { $taskArgs += "$PSScriptRoot\$taskFile" }
if ($Regression) { $taskArgs += '/main:UiRegression'; $taskArgs += "$PSScriptRoot\UiRegression.cs" }
& "$taskFramework\csc.exe" $taskArgs
if ($LASTEXITCODE -ne 0) { throw "Compilation failed: $LASTEXITCODE" }
