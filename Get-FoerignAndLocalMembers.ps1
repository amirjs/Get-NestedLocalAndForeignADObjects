Function Get-ForeignAndLocalMembers {
   <#
    .SYNOPSIS       

    .DESCRIPTION        

    .PARAMETER         

    .PARAMETER         

    .EXAMPLE
        
    .INPUTS
        Inputs (if any)
    .OUTPUTS
        Output (if any)
    .NOTES
        AUTHOR:      Mike Kanakos
        VERSION:     1.0.4
        DateCreated: 2020-04-15
        DateUpdated: 2019-07-28
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
                $BuildHash = Get-ADDomain -Identity $DomainEntry                 
                $DomainsTable +=  [PSCustomObject]@{
                    "DomainName" = $($BuildHash.name)
                    "NetBIOSName" = $($BuildHash.NetBIOSName)
                    "DNSRoot" = $($BuildHash.DNSRoot)
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
                            $ObjectNameFromSID =  ([System.Security.Principal.SecurityIdentifier] $row.name).Translate([System.Security.Principal.NTAccount])                                               
                        }
                        Catch {                            
                            #If ObjectNameFromSID is not found, it's likely that object does not exist anymore although it is still referenced as a foregin member of the currect AD group
                            #Build an object to highlight those orphened objects                            
                            If ($null -eq $ObjectNameFromSID) {
                                $NewPSObj = New-Object -TypeName PSobject                                                                
                                $NewPSObj | Add-Member -MemberType NoteProperty -Name "ParentGroup" -Value "$($GroupEntry)" -Force
                                $NewPSObj | Add-Member -MemberType NoteProperty -Name "Status" -Value "Couldn't find in target domain" -Force
                                $NewPSObj | Add-Member -MemberType NoteProperty -Name "Name" -Value "$($row.name)" -Force
                                $NewPSObj | Add-Member -MemberType NoteProperty -Name "DisplayName" -Value "$($row.DisplayName)" -Force                                
                                $AllMemberObjects += $NewPSObj
                                $NewPSObj = $null
                                #skip just this iteration, but continue loop
                                Continue 
                            }
                        }
                        Try {
                            ##Find the DNSRoot name (Domain full name) based on the current user/group being processed e.g. domain\user
                            If ($ObjectNameFromSID) {
                                $CurrentUserDomainFullName = $DomainsHashTable.where({$_.NetBIOSName -like ($ObjectNameFromSID.value.split("\")[0])}).DNSRoot                                                     
                            }                            
                        }
                        Catch {
                            Write-Error "Could not find a matching domain for $($ObjectNameFromSID) from the list of provided domains: $($DomainsHashTable.NetBIOSName) .Full error: $($Error[0])"
                            #skip just this iteration, but continue loop
                            Continue
                        }                            
                        Try {
                            #Call the domain found above and retrieve the users data                             
                            $LDAPQuery = [ADSI]"LDAP://$($CurrentUserDomainFullName)/<SID=$($row.name)>"      
                        }
                        Catch {
                            Write-Error 'Error querying AD via LDAP: [ADSI]"LDAP://$($CurrentUserDomainFullName)/<SID=$($row.name)>"'+ "Full error: $($error[0])"
                            #skip just this iteration, but continue loop
                            continue
                        }   
                        #If the current retrived object is a user, grab their information 
                        if ($LDAPQuery.SchemaClassName -eq "user") {                                
                            $NewPSObj = New-Object -TypeName PSobject                                
                            $NewPSObj = Get-ADObject -Identity $($LDAPQuery.distinguishedName) -Server $CurrentUserDomainFullName -Properties *
                            $NewPSObj | Add-Member -MemberType NoteProperty -Name "ParentGroup" -Value "$($GroupEntry)" -Force
                            $AllMemberObjects += $NewPSObj
                            $NewPSObj = $null
                                                        
                            #Clean up variables 
                            $LDAPQuery = $CurrentUserDomainFullName = $ObjectNameFromSID = $null
                            $Orphan = $false                                
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
                        #Add member property to display the parent group of the current object                                 
                        $NewPSObj | Add-Member -MemberType NoteProperty -Name "ParentGroup" -Value "$($GroupEntry)" -Force
                        #pipe the new PS object containing the AD object and the added ParentGroup property into the results array 
                        $AllMemberObjects += $NewPSObj
                        $NewPSObj = $null                        
                    }                       
                }               
            #Return all member objects
            $AllMemberObjects        
            }
        }
    END {}                    
    
}

# Main 

$Domains = @("uk.corp.investec.com","BWD-RENSBURG.co.uk","investec.corp")
$result = @()
$result = Get-ForeignAndLocalMembers -Groups "AmirTest" -Server "uk.corp.investec.com" -Domains $Domains
$result | select ParentGroup, status, CN, name, DisplayName | ft
$result.Count
