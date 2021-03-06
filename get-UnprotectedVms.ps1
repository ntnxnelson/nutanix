<#
.SYNOPSIS
  This script retrieves the list of unprotected (not in any protection domain) virtual machines from a given Nutanix cluster.
.DESCRIPTION
  The script uses v2 REST API in Prism to GET the list of unprotected VMs from /protection_domains/unprotected_vms/.
.PARAMETER help
  Displays a help message (seriously, what did you think this was?)
.PARAMETER history
  Displays a release history for this script (provided the editors were smart enough to document this...)
.PARAMETER log
  Specifies that you want the output messages to be written in a log file as well as on the screen.
.PARAMETER debugme
  Turns off SilentlyContinue on unexpected error messages.
.PARAMETER cluster
  Nutanix cluster fully qualified domain name or IP address.
.PARAMETER username
  Username used to connect to the Nutanix cluster.
.PARAMETER password
  Password used to connect to the Nutanix cluster.

.EXAMPLE
.\get-UnprotectedVms.ps1 -cluster ntnxc1.local -username admin -password admin
Retrieve the list of unprotected VMs from cluster ntnxc1.local

.LINK
  http://www.nutanix.com/services
.LINK
  https://github.com/sbourdeaud/nutanix
.NOTES
  Author: Stephane Bourdeaud (sbourdeaud@nutanix.com)
  Revision: Feb 19th 2017
#>

#region parameters
######################################
##   parameters and initial setup   ##
######################################
#let's start with some command line parsing
Param
(
    #[parameter(valuefrompipeline = $true, mandatory = $true)] [PSObject]$myParam1,
    [parameter(mandatory = $false)] [switch]$help,
    [parameter(mandatory = $false)] [switch]$history,
    [parameter(mandatory = $false)] [switch]$log,
    [parameter(mandatory = $false)] [switch]$debugme,
    [parameter(mandatory = $true)] [string]$cluster,
    [parameter(mandatory = $false)] [string]$username,
    [parameter(mandatory = $false)] [string]$password
)
#endregion

#region functions
########################
##   main functions   ##
########################

#endregion

#region prepwork
# get rid of annoying error messages
if (!$debugme) {$ErrorActionPreference = "SilentlyContinue"}
#check if we need to display help and/or history
$HistoryText = @'
 Maintenance Log
 Date       By   Updates (newest updates at the top)
 ---------- ---- ---------------------------------------------------------------
 02/19/2018 sb   Initial release.
################################################################################
'@
$myvarScriptName = ".\get-UnprotectedVms.ps1"
 
if ($help) {get-help $myvarScriptName; exit}
if ($History) {$HistoryText; exit}


#process requirements (PoSH version and modules)
    Write-Host "$(get-date) [INFO] Checking the Powershell version..." -ForegroundColor Green
    if ($PSVersionTable.PSVersion.Major -lt 5) {
        Write-Host "$(get-date) [WARNING] Powershell version is less than 5. Trying to upgrade from the web..." -ForegroundColor Yellow
        if (!$IsLinux) {
            $ChocoVersion = choco
            if (!$ChocoVersion) {
                Write-Host "$(get-date) [WARNING] Chocolatey is not installed!" -ForegroundColor Yellow
                [ValidateSet('y','n')]$ChocoInstall = Read-Host "Do you want to install the chocolatey package manager? (y/n)"
                if ($ChocoInstall -eq "y") {
                    Write-Host "$(get-date) [INFO] Downloading and running chocolatey installation script from chocolatey.org..." -ForegroundColor Green
                    iex ((New-Object System.Net.WebClient).DownloadString('https://chocolatey.org/install.ps1'))
                    Write-Host "$(get-date) [INFO] Downloading and installing the latest Powershell version from chocolatey.org..." -ForegroundColor Green
                    choco install -y powershell
                } else {
                    Write-Host "$(get-date) [ERROR] Please upgrade to Powershell v5 or above manually (https://www.microsoft.com/en-us/download/details.aspx?id=54616)" -ForegroundColor Red
                    Exit
                }#endif choco install
            }#endif not choco
        } else {
            Write-Host "$(get-date) [ERROR] Please upgrade to Powershell v5 or above manually by running sudo apt-get upgrade powershell" -ForegroundColor Red
            Exit
        } #endif not Linux
    }#endif PoSH version
    Write-Host "$(get-date) [INFO] Checking for required Powershell modules..." -ForegroundColor Green
    if (!(Get-Module -Name sbourdeaud)) {
        Write-Host "$(get-date) [INFO] Importing module 'sbourdeaud'..." -ForegroundColor Green
        try
        {
            Import-Module -Name sbourdeaud -ErrorAction Stop
            Write-Host "$(get-date) [SUCCESS] Imported module 'sbourdeaud'!" -ForegroundColor Cyan
        }#end try
        catch #we couldn't import the module, so let's download it
        {
            Write-Host "$(get-date) [INFO] Downloading module 'sbourdeaud' from github..." -ForegroundColor Green
            if (!$IsLinux) {
                $ModulesPath = ($env:PsModulePath -split ";")[0]
                $MyModulePath = "$ModulesPath\sbourdeaud"
            } else {
                $ModulesPath = "~/.local/share/powershell/Modules"
                $MyModulePath = "$ModulesPath/sbourdeaud"
            }
            New-Item -Type Container -Force -path $MyModulePath | out-null
            (New-Object net.webclient).DownloadString("https://raw.github.com/sbourdeaud/modules/master/sbourdeaud.psm1") | Out-File "$MyModulePath\sbourdeaud.psm1" -ErrorAction Continue
            (New-Object net.webclient).DownloadString("https://raw.github.com/sbourdeaud/modules/master/sbourdeaud.psd1") | Out-File "$MyModulePath\sbourdeaud.psd1" -ErrorAction Continue

            try
            {
                Import-Module -Name sbourdeaud -ErrorAction Stop
                Write-Host "$(get-date) [SUCCESS] Imported module 'sbourdeaud'!" -ForegroundColor Cyan
            }#end try
            catch #we couldn't import the module
            {
                Write-Host "$(get-date) [ERROR] Unable to import the module sbourdeaud.psm1 : $($_.Exception.Message)" -ForegroundColor Red
                Write-Host "$(get-date) [WARNING] Please download and install from https://github.com/sbourdeaud/modules" -ForegroundColor Yellow
                Exit
            }#end catch
        }#end catch
    }#endif module sbourdeaud

