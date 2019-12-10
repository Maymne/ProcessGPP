#This was begun from the 2017-05-16 version of the follow page, but then updated to support more filter varieties and run more speedily
#https://www.atumvirt.com/2013/11/dramatically-reducing-logon-time-to-desktop-by-moving-from-group-policy-preferences-to-powershell-logon-script/

#$GPOGuidObject = Get-GPO "PRINTING-GPO"
#$GPOGuid = $GPOGuidObject.Id
#$GPOGuidDomain = $GPOGuidObject.DomainName

#The dynamic check above only works if RSAT is installed, so we will manually define the Guid and Domain
#Look up the Domain and Ids from a computer with RSAT and replace the placeholders below

#$GPOGuidDomain = "contoso.local"

#Rather than one Guid, we're grabbing an array; add as many as needed
[string[]] $Guids = 
@("aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee",
"ffffffff-gggg-hhhh-iiii-jjjjjjjjjjjj",
"kkkkkkkk-llll-mmmm-nnnn-oooooooooooo")

#If we're going to do an LDAP lookup, we need our base domain name; parse it from our official GPO domain
[string[]] $GPOGuidDomainSplit = $GPOGuidDomain.split(".")
$GPOGuidDomainLDAP = "LDAP://DC="+$GPOGuidDomainSplit[0]
for ($i = 1; $i -lt ($GPOGuidDomainSplit.count); ++$i) {$GPOGuidDomainLDAP += ",DC="+$GPOGuidDomainSplit[$i]}

[string[]] $badDrivers = @("EPSON Stylus Pro 4880","Xerox EX-i C60-C70 Printer")
 
$userGroups = ([Security.Principal.WindowsIdentity]"$($env:USERNAME)").Groups.Translate([System.Security.Principal.NTAccount])
$computerGroups = ([Security.Principal.WindowsIdentity]"$($env:COMPUTERNAME)").Groups.Translate([System.Security.Principal.NTAccount])
 
Function Process-FilterComputer {
    Param(
        $filter
    )
 
    $result = $false
 
    if ($filter.type -eq "NETBIOS") {
        if ($env:COMPUTERNAME -like $filter.name) {
            $result = $true
        }
    }
 
    if ($filter.not -eq 0) {
        return $result
    } else {
        return !$result
    }
}
 
Function Process-FilterUser {
    Param(
        $filter
    )
 
    $result = $false
 
    if ("$env:USERDOMAIN\$env:USERNAME" -like $filter.name) {
        $result = $true
    }
 
    if ($filter.not -eq 0) {
        return $result
    } else {
        return !$result
    }
}
 
Function Process-FilterGroup {
    Param(
        $filter
    )
 
    $result = $false
 
    if ($filter.userContext -eq 1) {
        if ($userGroups -contains $filter.name) {
            $result = $true
        }
    } else {
        if ($computerGroups -contains $filter.name) {
            $result = $true
        }
    }
 
    if ($filter.not -eq 0) {
        return $result
    } else {
        return !$result
    }
}
 
Function Process-FilterLDAP {
    Param(
        $filter
    )
 
    $result = $false
 
    $Searcher = New-Object DirectoryServices.DirectorySearcher
    $Searcher.Filter = $filter.searchfilter
    $Searcher.SearchRoot = $GPOGuidDomainLDAP
    $Matched = $Searcher.FindAll()

    if ($Matched.count -gt 0) {
        $result = $true
    }

    if ($filter.not -eq 0) {
        return $result
    } else {
        return !$result
    }
}
 
Function Process-FilterOrgUnit {
    Param(
        $filter
    )
 
    $result = $false

    $Searcher = New-Object DirectoryServices.DirectorySearcher
    if ($filter.userContext -eq 1) {
        $FindName = $env:USERNAME
        $Searcher.Filter = '(&(name=' + $FindName + ')(objectClass=user))'
    } else {
        $FindName = $env:COMPUTERNAME
        $Searcher.Filter = '(&(name=' + $FindName + ')(objectClass=computer))'
	}
    $Searcher.SearchRoot = $GPOGuidDomainLDAP
    $Matched = $Searcher.FindAll()
    $OU = $($Matched.Properties.Item('distinguishedName')).Substring($($Matched.Properties.Item('distinguishedName')).IndexOf('OU='))

    if ($filter.directMember -eq 1) {
        if ($OU -eq $filter.name) {
            $result = $true
        }
    } elseif ($OU.contains($filter.name)) {
        $result = $true
    }

    if ($filter.not -eq 0) {
        return $result
    } else {
        return !$result
    }
}
 
