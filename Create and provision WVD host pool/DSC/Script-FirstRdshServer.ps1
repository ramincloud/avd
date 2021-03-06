<#

.SYNOPSIS
Creating Hostpool and add sessionhost servers to existing/new Hostpool.

.DESCRIPTION
This script add sessionhost servers to existing/new Hostpool
The supported Operating Systems Windows Server 2016.

.ROLE
Readers

#>
param(
    [Parameter(mandatory = $true)]
    [string]$RDBrokerURL,

    [Parameter(mandatory = $true)]
    [string]$definedTenantGroupName,

    [Parameter(mandatory = $true)]
    [string]$TenantName,

    [Parameter(mandatory = $true)]
    [string]$HostPoolName,

    [Parameter(mandatory = $false)]
    [string]$Description,

    [Parameter(mandatory = $false)]
    [string]$FriendlyName,

    [Parameter(mandatory = $true)]
    [string]$Hours,

    [Parameter(mandatory = $true)]
    [PSCredential]$TenantAdminCredentials,

    [Parameter(mandatory = $false)]
    [string]$isServicePrincipal = "False",

    [Parameter(Mandatory = $false)]
    [AllowEmptyString()]
    [string]$AadTenantId="",

    [Parameter(Mandatory = $false)]
    [string]$EnablePersistentDesktop="False",

    [Parameter(Mandatory = $false)]
    [string]$DefaultDesktopUsers=""
)

$ScriptPath = [system.io.path]::GetDirectoryName($PSCommandPath)

# Dot sourcing Functions.ps1 file
. (Join-Path $ScriptPath "Functions.ps1")

# Setting ErrorActionPreference to stop script execution when error occurs
$ErrorActionPreference = "Stop"

# Testing if it is a ServicePrincipal and validade that AadTenant ID in this case is not null or empty
ValidateServicePrincipal -IsServicePrincipal $isServicePrincipal -AadTenantId $AadTenantId

Write-Log -Message "Creating a folder inside rdsh vm for extracting deployagent zip file"
$DeployAgentLocation = "C:\DeployAgent"
ExtractDeploymentAgentZipFile -ScriptPath $ScriptPath -DeployAgentLocation $DeployAgentLocation

Write-Log -Message "Changing current folder to Deployagent folder: $DeployAgentLocation"
Set-Location "$DeployAgentLocation"

# Checking if RDInfragent is registered or not in rdsh vm
$CheckRegistry = Get-ItemProperty -Path "Registry::HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\RDInfraAgent" -ErrorAction SilentlyContinue

Write-Log -Message "Checking whether VM was Registered with RDInfraAgent"

