<#
.SYNOPSIS
  This script is used to deal with IP changes in DR scenarios.  It saves static IP configuration (ipconfig.csv and previous_ipconfig.csv), allows for alternative DR IP configuration (dr_ipconfig.csv) and reconfigures an active interface accordingly. The script only works with 2 DNS servers (no suffix or search list). Each configuration file is appended with a numerical index starting at 1 to indicate the number of the interface (sorted using the ifIndex parameter).
.DESCRIPTION
  This script is meant to be run at startup of a Windows machine, at which point it will list all active network interfaces (meaning they are connected).  If it finds no active interface, it will display an error and exit, otherwise it will continue.  If the active interface is using DHCP, it will see if there is a previously saved configuration and what was the last previous state (if any).  If there is a config file and the previous IP state is the same, if there is a DR config, it will apply it, otherwise it will reapply the static config. If the IP is static and there is no previously saved config, it will save the configuration.  It records the status every time it runs so that it can detect regular static to DR changes.  A change is triggered everytime the interface is in DHCP, and there is a saved config.  If the active interface is already using a static IP address and there is a dr_ipconfig.csv file, the script will try to ping the default gateway and apply the dr_ipconfig if it does NOT ping. If the gateway still does not ping, it will revert back to the standard ipconfig.
.PARAMETER help
  Displays a help message (seriously, what did you think this was?)
.PARAMETER history
  Displays a release history for this script (provided the editors were smart enough to document this...)
.PARAMETER log
  Specifies that you want the output messages to be written in a log file as well as on the screen.
.PARAMETER debugme
  Turns off SilentlyContinue on unexpected error messages.
.PARAMETER path
  Specify the path where you want config files and last state to be saved.  By default, this is in c:\
.PARAMETER dhcp
  Use this switch if you want to configure one or more interfaces with dhcp
.PARAMETER interface
  Specify the interface you want to configure with -dhcp using an index number.  Use 1 for the first interface, 2 for the second, etc... or all for all interfaces.
.PARAMETER setprod
  Apply the production ip configuration (in ipconfig.csv) to the specified interface (use with -interface).
.PARAMETER setdr
  Apply the DR ip configuration (in dr_ipconfig.csv) to the specified interface (use with -interface).
.EXAMPLE
  Simply run the script and save to c:\windows:
  PS> .\set-ipconfig.ps1 -path c:\windows\
.LINK
  http://www.nutanix.com/services
.NOTES
  Author: Stephane Bourdeaud (sbourdeaud@nutanix.com)
  Revision: November 7th 2016
#>

#region Parameters
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
    [parameter(mandatory = $false)] [string]$path,
	[parameter(mandatory = $false)] [switch]$dhcp,
	[parameter(mandatory = $false)] [string]$interface,
	[parameter(mandatory = $false)] [switch]$setprod,
	[parameter(mandatory = $false)] [switch]$setdr
)
#endregion

#region Prep-work
# get rid of annoying error messages
if (!$debugme) {$ErrorActionPreference = "SilentlyContinue"}

#check if we need to display help and/or history
$HistoryText = @'
 Maintenance Log
 Date       By   Updates (newest updates at the top)
 ---------- ---- ---------------------------------------------------------------
 08/24/2016 sb   Initial release.
 11/07/2016 sb   Added support for multiple network interfaces.
################################################################################
'@
$myvarScriptName = ".\set-ipconfig.ps1"
 
if ($help) {get-help $myvarScriptName; exit}
if ($History) {$HistoryText; exit}

#initialize variables
#misc variables
$myvarElapsedTime = [System.Diagnostics.Stopwatch]::StartNew() #used to store script begin timestamp
$myvarvCenterServers = @() #used to store the list of all the vCenter servers we must connect to
$myvarOutputLogFile = (Get-Date -UFormat "%Y_%m_%d_%H_%M_")
$myvarOutputLogFile += "OutputLog.log"
#endregion

#region Functions
########################
##   main functions   ##
########################

#this function is used to output log data
Function OutputLogData 
{
	#input: log category, log message
	#output: text to standard output
<#
.SYNOPSIS
  Outputs messages to the screen and/or log file.
.DESCRIPTION
  This function is used to produce screen and log output which is categorized, time stamped and color coded.
.NOTES
  Author: Stephane Bourdeaud
.PARAMETER myCategory
  This the category of message being outputed. If you want color coding, use either "INFO", "WARNING", "ERROR" or "SUM".
.PARAMETER myMessage
  This is the actual message you want to display.
.EXAMPLE
  PS> OutputLogData -mycategory "ERROR" -mymessage "You must specify a cluster name!"
#>
	param
	(
		[string] $category,
		[string] $message
	)

    begin
    {
	    $myvarDate = get-date
	    $myvarFgColor = "Gray"
	    switch ($category)
	    {
		    "INFO" {$myvarFgColor = "Green"}
		    "WARNING" {$myvarFgColor = "Yellow"}
		    "ERROR" {$myvarFgColor = "Red"}
		    "SUM" {$myvarFgColor = "Magenta"}
	    }
    }

    process
    {
	    Write-Host -ForegroundColor $myvarFgColor "$myvarDate [$category] $message"
	    if ($log) {Write-Output "$myvarDate [$category] $message" >>("$path$myvarOutputLogFile")}
    }

    end
    {
        Remove-variable category
        Remove-variable message
        Remove-variable myvarDate
        Remove-variable myvarFgColor
    }
}#end function OutputLogData

