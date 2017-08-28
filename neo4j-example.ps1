﻿

$password = ConvertTo-SecureString -String "myneo4jpassword!" -AsPlainText -Force
$neocred = New-Object -TypeName System.Management.Automation.PSCredential -ArgumentList neo4j, $password
$PSNeo4jConfig = @{
    BaseUri = 'http://127.0.0.1:7474'
    Credential = $neocred
}

$Credential = $PSNeo4jConfig.Credential
$BaseUri = $PSNeo4jConfig.BaseUri



# data root

$uri = Join-Parts -Parts $BaseUri, 'db/data'
Try
{
    Invoke-RestMethod -Method Get -Uri "$uri/" -Headers $Headers -ErrorAction Stop

}
catch
{
    Write-Error $_
}

# Add a few constraints, examples, thanks to bloodhound folks

$Statements = @{ "statement"="CREATE CONSTRAINT ON (c:Services) ASSERT c.ServiceName IS UNIQUE" },
              @{ "statement"="CREATE CONSTRAINT ON (c:Server) ASSERT c.ComputerName IS UNIQUE" },
              @{ "statement"="CREATE CONSTRAINT ON (c:User) ASSERT c.UserName IS UNIQUE" } 

$json = ConvertTo-Json -InputObject (@{ statements = $Statements })
$uri = Join-Parts -Parts $BaseUri, 'db/data/transaction/commit'
Invoke-RestMethod -Method Post -Headers $Headers -Uri $uri -Body $json




# Add a few servers
$dcs = Get-ADDomainController -Filter *
$Query = $dcs | Select @{l='ComputerName';e={$_.Name}},
                      Domain,
                      OperatingSystem |
               ConvertTo-Neo4jNodes -Label Server -Passthru

$uri = Join-Parts -Parts $BaseUri, 'db/data/transaction/commit'
$Body = @{
    statements = @($Query)
} | ConvertTo-Json -Depth 10
$Response = Invoke-RestMethod -Method Post -Headers $Headers -Uri $uri -Body $Body


Function Get-Neo4jStats {
  [cmdletBinding(SupportsShouldProcess=$false,ConfirmImpact='Low')]
  param (
    [Parameter(Mandatory=$true,ValueFromPipeline=$true)]
    [Alias('URL','URI')]
    [string]$ServerURL = 'http://127.0.0.1:7474'

    ,[Parameter(Mandatory=$false,ValueFromPipeline=$true)]
    [pscredential]$Credential = [pscredential]::Empty

    ,[Parameter(Mandatory=$false,ValueFromPipeline=$false)]
    [string[]]$IncludeDomains = $null
  )
  
  Begin {
  }
  
  Process {
    $WebRequestProps = @{
      'Method' = 'GET'
    }
    if ($Credential -ne [pscredential]::Empty) { $WebRequestProps.Add('Credential',$Credential)}

    # Get the management endpoint list;
    $uri = $ServerURL + "/db/manage/server/jmx/domain"
  
    $response = Invoke-WebRequest -Uri $uri @WebRequestProps
    
    $output = [pscustomobject]@{}
    
    # The response should be a JSON encoded array...
    $domains = @()
    Write-Verbose "Querying for all domains ..."
    ($response.content | ConvertFrom-Json) | ? { ($IncludeDomains -eq $null) -or ($IncludeDomains -contains $_) } | % {
      $domainName = $_
      $domains += $domainName
      $thisDomain = [pscustomobject]@{}

      Write-Verbose "Querying domain $domainName ..."
      $uri = $ServerURL + "/db/manage/server/jmx/domain/$($domainName)"
      $domainResponse = $null
      $domainResponse = Invoke-WebRequest -Uri $uri  @WebRequestProps
      
      $resp = ($domainResponse.content | ConvertFrom-JSON)

      $beanNames = @()

      $resp.beans | % {
        $thisBean = $_
        $beanNames += $thisBean.name

        $attribs = @{}
        $_.attributes | % {
          $thisAttr = $_
          $keyName = $_.Name
          switch ($thisAttr.type.ToString().ToLower())  {
            "boolean" { $attribs.Add($keyName,[boolean]($thisAttr.value)) }
            "long" {
              $thisValue = $null
              if (-not [System.Int64]::TryParse($thisAttr.value,[ref]$thisValue)) { $thisValue = $null }
              $attribs.Add($keyName,$thisValue)
            }
            "int" {
              $thisValue = $null
              if (-not [System.Int32]::TryParse($thisAttr.value,[ref]$thisValue)) { $thisValue = $null }
              $attribs.Add($keyName,$thisValue)
            }
            "double" {
              $thisValue = $null
              if (-not [System.Double]::TryParse($thisAttr.value,[ref]$thisValue)) { $thisValue = $null }
              $attribs.Add($keyName,$thisValue)
            }

            "[Ljava.lang.String;" { $attribs.Add($keyName,[string[]]($thisAttr.value)) }
            "java.lang.String" { $attribs.Add($keyName,[string]($thisAttr.value)) }
            "javax.management.ObjectName" { $attribs.Add($keyName,[string]($thisAttr.value)) }
            # Unfortunately the datetime string is not parsable back to a different format
            "java.util.Date" { $attribs.Add($keyName,[string]($thisAttr.value)) }
            default {
              Write-Verbose "Unknown response type $($thisAttr.type.ToString()) for attribute $KeyName"
              $attribs.Add($keyName,"[Unable to convert type $($thisAttr.type.ToString())]")
            }
          }
        }

        $beanProps = @{
          "description" = $thisBean.description
          "attributes" = $attribs
        }
        # Add the bean to the domain object
        Add-Member -InputObject $thisDomain -Name $thisBean.name -MemberType NoteProperty -Value ([pscustomobject]$beanProps)

        #$beans += ([pscustomobject]$beanProps)
      }
      # Add the bean name list to the domain object
      Add-Member -InputObject $thisDomain -Name 'beans' -MemberType NoteProperty -Value $beanNames
      
      # Add the results to the output object
      #Add-Member -InputObject $output -Name $domainName -MemberType NoteProperty -Value ([pscustomobject]$beans)
      Add-Member -InputObject $output -Name $domainName -MemberType NoteProperty -Value $thisDomain
    }
    Add-Member -InputObject $output -Name "domains" -MemberType NoteProperty -Value $domains
    
    Write-Output $output
  }
  
  End {
  }
}