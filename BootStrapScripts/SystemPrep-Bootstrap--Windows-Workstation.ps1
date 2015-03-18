###
#Define User variables
###
$SystemPrepMasterScriptUrl = 'https://s3.amazonaws.com/systemprep/MasterScripts/SystemPrep-WindowsMaster.ps1'
$SystemPrepParams = @{
    AshRole = "Workstation"
    NetBannerLabel = "Unclass"
    SaltStates = "Highstate"
    NoReboot = $false
    SourceIsS3Bucket = $true
    AwsRegion = "us-east-1"
}
$AwsToolsUrl = $null
$RootCertUrl = $null
$ConfigureEc2EventLogging = $true

###
#Define System variables
###
$CertDir = "${env:temp}\certs"
$SystemPrepDir = "${env:SystemDrive}\SystemPrep"
$SystemPrepLogDir = "${env:SystemDrive}\SystemPrep\Logs"
$LogSource = "SystemPrep"
$DateTime = $(get-date -format "yyyyMMdd_HHmm_ss")
$SystemPrepLogFile = "${SystemPrepLogDir}\systemprep-log_${DateTime}.txt"
$ScriptName = $MyInvocation.mycommand.name
$ErrorActionPreference = "Stop"

###
#Start a transcript to record script output
###
#Create the SystemPrep log directory
New-Item -Path $SystemPrepDir -ItemType "directory" -Force 2>&1 > $null
New-Item -Path $SystemPrepLogDir -ItemType "directory" -Force 2>&1 > $null
Start-Transcript $SystemPrepLogFile

###
#Define Functions
###
function log {
    [CmdLetBinding()]
    Param(
        [Parameter(Mandatory=$false,Position=0,ValueFromPipeLine=$true,ValueFromPipeLineByPropertyName=$true)] [string[]] 
        $LogMessage,
        [Parameter(Mandatory=$false,Position=1,ValueFromPipeLine=$false,ValueFromPipeLineByPropertyName=$true)] [string] 
        $EntryType="Information",
        [Parameter(Mandatory=$false,Position=2,ValueFromPipeLine=$false,ValueFromPipeLineByPropertyName=$true)] [string] 
        $LogTag
    )
    PROCESS {
        foreach ($message in $LogMessage) {
            $date = get-date -format "yyyyMMdd.HHmm.ss"
            Manage-Output -EntryType $EntryType "${date}: ${LogTag}: $message"
        }
    }
}


function Manage-Output {
    [CmdLetBinding()]
    Param(
        [Parameter(Mandatory=$false,Position=0,ValueFromPipeLine=$true,ValueFromPipeLineByPropertyName=$true)] [string[]]
        $Output,
        [Parameter(Mandatory=$false,Position=1,ValueFromPipeLine=$false,ValueFromPipeLineByPropertyName=$true)] [string]
        $EntryType="Information"
    )
	PROCESS {
		foreach ($str in $Output) {
            #Write to the event log
            Write-EventLog -LogName Application -Source SystemPrep -EventId 1 -EntryType $EntryType -Message "${str}"
            #Write to the default stream (this way we don't clobber the output stream, and the output will be captured by Start-Transcript)
            "${str}" | Out-Default
		}
	}
}