#this function is used to retrieve the IPv4 config of a given network interface
Function getIPv4 
{
	#input: interface
	#output: ipv4 configuration
<#
.SYNOPSIS
  Retrieves the IPv4 configuration of a given Windows interface.
.DESCRIPTION
  Retrieves the IPv4 configuration of a given Windows interface.
.NOTES
  Author: Stephane Bourdeaud
.PARAMETER interface
  A Windows network interface.
.EXAMPLE
  PS> getIPv4 -interface Ethernet
#>
	param 
	(
		[string] $NetworkInterface
	)

    begin
    {
	    $myvarIPv4Configuration = "" | Select-Object -Property InterfaceIndex,InterfaceAlias,IPv4Address,PrefixLength,PrefixOrigin,IPv4DefaultGateway,DNSServer
    }

    process
    {
		OutputLogData -category "INFO" -message "Getting IPv4 information for the active network interface $NetworkInterface ..."
		$myvarActiveNetAdapterIP = Get-NetIPAddress -InterfaceAlias $NetworkInterface | where {$_.AddressFamily -eq "IPv4"}
		$myvarActiveIPConfiguration = Get-NetIPConfiguration -InterfaceAlias $NetworkInterface
		
		$myvarIPv4Configuration.InterfaceIndex = $myvarActiveNetAdapterIP.InterfaceIndex
		$myvarIPv4Configuration.InterfaceAlias = $myvarActiveNetAdapterIP.InterfaceAlias
		$myvarIPv4Configuration.IPv4Address = $myvarActiveIPConfiguration.IPv4Address
		$myvarIPv4Configuration.PrefixLength = $myvarActiveNetAdapterIP.PrefixLength
		$myvarIPv4Configuration.PrefixOrigin = $myvarActiveNetAdapterIP.PrefixOrigin
		$myvarIPv4Configuration.IPv4DefaultGateway = $myvarActiveIPConfiguration.IPv4DefaultGateway
		$myvarIPv4Configuration.DNSServer = $myvarActiveIPConfiguration.DNSServer
    }

    end
    {
       return $myvarIPv4Configuration
    }
}#end function getIPv4

#this function is used to test a given IP address
Function TestDefaultGw 
{
	#input: ip
	#output: boolean
<#
.SYNOPSIS
  Tries to ping the IP address provided and returns true or false.
.DESCRIPTION
  Tries to ping the IP address provided and returns true or false.
.NOTES
  Author: Stephane Bourdeaud
.PARAMETER ip
  An IP address to test.
.EXAMPLE
  PS> TestDefaultGw -ip 10.10.1.1
#>
	param 
	(
		[string] $ip
	)

    begin
    {
	    
    }

    process
    {
		OutputLogData -category "INFO" -message "Trying to ping IP $ip ..."
		if ((Test-Connection $ip -Count 2)) {
			$myvarPingTest = $true
			OutputLogData -category "INFO" -message "Successfully pinged IP $ip ..."
		} 
		else {
			$myvarPingTest = $false
			OutputLogData -category "ERROR" -message "Could not ping IP $ip ..."
		}
    }

    end
    {
       return $myvarPingTest
    }
}#end function TestDefaultGw

#this function is used to test a given IP address
Function ApplyProductionIPConfig 
{
	#input: none
	#output: none
<#
.SYNOPSIS
  Applies the production IP configuration.
.DESCRIPTION
  Applies the production IP configuration.
.NOTES
  Author: Stephane Bourdeaud
#>
	param 
	(
		
	)

    begin
    {
	    
    }

    process
    {
		OutputLogData -category "WARNING" -message "Applying the production IP address to $($myvarNetAdapter.Name)..."
		#apply PROD
		Remove-NetRoute -InterfaceAlias $myvarNetAdapter.Name -Confirm:$false -ErrorAction SilentlyContinue
		Remove-NetIPAddress -InterfaceAlias $myvarNetAdapter.Name -AddressFamily IPv4 -ErrorAction SilentlyContinue -Confirm:$false
		if ($myvarSavedIPConfig.IPv4DefaultGateway) { #check this interface has a default gateway
        	New-NetIPAddress -InterfaceAlias $myvarNetAdapter.Name -AddressFamily IPv4 -IPAddress $myvarSavedIPConfig.IPAddress -PrefixLength $myvarSavedIPConfig.PrefixLength -DefaultGateway $myvarSavedIPConfig.IPv4DefaultGateway -ErrorAction Continue
		}#end if default gw
		else {
			New-NetIPAddress -InterfaceAlias $myvarNetAdapter.Name -AddressFamily IPv4 -IPAddress $myvarSavedIPConfig.IPAddress -PrefixLength $myvarSavedIPConfig.PrefixLength -ErrorAction Continue
		}#end else default gw
        Set-DnsClientServerAddress -InterfaceAlias $myvarNetAdapter.Name -ServerAddresses ($myvarSavedIPConfig.PrimaryDNSServer, $myvarSavedIPConfig.SecondaryDNSServer) -ErrorAction Continue
    }

    end
    {
       
    }
}#end function ApplyProductionIpConfig

