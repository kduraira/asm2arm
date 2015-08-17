﻿function New-VmStorageProfile 
{
	Param (
		$DiskAction,

		[Microsoft.WindowsAzure.Commands.ServiceManagement.Model.PersistentVMRoleContext]
		$VM,
		
		[string]
		$StorageAccountName,

		# Location to search the image reference in
		$Location,
        $ResourceGroupName        
	)

	$storageProfile = @{}
	$dataDisks = @()
	$osDiskCreateOption = "Attach"
	$dataDiskCreateOption = "Attach"

	# Construct a new URI for the OS disk, which will be placed in the new storage account
	$osDiskUri = Get-NewBlobLocation -SourceBlobUri $VM.VM.OSVirtualHardDisk.MediaLink.AbsoluteUri -StorageAccountName $StorageAccountName -ContainerName $Global:vhdContainerName

	# Use a vanilla VM disk image from the Azure gallery
	if ($DiskAction -eq "NewDisks")
	{
		# Find the VMs image on the catalog
        $ImageName = $vm.vm.OSVirtualHardDisk.SourceImageName

        Write-Verbose $("Discovering the corresponding target VM image for '{0}' source VM image" -f $ImageName)

		$vmImage = Azure\Get-AzureVMImage -ImageName $ImageName -ErrorAction SilentlyContinue

		if (-not $vmImage)
		{
			$message = "Disk image {0} cannot be found for the specified VM." -f $ImageName

			Write-Error $message
			throw $message
		}

		# Retrieve the ARM Image reference for a given ASM image
		$armImageReference = Get-AzureArmImageRef -Location $Location -Image $vmImage 

		$imageReference = @{'publisher' = $armImageReference.Publisher; `
											'offer'= $armImageReference.Offer;
											'sku'= $armImageReference.Skus;
											'version'= $armImageReference.Version;}  

		# Add the imageReference section to the resource metadata
		$storageProfile.Add('imageReference', $imageReference)    

		# Request that OS data disk is created from base image
		$osDiskCreateOption = "FromImage"
		
		# Request that all data disks are created as empty
		$dataDiskCreateOption = "Empty"   
	}
	elseif ($DiskAction -eq "CopyDisks")
	{
		# Create a copy of the existing VM disk
		# Copy-VmDisks -VM $VM -StorageAccountName $StorageAccountName -ResourceGroupName $ResourceGroupName
	}
	elseif ($DiskAction -eq "KeepDisks")
	{
		# Reuse the existing OS disk image
		$osDiskUri = $VM.VM.OSVirtualHardDisk.MediaLink.AbsoluteUri
	}

	# Compose OS disk section
	$osDisk = @{'name' = 'osdisk'; `
								'vhd'= @{ 'uri' = $osDiskUri };
								'caching'= $vm.vm.OSVirtualHardDisk.HostCaching;
								'createOption'= $osDiskCreateOption;} 

    if ($DiskAction -eq "CopyDisks")
    {
        $osDisk.Add('osType', $VM.VM.OSVirtualHardDisk.OS); 
    }
    
	# Add the osDisk section to the resource metadata
	$storageProfile.Add('osDisk', $osDisk)                  

	# Compose data disk section
	foreach ($disk in $VM.VM.DataVirtualHardDisks)
	{
		# Modify data disk URI to point to a copy of the disk
		if ($DiskAction -eq "KeepDisks")
		{
			$dataDiskUri = $disk.MediaLink.AbsoluteUri
		}
		else
		{
			# Construct a new URI for the OS disk, which will be placed in the new storage account
			$dataDiskUri = Get-NewBlobLocation -SourceBlobUri $disk.MediaLink.AbsoluteUri -StorageAccountName $StorageAccountName -ContainerName $Global:vhdContainerName
		}

        # Slightly different property sets are required depending on disk action. For instance, diskSizeGB must only be set for new disks.
        if ($DiskAction -eq "NewDisks")
        {
    		$dataDisks += @{'name' = $disk.DiskName; `
						    'diskSizeGB'= $disk.LogicalDiskSizeInGB;
						    'lun'= $disk.Lun;
						    'vhd'= @{ 'Uri' = $dataDiskUri };
						    'caching'= $disk.HostCaching;
						    'createOption'= $dataDiskCreateOption; }   
        }
        else
        {
            $dataDisks += @{'name' = $disk.DiskName; `
						    'lun'= $disk.Lun;
						    'vhd'= @{ 'Uri' = $dataDiskUri };
						    'caching'= $disk.HostCaching;
						    'createOption'= $dataDiskCreateOption; }   
        }
	}

	# Add the dataDisks section to the resource metadata
	$storageProfile.Add('dataDisks', $dataDisks)  

	return $storageProfile
}

function Copy-VmDisks
{
	Param (
		[Microsoft.WindowsAzure.Commands.ServiceManagement.Model.PersistentVMRoleContext]
		$VM,

		[string]
		$StorageAccountName,
        $ResourceGroupName
	)
        $verboseOutput = ($PSBoundParameters.ContainsKey('Verbose'))
		$vmOsDiskStorageAccountName = ([System.Uri]$VM.VM.OSVirtualHardDisk.MediaLink).Host.Split('.')[0]
		$diskUrlsToCopy = @($VM.VM.OSVirtualHardDisk.MediaLink.AbsoluteUri)

		foreach ($disk in $VM.VM.DataVirtualHardDisks)
		{
			$diskUrlsToCopy += $disk.MediaLink.AbsoluteUri
		}
		
		# Prepare a context in case the source storage account is still the same
		$vmOsDiskStorageAccountKey = (Azure\Get-AzureStorageKey -StorageAccountName $vmOsDiskStorageAccountName).Primary
		$vmOsDiskStorageContext = Azure\New-AzureStorageContext -StorageAccountName $vmOsDiskStorageAccountName -StorageAccountKey $vmOsDiskStorageAccountKey

		# We are assuming we will be using the same storage account for all of the destination VM's disks.
		# However, please make sure to take the storage account's available throughput constraints into account.
		# Please see https://azure.microsoft.com/en-us/documentation/articles/storage-scalability-targets/ for details
        $armStorageAccount = AzureResourceManager\Get-AzureStorageAccount | Where-Object {$_.Name -eq $StorageAccountName} 

        # Check if we can actually find the storage account. If we are here, it should be either crated in this run, or earlier.
        if (-not $armStorageAccount)
        {
            $message = "Cannot find a storage account with name {0} on the subscription's ARM stack." -f $StorageAccountName
            throw $message
        }

		$destinationAccountKey = (AzureResourceManager\Get-AzureStorageAccountKey -Name $StorageAccountName -ResourceGroupName $armStorageAccount.ResourceGroupName).Key1 
		$destinationContext = AzureResourceManager\New-AzureStorageContext -StorageAccountName $StorageAccountName -StorageAccountKey $destinationAccountKey
		
		$previousStorageAccountName = ''
		$destContainerName = $Global:vhdContainerName

        # Create the destination container (if doesn't already exist)
        Azure\New-AzureStorageContainer -Context $destinationContext -Name $destContainerName -Permission Off -ErrorAction SilentlyContinue

		foreach ($srcVhdUrl in $diskUrlsToCopy)
		{
			$root, $rawContainerName, $srcBlobNameParts = ([System.Uri]$srcVhdUrl).Segments
			$srcAccountName = ([System.Uri]$srcVhdUrl).Host.Split('.')[0] 
            $srcContainerName = $rawContainerName.Replace("/", "")
            $destBlobName = $srcBlobNameParts -join ""

            # Compose an URL for the target blob
            $destVhdUrl = Get-NewBlobLocation -SourceBlobUri $srcVhdUrl -StorageAccountName $StorageAccountName -ContainerName $destContainerName

            # Set up the source storage account context in two cases: during the very first iteration and when storage account name changes between URLs
			if ($previousStorageAccountName -eq '' -or $previousStorageAccountName -ne $srcAccountName)
			{                
				$sourceAccountKey = (Azure\Get-AzureStorageKey -StorageAccountName $srcAccountName).Primary
                $sourceContext = Azure\New-AzureStorageContext -StorageAccountName $srcAccountName -StorageAccountKey $sourceAccountKey
			}  

            # Acquire a reference to the blob containing the source VHD
            $srcCloudBlob = Azure\Get-AzureStorageBlob -Context $sourceContext -Container $srcContainerName -Blob $destBlobName

            Write-Output $("Copying a VHD from {0} to {1}" -f $srcVhdUrl, $destVhdUrl)

            $blobCopy = AzureResourceManager\Start-AzureStorageBlobCopy -Context $sourceContext -ICloudBlob $srcCloudBlob.ICloudBlob -DestContext $destinationContext -DestContainer $destContainerName -DestBlob $destBlobName
            
            # Find out what's going on with our copy request and block
            $copyState = $blobCopy | Get-AzureStorageBlobCopyState -WaitForComplete

            # Dump the current state so that we can see it
            if($verboseOutput) { $copyState }		

			$previousStorageAccountName = $srcAccountName
		}
}

function New-AvailabilitySetResource
{
	Param
	(
		$Name,
		$Location
	)

	$createProperties = @{}

	$resource = New-ResourceTemplate -Type "Microsoft.Compute/availabilitySets" -Name $Name `
		-Location $Location -ApiVersion $Global:apiVersion -Properties $createProperties

	return $resource
 }

function New-VmResource 
{
	Param 
	(
		[Microsoft.WindowsAzure.Commands.ServiceManagement.Model.PersistentVMRoleContext]
		$VM,
		$NetworkInterfaceName,
        $StorageAccountName,
        $Location,
        $LocationValue,
        $ResourceGroupName,
		$DiskAction,
        $KeyVaultResourceName,
        $KeyVaultVaultName,
        $CertificatesToInstall,
        $WinRmCertificateName,
        [string[]]
        $Dependecies
	)

    
    $properties = @{}
    if ($vm.AvailabilitySetName)
    {
        $availabilitySet = @{'id' = '[resourceId(''Microsoft.Compute/availabilitySets'',''{0}'')]' -f $vm.AvailabilitySetName;}
        $properties.Add('availabilitySet', $availabilitySet)
    }

    $vmSize = Get-AzureArmVmSize -Size $VM.InstanceSize   

    if ($DiskAction -eq 'NewDisks')
    {           
        $osProfile = @{'computername' = $vm.Name; 'adminUsername' = "[parameters('adminUser')]" ; `
            'adminPassword' = "[parameters('adminPassword')]"}

        $endpoints = $VM | Azure\Get-AzureEndpoint

        if ($VM.vm.OSVirtualHardDisk.OS -eq "Windows")
        {
            # QUESTION TO CRP TEAM
            # How to add windowsCOnfiguration property when there is a default WinRM endpoint?
            $winRMListeners = @()
            $winRm = @{}

            # Either of the two well-known endpoint names identify the presence of the WinRM endpoint on which we need to take further actions
            $winRmEndpoint = $endpoints | Where-Object {$_.Name -eq "PowerShell" -or $_.Name -eq "WinRM"}

            if ($winRmEndpoint -ne $null -and $false)
            {            
              $listener = @{'protocol' = "https"}

              if ($WinRmCertificateName)
              {
                $certificateUri = New-KeyVaultCertificaterUri -KeyVaultVaultName $KeyVaultVaultName -CertificateName $(New-KeyVaultCertificaterUri -KeyVaultVaultName $KeyVaultVaultName -CertificateName $WinRmCertificateName)
                $listener.Add('certificateUrl', $certificateUri)
              }

              $winRm.Add('listeners', @($listener));
            }

            $windowsConfiguration = @{
                'provisionVMAgent' = $vm.vm.ProvisionGuestAgent;
                'enableAutomaticUpdates' = $true
            }

            # If WinRM configuration was fully resolved, it must be specified in the resource
            if($winRm.Count -ne 0)
            {
                $windowsConfiguration.Add('winRM', $winRm)
            }
        
            $osProfile.Add('windowsConfiguration', $windowsConfiguration)
        }
        elseif ($VM.vm.OSVirtualHardDisk.OS -eq "Linux")
        {
            # We cannot determine if password authentication is disabled or not using ASM 
            # or if any public keys are used for SSH. So we will just configure SSH in the outer
            # scope while creating the network security groups.
        }

        $certificateUrls = @()
        foreach ($cert in $CertificatesToInstall)
        {
            $certificateObject = @{'certificateUrl' = New-KeyVaultCertificaterUri -KeyVaultVaultName $KeyVaultVaultName -CertificateName $cert; `
                                                    'certificateStore' = 'My'}
            $certificateObject += $certificateUrls
        }
        $secrets = @()
        $secretsItem = @{'sourceVault' = @{'id' = '[resourceId(parameters(''{0}''), ''Microsoft.KeyVault/vaults'', ''{1}'')]' -f $KeyVaultResourceName, $KeyVaultVaultName}; `
                            'vaultCertificates' = $certificateUrls}

        if ($secrets.Count -gt 0)
        {
            $osProfile.Add('secrets', $secrets)
        }

        $properties.Add('osProfile', $osProfile)
    }

    $storageProfile = New-VmStorageProfile -VM $VM -DiskAction $DiskAction -StorageAccountName $StorageAccountName -Location $LocationValue -ResourceGroupName $ResourceGroupName
    $properties.Add('storageProfile', $storageProfile)

    $properties.Add('hardwareProfile', @{'vmSize' = $(Get-AzureArmVmSize -Size $vm.VM.RoleSize)})

    $properties.Add('networkProfile', @{'networkInterfaces' = @(@{'id' = '[resourceId(''Microsoft.Network/networkInterfaces'',''{0}'')]' -f $NetworkInterfaceName } ); `
                                        'inputEndpoints' = Get-AzureVmEndpoints -VM $VM })
    
    $computeResourceProvider = "Microsoft.Compute/virtualMachines"
    $crpApiVersion = $Global:apiVersion
    if ($DiskAction -eq 'KeepDisks')
    {
        # ARM Compute Resource Provider (CRP) can only be used with Storage Resource Provider (SRP).
        # Since keep disks uses the classic SRP, we need to use classic CRP.
        $computeResourceProvider = "Microsoft.ClassicCompute/virtualMachines"
        $crpApiVersion = $Global:classicResourceApiVersion
    }            

    $resource = New-ResourceTemplate -Type $computeResourceProvider -Name $VM.Name -Location $Location -ApiVersion $crpApiVersion -Properties $properties -DependsOn $Dependecies

    return $resource
}

function Get-AzureArmVmSize 
{
	Param 
	(
		$Size
	)

	$sizes = @{
	     "ExtraSmall" = "Standard_A0";
	"Small" = "Standard_A1";
	"Medium" = "Standard_A2";
	"Large" = "Standard_A3";
	"ExtraLarge" = "Standard_A4";
	"Basic_A0" = "Basic_A0";
	"Basic_A1" = "Basic_A1";
	"Basic_A2" = "Basic_A2";
	"Basic_A3" = "Basic_A3";
	"Basic_A4" = "Basic_A4";
	"A5" = "Standard_A5";
	"A6" = "Standard_A6";
	"A7" = "Standard_A7";
	"A8" = "Standard_A8";
	"A9" = "Standard_A9";
	"A10" = "Standard_A10";
	"A11" = "Standard_A11";
	"Standard_D1" = "Standard_D1";
	"Standard_D2" = "Standard_D2";
	"Standard_D3" = "Standard_D3";
	"Standard_D4" = "Standard_D4";
	"Standard_D11" = "Standard_D11";
	"Standard_D12" = "Standard_D12";
	"Standard_D13" = "Standard_D13";
	"Standard_D14" = "Standard_D14";
	"Standard_G1" = "Standard_G1";
	"Standard_G2" = "Standard_G2";
	"Standard_G3" = "Standard_G3";
	"Standard_G4" = "Standard_G4";
	"Standard_G5" = "Standard_G5";
	"Standard_DS1 " = "Standard_DS1";
	"Standard_DS2 " = "Standard_DS2";
	"Standard_DS3 " = "Standard_DS3";
	"Standard_DS4 " = "Standard_DS4";
	"Standard_DS11" = "Standard_DS11";
	"Standard_DS12" = "Standard_DS12";
	"Standard_DS13" = "Standard_DS13";
	"Standard_DS14" = "Standard_DS14";
	"Basic_D1" = "Basic_D1";
	"Basic_D11" = "Basic_D11";
	"Basic_D12" = "Basic_D12";
	"Basic_D13" = "Basic_D13";
	"Basic_D2" = "Basic_D2";
	"Basic_D3" = "Basic_D3";
	"Basic_D4" = "Basic_D4";
	"Basic_D5" = "Basic_D5";
	}

	return $sizes[$Size]

}

function New-KeyVaultCertificaterUri
{
    Param
    (
        $KeyVaultVaultName,
        $CertificateName
    )

    $uri = "https://{0}.vault.azure.net/keys/{1}" -f $KeyVaultResourceName, $CertificateName

    return $uri
}

#---------------------------------------------------------------------------------------
# Translates all extensions found on the specified VM into a collection of ARM resources
#---------------------------------------------------------------------------------------
function New-VmExtensionResources 
{
	Param 
	(
		[Microsoft.WindowsAzure.Commands.ServiceManagement.Model.PersistentVMRoleContext]
		$VM,
        $ServiceLocation,
        $ResourceGroupName

	)

    $resourceType = 'Microsoft.Compute/virtualMachines/extensions'
    $vmDependency = 'Microsoft.Compute/virtualMachines/{0}' -f $VM.Name
    $imperativeSetExtensions = @()

    # Fetch all extensions registered for the classic VM
    $extensions = Azure\Get-AzureVMExtension -VM $Vm

    # Walk through all extensions and build a corresponding resource
    foreach ($extension in $extensions)
    {
        # Attempt to locate the VM extension in the Resource Manager by performing a lookup
        $armExtensions = AzureResourceManager\Get-AzureVMExtensionImage -Location $ServiceLocation -PublisherName $extension.Publisher -Type $extension.ExtensionName -ErrorAction SilentlyContinue

        # Only proceed with adding a new resource if it was found in ARM
        if($armExtensions -ne $null)
        {
            # Resolve the latest version of the current extension
            $latestExtension = $armExtensions | sort @{Expression={$_.Version}; Ascending=$false} | Select-Object -first 1

            # Normalize the version number so that only major and minor components are present
            $latestVersion = $latestExtension.Version.Replace('.0.0', '')

            # Compose imperative script line for each extension
            $protectedSettingsString = ''
            if ($extension.PrivateConfiguration)
            {
                $protectedSettingsString = "-ProtectedSettingString '{7}'" -f $extension.PrivateConfiguration
            }

            $imperativeSetExtension = "AzureResourceManager\Set-AzureVMExtension -ResourceGroupName '{0}' -VMName '{1}' -Name '{2}' -Publisher '{3}' -ExtensionType '{4}' -TypeHandlerVersion '{5}' -SettingString '{6}' {7} -Location '{8}'" `
                -f $ResourceGroupName, $vm.Name, $latestExtension.Type, $latestExtension.PublisherName, $latestExtension.Type, $latestVersion, $extension.PublicConfiguration, $protectedSettingsString, $ServiceLocation

           $imperativeSetExtensions += $imperativeSetExtension
        }
    }

    if ($imperativeSetExtensions -ne '')
    {
        return ($imperativeSetExtensions -join "`r`n" | Out-String)
    }
    
    return ''
}

