$Default_Image="ethomson/rust-build-win32:latest"
$Default_ShareDir="C:\Data\Share"

$AgentPipelinesAccount = "rust-lang"
$AgentRepo="microsoft/azure-pipelines-agent"

Set-StrictMode -Version Latest

$ErrorActionPreference = "Stop"
$PSDefaultParameterValues['*:ErrorAction'] = 'Stop'

if (-not $Env:AZURE_PIPELINES_URL -or -not $Env:AZURE_PIPELINES_POOL -or -not $Env:AZURE_PIPELINES_PAT) {
	[System.Console]::Error.WriteLine("Configuration is incomplete; the following environment variables must be set:")
	[System.Console]::Error.WriteLine(" AZURE_PIPELINES_URL to the URL of your Azure DevOps organization")
	[System.Console]::Error.WriteLine(" AZURE_PIPELINES_POOL to the name of the pool that this agent will belong")
	[System.Console]::Error.WriteLine(" AZURE_PIPELINES_PAT to the PAT to authenticate to Azure DevOps")
	exit 1
}

function CheckLastExitCode {
	if ($LastExitCode -ne 0) { Write-Error "Command failed with exit code ${LastExitCode}" }
}

function CleanupAgent($path) {
	if (Test-Path "${path}") {
		if (Test-Path "${path}\.agent") { attrib -h "${path}\.agent" }
		if (Test-Path "${path}\.credentials") { attrib -h "${path}\.credentials" }
		if (Test-Path "${path}\.credentials_rsaparams") { attrib -h "${path}\.credentials_rsaparams" }
		Remove-Item -Path "${path}" -Recurse
	}
}

if ($Env:AZURE_PIPELINES_AGENT_NAME) { $Agent_Name=$Env:AZURE_PIPELINES_AGENT_NAME } else { $Agent_Name="$(hostname)" }
if ($Env:IMAGE) { $Agent_Image=$Env:IMAGE } else { $Agent_Image=$Default_Image }
if ($Env:SHARE_DIR) { $Agent_ShareDir=$Env:SHARE_DIR } else { $Agent_ShareDir=$Default_ShareDir }
if ($Env:STORAGE_SIZE) { $Agent_Storage=$Env:STORAGE_SIZE } else { $Agent_Storage="20G" }

$Agent_MapPath=$Agent_ShareDir.replace("\\", "/");

Write-Host ""
Write-Host ":: Updating runner image (${Agent_Image})..."
docker pull "${Agent_Image}"

# Register an agent that will remain idle; we always need an agent in the
# pool and since our container agents create and delete themselves, there's
# a possibility of the pool existing with no agents in it, and jobs will
# fail to queue in this case.  This idle agent will prevent that.

if (-not $Env:SKIP_RESERVEDAGENT) {
	Write-Host ""
	Write-Host ":: Setting up reserved agent (${Env:AZURE_PIPELINES_POOL}_reserved)..."
	CleanupAgent C:\Data\Reserved_Agent
	Copy-Item C:\Data\Agent C:\Data\Reserved_Agent -Recurse
	C:\Data\Reserved_Agent\config.cmd --unattended --url "${Env:AZURE_PIPELINES_URL}" --pool "${Env:AZURE_PIPELINES_POOL}" --agent "${Env:AZURE_PIPELINES_POOL}_reserved" --auth pat --token "${Env:AZURE_PIPELINES_PAT}" --replace
	CheckLastExitCode
}


$ret=0

while ($ret -eq 0) {
	Write-Host ""
	Write-Host ":: Updating agent image..."
	docker pull "${Agent_Image}"

	Write-Host ""
	Write-Host ":: Checking agent version..."
	$currentVersion = $null
	$latestVersion = $null
	$latestUrl = $null

	$webclient=New-Object Net.WebClient
	$webclient.Headers.Add("User-Agent", "azure-pipelines-build/0.42")
	$webclient.Headers.Add("Authorization", "Basic " + [Convert]::ToBase64String([System.Text.Encoding]::ASCII.GetBytes("azpagent" + ":" + $Env:AZURE_PIPELINES_PAT)))

	$packages = $webclient.DownloadString("https://dev.azure.com/${AgentPipelinesAccount}/_apis/distributedtask/packages/agent?%24top=1") | ConvertFrom-Json

	foreach ($package in $packages.value) {
		if ($package.platform -eq "win-x64") {
			$latestVersion = ($package.version.major, $package.version.minor, $package.version.patch) -Join '.'
			$latestUrl = $package.downloadUrl
			break
		}
	}

	if ($latestVersion -eq $null) {
		Write-Host "!! ERROR: could not get package version"
		exit 1
	}

	if (Test-Path -Path "C:\Data\Agent\version.txt") {
		$currentVersion = Get-Content "C:\Data\Agent\version.txt"
	}

	if ($latestVersion -ne $currentVersion) {
		Write-Host ""
		Write-Host ":: Upgrading agent to ${latestVersion}..."

		$webclient=(new-object net.webclient)
		$webclient.Headers.Add("User-Agent", "azure-pipelines-build/0.42")
		$webclient.DownloadFile($latestUrl, "C:\Temp\agent.zip")

		Expand-Archive -Path "C:\Temp\Agent.zip" -DestinationPath "C:\Data\Agent" -Force
		[System.IO.File]::WriteAllLines("C:\Data\\Agent\version.txt", $latestVersion)
		Copy-Item C:\Data\Agent "${Agent_ShareDir}\Agent" -Recurse -Force
	}

	# Set up the actual runner that will do work.
	Write-Host ""
	Write-Host ":: Setting up runner agent (${Agent_Name})..."
	CleanupAgent "${Agent_ShareDir}\Agent"
	Copy-Item C:\Data\Agent "${Agent_ShareDir}\Agent" -Recurse -Force

	# Configure the agent; map the shared path as a read-write share so that
	# we can set up the tokens for the actual runner.
	docker run -v "${Agent_MapPath}:${Agent_MapPath}" --storage-opt size="${Agent_Storage}" "${Agent_Image}" powershell """${Agent_ShareDir}\Agent\config.cmd"" --unattended --url ""${Env:AZURE_PIPELINES_URL}"" --pool ""${Env:AZURE_PIPELINES_POOL}"" --agent ""${Agent_Name}"" --auth pat --token ""${Env:AZURE_PIPELINES_PAT}"" --replace"
	CheckLastExitCode

	Write-Host ""
	Write-Host ":: Starting agent..."

	# Run the agent; map the shared path as a read-only share so that
	# the build code is wholly isolated and cannot mutate any shared
	# state.
	docker run -v "${Agent_MapPath}:${Agent_MapPath}:ro" --storage-opt size="${Agent_Storage}" "${Agent_Image}" powershell "Copy-Item ""${Agent_ShareDir}\Agent"" C:\ -Recurse ; ""C:\Agent\run.cmd"" --once"

	$ret=$LastExitCode
	Write-Host ":: Agent exited with: ${ret}"
}

Write-Host ""
Write-Host ":: Cleaning up runner agent..."
& "${Agent_ShareDir}\Agent\config.cmd" remove --auth pat --token "${Env:AZURE_PIPELINES_PAT}"
CheckLastExitCode

echo ":: Exiting (exit code ${ret})"
exit $ret