#this function is used to test a given IP address
Function ApplyDrIPConfig 
{
	#input: none
	#output: none
<#
.SYNOPSIS
  Applies the DR IP configuration.
.DESCRIPTION
  Applies the DR IP configuration.
.NOTES
  Author: Stephane Bourdeaud
#>
	param 
	(
		
	)

    begin
    {
	    
    }

    process
    {
		OutputLogData -category "WARNING" -message "Applying the DR IP address to $($myvarNetAdapter.Name)..."
		Remove-NetRoute -InterfaceAlias $myvarNetAdapter.Name -Confirm:$false -ErrorAction SilentlyContinue
		Remove-NetIPAddress -InterfaceAlias $myvarNetAdapter.Name -AddressFamily IPv4 -ErrorAction SilentlyContinue -Confirm:$false
		if ($myvarDrIPConfig.IPv4DefaultGateway) { #check this interface has a defined default gateway
        	New-NetIPAddress -InterfaceAlias $myvarNetAdapter.Name -AddressFamily IPv4 -IPAddress $myvarDrIPConfig.IPAddress -PrefixLength $myvarDrIPConfig.PrefixLength -DefaultGateway $myvarDrIPConfig.IPv4DefaultGateway -ErrorAction Continue
		}#end if default gw
		else {
			New-NetIPAddress -InterfaceAlias $myvarNetAdapter.Name -AddressFamily IPv4 -IPAddress $myvarDrIPConfig.IPAddress -PrefixLength $myvarDrIPConfig.PrefixLength -ErrorAction Continue
		}#end else default gw
        Set-DnsClientServerAddress -InterfaceAlias $myvarNetAdapter.Name -ServerAddresses ($myvarDrIPConfig.PrimaryDNSServer, $myvarDrIPConfig.SecondaryDNSServer) -ErrorAction Continue
    }

    end
    {
       
    }
}#end function ApplyDrIPConfig

#this function is used to test a given IP address
Function RestoreIPConfig 
{
	#input: none
	#output: none
<#
.SYNOPSIS
  Restores the IP configuration.
.DESCRIPTION
  Restores the IP configuration.
.NOTES
  Author: Stephane Bourdeaud
#>
	param 
	(
		
	)

    begin
    {
	    
    }

    process
    {
		OutputLogData -category "WARNING" -message "Restoring the IP configuration on $($myvarNetAdapter.Name)..."
		Remove-NetRoute -InterfaceAlias $myvarNetAdapter.Name -Confirm:$false -ErrorAction SilentlyContinue
		Remove-NetIPAddress -InterfaceAlias $myvarNetAdapter.Name -AddressFamily IPv4 -ErrorAction SilentlyContinue -Confirm:$false
		if ($myvarDrIPConfig.IPv4DefaultGateway) { #check this interface has a defined default gateway
        	New-NetIPAddress -InterfaceAlias $myvarNetAdapter.Name -AddressFamily IPv4 -IPAddress $myvarNetAdapter.IPAddress -PrefixLength $myvarNetAdapter.PrefixLength -DefaultGateway $myvarNetAdapter.IPv4DefaultGateway.NextHop -ErrorAction Continue
		}#end if default gw
		else {
			New-NetIPAddress -InterfaceAlias $myvarNetAdapter.Name -AddressFamily IPv4 -IPAddress $myvarNetAdapter.IPAddress -PrefixLength $myvarNetAdapter.PrefixLength -ErrorAction Continue
		}#end else default gw
        Set-DnsClientServerAddress -InterfaceAlias $myvarNetAdapter.Name -ServerAddresses ($myvarPrimaryDNS, $myvarSecondaryDNS) -ErrorAction Continue
    }

    end
    {
       
    }
}#end function RestoreIPConfig

#endregion

#region Main Processing
#########################
##   main processing   ##
#########################

