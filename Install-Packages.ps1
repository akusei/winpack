function Install-Dependencies
{
    if ((Get-PackageProvider | Select-Object Name).name -notcontains "nuget") {
        Write-Host "Installing NuGet Package Provider"
        Install-PackageProvider -Name NuGet -Force | Out-Null
    }
    if (!(Get-Module -ListAvailable -Name powershell-yaml)) {
        Write-Host "Installing YAML Powershell Module"
        Install-Module -Name powershell-yaml -Force -SkipPublisherCheck
    }
    if (!(Get-Module -ListAvailable -Name chocolatey)) {
        Write-Host "Installing Chocolatey"
        Install-Module -Name chocolatey -Force
    }
}

function Set-AutoLogin
{
    param (
        [Parameter(Mandatory=$True, ParameterSetName="enable")]
        [Switch] $Enabled,

        [Parameter(Mandatory=$True, ParameterSetName="enable")]
        [PSCredential] $Credential,

        [Parameter(Mandatory=$true, ParameterSetName="disable")]
        [Switch] $Disable
    )

    $regPath = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon"
    if ($Enabled)
    {
        Set-ItemProperty -Path $regPath -Name DefaultUserName -Value $Credential.GetNetworkCredential().UserName
        Set-ItemProperty -Path $regPath -Name DefaultPassword -Value $Credential.GetNetworkCredential().Password
        Set-ItemProperty -Path $regPath -Name AutoAdminLogon -Value 1
        Set-ItemProperty -Path $regPath -Name ForceAutoLogon -Value 1
    }

    if ($Disabled)
    {
        Remove-ItemProperty -Path $regPath -Name DefaultUserName -ErrorAction SilentlyContinue
        Remove-ItemProperty -Path $regPath -Name DefaultPassword -ErrorAction SilentlyContinue
        Set-ItemProperty -Path $regPath -Name AutoAdminLogon -Value 0 -ErrorAction SilentlyContinue
        Set-ItemProperty -Path $regPath -Name ForceAutoLogon -Value 0 -ErrorAction SilentlyContinue    
    }
}

function Unregister-RebootHandler
{
    Unregister-ScheduledTask -TaskName $Global:REBOOT_HANDLER -Confirm:$false
    Set-AutoLogin -Disable
}

