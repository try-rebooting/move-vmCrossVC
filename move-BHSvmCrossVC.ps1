<#
move-BHSvmCrossVC.ps1
Written: 7/2018 by Caleb Eaton

Below are goals / notes and will be taken out as the function progresses.

**** RIGHT NOW, THE ASSUMTION IS YOU ARE MOVING IT FROM VC TO VC1

V1. Move a vm from VC to VC1 and tags work, assumes you are moving to ds_BHS_VM
V2. Pre-Check to make sure you are connected to VC and VC1
v3. Modied datastores structure and only does over 150GB
v4. Added ability for Multi VM via variable
v5. fixed storage call .name was not needed 
v5. tweaked Multi VM
v6. out-null added to tags, need to fix to show an error. Add warning for EVC check.
v7. modified the tag script to start the ability to move back and forth between vcenters.

Things that need to be checked:
1.	VDS Switches are the same version
2.	Credentials are saved in powershell
3.	Somehow test the vmotion address / routing
4.	Warning / confirm if moving from a VDS to VSS it will need to power off machine

MOVE TO VC1
 
$vm = get-vm caleb_test -server vc
$vmtag = get-vm caleb_test | Get-TagAssignment
#$vmtags = $vmtag.tag.name
$network = Get-NetworkAdapter -VM $vm -server vc
$datastore = get-datastore PROD01_0307_023 -server vc1
$destination = get-vmhost exbhi2003.bhsi.com -Server vc1
$destport = Get-VDPortgroup -VDSwitch ds_BHS_VM -Name dpg_10.2.212.x -server vc1
move-vm -VM $vm -Destination $destination -NetworkAdapter $network -Datastore $datastore -PortGroup $destport
foreach ($vmtag_new in $vmtag) {New-TagAssignment -Tag (get-tag -name $vmtag_new.tag.name -Server vc1) -Entity $vm.name -Server vc1}
 
 
MOVE TO VC
 
*** MOVE A VM FROM VDS to a VSS in a differen VC ****
*** VM MUST BE POWERED OFF ******


$vm = get-vm caleb_test -server vc1
$network = Get-NetworkAdapter -VM $vm -server vc1
$datastore = get-datastore PRODJ_SABHS01_004 -server vc
$destination = get-vmhost exbhi127.bhsi.com -Server vc
$destport = Get-VirtualSwitch -VMHost exbhi127.bhsi.com -Name vswitch0 | Get-VirtualPortGroup -Name 10.2.212.x -server vc
move-vm -VM $vm -Destination $destination -NetworkAdapter $network -Datastore $datastore -PortGroup $destport

.EXAMPLE
   move-BHSvmCrossVC_Multivm -VMName caleb_test -Cluster PROD01
   Moves one VM to another cluster.
.EXAMPLE
   $tomove = get-vmhost exbhi119.bhsi.com | get-vm
   move-BHSvmCrossVC_Multivm -VMName $tomove  -Cluster PROD01
   Uses varialbe to move mutiple VMs to another cluster.
.EXAMPLE
    move-BHSvmCrossVC -VMName (get-vmhost exbhi119.bhsi.com | get-vm) -Cluster prod02
.EXAMPLE
    get-vm caleb_test, Caleb_test2 | move-bhsvmcrossvc -cluster PROD02

#>

function move-BHSvmCrossVC {
    param (
       [Parameter(Mandatory=$true,Position=0,ValueFromPipeline=$True,ValueFromPipelineByPropertyName=$True)]
      [string[]] $VMName,
       [Parameter(Mandatory=$true,Position=1)]
       [string] $Cluster
       )


################
## Pre-Checks  #
################

# Check to see if connected to both vcenters
Begin {
   . \\bhsi.com\deptdata\BHS\ServerInfrastructure\VMware\Scripts\Get-BHSTagAssignment.ps1

 $OriginalErrorActionPreference = $ErrorActionPreference
 $ErrorActionPreference = 'SilentlyContinue'
 IF ($global:DefaultVIServers.name -notcontains "vc" -and "vc1") {
    $title = "Wrong or no Vcenters are connected."
    $message= "Not connected to VC and VC1 do you want me to connect you?"

    $yes = New-Object System.Management.Automation.Host.ChoiceDescription "&Yes","Connects to both vcenters with domain credentials."
    $no = New-Object System.Management.Automation.Host.ChoiceDescription "&No","Ends the script."

    $options = [System.Management.Automation.Host.ChoiceDescription[]]($yes, $no)
    $result = $host.ui.PromptForChoice($title, $message, $options, 0)

    switch ($result)
    {
        0 {
            write-output "Connecting to VC and VC1"
            Get-vc vc, vc1
            #Pre-Copy tags to C:\
            }

        1 {
            write-warning "Check vcenter connections, please investigate and re-run."
            $FoundError = $true
            }
    }
 If ($FoundError) {break}
 }
 $ErrorActionPreference = $OriginalErrorActionPreference # Set ErrorActionPreference back to its original value
    }



PROCESS {
    #variable for Multi VM
   foreach ($VMNames in $VMName)
   {
   Get-BHSTagAssignment -VM $VMName | export-csv -Path c:\$VMNames.csv -NoTypeInformation
   # This might change, making variables
   # Variable for to collect the VM
   $VM = get-vm -Name $VMNames

   # Variable to get the tag info
   $VMtagassignment = get-vm $VM | Get-TagAssignment

   # Variable to get the Network Adapter for the VM
   $network = Get-NetworkAdapter -VM $VM -server ($VM.uid.split('@')[1].split(':')[0])

   #Varialbe to get the Datastore on SOURCE cluster, will only select datastore if more than 150 GB free space.
   $datastore =  get-datastore -RelatedObject ($Cluster) | sort -Descending -Property FreeSpaceGB | ? {$_.name -like $Cluster + "*" -and $_.freespacegb -gt 150} | select -first 1

#### CHECK Datastore size ######

#Varialbe to combine datastore and vm provisioned
$vm_and_ds = $VM.provisionedspacegb + 150


IF ($vm_and_ds -gt $datastore.FreeSpaceGB) {
    Write-Warning "Cluster does not have enough storage add more storage and re-run"
   }
Else {
#Variable to select a random host in cluster
$destination = Get-cluster $cluster | get-vmhost |Get-Random

#Check EVC mode / warning
$VMEVC = $vm.vmhost.parent.evcmode
$destinationevc = $destination.parent.evcmode

IF ($VMEVC -ne $destinationevc){
    Write-Warning "$Cluster is not configured with the same EVC mode, you will have to turn $VM off to move back"
   }

#Name to move the network over to
$destport = Get-VDPortgroup -VDSwitch (Get-VDSwitch -VMHost $destination) -Name $($network.NetworkName) -Server ($destination.uid.split('@')[1].split(':')[0])


################
## Move Time  ##
################

move-vm -VM $vm -Destination $destination -NetworkAdapter $network -Datastore $datastore -PortGroup $destport

################
#Re-Assign tags#
################

foreach ($vmtag_new in $VMtagassignment) {New-TagAssignment -Tag (get-tag -name $vmtag_new.tag.name -Server $destination.uid.split('@')[1].split(':')[0]) -Entity $VM.name -Server $destination.uid.split('@')[1].split(':')[0] | Out-Null}


    }
  }
}
}

