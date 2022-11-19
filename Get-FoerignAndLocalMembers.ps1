Function Get-ForeignAndLocalMembers {
   <#
    .SYNOPSIS       
        Recursively get all members of given group(s) and retrieve their nested groups and users including foreign principles from other domains/forests and show their parent group.
    .DESCRIPTION    
        This function takes an AD Group(s) name and gets all members objects to N level deep, including foregin members of other domains and shows the parent group of each returned object.        

    .PARAMETER Groups
    Mandatory -  The AD group(s) names of AD groups that the function will get members of.  

    .PARAMETER Domains
    Mandatory - The FQDNs of all possible domains in your environemnt.    

    .PARAMETER Server
    Optional - The local Domain name of the group(s) being queried initially by the function. By default, the function will get the current machine domain.
    
    .EXAMPLE
        $Domains = @("FQDN_DomainA","FQDN_DomainB","FQDN_DomainC")
        $result = @()
        $result = Get-ForeignAndLocalMembers -Groups "ADGroupXYZ" -Server "LocalDomain_Of_ADGroupXYZ" -Domains $Domains
        $result | Select-Object Name, ParentGroup, ObjectClass, Status, ObjectDomain, mail | Format-Table

        This recursively gets all nested groups and users of "ADGroupXYZ" AD Group from original domains defined in $Domains variable

        Name         : User1
        ParentGroup  : ADGroupXYZ
        ObjectClass  : user
        status       : {}        
        ObjectDomain : FQDN_DomainA
        mail         : User1@example.com

        Name         : NestedGroup1
        ParentGroup  : ADGroupXYZ
        ObjectClass  : group
        status       : {}        
        ObjectDomain : FQDN_DomainB
        mail         :

        Name         : User2
        ParentGroup  : NestedGroup1
        ObjectClass  : user
        status       : {}        
        ObjectDomain : FQDN_DomainC
        mail         : User2@example.com

        Name         : S-1-5-21-2658941983-88728025-1827694959-47966481
        ParentGroup  : ADGroupXYZ
        ObjectClass  :
        Status       : Couldn't find in target domain        
        ObjectDomain :
        mail         :
    
    .EXAMPLE        
        Get-ForeignAndLocalMembers -Groups "ADGroupXYZ" -Domains ("FQDN_DomainA","FQDN_DomainB","FQDN_DomainC")

        This recursively gets all nested groups and users of "ADGroupXYZ" AD Group from original domains that are passed to -Domains switch
    
    .INPUTS
        You can pipe the group mame(s) into the command which is recognised by type, you can also pipe any parameter by name. 

    .OUTPUTS
        All properties of Get-ADObject as well as a PSCustomObject that includes the following:        
        ParentGroup - shows the parent group of the current object (user or group)
        Status - populated when the object is orphened to indicate that the foreign object could not be found in its source domain    
        DisplayName of the foreign orphened object    
        ObjectDomain - shows the source domain of the object (User or group)

    .NOTES
        AUTHOR:     Amir Joseph Sayes
        VERSION:    1.0
        Twitter:    @amirjsa
        
    .Link
        http://amirsayes.co.uk
        https://github.com/amirjs/Get-NestedLocalAndForeignADObjects
    #>    
    [CmdletBinding(DefaultParameterSetName = 'Groups')]    
    param (
        [Parameter(ValueFromPipelineByPropertyName, Mandatory = $True)]
        [String[]]$Groups,

        [Parameter(ValueFromPipelineByPropertyName, Mandatory = $True)]
        [String[]]$Domains,

        [Parameter()]
        [String]$Server = (Get-ADReplicationsite | Get-ADDomainController -SiteName $_.name -Discover -ErrorAction SilentlyContinue).name
    )    
        Begin {
            #Check if the current session is running in full language mode, otherwise, exit.
            #Build a hash table of NetBios and Domain names based on $Domains variable entered by the user
            $DomainsTable = @()
            Foreach ($DomainEntry in $Domains) {                
                Try {
                    $BuildHash = Get-ADDomain -Identity $DomainEntry -Server $DomainEntry -ErrorAction Stop   
                    $DomainsTable +=  [PSCustomObject]@{
                        "DomainName" = $($BuildHash.name)
                        "NetBIOSName" = $($BuildHash.NetBIOSName)
                        "DNSRoot" = $($BuildHash.DNSRoot)
                    }
                }
                Catch {
                    $err = $error[0]
                    Write-Error "Domain $($DomainEntry) could not be found. Please ensure the domain name is correct and you have rights to connect/read the domain. Full error: $err"                    
                    exit
                }
            }            
        }
        Process {  
            $AllMemberObjects = @()                      
            Foreach ($GroupEntry in $Groups) {
                #Get details of groups queried by the function to find their members 
                $GroupProperties = Get-ADGroup -Identity $($GroupEntry) -Properties * -Server $Server -ErrorAction SilentlyContinue
                #Get the "members" property of the groups and pipe it into Get-ADObject 
                $NestedGroupsAndUsers = $GroupProperties.Members | Get-ADObject -Properties * -Server $Server -ErrorAction SilentlyContinue                                                
                #Loop inside the members (users and groups) and query them in their original domain
                Foreach ($row in $NestedGroupsAndUsers) {                                                                             
                    #Use Regex to figure out if a group or a user is a foreign principal i.e. resides in different domain/forest                    
                    if($row.name -match "^S-\d-\d-\d\d") {                               
                        try {
                            #Translate the SID of the user/Group to their actual NTAccount name e.g. DomainA\group_name_1, DomainB\User1                             
                            $ObjectNameFromSID =  ([System.Security.Principal.SecurityIdentifier]$row.name).Translate([System.Security.Principal.NTAccount])                                                                                                                                   
                        }
                        Catch {                            
                            #If ObjectNameFromSID is not found, it's likely that object does not exist anymore in their domain of origin, although it is still referenced as a foregin member of the currect AD group
                            #Build an object to highlight those orphened objects                            
                            If ($null -eq $ObjectNameFromSID) {                                
                                $NewPSObj = New-Object -TypeName PSobject                                                                
                                $NewPSObj | Add-Member -MemberType NoteProperty -Name "ParentGroup" -Value "$($GroupEntry)" -Force
                                $NewPSObj | Add-Member -MemberType NoteProperty -Name "Status" -Value "Couldn't find in target domain" -Force
                                $NewPSObj | Add-Member -MemberType NoteProperty -Name "Name" -Value "$($row.name)" -Force
                                $NewPSObj | Add-Member -MemberType NoteProperty -Name "DisplayName" -Value "$($row.DisplayName)" -Force                                
                                $AllMemberObjects += $NewPSObj
                                $NewPSObj = $null
                                #Clean up variables 
                                $LDAPQuery = $CurrentUserDomainFullName = $ObjectNameFromSID = $null                                                        
                                #skip just this iteration, but continue loop    
                                Continue                             
                            }
                        }
                        Try {
                            ##Find the DNSRoot name (Domain full name) based on the current user/group being processed e.g. domain\user
                            If ($ObjectNameFromSID) {                                
                                $CurrentUserDomainFullName = $DomainsTable.where({$_.NetBIOSName -like ($ObjectNameFromSID.value.split("\")[0])}).DNSRoot                                                                                                                                                     
                            }                            
                        }
                        Catch {
                            Write-Error "Could not find a matching domain for $($ObjectNameFromSID) from the list of provided domains: $($DomainsHashTable.NetBIOSName) .Full error: $($Error[0])"
                            #Clean up variables 
                            $LDAPQuery = $CurrentUserDomainFullName = $ObjectNameFromSID = $null                                                        
                            #skip just this iteration, but continue loop                            
                            Continue NestedRows                            
                        }                            
                        Try {
                            #Call the domain found above and retrieve the users data                                                         
                            $LDAPQuery = [ADSI]"LDAP://$($CurrentUserDomainFullName)/<SID=$($row.name)>"                                                              
                        }
                        Catch {                            
                            Write-Error 'Error querying AD via LDAP: [ADSI]"LDAP://$($CurrentUserDomainFullName)/<SID=$($row.name)>"'+ "Full error: $($error[0])"
                            #Clean up variables 
                            $LDAPQuery = $CurrentUserDomainFullName = $ObjectNameFromSID = $null                                                        
                            #skip just this iteration, but continue loop
                            Continue NestedRows                            
                        }   
                        #If the current retrieved object is a user, grab their information 
                        if ($LDAPQuery.SchemaClassName -eq "user") {                                
                            $NewPSObj = New-Object -TypeName PSobject                                
                            $NewPSObj = Get-ADObject -Identity $($LDAPQuery.distinguishedName) -Server $CurrentUserDomainFullName -Properties *
                            $NewPSObj | Add-Member -MemberType NoteProperty -Name "ParentGroup" -Value "$($GroupEntry)" -Force
                            $NewPSObj | Add-Member -MemberType NoteProperty -Name "ObjectDomain" -Value "$($CurrentUserDomainFullName)" -Force
                            $AllMemberObjects += $NewPSObj
                            $NewPSObj = $null
                                                        
                            #Clean up variables 
                            $LDAPQuery = $CurrentUserDomainFullName = $ObjectNameFromSID = $null                                                        
                        }
                        #If the current retrieved object is a group, recursivly call the function again for that group
                        elseif ($LDAPQuery.SchemaClassName -eq "group") {                                
                            Get-ForeignAndLocalMembers -Groups "$($LDAPQuery.sAMAccountName)" -Server $($CurrentUserDomainFullName) -Domains $Domains
                        }                            
                    }                                  
                    else {                        
                        #If the object (group or user) is local to the current domain, query it using get-adobject                         
                        $NewPSObj = New-Object -TypeName PSobject
                        $NewPSObj = Get-ADObject -Identity $row.distinguishedName -Server $Server -Properties * 
                        #Add member property to display the parent group and domain name of the current object                                 
                        $NewPSObj | Add-Member -MemberType NoteProperty -Name "ParentGroup" -Value "$($GroupEntry)" -Force
                        $NewPSObj | Add-Member -MemberType NoteProperty -Name "ObjectDomain" -Value "$($Server)" -Force
                        #pipe the new PS object containing the AD object and the added ParentGroup property into the results array 
                        $AllMemberObjects += $NewPSObj
                        $NewPSObj = $null     
                        #Clean up variables 
                        $LDAPQuery = $CurrentUserDomainFullName = $ObjectNameFromSID = $null                                                                           
                    }                       
                }               
            #Return all member objects
            $AllMemberObjects        
            }
        }
    END {}                    
    
}