function Get-AzureVmEndpoints
{
	Param 
	(
		[Microsoft.WindowsAzure.Commands.ServiceManagement.Model.PersistentVMRoleContext]
		$VM
	)

    # Report all load balanced endpoints to the user so that they know that we do not currently handle these endpoints
    $VM | Azure\Get-AzureEndpoint | Where-Object {$_.LBSetName -ne $null} | ForEach-Object { Write-Warning $("Endpoint {0} is skipped as load balanced endpoints are NOT currently supported by this cmdlet. You can still manually recreate this endpoint in ARM using the following details: {1}" -f $_.Name, $(ConvertTo-Json $_)) }

    # Walk through all endpoints and filter those that are assigned to a load balancer set (we do not currently handle these endpoints)
    return $VM | Azure\Get-AzureEndpoint | Where-Object {$_.LBSetName -eq $null} | Select-Object @{n='endpointName';e={$_.Name}},`
                                                         @{n='privatePort';e={$_.LocalPort}},
                                                         @{n='publicPort';e={$_.Port}},
                                                         @{n='protocol';e={$_.Protocol}},
                                                         @{n='enableDirectServerReturn';e={$_.EnableDirectServerReturn}}
}


function Get-AzureDnsName
{
    [OutputType([string])]
    Param
    (
      $ServiceName,
      $Location
    )

    $retry = $true
    $dnsSuffix = '{0}.cloudapp.azure.com' -f $Location.Replace(' ','').ToLower()  
    $maxServiceNameLength = 253 - $dnsSuffix.Length
    $ServiceName = $ServiceName.Substring(0,[math]::Min($maxServiceNameLength, $ServiceName.Length))  
    
    $suffix = 0
    do
    {
        $dnsName = '{0}.{1}' -f $ServiceName, $dnsSuffix

        # No Test-AzureName for ARM... do .NET call instead.
        try 
        {
            [System.Net.Dns]::GetHostAddresses($dnsName) |  Out-Null
        } 
        catch [System.Management.Automation.MethodInvocationException] 
        {
            # 11001 is Host not found and 11004 no data
            # https://msdn.microsoft.com/en-us/library/windows/desktop/ms740668(v=vs.85).aspx
            if (($_.Exception.InnerException.ErrorCode -eq 11001) -or ($_.Exception.InnerException.ErrorCode -eq 11004))
            {
                $retry = $false
            }
        }

        if ($retry)
        {
            $ServiceName = '{0}{1:00}' -f $ServiceName.Substring(0,[math]::Min($maxServiceNameLength - 2, $ServiceName.Length-2)), $suffix
        }
    }
    while ($retry)    

    return $ServiceName
}

<#
.Synopsis
   Retrieve the ARM Image reference for a given ASM image
.DESCRIPTION
   Do a search on the ARM image catalog, based on the input ASM VM Image.
.EXAMPLE
   Get-AzureArmImageRef -Location $vm.$location -Image $vmImage
#>
function Get-AzureArmImageRef
{
    [OutputType([PSCustomObject])]
	Param
	(
		# Location to search the image reference in
		[Parameter(Mandatory=$true)]
		$Location,

		# Param2 help description
		[Microsoft.WindowsAzure.Commands.ServiceManagement.Model.OSImageContext]
		$Image
	)

	$asmToArmPublishersMap = @{
		"Barracuda Networks, Inc." = "barracudanetworks";
		"Bitnami" = "";
		"Canonical" = "Canonical";
		"Cloudera" = "cloudera";
		"CoreOS" = "CoreOS";
		"DataStax" = "datastax";
		"GitHub, Inc." = "GitHub";
		"Hortonworks" = "hortonworks";
		"Microsoft Azure Site Recovery group" = "MicrosoftAzureSiteRecovery";
		"Microsoft BizTalk Server Group" = "MicrosoftBizTalkServer";
		"Microsoft Dynamics AX" = "MicrosoftDynamicsAX";
		"Microsoft Dynamics GP Group" = "MicrosoftDynamicsGP";
		"Microsoft Dynamics NAV Group" = "MicrosoftDynamicsNAV";
		"Microsoft Hybrid Cloud Storage Group" = "MicrosoftHybridCloudStorage";
		"Microsoft Open Technologies, Inc." = "msopentech";
		"Microsoft SharePoint Group" = "MicrosoftSharePoint";
		"Microsoft SQL Server Group" = "MicrosoftSQLServer";
		"Microsoft Visual Studio Group" = "MicrosoftVisualStudio";
		"Microsoft Windows Server Essentials Group" = "MicrosoftWindowsServerEssentials";
		"Microsoft Windows Server Group" = "MicrosoftWindowsServer";
		"Microsoft Windows Server HPC Pack team" = "MicrosoftWindowsServerHPCPack";
		"Microsoft Windows Server Remote Desktop Group" = "MicrosoftWindowsServerRemoteDesktop";
		"OpenLogic" = "OpenLogic";
		"Oracle" = "Oracle";
		"Puppet Labs" = "PuppetLabs";
		"RightScale with Linux" = "RightScaleLinux";
		"RightScale with Windows Server" = "RightScaleWindowsServer";
		"Riverbed Technology" = "RiverbedTechnology";
		"SUSE" = "SUSE"}

	$publisher = $asmToArmPublishersMap[$Image.PublisherName]

	$offers = AzureResourceManager\Get-AzureVMImageOffer -Location $Location -PublisherName $publisher 

	$skus = @()
	$offers | ForEach-Object { $skus += AzureResourceManager\Get-AzureVMImageSku -Location $Location -PublisherName $publisher -Offer $_.Offer}

	$imageLabelTokens = $image.ImageFamily.Split()
	$skuRanks = @()     
	foreach ($sku in $skus)
	{
		$skuRank = [PSCustomObject] @{
			'Skus' = $sku.Skus;
			'Offer' = $sku.Offer;
			'Rank' = 0;
			}
		
		foreach ($token in $imageLabelTokens)
		{
			if ($sku.Skus.Contains($token)) {
				$skuRank.Rank++                
			}    
		}

		if ($skuRank.Rank -gt 0) {
			$skuRanks += $skuRank
		}
	}

	$maximumRank = ($skuRanks | Measure-Object -Maximum Rank).Maximum
	$skusWithMaximumRank = $skuRanks | Where-Object {$_.Rank -eq $maximumRank}

	if (-not $skusWithMaximumRank)
	{
		return $null
	}

	$images = @()
	$optionCount = 1
	foreach ($imageSku in $skusWithMaximumRank)
	{
		$imagesForSku = AzureResourceManager\Get-AzureVMImage -Location $Location -PublisherName $publisher -Offer $imageSku.Offer -Skus $imageSku.Skus -ErrorAction SilentlyContinue
		if ($imagesForSku.Length -gt 0) {  
			$latestImage = ($imagesForSku | Sort-Object -Property Version -Descending)[0]

			$images += [PsCustomObject] @{
				'Publisher' = $latestImage.PublisherName
				'Offer' = $latestImage.Offer;
				'Skus' = $latestImage.Skus;
				'Version' = $latestImage.Version
				'Id' = $latestImage.Id;
				'Option' = $optionCount++;
			}
		}
	}

	if ($images.Length -gt 0)
	{
		Write-Host "Found the following potential images:"
		$images | Select-Object Option, Publisher, Offer, Skus, Version | Format-Table -AutoSize -Force | Out-Host
		$option = Read-Host -Prompt "Please type in the Option number and press Enter"

        return $images[$option - 1]
	}

	if ($skusWithMaximumRank.length -eq 0)
	{
		return $null
	}
}