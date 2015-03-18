[CmdLetBinding()]
Param(
    [Parameter(Mandatory=$false,Position=0,ValueFromRemainingArguments=$true)] 
    $RemainingArgs
    ,
	[Parameter(Mandatory=$true,ValueFromPipeLine=$false,ValueFromPipeLineByPropertyName=$false)]
    [string] $SaltWorkingDir
    ,
	[Parameter(Mandatory=$true,ValueFromPipeLine=$false,ValueFromPipeLineByPropertyName=$false)]
    [ValidateScript({ $_ -match "^http[s]?://.*\.zip$" })]
    [string] $SaltInstallerUrl
    ,
	[Parameter(Mandatory=$true,ValueFromPipeLine=$false,ValueFromPipeLineByPropertyName=$false)]
    [ValidateScript({ $_ -match "^http[s]?://.*\.zip$" })]
    [string] $SaltContentUrl
    ,
	[Parameter(Mandatory=$false,ValueFromPipeLine=$false,ValueFromPipeLineByPropertyName=$false)]
    [ValidateScript({ $_ -match "^http[s]?://.*\.zip$" })]
    [string[]] $FormulasToInclude
    ,
	[Parameter(Mandatory=$false,ValueFromPipeLine=$false,ValueFromPipeLineByPropertyName=$false)]
    [string[]] $FormulaTerminationStrings = "-latest"
    ,
	[Parameter(Mandatory=$false,ValueFromPipeLine=$false,ValueFromPipeLineByPropertyName=$false)]
    [ValidateSet("None","MemberServer","DomainController","Workstation")]
    [string] $AshRole = "None"
    ,
    [Parameter(Mandatory=$false,ValueFromPipeLine=$false,ValueFromPipeLineByPropertyName=$false)]
    [ValidateSet("None","Unclass","NIPR","SIPR","JWICS")]
    [string] $NetBannerLabel = "None"
    ,
    [Parameter(Mandatory=$false,ValueFromPipeLine=$false,ValueFromPipeLineByPropertyName=$false)] 
    [string] $SaltStates = "None"
    ,
    [Parameter(Mandatory=$false,ValueFromPipeLine=$false,ValueFromPipeLineByPropertyName=$false)] 
    [string] $SaltDebugLog
    ,
    [Parameter(Mandatory=$false,ValueFromPipeLine=$false,ValueFromPipeLineByPropertyName=$false)] 
    [string] $SaltResultsLog
    ,
    [Parameter(Mandatory=$false,ValueFromPipeLine=$false,ValueFromPipeLineByPropertyName=$false)] 
    [switch] $SourceIsS3Bucket
	,
    [Parameter(Mandatory=$false,ValueFromPipeLine=$false,ValueFromPipeLineByPropertyName=$false)] 
    [string] $AwsRegion
)
#Parameter Descriptions
#$RemainingArgs       #Parameter that catches any undefined parameters passed to the script.
                      #Used by the bootstrapping framework to pass those parameters through to other scripts. 
                      #This way, we don't need to know in the master script all the parameter names for downstream scripts.

#$SaltWorkingDir      #Fully-qualified path to a directory that will be used as a staging location for download and unzip salt content
                      #specified in $SaltContentUrl and any formulas in $FormulasToInclude

#$SaltContentUrl      #Url to a zip file containing the salt installer executable

#$SaltContentUrl      #Url to a zip file containing the `files_root` salt content

#$FormulasToInclude   #Array of strings, where each string is the url of a zipped salt formula to be included in the salt configuration.
                      #Formula content *must* be contained in a zip file.

#$FormulaTerminationStrings = "-latest" #Array of strings
                                        #If an included formula ends with a string in this list, the TerminationString will be removed from the formula name
                                        #Intended to remove versioning information from the formula name
                                        #For example, the formula 'ash-windows-formula-latest' will be renamed to 'ash-windows-formula'

#$AshRole = "None"    #Writes a salt custom grain to the system, ash-windows:role. The role affects the security policies applied. Parameter key:
                      #-- "None"             -- Does not write the custom grain to the system; ash-windows will default to the MemberServer security policy
                      #-- "MemberServer"     -- Ash-windows applies the "MemberServer" security baseline
                      #-- "DomainController" -- Ash-windows applies the "DomainController" security baseline
                      #-- "Workstation"      -- Ash-windows applies the "Workstation" security baseline