function Download-File {
    [CmdLetBinding()]
    Param(
        [Parameter(Mandatory=$true,Position=0,ValueFromPipeLine=$true,ValueFromPipeLineByPropertyName=$true)] [string[]] $Url,
        [Parameter(Mandatory=$true,Position=1,ValueFromPipeLine=$false,ValueFromPipeLineByPropertyName=$false)] [string] $SavePath,
        [Parameter(Mandatory=$false,Position=2,ValueFromPipeLine=$false,ValueFromPipeLineByPropertyName=$false)] [switch] $SourceIsS3Bucket,
        [Parameter(Mandatory=$false,Position=3,ValueFromPipeLine=$false,ValueFromPipeLineByPropertyName=$false)] [string] $AwsRegion
    )
    BEGIN {
        New-Item -Path ${SavePath} -ItemType Directory -Force -WarningAction SilentlyContinue > $null
    }
    PROCESS {
        foreach ($url_item in $Url) {
            $FileName = "${SavePath}\$((${url_item}.split('/'))[-1])"
            if ($SourceIsS3Bucket) {
                log -LogTag ${ScriptName} "Downloading file from S3 bucket: ${url_item}"
                $SplitUrl = $url_item.split('/') | where { $_ -notlike "" }
                $BucketName = $SplitUrl[2]
                $Key = $SplitUrl[3..($SplitUrl.count-1)] -join '/'
                $ret = Invoke-Expression "Powershell Read-S3Object -BucketName $BucketName -Key $Key -File $FileName -Region $AwsRegion"
            }
            else {
                log -LogTag ${ScriptName} "Downloading file from HTTP host: ${url_item}"
                (new-object net.webclient).DownloadFile("${url_item}","${FileName}")
            }
            Write-Output (Get-Item $FileName)
        }
    }
}


function Expand-ZipFile {
    [CmdLetBinding()]
    Param(
        [Parameter(Mandatory=$true,Position=0,ValueFromPipeLine=$true,ValueFromPipeLineByPropertyName=$true)] [string[]] $FileName,
        [Parameter(Mandatory=$true,Position=1,ValueFromPipeLine=$false,ValueFromPipeLineByPropertyName=$false)] [string] $DestPath,
        [Parameter(Mandatory=$false,Position=2,ValueFromPipeLine=$false,ValueFromPipeLineByPropertyName=$false)] [switch] $CreateDirFromFileName
    )
    PROCESS {
        foreach ($file in $FileName) {
            $Shell = new-object -com shell.application
            if (!(Test-Path "$file")) {
                throw "$file does not exist" 
            }
            log -LogTag ${ScriptName} "Unzipping file: ${file}"
            if ($CreateDirFromFileName) { $DestPath = "${DestPath}\$((Get-Item $file).BaseName)" }
            New-Item -Path $DestPath -ItemType Directory -Force -WarningAction SilentlyContinue > $null
            $Shell.namespace($DestPath).copyhere($Shell.namespace("$file").items(), 0x14) 
            Write-Output (Get-Item $DestPath)
        }
    }
}


function Import-509Certificate {
    [CmdLetBinding()]
    Param(
        [Parameter(Mandatory=$true,Position=0,ValueFromPipeLine=$true,ValueFromPipeLineByPropertyName=$false)] [string[]] $certPath,
        [Parameter(Mandatory=$true,Position=1,ValueFromPipeLine=$false,ValueFromPipeLineByPropertyName=$false)] [string] $certRootStore,
        [Parameter(Mandatory=$true,Position=2,ValueFromPipeLine=$false,ValueFromPipeLineByPropertyName=$false)] [string] $certStore
    )
    PROCESS {
        foreach ($item in $certpath) {
            log -LogTag ${ScriptName} "Importing certificate: ${item}"
            $pfx = new-object System.Security.Cryptography.X509Certificates.X509Certificate2
            $pfx.import($item)

            $store = new-object System.Security.Cryptography.X509Certificates.x509Store($certStore,$certRootStore)
            $store.open("MaxAllowed")
            $store.add($pfx)
            $store.close()
        }
    }
}