#region module BetterTls
if (!(Get-Module -Name BetterTls)) {
    Write-Host "$(get-date) [INFO] Importing module 'BetterTls'..." -ForegroundColor Green
    try
    {
        Import-Module -Name BetterTls -ErrorAction Stop
        Write-Host "$(get-date) [SUCCESS] Imported module 'BetterTls'!" -ForegroundColor Cyan
    }#end try
    catch #we couldn't import the module, so let's install it
    {
        Write-Host "$(get-date) [INFO] Installing module 'BetterTls' from the Powershell Gallery..." -ForegroundColor Green
        try {Install-Module -Name BetterTls -Scope CurrentUser -ErrorAction Stop}
        catch {throw "$(get-date) [ERROR] Could not install module 'BetterTls': $($_.Exception.Message)"}

        try
        {
            Import-Module -Name BetterTls -ErrorAction Stop
            Write-Host "$(get-date) [SUCCESS] Imported module 'BetterTls'!" -ForegroundColor Cyan
        }#end try
        catch #we couldn't import the module
        {
            Write-Host "$(get-date) [ERROR] Unable to import the module BetterTls : $($_.Exception.Message)" -ForegroundColor Red
            Write-Host "$(get-date) [WARNING] Please download and install from https://www.powershellgallery.com/packages/BetterTls/0.1.0.0" -ForegroundColor Yellow
            Exit
        }#end catch
    }#end catch
}
Write-Host "$(get-date) [INFO] Disabling Tls..." -ForegroundColor Green
try {Disable-Tls -Tls -Confirm:$false -ErrorAction Stop} catch {throw "$(get-date) [ERROR] Could not disable Tls : $($_.Exception.Message)"}
Write-Host "$(get-date) [INFO] Enabling Tls 1.2..." -ForegroundColor Green
try {Enable-Tls -Tls12 -Confirm:$false -ErrorAction Stop} catch {throw "$(get-date) [ERROR] Could not enable Tls 1.2 : $($_.Exception.Message)"}
#endregion

    
    #let's get ready to use the Nutanix REST API
    #Accept self signed certs
if (!$IsLinux) {
add-type @"
    using System.Net;
    using System.Security.Cryptography.X509Certificates;
    public class TrustAllCertsPolicy : ICertificatePolicy {
        public bool CheckValidationResult(
            ServicePoint srvPoint, X509Certificate certificate,
            WebRequest request, int certificateProblem) {
            return true;
        }
    }
"@
[System.Net.ServicePointManager]::CertificatePolicy = New-Object TrustAllCertsPolicy
[Net.ServicePointManager]::SecurityProtocol =  [System.Security.Authentication.SslProtocols] "tls, tls11, tls12"
}#endif not Linux

#endregion

#region variables
#initialize variables
	#misc variables
	$ElapsedTime = [System.Diagnostics.Stopwatch]::StartNew() #used to store script begin timestamp


    #let's deal with the password
    if (!$password) #if it was not passed as an argument, let's prompt for it
    {
        $PrismSecurePassword = Read-Host "Enter the Prism admin user password" -AsSecureString
    }
    else #if it was passed as an argument, let's convert the string to a secure string and flush the memory
    {
        $PrismSecurePassword = ConvertTo-SecureString $password –asplaintext –force
        Remove-Variable password
    }
    if (!$username) {
        $username = "admin"
    }#endif not username
#endregion

#region parameters validation
	############################################################################
	# command line arguments initialization
	############################################################################

    
#endregion

#region processing	
	################################
	##  Main execution here       ##
	################################
   
    #retrieving all AHV vm information
    Write-Host "$(get-date) [INFO] Retrieving list of unprotected VMs..." -ForegroundColor Green
    $url = "https://$($cluster):9440/api/nutanix/v2.0/protection_domains/unprotected_vms/"
    $method = "GET"
    $vmList = Get-PrismRESTCall -method $method -url $url -username $username -password ([System.Runtime.InteropServices.Marshal]::PtrToStringAuto([System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($PrismSecurePassword)))
    Write-Host "$(get-date) [SUCCESS] Successfully retrieved unprotected VMs list from $cluster!" -ForegroundColor Cyan

    
    Foreach ($vm in $vmList.entities) {
        Write-Host $vm.vm_name
    }#end foreach vm

    $vmList.entities | select -Property vm_name | export-csv -NoTypeInformation unprotected-vms.csv
    Write-Host "$(get-date) [SUCCESS] Exported list to unprotected-vms.csv" -ForegroundColor Cyan


#endregion

#region cleanup
#########################
##       cleanup       ##
#########################

	#let's figure out how much time this all took
    Write-Host "$(get-date) [SUM] total processing time: $($ElapsedTime.Elapsed.ToString())" -ForegroundColor Magenta
	
#endregion