#$NetBannerLabel = "None" #Writes a salt custom grain to the system, netbanner:string. Determines the NetBanner string and color configuration. Parameter key:
                           #-- "None"    -- Does not write the custom grain to the system; netbanner will default to the Unclass string
                           #-- "Unclass" -- NetBanner Background color: Green,  Text color: White, String: "UNCLASSIFIED"
                           #-- "NIPR"    -- NetBanner Background color: Green,  Text color: White, String: "UNCLASSIFIED//FOUO"
                           #-- "SIPR"    -- NetBanner Background color: Red,    Text color: White, String: "SECRET AND AUTHORIZED TO PROCESS NATO SECRET"
                           #-- "JWICS"   -- NetBanner Background color: Yellow, Text color: White, String: "TOPSECRET//SI/TK/NOFORN                  **G//HCS//NATO SECRET FOR APPROVED USERS IN SELECTED STORAGE SPACE**"

#$SaltStates = "None" #Comma-separated list of salt states. Listed states will be applied to the system. Parameter key:
                      #-- "None"              -- Special keyword; will not apply any salt states
                      #-- "Highstate"         -- Special keyword; applies the salt "highstate" as defined in the SystemPrep top.sls file
                      #-- "user,defined,list" -- User may pass in a comma-separated list of salt states to apply to the system; state names are case-sensitive and must match exactly

#$SourceIsS3Bucket    #Set to $true if all content to be downloaded is hosted in an S3 bucket and should be retrieved using AWS tools.
#$AwsRegion			  #Set to the region in which the S3 bucket is located.

#System variables
$ScriptName = $MyInvocation.mycommand.name
$SystemRoot = $env:SystemRoot
$ScriptStart = "++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++"
$ScriptEnd = "--------------------------------------------------------------------------------"
#Convert RemainingArgs to a hashtable
if ($PSVersionTable.PSVersion -eq "2.0") { #PowerShell 2.0 receives remainingargs in a different format than PowerShell 3.0
	$RemainingArgsHash = $RemainingArgs | ForEach-Object -Begin { $index = 0; $hash = @{} } -Process { if ($index % 2 -eq 0) { $hash[$_] = $RemainingArgs[$index+1] }; $index++ } -End { Write-Output $hash }
} else {
	$RemainingArgsHash = $RemainingArgs | ForEach-Object -Begin { $index = 0; $hash = @{} } -Process { if ($_ -match "^-.*:$") { $hash[($_.trim("-",":"))] = $RemainingArgs[$index+1] }; $index++ } -End { Write-Output $hash }
}###