function Install-RootCerts {
    [CmdLetBinding()]
    Param(
        [Parameter(Mandatory=$true,Position=0,ValueFromPipeLine=$true,ValueFromPipeLineByPropertyName=$false)] [string[]] $RootCertHost
    )
    PROCESS {
        foreach ($item in $RootCertHost) {
            $CertDir = "${env:temp}\certs-$(${item}.Replace(`"http://`",`"`"))"
            New-Item -Path $CertDir -ItemType "directory" -Force -WarningAction SilentlyContinue > $null
            log -LogTag ${ScriptName} "...Checking for certificates hosted by: $item..."
            $CertUrls = @((Invoke-WebRequest -Uri $item).Links | where { $_.href -match ".*\.cer$"} | foreach-object {$item + $_.href})
            log -LogTag ${ScriptName} "...Found $(${CertUrls}.count) certificate(s)..."
            log -LogTag ${ScriptName} "...Downloading certificate(s)..."
            $CertFiles = $CertUrls | Download-File -SavePath $CertDir
            $TrustedRootCACertFiles = $CertFiles | where { $_.Name -match ".*root.*" }
            $IntermediateCACertFiles = $CertFiles | where { $_.Name -notmatch ".*root.*" }
            log -LogTag ${ScriptName} "...Beginning import of $(${TrustedRootCACertFiles}.count) trusted root CA certificate(s)..."
            $TrustedRootCACertFiles | Import-509Certificate -certRootStore "LocalMachine" -certStore "Root"
            log -LogTag ${ScriptName} "...Beginning import of $(${IntermediateCACertFiles}.count) intermediate CA certificate(s)..."
            $IntermediateCACertFiles | Import-509Certificate -certRootStore "LocalMachine" -certStore "CA"
            log -LogTag ${ScriptName} "...Completed import of certificate(s) from: ${item}"
        }
    }
}


function Install-AwsSdkEndpointXml {
    [CmdLetBinding()]
    Param(
        [Parameter(Mandatory=$true,Position=0,ValueFromPipeLine=$true,ValueFromPipeLineByPropertyName=$false)] [string[]] $AwsToolsUrl
    )
    PROCESS {
        foreach ($item in $AwsToolsUrl) {
            log -LogTag ${ScriptName} "...Beginning import of AWS SDK Endpoints XML file..."
            $AwsToolsFile = Download-File -Url $item -SavePath ${env:temp}
            log -LogTag ${ScriptName} "...Extracting AWS Tools..."
            $AwsToolsDir = Expand-ZipFile -FileName $AwsToolsFile -DestPath ${env:temp} -CreateDirFromFileName
            $AwsSdkEndpointSource = "${AwsToolsDir}\customization\sdk\AWSSDK.endpoints.xml"
            $AwsSdkEndpointDest = "${Env:ProgramFiles(x86)}\AWS Tools\PowerShell\AWSPowerShell"
            log -LogTag ${ScriptName} "Copying AWS SDK Endpoints XML file -- "
            log -LogTag ${ScriptName} "  -- source: ${AwsSdkEndpointSource}"
            log -LogTag ${ScriptName} "  -- dest:   ${AwsSdkEndpointDest}"
            Copy-Item $AwsSdkEndpointSource $AwsSdkEndpointDest
            log -LogTag ${ScriptName} "...Completed import of AWS SDK Endpoints XML file..."
        }
    }
}


function Enable-Ec2EventLogging {
    [CmdLetBinding()]
    Param()
    PROCESS {
        $EC2SettingsFile = "${env:ProgramFiles}\Amazon\Ec2ConfigService\Settings\Config.xml"
        $xml = [xml](get-content $EC2SettingsFile)
        $xmlElement = $xml.get_DocumentElement()
        $xmlElementToModify = $xmlElement.Plugins

        foreach ($element in $xmlElementToModify.Plugin)
        {
            if ($element.name -eq "Ec2EventLog")
            {
                $element.State = "Enabled"
            }
        }
        $xml.Save($EC2SettingsFile)
        log -LogTag ${ScriptName} "Enabled EC2 event logging"
    }
}


