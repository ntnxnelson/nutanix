<#
.SYNOPSIS
  This script can be used to create protection domains and consistency groups based on a VM folder structure in vCenter.
.DESCRIPTION
  This script creates protection domains with consistency groups including all VMs in a given vCenter server VM folder.  Protection domains and consistency groups are automatically named "<clustername>-pd-<foldername>" and "<clustername>-cg-<foldername>".
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
.PARAMETER vcenter
  Hostname of the vSphere vCenter to which the hosts you want to mount the NFS datastore belong to.  This is optional.  By Default, if no vCenter server and vSphere cluster name are specified, then the NFS datastore is mounted to all hypervisor hosts in the Nutanix cluster.  The script assumes the user running it has access to the vcenter server.
.PARAMETER folder
  Name of the VM folder object in vCenter which contains the virtual machines to be added to the protection domain and consistency group. You can specify multiple folder names by separating them with commas in which case you must enclose them in double quotes.
.PARAMETER repeatEvery
  Valid values are HOURLY, DAILY and WEEKLY, followed by the number of repeats.  For example, if you want backups to occur once a day, specify "DAILY,1" (note the double quotes).
.PARAMETER startOn
  Specifies the date and time at which you want to start the backup in the format: "MM/dd/YYYY,HH:MM". Note that this should be in UTC znd enclosed in double quotes.
.PARAMETER retention
  Specifies the number of snapshot versions you want to keep.
.PARAMETER replicateNow
  This is an optional parameter. If you use -replicateNow, a snapshot will be taken immediately for each created consistency group.
.PARAMETER interval
  This is an optional parameter. Specify the interval in minutes at which you want to separate each schedule.  This is to prevent scheduling all protection domains snapshots at the same time. If you are processing multiple folders, the first protection domain will be scheduled at the exact specified time (say 20:00 UTC), the next protection domain will be scheduled at +interval minutes (so 20:05 UTC if your interval is 5), and so on...
.EXAMPLE
  Create a protection domain for VM folders "appA" and "appB", schedule a replication every day at 8:00PM UTC, set a retention of 3 snapshots and replicate immediately:
  PS> .\add-NutanixProtectionDomains.ps1 -cluster ntnxc1.local -username admin -password admin -vcenter vcenter1 -folder "appA,appB" -repeatEvery "DAILY,1" -startOn "07/29/2015,20:00" -retention 3 -replicateNow
.LINK
  http://www.nutanix.com/services
.NOTES
  Author: Stephane Bourdeaud (sbourdeaud@nutanix.com)
  Revision: July 29th 2015
#>

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
	[parameter(mandatory = $true)] [string]$username,
	[parameter(mandatory = $true)] [string]$password,
	[parameter(mandatory = $true)] [string]$vcenter,
	[parameter(mandatory = $true)] [string]$folder,
	[parameter(mandatory = $true)] [string]$repeatEvery,
	[parameter(mandatory = $true)] [string]$startOn,
	[parameter(mandatory = $true)] [string]$retention,
	[parameter(mandatory = $false)] [switch]$replicateNow,
	[parameter(mandatory = $false)] [int]$interval
)

# get rid of annoying error messages
if (!$debugme) {$ErrorActionPreference = "SilentlyContinue"}

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
	    if ($log) {Write-Output "$myvarDate [$category] $message" >>$myvarOutputLogFile}
    }

    end
    {
        Remove-variable category
        Remove-variable message
        Remove-variable myvarDate
        Remove-variable myvarFgColor
    }
}#end function OutputLogData

#########################
##   main processing   ##
#########################

#check if we need to display help and/or history
$HistoryText = @'
 Maintenance Log
 Date       By   Updates (newest updates at the top)
 ---------- ---- ---------------------------------------------------------------
 06/19/2015 sb   Initial release.
################################################################################
'@
$myvarScriptName = ".\template.ps1"
 
if ($help) {get-help $myvarScriptName; exit}
if ($History) {$HistoryText; exit}


#let's load the Nutanix cmdlets
if ((Get-PSSnapin -Name NutanixCmdletsPSSnapin -ErrorAction SilentlyContinue) -eq $null)#is it already there?
{
	Add-PSSnapin NutanixCmdletsPSSnapin #no? let's add it
	if (!$?) #have we been able to add it successfully?
	{
		OutputLogData -category "ERROR" -message "Unable to load the Nutanix snapin.  Please make sure the Nutanix Cmdlets are installed on this server."
		return
	}
}