###
#Define functions
###
function log {
    [CmdLetBinding()]
    Param(
        [Parameter(Mandatory=$false,Position=0,ValueFromPipeLine=$true,ValueFromPipeLineByPropertyName=$true)] [string[]] 
        $LogMessage,
        [Parameter(Mandatory=$false,Position=1,ValueFromPipeLine=$false,ValueFromPipeLineByPropertyName=$true)] [string] 
        $LogTag
    )
    PROCESS {
        foreach ($message in $LogMessage) {
            $date = get-date -format "yyyyMMdd.HHmm.ss"
            "${date}: ${LogTag}: $message" | Out-Default
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


###
#Begin Script
###
#Make sure the salt working directories exist
if (-Not (Test-Path $SaltWorkingDir)) { 
    New-Item -Path $SaltWorkingDir -ItemType "directory" -Force > $null
    log -LogTag ${ScriptName} "Created working directory -- ${SaltWorkingDir}" 
} else { 
    log -LogTag ${ScriptName} "Working directory already exists -- ${SaltWorkingDir}" 
}

#Create log entry to note the script that is executing
log -LogTag ${ScriptName} $ScriptStart
log -LogTag ${ScriptName} "Within ${ScriptName} --"
log -LogTag ${ScriptName} "SaltWorkingDir = ${SaltWorkingDir}"
log -LogTag ${ScriptName} "SaltInstallerUrl = ${SaltInstallerUrl}"
log -LogTag ${ScriptName} "SaltContentUrl = ${SaltContentUrl}"
log -LogTag ${ScriptName} "FormulasToInclude = ${FormulasToInclude}"
log -LogTag ${ScriptName} "FormulaTerminationStrings = ${FormulaTerminationStrings}"
log -LogTag ${ScriptName} "AshRole = ${AshRole}"
log -LogTag ${ScriptName} "NetBannerLabel = ${NetBannerLabel}"
log -LogTag ${ScriptName} "SaltStates = ${SaltStates}"
log -LogTag ${ScriptName} "SaltDebugLog = ${SaltDebugLog}"
log -LogTag ${ScriptName} "SaltResultsLog = ${SaltResultsLog}"
log -LogTag ${ScriptName} "SourceIsS3Bucket = ${SourceIsS3Bucket}"
log -LogTag ${ScriptName} "RemainingArgsHash = $(($RemainingArgsHash.GetEnumerator() | % { `"-{0}: {1}`" -f $_.key, $_.value }) -join ' ')"

#Insert script commands
###
#Download and extract the salt installer
$SaltInstallerFile = Download-File -Url $SaltInstallerUrl -SavePath $SaltWorkingDir -SourceIsS3Bucket:$SourceIsS3Bucket -AwsRegion $AwsRegion
$SaltInstallerDir = Expand-ZipFile -FileName ${SaltInstallerFile} -DestPath ${SaltWorkingDir}

#Download and extract the salt content
$SaltContentFile = Download-File -Url $SaltContentUrl -SavePath $SaltWorkingDir -SourceIsS3Bucket:$SourceIsS3Bucket -AwsRegion $AwsRegion
$SaltContentDir = Expand-ZipFile -FileName ${SaltContentFile} -DestPath ${SaltWorkingDir}

#Download and extract the salt formulas
foreach ($Formula in $FormulasToInclude) {
    $FormulaFile = Download-File -Url ${Formula} -SavePath $SaltWorkingDir -SourceIsS3Bucket:$SourceIsS3Bucket -AwsRegion $AwsRegion
    $FormulaDir = Expand-ZipFile -FileName ${FormulaFile} -DestPath "${SaltWorkingDir}\formulas"
    $FormulaBaseName = ($Formula.split('/')[-1].split('.') | Select-Object -Skip 1 -last 10000000) -join '.'
    $FormulaDir = Get-Item "${FormulaDir}\${FormulaBaseName}"
	#If the formula directory ends in a string in $FormulaTerminationStrings, delete the string from the directory name
	$FormulaTerminationStrings | foreach { if ($FormulaDir.Name -match "${_}$") { mv $FormulaDir.FullName $FormulaDir.FullName.substring(0,$FormulaDir.FullName.length-$_.length) } }
}

$VcRedistInstaller = (Get-ChildItem "${SaltWorkingDir}" | where {$_.Name -like "vcredist_x64.exe"}).FullName
$SaltInstaller = (Get-ChildItem "${SaltWorkingDir}" | where {$_.Name -like "Salt-Minion-*-Setup.exe"}).FullName
$SaltBase = "C:\salt"
$SaltSrv = "C:\salt\srv"
$SaltFileRoot = "${SaltSrv}\states"
$SaltBaseEnv = "${SaltFileRoot}\base"
$SaltFormulaRoot = "${SaltSrv}\formulas"
$SaltWinRepo = "${SaltSrv}\winrepo"
$MinionConf = "${SaltBase}\conf\minion"
$MinionExe = "${SaltBase}\salt-call.exe"
$MinionService = "salt-minion"
if (-not $SaltDebugLog) {
    $SaltDebugLogFile = "${SaltWorkingDir}\salt.staterun.debug.log"
} else {
    $SaltDebugLogFile = $SaltDebugLog
}
if (-not $SaltResultsLog) {
    $SaltResultsLogFile = "${SaltWorkingDir}\salt.staterun.results.log"
} else {
    $SaltResultsLogFile = $SaltResultsLog
}

log -LogTag ${ScriptName} "Installing Microsoft Visual C++ 2008 SP1 MFC Security Update redist package -- ${VcRedistInstaller}"
$VcRedistInstallResult = Start-Process -FilePath $VcRedistInstaller -ArgumentList "/q" -NoNewWindow -PassThru -Wait
log -LogTag ${ScriptName} "Return code of vcredist install: $(${VcRedistInstallResult}.ExitCode)"

log -LogTag ${ScriptName} "Installing salt -- ${SaltInstaller}"
$SaltInstallResult = Start-Process -FilePath $SaltInstaller -ArgumentList "/S" -NoNewWindow -PassThru -Wait
log -LogTag ${ScriptName} "Return code of salt install: $(${SaltInstallResult}.ExitCode)"

log -LogTag ${ScriptName} "Populating salt file_roots"
mkdir -Force $SaltSrv 2>&1 > $null
cp "${SaltWorkingDir}\srv" "${SaltBase}" -Force -Recurse 2>&1 | log -LogTag ${ScriptName}
rm "${SaltWorkingDir}\srv" -Force -Recurse 2>&1 | log -LogTag ${ScriptName}
log -LogTag ${ScriptName} "Populating salt formulas"
mkdir -Force $SaltFormulaRoot 2>&1 > $null
cp "${SaltWorkingDir}\formulas" "${SaltSrv}" -Force -Recurse 2>&1 | log -LogTag ${ScriptName}
rm "${SaltWorkingDir}\formulas" -Force -Recurse 2>&1 | log -LogTag ${ScriptName}

log -LogTag ${ScriptName} "Setting salt-minion configuration to local mode"
cp $MinionConf "${MinionConf}.bak" 2>&1 | log -LogTag ${ScriptName}
#get the contents of the minion's conf file
$MinionConfContent = Get-Content $MinionConf
#set file_client: to "local"
$MinionConfContent = $MinionConfContent | ForEach-Object {$_ -replace "^#file_client: remote","file_client: local"}
#set win_repo_cachfile: to ${SaltWinRepo}\winrepo.p AND set win_repo: to ${SaltWinRepo}
$MinionConfContent = $MinionConfContent | ForEach-Object {$_ -replace "^# win_repo_cachefile: 'salt://win/repo/winrepo.p'","win_repo_cachefile: '${SaltWinRepo}\winrepo.p'`r`nwin_repo: '${SaltWinRepo}'"}
#Construct an array of all the Formula directories to include in the minion conf file
$FormulaFileRootConf = (Get-ChildItem ${SaltFormulaRoot} | where {$_.Attributes -eq "Directory"}) | ForEach-Object { "    - " + $(${_}.fullname) }
#Construct the contents for the file_roots section of the minion conf file
$SaltFileRootConf = @()
$SaltFileRootConf += "file_roots:"
$SaltFileRootConf += "  base:"
$SaltFileRootConf += "    - ${SaltBaseEnv}"
$SaltFileRootConf += "    - ${SaltWinRepo}"
$SaltFileRootConf += $FormulaFileRootConf
$SaltFileRootConf += ""

#Regex strings to mark the beginning and end of the file_roots section
$FilerootsBegin = "^#file_roots:|^file_roots:"
$FilerootsEnd = "^$"

#Find the file_roots section in the minion conf file and replace it with the new configuration in $SaltFileRootConf
$MinionConfContent | foreach -Begin { 
    $n=0; $beginindex=$null; $endindex=$null 
} -Process { 
    if ($_ -match "$FilerootsBegin") { 
        $beginindex = $n 
    }
    if ($beginindex -and -not $endindex -and $_ -match "$FilerootsEnd") { 
        $endindex = $n 
    }
    $n++ 
} -End { 
    $MinionConfContent = $MinionConfContent[0..($beginindex-1)] + $SaltFileRootConf + $MinionConfContent[($endindex+1)..$MinionConfContent.Length]
}

#Write custom grains to the salt configuration file
if ( ($AshRole -ne "None") -or ($NetBannerLabel -ne "None") ) {
    $CustomGrainsContent = @()
    $CustomGrainsContent += "grains:"

    if ($AshRole -ne "None") {
        log -LogTag ${ScriptName} "Writing the Ash role to a grain in the salt configuration file"
        $AshRoleCustomGrain = @()
        $AshRoleCustomGrain += "  ash-windows:"
        $AshRoleCustomGrain += "    role: ${AshRole}"
    }
    if ($NetBannerLabel -ne "None") {
        log -LogTag ${ScriptName} "Writing the NetBanner label to a grain in the salt configuration file"
        $NetBannerLabelCustomGrain = @()
        $NetBannerLabelCustomGrain += "  netbanner:"
        $NetBannerLabelCustomGrain += "    network_label: ${NetBannerLabel}"
    }

    $CustomGrainsContent += $AshRoleCustomGrain
    $CustomGrainsContent += $NetBannerLabelCustomGrain
    $CustomGrainsContent += ""

    #Regex strings to mark the beginning and end of the custom grains section
    $CustomGrainsBegin = "^#grains:|^grains:"
    $CustomGrainsEnd = "^$"

    #Find the custom grains section in the minion conf file and replace it with the new configuration in $CustomGrainsContent
    $MinionConfContent | foreach -Begin { 
        $n=0; $beginindex=$null; $endindex=$null 
    } -Process { 
        if ($_ -match "$CustomGrainsBegin") { 
            $beginindex = $n 
        }
        if ($beginindex -and -not $endindex -and $_ -match "$CustomGrainsEnd") { 
            $endindex = $n 
        }
        $n++ 
    } -End { 
        $MinionConfContent = $MinionConfContent[0..($beginindex-1)] + $CustomGrainsContent + $MinionConfContent[($endindex+1)..$MinionConfContent.Length]
    }
}

#Write the updated minion conf file to disk
$MinionConfContent | Set-Content $MinionConf

log -LogTag ${ScriptName} "Generating salt winrepo cachefile"
$GenRepoResult = Start-Process $MinionExe -ArgumentList "--local winrepo.genrepo" -NoNewWindow -PassThru -Wait

if ("none" -eq $SaltStates.tolower()) {
    log -LogTag ${ScriptName} "Detected the SaltStates parameter is set to: ${SaltStates}. Will not apply any salt states."
} else {
    #Run the specified salt state
    if ("highstate" -eq $SaltStates.tolower() ) {
        log -LogTag ${ScriptName} "Detected the States parameter is set to: ${SaltStates}. Applying the salt `"highstate`" to the system."
        $ApplyStatesResult = Start-Process $MinionExe -ArgumentList "--local state.highstate --out json --out-file ${SaltResultsLogFile} --return local --log-file ${SaltDebugLogFile} --log-file-level debug" -NoNewWindow -PassThru -Wait
        log -LogTag ${ScriptName} "Return code of salt-call: $(${ApplyStatesResult}.ExitCode)"
    } else {
        log -LogTag ${ScriptName} "Detected the States parameter is set to: ${SaltStates}. Applying the user-defined list of states to the system."
        $ApplyStatesResult = Start-Process $MinionExe -ArgumentList "--local state.sls ${SaltStates} --out json --out-file ${SaltResultsLogFile} --return local --log-file ${SaltDebugLogFile} --log-file-level debug" -NoNewWindow -PassThru -Wait
        log -LogTag ${ScriptName} "Return code of salt-call: $(${ApplyStatesResult}.ExitCode)"
    }
    #Check for errors in the results file
    if (Select-String -Path ${SaltResultsLogFile} -Pattern '"result": false') {
        # One of the salt states failed, log and throw an error
        log -LogTag ${ScriptName} "ERROR: One of the salt states failed! Check the log file for details, ${SaltResultsLogFile}"
        throw ("ERROR: One of the salt states failed! Check the log file for details, ${SaltResultsLogFile}")
    } else {
        log -LogTag ${ScriptName} "Salt states applied successfully! Details are in the log, ${SaltResultsLogFile}"
    }
}
###

#Log exit from script
log -LogTag ${ScriptName} "Exiting ${ScriptName} -- salt install complete"
log -LogTag ${ScriptName} $ScriptEnd