function Add-Ec2EventLogSource {
    [CmdLetBinding()]
    Param(
        [Parameter(Mandatory=$true,Position=0,ValueFromPipeLine=$false,ValueFromPipeLineByPropertyName=$false)] [string[]] $LogSource
    )
    PROCESS {
        foreach ($Source in $LogSource) {
            $EC2EventLogFile = "${env:ProgramFiles}\Amazon\Ec2ConfigService\Settings\EventLogConfig.xml"
            $xml = [xml](Get-Content $EC2EventLogFile)

            foreach ($MessageType in @("Information","Warning","Error")) {
                $xmlElement = $xml.EventLogConfig.AppendChild($xml.CreateElement("Event"))

                $xml_category = $xmlElement.AppendChild($xml.CreateElement("Category"))
                $xml_category.AppendChild($xml.CreateTextNode("Application"))

                $xml_errortype = $xmlElement.AppendChild($xml.CreateElement("ErrorType"))
                $xml_errortype.AppendChild($xml.CreateTextNode($MessageType))

                $xml_numentries = $xmlElement.AppendChild($xml.CreateElement("NumEntries"))
                $xml_numentries.AppendChild($xml.CreateTextNode("9999"))

                $xml_appname = $xmlElement.AppendChild($xml.CreateElement("AppName"))
                $xml_appname.AppendChild($xml.CreateTextNode("${Source}"))

                $xml_lastmessagetime = $xmlElement.AppendChild($xml.CreateElement("LastMessageTime"))
                $xml_lastmessagetime.AppendChild($xml.CreateTextNode($(get-date -Format "yyyy-MM-ddTHH:mm:ss.0000000+00:00")))
            }
            
            $xml.Save($EC2EventLogFile)
            log -LogTag ${ScriptName} "Added the log source, ${Source}, to the EC2 Event Log configuration file"
        }
    }
}


###
#Begin Script
###

#Create a "SystemPrep" event log source
try {
    New-EventLog -LogName Application -Source "${LogSource}"
} catch [System.InvalidOperationException] {
    # Event log already exists, log a message but don't force an exit
    log -LogTag ${ScriptName} "Event log source, ${LogSource}, already exists. Continuing..."
} catch {
    # Unhandled exception, log an error and exit!
    "$(get-date -format "yyyyMMdd.HHmm.ss"): ${ScriptName}: ERROR: Encountered a problem trying to create the event log source." | Out-Default
    Stop-Transcript
    throw
}

if ($ConfigureEc2EventLogging) {
    #Enable and configure EC2 event logging
    try {
        Enable-Ec2EventLogging
        Add-Ec2EventLogSource -LogSource ${LogSource}
    } catch {
        # Unhandled exception, log an error and exit!
        log -LogTag ${ScriptName} -EntryType "Error" "ERROR: Encountered a problem trying to configure EC2 event logging."
        Stop-Transcript
        throw
    }
}

if ($RootCertUrl) {
    #Download and install the root certificates
    try {
        Install-RootCerts -RootCertHost ${RootCertUrl}
    } catch {
        # Unhandled exception, log an error and exit!
        log -LogTag ${ScriptName} -EntryType "Error" "ERROR: Encountered a problem trying to install root certificates."
        Stop-Transcript
        throw
    }
}

if ($AwsToolsUrl) {
    #Download and install the AWS SDK Endpoint XML file
    try {
        Install-AwsSdkEndpointXml -AwsToolsUrl ${AwsToolsUrl}
    } catch {
        # Unhandled exception, log an error and exit!
        log -LogTag ${ScriptName} -EntryType "Error" "ERROR: Encountered a problem trying to install root certificates."
        Stop-Transcript
        throw
    }
}

#Download the master script
log -LogTag ${ScriptName} "Downloading the SystemPrep master script: ${SystemPrepMasterScriptUrl}"
try {
    $SystemPrepMasterScript = Download-File $SystemPrepMasterScriptUrl $SystemPrepDir -SourceIsS3Bucket:($SystemPrepParams["SourceIsS3Bucket"]) -AwsRegion $SystemPrepParams["AwsRegion"]
} catch {
    # Unhandled exception, log an error and exit!
    log -LogTag ${ScriptName} -EntryType "Error" "ERROR: Encountered a problem trying to download the master script!"
    Stop-Transcript
    throw
}

#Execute the master script
log -LogTag ${ScriptName} "Running the SystemPrep master script: ${SystemPrepMasterScript}"
try {
    Invoke-Expression "& ${SystemPrepMasterScript} @SystemPrepParams" | Manage-Output
} catch {
    # Unhandled exception, log an error and exit!
    log -LogTag ${ScriptName} -EntryType "Error" "ERROR: Encountered a problem executing the master script!"
    Stop-Transcript
    throw
}

#Reached the exit without an error, log success message
log -LogTag ${ScriptName} "SystemPrep completed successfully! Exiting..."
Stop-Transcript