Function Process-FilterCollection {
    Param(
        $filter
    )
 
    if ($filter.HasChildNodes) {
        $result = $true
        $childFilter = $filter.FirstChild
 
        while ($childFilter -ne $null) {
            if (($childFilter.bool -eq "OR") -or ($childFilter.bool -eq "AND" -and $result -eq $true)) {
                if ($childFilter.LocalName -eq "FilterComputer") {                    
                    $result = Process-FilterComputer $childFilter
                } elseif ($childFilter.LocalName -eq "FilterUser") {
                    $result = Process-FilterUser $childFilter
                } elseif ($childFilter.LocalName -eq "FilterGroup") {
                    $result = Process-FilterGroup $childFilter
                } elseif ($childFilter.LocalName -eq "FilterLDAP") {
                    $result = Process-FilterLDAP $childFilter
                } elseif ($childFilter.LocalName -eq "FilterOrgUnit") {
                    $result = Process-FilterOrgUnit $childFilter
                } elseif ($childFilter.LocalName -eq "FilterCollection") {
                    $result = Process-FilterCollection $childFilter
                }
 
                #Write-Host "Process-$($childFilter.LocalName) $($childFilter.name): $($result)"
            } else {
                #Write-Host "Process-$($childFilter.LocalName) $($childFilter.name): skipped"
            }
 
            if (($childFilter.NextSibling.bool -eq "OR") -and ($result -eq $true)) {
                break
            } else {
                $childFilter = $childFilter.NextSibling
            }
        }
    }
 
    if ($filter.not -eq 1) {
        return !$result
    } else {
        return $result
    }
}
 
#Process each GPO from our array
foreach ($GPOGuid in $Guids) {
[xml]$printersXml = Get-Content "\\$GPOGuidDomain\sysvol\$GPOGuidDomain\Policies\{$GPOGuid}\User\Preferences\Printers\Printers.xml"
 
$com = New-Object -ComObject WScript.Network
 
$installedPrinterDrivers = get-printerdriver
$installedPrinters = get-printer | ? {$_.shared -eq $true}
 
foreach ($sharedPrinter in $printersXml.Printers.SharedPrinter) {
    $filterResult = Process-FilterCollection $sharedPrinter.Filters
#I want to know what our action is: whether we're creating, updating, replacing, or deleting our printer
    Write-Host "$($sharedPrinter.name) filters passed: $($sharedPrinter.Properties.action) $($filterResult)"
 
    if ($filterResult -eq $true) {
#Skip adding the printer on Create if it's already there
        if (($sharedPrinter.Properties.action -eq 'C' -and (!$installedPrinters -or !$installedPrinters.name.contains($sharedPrinter.Properties.path))) -or $sharedPrinter.Properties.action -eq 'U' -or $sharedPrinter.Properties.action -eq 'R') {
            #check to see if the driver is present on the XenAppServer
           
           $printServer = $sharedPrinter.Properties.path
           $printServer = $printServer.Split("\\")[2]
           $driverName = Get-Printer -ComputerName $($PrintServer) -Name $($sharedPrinter.name)
 
            if (!($badDrivers.contains($driverName.drivername)) -or ($installedPrinterDrivers | where {$_.name -eq $driverName.drivername})) {
#Replacing the printer involves deleting the mapping before we recreate it
                if ($sharedPrinter.Properties.action -eq 'R' -and ($installedPrinters -and $installedPrinters.name.contains($sharedPrinter.Properties.path))) {
                    $com.RemovePrinterConnection($sharedPrinter.Properties.path, $true, $true)
                    "RemovePrinterConnection:$($sharedPrinter.Properties.path)"
                }
            #Create the printer in the session
                $com.AddWindowsPrinterConnection($sharedPrinter.Properties.path)
                "AddWindowsPrinterConnection:$($sharedPrinter.Properties.path)"
#                if ($sharedPrinter.Properties.default -eq 1) {
#                    #$com.SetDefaultPrinter($sharedPrinter.Properties.path)
#                    (Get-WmiObject -ComputerName . -Class Win32_Printer -Filter "Name='$($($sharedPrinter.Properties.path) -replace "\\","\\")'").SetDefaultPrinter()
#                    "SetDefaultPrinter:$($sharedPrinter.Properties.path)"
#                }
#            } else {
            #alert that the driver isn't present
#            write-host "`r`n  The driver for $($sharedPrinter.Properties.path) doesn't appear to be present.  The driver that needs to be installed is $($driverName.drivername).  Please install this driver on the XenApp Server.  `n`r"
            }
        } elseif ($sharedPrinter.Properties.action -eq 'D' -and ($installedPrinters -and $installedPrinters.name.contains($sharedPrinter.Properties.path))) {
            $com.RemovePrinterConnection($sharedPrinter.Properties.path, $true, $true)
            "RemovePrinterConnection:$($sharedPrinter.Properties.path)"
        }
    }
}
}