if ($CheckRegistry)
{
    Write-Log -Message "VM was already registered with RDInfraAgent, script execution was stopped"
}
else
{
    Write-Log -Message "VM not registered with RDInfraAgent, script execution will continue"

    # Importing Windows Virtual Desktop PowerShell module
    Import-Module .\PowershellModules\Microsoft.RDInfra.RDPowershell.dll

    Write-Log -Message "Imported Windows Virtual Desktop PowerShell modules successfully"

    # Getting fqdn of rdsh vm
    $SessionHostName = (Get-WmiObject win32_computersystem).DNSHostName + "." + (Get-WmiObject win32_computersystem).Domain
    Write-Log  -Message "Getting fully qualified domain name of RDSH VM: $SessionHostName"

    # Authenticating to Windows Virtual Desktop
    if ($isServicePrincipal -eq "True")
    {
        Write-Log  -Message "Authenticating using service principal $TenantAdminCredentials.username and Tenant id: $AadTenantId "
        $authentication = Add-RdsAccount -DeploymentUrl $RDBrokerURL -Credential $TenantAdminCredentials -ServicePrincipal -TenantId $AadTenantId 
    }
    else
    {
        Write-Log  -Message "Authenticating using user $($TenantAdminCredentials.username) "
        $authentication = Add-RdsAccount -DeploymentUrl $RDBrokerURL -Credential $TenantAdminCredentials
    }

    Write-Log  -Message "Authentication object: $($authentication | Out-String)"
    $obj = $authentication | Out-String

    if ($authentication)
    {
        Write-Log -Message "Windows Virtual Desktop Authentication successfully Done. Result:`n$obj"  
    }
    else
    {
        Write-Log -Error "Windows Virtual Desktop Authentication Failed, Error:`n$obj"
        throw "Windows Virtual Desktop Authentication Failed, Error:`n$obj"
    }

    # Set context to the appropriate tenant group
    Write-Log "Running switching to the $definedTenantGroupName context"
    if ($definedTenantGroupName -ne "Default Tenant Group") {
        Set-RdsContext -TenantGroupName $definedTenantGroupName
    }
    try
    {
        $tenants = Get-RdsTenant -Name "$TenantName"
        if(!$tenants)
        {
            Write-Log "No tenants exist or you do not have proper access."
        }
    }
    catch
    {
        Write-Log -Message $_
        throw $_
    }

    # Checking if host pool exists. If not, create a new one with the given HostPoolName
    Write-Log -Message "Checking Hostpool exists inside the Tenant"
    $HostPool = Get-RdsHostPool -TenantName "$TenantName" | Where-Object { $_.HostPoolName -eq "$HostPoolName"}
    $ApplicationGroupName = "Desktop Application Group"
    if ($HostPool)
    {
        Write-log -Message "Hostpool exists inside tenant: $TenantName"
    }
    else
    {
        $EnablePersistentDesktopOption=@{$true = "-Persistent"; $false = ""}[$EnablePersistentDesktop -ieq "true"]
        $HostPool = Invoke-Expression("New-RdsHostPool -TenantName `"`$TenantName`" -Name `"`$HostPoolName`" -Description `$Description -FriendlyName `$FriendlyName $EnablePersistentDesktopOption -ValidationEnv `$false")
        $HName = $HostPool.name | Out-String -Stream
        Write-Log -Message "Successfully created new Hostpool: $HName"
        
        Write-Log -Message "Changing Application Group: $ApplicationGroupName FriendlyName to: $HostPoolName"
        Set-RdsRemoteDesktop -TenantName $TenantName -HostPoolName $HostPoolName -AppGroupName $ApplicationGroupName -FriendlyName $HostPoolName
    }

    # Setting UseReverseConnect property to true
    Write-Log -Message "Checking Hostpool UseResversconnect is true or false"
    if ($HostPool.UseReverseConnect -eq $False)
    {
        Write-Log -Message "UseReverseConnect is false, it will be changed to true"
        Set-RdsHostPool -TenantName "$TenantName" -Name "$HostPoolName" -UseReverseConnect $true
    }
    else
    {
        Write-Log -Message "Hostpool UseReverseConnect already enabled as true"
    }

    $Registered = New-RdsRegistrationInfo -TenantName "$TenantName" -HostPoolName "$HostPoolName" -ExpirationHours $Hours -ErrorAction SilentlyContinue
    if (-Not $Registered)
    {
        $Registered = Export-RdsRegistrationInfo -TenantName "$TenantName" -HostPoolName "$HostPoolName" 
        $obj =  $Registered | Out-String
        Write-Log -Message "Exported Rds RegistrationInfo into variable 'Registered': $obj"
    }
    else
    {
        $obj =  $Registered | Out-String
        Write-Log -Message "Created new Rds RegistrationInfo into variable 'Registered': $obj"
    }

    # Executing DeployAgent psl file in rdsh vm and add to hostpool
    Write-Log "AgentInstaller is $DeployAgentLocation\RDAgentBootLoaderInstall, InfraInstaller is $DeployAgentLocation\RDInfraAgentInstall, SxS is $DeployAgentLocation\RDInfraSxSStackInstall"
    $DAgentInstall = .\DeployAgent.ps1 -AgentBootServiceInstallerFolder "$DeployAgentLocation\RDAgentBootLoaderInstall" `
                                       -AgentInstallerFolder "$DeployAgentLocation\RDInfraAgentInstall" `
                                       -RegistrationToken $Registered.Token `
                                       -StartAgent $true
    
    Write-Log -Message "DeployAgent Script was successfully executed and RDAgentBootLoader,RDAgent,StackSxS installed inside VM for existing hostpool: $HostPoolName`n$DAgentInstall"

    # Get Session Host Info
    Write-Log -Message "Getting rdsh host $SessionHostName information"

    [PsRdsSessionHost]$pssh = [PsRdsSessionHost]::new("$TenantName","$HostPoolName",$SessionHostName)
    [Microsoft.RDInfra.RDManagementData.RdMgmtSessionHost]$rdsh = $pssh.GetSessionHost()
    Write-Log -Message "RDSH object content: `n$($rdsh | Out-String)"

    $rdshName = $rdsh.SessionHostName | Out-String -Stream
    $poolName = $rdsh.hostpoolname | Out-String -Stream

    # Adding default users

    # Sanitizing $DefaultDesktopUsers from ", ' or spaces
    $DefaultDesktopUsers = $DefaultDesktopUsers.Replace("`"","").Replace("'","").Replace(" ","")
    if (-Not ([string]::IsNullOrEmpty($DefaultDesktopUsers)))
    {
        AddDefaultUsers -TenantName "$TenantName" -HostPoolName "$HostPoolName" -ApplicationGroupName $ApplicationGroupName -DefaultUsers $DefaultDesktopUsers
    }

    Write-Log -Message "Waiting for session host return when in available status"
    $AvailableSh =  $pssh.GetSessionHostWhenAvailable()
    if ($AvailableSh -ne $null)
    {
        Write-Log -Message "Session host $($rdsh.SessionHostName) is now in Available state"
    }
    else
    {
        Write-Log -Message "Session host $($rdsh.SessionHostName) not in Available state, wait timed out (threshold is $($rdsh.TimeoutInSec) seconds)"
    }
   
    Write-Log -Message "Successfully added $rdshName VM to $poolName"
}