#let's make sure the VIToolkit is being used
if ((Get-PSSnapin VMware.VimAutomation.Core -ErrorAction SilentlyContinue) -eq $null)#is it already there?
{
	Add-PSSnapin VMware.VimAutomation.Core #no? let's add it
	if (!$?) #have we been able to add it successfully?
	{
		OutputLogData -category "ERROR" -message "Unable to load the PowerCLI snapin.  Please make sure PowerCLI is installed on this server."
		return
	}
}

#initialize variables
	#misc variables
	$myvarElapsedTime = [System.Diagnostics.Stopwatch]::StartNew() #used to store script begin timestamp
	$myvarvCenterServers = @() #used to store the list of all the vCenter servers we must connect to
	$myvarOutputLogFile = (Get-Date -UFormat "%Y_%m_%d_%H_%M_")
	$myvarOutputLogFile += "OutputLog.log"
	
	############################################################################
	# command line arguments initialization
	############################################################################	
	#let's initialize parameters if they haven't been specified
	$myvarFolders = $folder.Split("{,}")
	if ($interval -and (($interval -le 0) -or ($interval -ge 60)))
	{
		OutputLogData -category "ERROR" -message "Interval must be between 1 and 59 minutes!"
		break
	}
	
	################################
	##  Main execution here       ##
	################################
	OutputLogData -category "INFO" -message "Connecting to Nutanix cluster $cluster..."
	if (!($myvarNutanixCluster = Connect-NutanixCluster -Server $cluster -UserName $username -Password $password –acceptinvalidsslcerts))#make sure we connect to the Nutanix cluster OK...
	{#error handling
		$myvarerror = $error[0].Exception.Message
		OutputLogData -category "ERROR" -message "$myvarerror"
		return
	}
	else #...otherwise show confirmation
	{
		OutputLogData -category "INFO" -message "Connected to Nutanix cluster $cluster."
	}#endelse
	
	if ($myvarNutanixCluster)
	{		
		#connect to the vcenter server
		OutputLogData -category "INFO" -message "Connecting to vCenter server $vcenter..."
		if (!($myvarvCenterObject = Connect-VIServer $vcenter))#make sure we connect to the vcenter server OK...
		{#make sure we can connect to the vCenter server
			$myvarerror = $error[0].Exception.Message
			OutputLogData -category "ERROR" -message "$myvarerror"
			return
		}
		else #...otherwise show the error message
		{
			OutputLogData -category "INFO" -message "Connected to vCenter server $vcenter."
		}#endelse
		
		if ($myvarvCenterObject)
		{
			######################
			#main processing here#
			######################
			$myvarLoopCount = 0
			foreach ($myvarFolder in $myvarFolders)
			{
				#let's make sure the protection domain doesn't already exist
				$myvarPdName = (Get-NTNXClusterInfo).Name + "-pd-" + $myvarFolder
				if (Get-NTNXProtectionDomain -Name $myvarPdName)
				{
					OutputLogData -category "WARN" -message "The protection domain $myvarPdName already exists! Skipping to the next item..."
					continue
				}
			
				#retrieve list of VMs in the specified folder
				OutputLogData -category "INFO" -message "Retrieving the names of the VMs in $myvarFolder..."
				$myvarVMs = Get-Folder -Name $myvarFolder | get-vm | select -ExpandProperty Name
				if (!$myvarVMs)
				{#no VM in that folder...
					OutputLogData -category "WARN" -message "No VM object was found in $myvarFolder or that folder was not found! Skipping to the next item..."
					continue
				}
				
				#create the protection domain
				OutputLogData -category "INFO" -message "Creating the protection domain $myvarPdName..."
				Add-NTNXProtectionDomain -Input $myvarPdName | Out-Null
				#create the consistency group
				$myvarCgName = (Get-NTNXClusterInfo).Name + "-cg-" + $myvarFolder
				OutputLogData -category "INFO" -message "Creating the consistency group $myvarCgName..."
				Add-NTNXProtectionDomainVM -Name $myvarPdName -ConsistencyGroupName $myvarCgName -Names $myvarVMs | Out-Null
				
				####################
				#create the schedule
				####################
				
				#let's parse the repeatEvery argument (exp format: DAILY,1)
				$myvarType = ($repeatEvery.Split("{,}"))[0]
				$myvarEveryNth = ($repeatEvery.Split("{,}"))[1]
				#let's parse the startOn argument (exp format: MM/dd/YYYY,HH:MM in UTC)
				$myvarDate = ($startOn.Split("{,}"))[0]
				$myvarTime = ($startOn.Split("{,}"))[1]
				$myvarMonth = ($myvarDate.Split("{/}"))[0]
				$myvarDay = ($myvarDate.Split("{/}"))[1]
				$myvarYear = ($myvarDate.Split("{/}"))[2]
				$myvarHour = ($myvarTime.Split("{:}"))[0]
				$myvarMinute = ($myvarTime.Split("{:}"))[1]
				#let's figure out the target date for that schedule
				if ($interval -and ($myvarLoopCount -ge 1))
				{#an interval was specified and this is not the first time we create a schedule
					$myvarTargetDate = (Get-Date -Year $myvarYear -Month $myvarMonth -Day $myvarDay -Hour $myvarHour -Minute $myvarMinute -Second 00 -Millisecond 00).AddMinutes($interval * $myvarLoopCount)
				}
				else
				{#no interval was specified, or this is our first time in this loop withna valid object
					$myvarTargetDate = Get-Date -Year $myvarYear -Month $myvarMonth -Day $myvarDay -Hour $myvarHour -Minute $myvarMinute -Second 00 -Millisecond 00
				}
				$myvarUserStartTimeInUsecs = [long][Math]::Floor((($myvarTargetDate - (New-Object DateTime 1970, 1, 1, 0, 0, 0, ([DateTimeKind]::Utc))).Ticks / [timespan]::TicksPerSecond)) * 1000 * 1000
				
				#let's create the schedule
				OutputLogData -category "INFO" -message "Creating the schedule for $myvarPdName to start on $myvarTargetDate UTC..."
				Add-NTNXProtectionDomainCronSchedule -Name $myvarPdName -Type $myvarType -EveryNth $myvarEveryNth -UserStartTimeInUsecs $myvarUserStartTimeInUsecs | Out-Null
				#configure the retention policy
				OutputLogData -category "INFO" -message "Configuring the retention policy on $myvarPdName to $retention..."
				Set-NTNXProtectionDomainRetentionPolicy -pdname ((Get-NTNXProtectionDomain -Name $myvarPdName).Name) -Id ((Get-NTNXProtectionDomainCronSchedule -Name $myvarPdName).Id) -LocalMaxSnapshots $retention | Out-Null
				
				if ($replicateNow)
				{
					#replicate now
					OutputLogData -category "INFO" -message "Starting an immediate replication for $myvarPdName..."
					Add-NTNXOutOfBandSchedule -Name $myvarPdName | Out-Null
				}
				++$myvarLoopCount
			}			
		}			
		
	}#endif
    OutputLogData -category "INFO" -message "Disconnecting from Nutanix cluster $cluster..."
	Disconnect-NutanixCluster -Servers $cluster #cleanup after ourselves and disconnect from the Nutanix cluster
	OutputLogData -category "INFO" -message "Disconnecting from vCenter server $vcenter..."
	Disconnect-viserver -Confirm:$False #cleanup after ourselves and disconnect from vcenter
	
#########################
##       cleanup       ##
#########################

	#let's figure out how much time this all took
	OutputLogData -category "SUM" -message "total processing time: $($myvarElapsedTime.Elapsed.ToString())"
	
	#cleanup after ourselves and delete all custom variables
	Remove-Variable myvar*
	Remove-Variable ErrorActionPreference
	Remove-Variable help
    Remove-Variable history
	Remove-Variable log
	Remove-Variable cluster
	Remove-Variable username
	Remove-Variable password
	Remove-Variable folder
	Remove-Variable repeatEvery
	Remove-Variable startOn
	Remove-Variable retention
	Remove-Variable replicateNow
	Remove-Variable vcenter
	Remove-Variable interval
    Remove-Variable debugme