############################################################################
# command line arguments initialization
############################################################################	
#let's initialize parameters if they haven't been specified
if (!$path) {$path = "c:\"}
if (!$path.EndsWith("\")) {$path += "\"}

################################
##  Main execution here       ##
################################

#region Get Interfaces
#get the network interface which is connected
OutputLogData -category "INFO" -message "Retrieving the active network interface..."
$myvarActiveNetAdapter = Get-NetAdapter | where {$_.status -eq "up"} | Sort-Object -Property ifIndex #we use ifIndex to determine the order of the interfaces
#also do something if none of the interfaces are up
if (!$myvarActiveNetAdapter) {
    OutputLogData -category "ERROR" -message "There is no active network interface: cannot continue!"
    break
}#endif no active network adapter
#endregion

#region Look at IPv4 Configuration
#get the basic IPv4 information
$myvarNetAdapterIPv4Configs = @() #we'll keep all configs in this array
ForEach ($myvarNetAdapter in $myvarActiveNetAdapter) {
	$myvarNetAdapterIPv4Configs += getIPv4 -NetworkInterface $myvarNetAdapter.Name
}#end foreach NetAdapter
#endregion

#region Process Each Network Adapter
$myvarNicCounter = 1 #we use this to keep track of the network adapter number we are processing
ForEach ($myvarNetAdapter in $myvarActiveNetAdapter) {

	#region -dhcp
	if ($dhcp) {#user specified the -dhcp parameter
		if (($interface -eq $myvarNicCounter) -or ($interface -eq "all")) {#we have a match on the interface to configure
			OutputLogData -category "WARNING" -message "Configuring $($myvarNetAdapter.Name) with DHCP..."
			Remove-NetRoute -InterfaceAlias $myvarNetAdapter.Name -Confirm:$false -ErrorAction SilentlyContinue
			Set-NetIPInterface -InterfaceAlias $myvarNetAdapter.Name -AddressFamily IPv4 -DHCP Enabled -ErrorAction Continue
			Set-DnsClientServerAddress -InterfaceAlias $myvarNetAdapter.Name -ResetServerAddresses -ErrorAction Continue
		}#endif match interface to configure with dhcp
	}#endif -dhcp
	#endregion	
	
	#region -setprod
	elseif ($setprod) {#user specified the -dhcp parameter
		if (($interface -eq $myvarNicCounter) -or ($interface -eq "all")) {#we have a match on the interface to configure
			#reading ipconfig.csv
		    $myvarSavedIPConfig = Import-Csv -path ($path+"ipconfig-"+$myvarNicCounter+".csv")
			ApplyProductionIPConfig
		}
	}#endif -setprod
	#endregion
	
	#region -setdr
	elseif ($setdr) {#user specified the -dhcp parameter
		if (($interface -eq $myvarNicCounter) -or ($interface -eq "all")) {#we have a match on the interface to configure
			#reading dr_ipconfig.csv
		    $myvarDrIPConfig = Import-Csv -path ($path+"dr_ipconfig-"+$myvarNicCounter+".csv")
			ApplyDrIPConfig
		}
	}#endif -setprod
	#endregion
	
	#region no specific command
	else {#no specific action was specified
		
		#saving the DNS config in case we need to restore
		$myvarDNSServers = (Get-DnsClientServerAddress -AddressFamily IPv4 -InterfaceAlias $myvarNetAdapter.Name).ServerAddresses
		$myvarPrimaryDNS = $myvarDNSServers[0]
		$myvarSecondaryDNS = $myvarDNSServers[1]
		
		#region dhcp nic
		#determine if the IP configuration is obtained from DHCP or not
		OutputLogData -category "INFO" -message "Checking if the active network interface $($myvarNetAdapter.Name) has DHCP enabled..."
		$myvarDHCPAdapter = Get-NetIPInterface -InterfaceAlias $myvarNetAdapter.Name -AddressFamily IPv4 -Dhcp Enabled -ErrorAction SilentlyContinue
		if ($myvarDHCPAdapter) {#the active interface is configured with dhcp
		    OutputLogData -category "INFO" -message "Determined the active network interface $($myvarNetAdapter.Name) has DHCP enabled!"
		    
			
			#region dhcp + dr_ipconfig
			#do we have a DR configuration?
		    OutputLogData -category "INFO" -message "Checking for the presence of a $($path+"dr_ipconfig-"+$myvarNicCounter+".csv") file for $($myvarNetAdapter.Name)..."
		    if (Test-Path -path ($path+"dr_ipconfig-"+$myvarNicCounter+".csv")) {#we have a dr_ipconfig.csv file
		        OutputLogData -category "INFO" -message "Determined we have a $($path+"dr_ipconfig-"+$myvarNicCounter+".csv") file for $($myvarNetAdapter.Name)!"
		        
				
				#region dhcp, dr_config, previous state
				#do we have a previous state?
		        OutputLogData -category "INFO" -message "Checking if we have a $($path+"previous_ipconfig-"+$myvarNicCounter+".csv") file $($myvarNetAdapter.Name)..."
		        if (Test-Path -path ($path+"previous_ipconfig-"+$myvarNicCounter+".csv")) {#we do have a previous state
		            OutputLogData -category "INFO" -message "Determined we have a $($path+"previous_ipconfig-"+$myvarNicCounter+".csv") file for $($myvarNetAdapter.Name)!"
		            
					
					#region dhcp, dr_config, previous state, ipconfig
		            if (Test-Path -path ($path+"ipconfig-"+$myvarNicCounter+".csv")) {#we have a ipconfig.csv file
		                #compare the actual ip with the previous ip
		                OutputLogData -category "INFO" -message "Comparing current state with previous state for $($myvarNetAdapter.Name)..."
		            
		                #reading ipconfig.csv
		                $myvarSavedIPConfig = Import-Csv -path ($path+"ipconfig-"+$myvarNicCounter+".csv")
		                #reading previous state
		                $myvarPreviousState = Import-Csv -path ($path+"previous_ipconfig-"+$myvarNicCounter+".csv")
		                #reading dr ipconfig
		                $myvarDrIPConfig = Import-Csv -path ($path+"dr_ipconfig-"+$myvarNicCounter+".csv")
						
						
						#region dhcp, dr_config, ipconfig, previous state was PROD
						#option 1: previous state was normal and we cannot ping the default gw, so we use DR
		                if ($myvarPreviousState.IPAddress -eq $myvarSavedIPConfig.IPAddress) {
		                    OutputLogData -category "INFO" -message "Previous state was normal/production, so applying DR configuration for $($myvarNetAdapter.Name)..."
		                    ApplyDrIPConfig
		                }#endif previous was normal
						#endregion
						
						
						#region dhcp, dr_config, ipconfig, previous state was DR
		                #option 2: previous state was DR and we cannot ping the default gw, so we use normal
		                ElseIf ($myvarPreviousState.IPAddress -eq $myvarDrIPConfig.IPAddress) {
							OutputLogData -category "INFO" -message "Previous state was DR, so applying normal/production configuration for $($myvarNetAdapter.Name)..."
			                ApplyProductionIPConfig
		                }#endElseIf previous was dr
		                #endregion
						
						
						#region dhcp, dr_config, ipconfig, previous state is UNKNOWN
						Else {#previous state is unknown, in which case we start by applying prod, try default gw ping, if no response, we apply dr
		                    OutputLogData -category "WARNING" -message "Previous state does not match normal/production or DR and is therefore unknown for $($myvarNetAdapter.Name): testing default gateway..."
		                    #testing default-gw connectivity
							if (($myvarNetAdapterIPv4Configs | where {$_.InterfaceAlias -eq $myvarNetAdapter.Name}).IPv4DefaultGateway.NextHop) {
								$myvarGWPing = TestDefaultGw -ip ($myvarNetAdapterIPv4Configs | where {$_.InterfaceAlias -eq $myvarNetAdapter.Name}).IPv4DefaultGateway.NextHop
							}#end if default gw
							else { #if there is no gw for this inetrface, we assume it needs a change
								$myvarGWPing = $false
							}#end else default gw
							if ($myvarGWPing -eq $false) {
								
								
								#region previous state UNKNOWN, apply DR
			                    OutputLogData -category "INFO" -message "Previous state was unknown but default gateway does not ping, so applying DR configuration for $($myvarNetAdapter.Name)..."
			                    ApplyDrIPConfig
								#endregion
								#test new GW
								OutputLogData -category "INFO" -message "Waiting for 10 seconds..."
								Start-Sleep -Seconds 10
								if (!(TestDefaultGw -ip $myvarDrIPConfig.IPv4DefaultGateway)) {#set default gateway still does not ping...
									
									
									#region previous state UNKNOWN, DR GW NO ping, apply PROD
									ApplyProductionIPConfig
									#endregion
								}#endif test DR default gateway
							}#end if gw does not ping
		                }#endelse (previous state is unknown)
						#endregion

		            }#endif ipconfig.csv?
		            #endregion
					
					
					#region dhcp, dr_config, previous state, NO ipconfig
					else {
		                OutputLogData -category "ERROR" -message "The active network interface $($myvarNetAdapter.Name) is using DHCP, we have a dr_config.csv and a previous_ipconfig.csv file but we don't have an ipconfig.csv file in $path. Cannot continue!"
		                break
		            }#endelse we have dhcp, dr config, previous state and NO ipconfig.csv
					#endregion

		        }#endif do we have a previous state?
				#endregion
		    }#endif dr_ipconfig.csv
			#endregion
			
			
			#region dhcp but NO dr_ipconfig
		    else {#we don't have a dr_ipconfig.csv file
		        #do we have a saved config?
		        OutputLogData -category "INFO" -message "There is no $($path+"dr_ipconfig-"+$myvarNicCounter+".csv") for $($myvarNetAdapter.Name). Checking now if we have a $($path+"ipconfig-"+$myvarNicCounter+".csv") file..."
		        
				
				#region dhcp, NO dr_ipconfig, ipconfig
				if (Test-Path -path ($path+"ipconfig-"+$myvarNicCounter+".csv")) {#we have a ipconfig.csv file
		            #apply the saved config
		            OutputLogData -category "INFO" -message "Applying the static IP configuration from $($path+"ipconfig-"+$myvarNicCounter+".csv") for $($myvarNetAdapter.Name)..."
		            #read ipconfig.csv
		            $myvarSavedIPConfig = Import-Csv ($path+"ipconfig-"+$myvarNicCounter+".csv")
		            #apply PROD
					ApplyProductionIPConfig
		        }#endif ipconfig.csv?
				#endregion
				
				
				#region dhcp, NO dr_ipconfig, NO ipconfig
		        else {
		            OutputLogData -category "ERROR" -message "The active network interface is using DHCP but we don't have a $($path+"ipconfig-"+$myvarNicCounter+".csv") for $($myvarNetAdapter.Name). Cannot continue!"
		            break
		        }#endelse we have dhcp and NO ipconfig.csv
				#endregion
		    }#endelse we don't have a dr_ipconfig.csv file
			#endregion
		}#endif active dhcp interface
		#endregion

		#region NOT dhcp
		else {#ip config is already static
			#do we have a saved dr_config?
			OutputLogData -category "INFO" -message "Active network interface $($myvarNetAdapter.Name) already has a static IP.  Checking if we already have a $($path+"dr_ipconfig-"+$myvarNicCounter+".csv") file..."
			
			
			#region NO dhcp, dr_ipconfig
			if ((Test-Path -path ($path+"dr_ipconfig-"+$myvarNicCounter+".csv")) -and (Test-Path -path ($path+"ipconfig-"+$myvarNicCounter+".csv"))) {#we have a saved dr_config
				OutputLogData -category "INFO" -message "Determined we have a $($path+"dr_ipconfig-"+$myvarNicCounter+".csv") file for $($myvarNetAdapter.Name)!"
				#compare the actual ip with the previous ip
	            OutputLogData -category "INFO" -message "Comparing current state with previous state for $($myvarNetAdapter.Name)..."
	        
	            #reading ipconfig.csv
	            $myvarSavedIPConfig = Import-Csv -path ($path+"ipconfig-"+$myvarNicCounter+".csv")
	            #reading previous state
	            $myvarPreviousState = Import-Csv -path ($path+"previous_ipconfig-"+$myvarNicCounter+".csv")
	            #reading dr ipconfig
	            $myvarDrIPConfig = Import-Csv -path ($path+"dr_ipconfig-"+$myvarNicCounter+".csv")
				
				
				#region NO dhcp, dr_ipconfig, previous state was PROD
	            #option 1: previous state was normal and we cannot ping the default gw, so we use DR
	            if ($myvarPreviousState.IPAddress -eq $myvarSavedIPConfig.IPAddress) {
					#testing default-gw connectivity
					if (($myvarNetAdapterIPv4Configs | where {$_.InterfaceAlias -eq $myvarNetAdapter.Name}).IPv4DefaultGateway.NextHop) {
						$myvarGWPing = TestDefaultGw -ip ($myvarNetAdapterIPv4Configs | where {$_.InterfaceAlias -eq $myvarNetAdapter.Name}).IPv4DefaultGateway.NextHop
					}#end if default gw
					else { #if there is no gw for this inetrface, we assume it needs a change
						$myvarGWPing = $false
					}#end else default gw
					if ($myvarGWPing -eq $false) {
	                    OutputLogData -category "INFO" -message "Previous state was normal/production, so applying DR configuration for $($myvarNetAdapter.Name)..."
	                    #apply DR
						Remove-NetIPAddress -InterfaceAlias $myvarNetAdapter.Name -AddressFamily IPv4 -IPAddress ($myvarNetAdapterIPv4Configs | where {$_.InterfaceAlias -eq $myvarNetAdapter.Name}).IPv4Address.IPAddress -ErrorAction SilentlyContinue -Confirm:$false
						if ($myvarSavedIPConfig.IPv4DefaultGateway) { #check this interface has a default gateway
	                    	New-NetIPAddress -InterfaceAlias $myvarNetAdapter.Name -AddressFamily IPv4 -IPAddress $myvarDrIPConfig.IPAddress -PrefixLength $myvarDrIPConfig.PrefixLength -DefaultGateway $myvarDrIPConfig.IPv4DefaultGateway -ErrorAction Continue
						}#end if default gw
						else {
							New-NetIPAddress -InterfaceAlias $myvarNetAdapter.Name -AddressFamily IPv4 -IPAddress $myvarDrIPConfig.IPAddress -PrefixLength $myvarDrIPConfig.PrefixLength -ErrorAction Continue
						}#end else default gw
	                    Set-DnsClientServerAddress -InterfaceAlias $myvarNetAdapter.Name -ServerAddresses ($myvarDrIPConfig.PrimaryDNSServer, $myvarDrIPConfig.SecondaryDNSServer) -ErrorAction Continue
					}#end if gw does not ping
	            }#endif previous was normal
	            #endregion
				
				
				#region NO dhcp, dr_ipconfig, previous state was DR
				#option 2: previous state was DR and we cannot ping the default gw, so we use normal
	            ElseIf ($myvarPreviousState.IPAddress -eq $myvarDrIPConfig.IPAddress) {
					#testing default-gw connectivity
					if (($myvarNetAdapterIPv4Configs | where {$_.InterfaceAlias -eq $myvarNetAdapter.Name}).IPv4DefaultGateway.NextHop) {
						$myvarGWPing = TestDefaultGw -ip ($myvarNetAdapterIPv4Configs | where {$_.InterfaceAlias -eq $myvarNetAdapter.Name}).IPv4DefaultGateway.NextHop
					}#end if default gw
					else { #if there is no gw for this inetrface, we assume it needs a change
						$myvarGWPing = $false
					}#end else default gw
					if ($myvarGWPing -eq $false) {
	                    OutputLogData -category "INFO" -message "Previous state was DR, so applying normal/production configuration for $($myvarNetAdapter.Name)..."
	                    #apply Normal
						Remove-NetIPAddress -InterfaceAlias $myvarNetAdapter.Name -AddressFamily IPv4 -IPAddress ($myvarNetAdapterIPv4Configs | where {$_.InterfaceAlias -eq $myvarNetAdapter.Name}).IPv4Address.IPAddress -ErrorAction SilentlyContinue -Confirm:$false
						if ($myvarSavedIPConfig.IPv4DefaultGateway) { #check this interface has a default gateway
	                    	New-NetIPAddress -InterfaceAlias $myvarNetAdapter.Name -AddressFamily IPv4 -IPAddress $myvarSavedIPConfig.IPAddress -PrefixLength $myvarSavedIPConfig.PrefixLength -DefaultGateway $myvarSavedIPConfig.IPv4DefaultGateway -ErrorAction Continue
						}#end if default gw
						else {
							New-NetIPAddress -InterfaceAlias $myvarNetAdapter.Name -AddressFamily IPv4 -IPAddress $myvarSavedIPConfig.IPAddress -PrefixLength $myvarSavedIPConfig.PrefixLength -ErrorAction Continue
						}#end else default gw
	                    Set-DnsClientServerAddress -InterfaceAlias $myvarNetAdapter.Name -ServerAddresses ($myvarSavedIPConfig.PrimaryDNSServer, $myvarSavedIPConfig.SecondaryDNSServer) -ErrorAction Continue
					}
	            }#endElseIf previous was dr
	            #endregion
				
				#region NO dhcp, dr_ipconfig, previous state was UNKNOWN
				Else {#previous state is unknown, in which case we start by applying prod, try default gw ping, if no response, we apply dr
	                OutputLogData -category "WARNING" -message "Previous state does not match normal/production or DR and is therefore unknown for $($myvarNetAdapter.Name): testing default gateway..."
					if (!(TestDefaultGw -ip $myvarNetAdapter.IPv4DefaultGateway.NextHop)) {#default gateway does not ping...
						#start by applying PROD
						ApplyProductionIPConfig
						#then test ping on PROD gateway
						OutputLogData -category "INFO" -message "Waiting for 10 seconds..."
						Start-Sleep -Seconds 10
						if (!(TestDefaultGw -ip $myvarSavedIPConfig.IPv4DefaultGateway)) {#PROD default gateway does not ping
							#apply DR if no ping
							ApplyDrIPConfig
							#test ping DR gateway
							OutputLogData -category "INFO" -message "Waiting for 10 seconds..."
							Start-Sleep -Seconds 10
							if (!(TestDefaultGw -ip $myvarDrIPConfig.IPv4DefaultGateway)) {#DR default gateway does not ping
								#re-apply ipconfig if still no ping
								RestoreIPConfig
							}
						}
									
					}#endif test DR default gateway
	            }#endelse (previous state is unknown)
				#endregion
				
			}#end dr_config?
			#endregion
			
			
			#region NO dhcp, NO dr_ipconfig
			else {#we have no dr_config
				#do we have a saved config?
			    OutputLogData -category "INFO" -message "Active network interface $($myvarNetAdapter.Name) already has a static IP.  Checking if we already have a $($path+"ipconfig-"+$myvarNicCounter+".csv") file..."
			    
				
				#region NO dhcp, NO dr_ipconfig, ipconfig
				if (Test-Path -path ($path+"ipconfig-"+$myvarNicCounter+".csv")) {#we have a saved config
			        OutputLogData -category "INFO" -message "Determined we already have an ipconfig.csv file in $path for $($myvarNetAdapter.Name)!"
			        
			        #reading previous state
			        $myvarSavedIPConfig = Import-Csv -path ($path+"ipconfig-"+$myvarNicCounter+".csv")
			        
			        #is it the same as current config? Also we must not have a dr file.
			        OutputLogData -category "INFO" -message "Has the static IP address changed for $($myvarNetAdapter.Name)?"
			        
			        if ((($myvarNetAdapterIPv4Configs | where {$_.InterfaceAlias -eq $myvarNetAdapter.Name}).IPv4Address.IPAddress -ne $myvarSavedIPConfig.IPAddress) -and !(Test-Path -path ($path+"dr_ipconfig-"+$myvarNicCounter+".csv"))) {
			            OutputLogData -category "INFO" -message "Static IP address has changed for $($myvarNetAdapter.Name).  Updating the $($path+"ipconfig-"+$myvarNicCounter+".csv") file..."
			            $myvarDNSServers = (Get-DnsClientServerAddress -AddressFamily IPv4 -InterfaceAlias $myvarNetAdapter.Name).ServerAddresses
			            $myvarPrimaryDNS = $myvarDNSServers[0]
			            $myvarSecondaryDNS = $myvarDNSServers[1]
			            $myvarIPConfig = [psCustomObject][Ordered] @{   IPAddress = ($myvarNetAdapterIPv4Configs | where {$_.InterfaceAlias -eq $myvarNetAdapter.Name}).IPv4Address.IPAddress;
				                                                        PrefixLength = ($myvarNetAdapterIPv4Configs | where {$_.InterfaceAlias -eq $myvarNetAdapter.Name}).PrefixLength;
				                                                        IPv4DefaultGateway = ($myvarNetAdapterIPv4Configs | where {$_.InterfaceAlias -eq $myvarNetAdapter.Name}).IPv4DefaultGateway.NextHop;
				                                                        PrimaryDNSServer = $myvarPrimaryDNS;
				                                                        SecondaryDNSServer = $myvarSecondaryDNS
			                                                        }
			            $myvarIPConfig | Export-Csv -NoTypeInformation ($path+"ipconfig-"+$myvarNicCounter+".csv") -ErrorAction Continue
			        }
			        

			    }#endif do we have a saved config?
			    #endregion
				
				
				#region NO dhcp, NO dr_ipconfig, NO ipconfig
				else {#we don't have a saved config
			        #saving the ipconfig
			        OutputLogData -category "INFO" -message "Active network interface has a static IP and we don't have a $($path+"ipconfig-"+$myvarNicCounter+".csv") file for $($myvarNetAdapter.Name)! Saving to $($path+"ipconfig-"+$myvarNicCounter+".csv")..."
			        $myvarDNSServers = (Get-DnsClientServerAddress -AddressFamily IPv4 -InterfaceAlias $myvarNetAdapter.Name).ServerAddresses
			        $myvarPrimaryDNS = $myvarDNSServers[0]
			        $myvarSecondaryDNS = $myvarDNSServers[1]
			        $myvarIPConfig = [psCustomObject][Ordered] @{   IPAddress = ($myvarNetAdapterIPv4Configs | where {$_.InterfaceAlias -eq $myvarNetAdapter.Name}).IPv4Address.IPAddress;
			                                                        PrefixLength = ($myvarNetAdapterIPv4Configs | where {$_.InterfaceAlias -eq $myvarNetAdapter.Name}).PrefixLength;
			                                                        IPv4DefaultGateway = ($myvarNetAdapterIPv4Configs | where {$_.InterfaceAlias -eq $myvarNetAdapter.Name}).IPv4DefaultGateway.NextHop;
			                                                        PrimaryDNSServer = $myvarPrimaryDNS;
			                                                        SecondaryDNSServer = $myvarSecondaryDNS
			                                                    }
			        $myvarIPConfig | Export-Csv -NoTypeInformation ($path+"ipconfig-"+$myvarNicCounter+".csv") -ErrorAction Continue
			    }#end else saved config
				#endregion
			}#end else dr_config
		    #endregion
		}#end else (active interface has static config)

		#endregion
	}#end else no specific action specified
	#endregion
	
	#region Save config
	#save the current state to previous
	OutputLogData -category "INFO" -message "Saving current configuration to previous state ($($path+"previous_ipconfig-"+$myvarNicCounter+".csv")) for $($myvarNetAdapter.Name)..."
	$myvarActiveNetAdapterIP = Get-NetIPAddress -InterfaceAlias $myvarNetAdapter.Name | where {$_.AddressFamily -eq "IPv4"}
	$myvarActiveIPConfiguration = Get-NetIPConfiguration -InterfaceAlias $myvarNetAdapter.Name
	$myvarDNSServers = (Get-DnsClientServerAddress -AddressFamily IPv4 -InterfaceAlias $myvarNetAdapter.Name).ServerAddresses
	$myvarPrimaryDNS = $myvarDNSServers[0]
	$myvarSecondaryDNS = $myvarDNSServers[1]
	$myvarIPConfig = [psCustomObject][Ordered] @{   IPAddress = $myvarActiveNetAdapterIP.IPAddress;
                                                    PrefixLength = $myvarActiveNetAdapterIP.PrefixLength;
                                                    IPv4DefaultGateway = $myvarActiveIPConfiguration.IPv4DefaultGateway.NextHop;
	                                                PrimaryDNSServer = $myvarPrimaryDNS;
	                                                SecondaryDNSServer = $myvarSecondaryDNS
	                                            }
	$myvarIPConfig | Export-Csv -NoTypeInformation ($path+"previous_ipconfig-"+$myvarNicCounter+".csv") -ErrorAction Continue
	#endregion
	++$myvarNicCounter
}#end foreach NetAdapter
#endregion

OutputLogData -category "INFO" -message "We're done!"
#endregion

#region Cleanup
#########################
##       cleanup       ##
#########################

#let's figure out how much time this all took
OutputLogData -category "SUM" -message "total processing time: $($myvarElapsedTime.Elapsed.ToString())"

#cleanup after ourselves and delete all custom variables
Remove-Variable myvar* -ErrorAction SilentlyContinue
Remove-Variable ErrorActionPreference -ErrorAction SilentlyContinue
Remove-Variable help -ErrorAction SilentlyContinue
Remove-Variable history -ErrorAction SilentlyContinue
Remove-Variable log -ErrorAction SilentlyContinue
Remove-Variable path -ErrorAction SilentlyContinue
Remove-Variable debugme -ErrorAction SilentlyContinue
Remove-Variable * -ErrorAction SilentlyContinue
#endregion