function Register-RebootHandler
{
    param (
        [Parameter(Mandatory=$True)]
        [pscredential] $Credential
    )

    # Register the scheduled job
    $settingsArgs = @{
        "RunOnlyIfNetworkAvailable" = $true
        "AllowStartIfOnBatteries" = $true
        "MultipleInstances" = "IgnoreNew"
        "DontStopIfGoingOnBatteries" = $true
    }

    $principalArgs = @{
        "-RunLevel" = "Highest"
        "-LogonType" = "Interactive"
        "-UserId" = $Credential.GetNetworkCredential().UserName
    }

    $actionArgs = @{
        "-WorkingDirectory" = (Get-Location).Path
        "-Argument" = "-NoLogo -Command `"${Global:CURRENT_SCRIPT}`""
        "-Execute" = "powershell.exe"
    }

    $jobParams = @{
        "-TaskName" = $Global:REBOOT_HANDLER
        "-Trigger" = New-JobTrigger -AtLogOn 
        "-Settings" = New-ScheduledTaskSettingsSet @settingsArgs
        "-Action" = New-ScheduledTaskAction @actionArgs
        "-Principal" = New-ScheduledTaskPrincipal @principalArgs
    }

    Register-ScheduledTask @jobParams | Out-Null
    Set-AutoLogin -Enabled -Credential $Credential
}

function Save-State
{
    param (
        [Parameter(Mandatory=$true)]
        [Hashtable] $State
    )

    if (!(Test-Path $Global:STATE_PATH)) {
        New-Item -Path $Global:STATE_ROOT -Name ${STATE_REG} -Force | Out-Null
    }

    [String] $data = $State | ConvertTo-Json -Compress
    Set-ItemProperty -Path $Global:STATE_PATH -Name $Global:STATE_VALUE -Value $data | Out-Null
}

function Remove-State
{
    if (!(Test-Path $Global:STATE_PATH)) {
        return
    }

    Remove-Item -Path $Global:STATE_PATH -Force
}

function Restore-State
{
    if (!(Test-Path $Global:STATE_PATH)) {
        return @{
            packages = @()
            installed = @()
            initial = $true
            needsReboot = $false
            complete = $false
        }
    }

    $data = Get-ItemProperty -Path $Global:STATE_PATH -Name $Global:STATE_VALUE
    $stateTable = @{}
    ($data.State | ConvertFrom-Json).psobject.properties | ForEach-Object { $stateTable[$_.Name] = $_.Value }

    $packages = @()
    foreach ($item in $stateTable.packages)
    {
        $package = @{}
        $item.psobject.properties | ForEach-Object { $package[$_.Name] = $_.Value }
        $packages += $package
    }
    $stateTable.packages = $packages

    return $stateTable
}

function Install-Packages
{
    param (
        [Parameter(Mandatory=$true)]
        [Hashtable] $State
    )

    # TODO: switch to using an index instead of name of package?
    foreach ($item in $State.packages)
    {
        if ($State.installed -contains $item.name)
        {
            Write-Host "Skipping $($item.name) [Already Installed]"
            continue
        }

        $packageName = "${PSScriptRoot}\packages\$($item.name)\$($item.name).nuspec"
        if (!(Test-Path "${packageName}")) {
            $packageName = $item.name
        }

        $extraArgs = @()
        if ($item.version) { $extraArgs += "--version=$($item.version)" }
        if ($item.source) { $extraArgs += "-s $($item.source)" }
        if ($item.ignore_checksum) { $extraArgs += "--ignore-checksum" }
        if ($item.arguments) { $extraArgs += "--params=`"$($item.arguments)`"" }

        & choco install ${packageName} -y --acceptlicense @extraArgs

        $State.installed += $item.name
        Save-State -State $State

        if ($item.reboot)
        {
            Restart-Computer -Force
            Start-Sleep -Seconds 86400
        }
    }

    $State.complete = $true
    Save-State -State $State
}

function Initialize-State
{
    $state = Restore-State
    if ($state.initial)
    {
        if (!(Test-Path "${PSScriptRoot}\packages.yml"))
        {
            Write-Host "No package.yml file found"
            exit 1
        }
        
        $packages = Get-Content "${PSScriptRoot}\packages.yml" | ConvertFrom-Yaml
        $needsReboot = ($packages.packages | ForEach-Object { $_.reboot }) -contains $True
        
        if ($needsReboot)
        {
            $creds = Get-Credential -UserName $(whoami) -Message "Credentials for automated installs" -ErrorAction SilentlyContinue
            if (!$creds)
            {
                Write-Host "Credentials are needed to perform automated install"
                exit
            }
        
            Add-Type -assemblyname system.DirectoryServices.accountmanagement 
            $DS = New-Object System.DirectoryServices.AccountManagement.PrincipalContext([System.DirectoryServices.AccountManagement.ContextType]::Machine)
            
            $username = $creds.GetNetworkCredential().UserName
            $password = $creds.GetNetworkCredential().Password
            if (!$DS.ValidateCredentials($username, $password))
            {
                Write-Host "Invalid username or password"
                exit
            }
        
            Register-RebootHandler -Credential $creds
        }
    
        $state.packages = $packages.packages
        $state.initial = $false
        $state.needsReboot = $needsReboot
        $state.complete = $false
    
        # Save-State -State $state
    }

    return $state
}


$Global:STATE_ROOT = "HKLM:\SOFTWARE"
$Global:STATE_REG = "Provisioning"
$Global:STATE_VALUE = "State"
$Global:STATE_PATH = "${Global:STATE_ROOT}\${Global:STATE_REG}"
$Global:REBOOT_HANDLER = "799fc494-98e9-4163-bb47-55637b923905"
$Global:CURRENT_SCRIPT = "$($MyInvocation.MyCommand.Path)"


$hasError = $false

try
{
    Install-Dependencies
    $state = Initialize-State
    Install-Packages -State $state
}
catch
{
    $hasError = $true
}
finally
{
    $state = Restore-State
    if ($hasError -or $state.complete)
    {
        Unregister-RebootHandler
        Remove-State
    }
}