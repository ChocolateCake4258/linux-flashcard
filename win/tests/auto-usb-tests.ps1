# Real automatic coordinator with fake disk enumeration and subprocess boundaries.
# No native disk APIs, downloads or guest jobs are used by this harness.
$ErrorActionPreference='Stop'
$win=Split-Path $PSScriptRoot -Parent
Import-Module (Join-Path $win 'lib\pf-tools.psm1') -Force -WarningAction SilentlyContinue
. (Join-Path $win 'factory\usb.ps1')
. (Join-Path $win 'lib\pf-storage.ps1')
$root=Join-Path $env:TEMP ('pf-auto-usb-'+[guid]::NewGuid().ToString('N'))
$null=[IO.Directory]::CreateDirectory($root)
$passed=0
function Require($Condition,[string]$Message){if(-not $Condition){throw $Message}}
function Case([string]$Name,[scriptblock]$Body){& $Body;$script:passed++;Write-Output ('PASS '+$Name)}
$global:AutoDisk=[pscustomobject]@{Number=7;Path='test-device';SerialNumber='serial';Size=[long](8MB+512);BusType='USB';IsBoot=$false;IsSystem=$false;IsReadOnly=$false;IsOffline=$false;LogicalSectorSize=512}
$module=Get-Module pf-tools
& $module {function script:Get-Disk {param($Number) $global:AutoDisk}}
function Get-Disk {param($Number) $global:AutoDisk}
function Get-CimInstance {param($ClassName) [pscustomobject]@{Index=7;Model='Test USB';InterfaceType='USB'}}
function Get-Partition {param($DriveLetter) [pscustomobject]@{DiskNumber=$(if($global:RejectSource -and $DriveLetter -eq $win.Substring(0,1)){7}else{0})}}
function Get-Volume {param($DriveLetter) [pscustomobject]@{DriveLetter=$root.Substring(0,1);DriveType='Fixed';FileSystem='NTFS';SizeRemaining=200GB}}
$settings=Join-Path $root 'last-build.json'
function Get-PfPreparationSettingsPath {$settings}
try{
    Case 'Eligibility rejects system, read-only, unsupported sector and undersized disks' {
        Require (@(Get-PfPreparationDisks 8MB).Count -eq 1) 'Valid USB was rejected'
        foreach($field in @('IsBoot','IsSystem','IsReadOnly','IsOffline','LogicalSectorSize','Size')){
            $old=$global:AutoDisk.$field
            try{
                $global:AutoDisk.$field=if($field -eq 'LogicalSectorSize'){4096}elseif($field -eq 'Size'){1MB}else{$true}
                Require (@(Get-PfPreparationDisks 8MB).Count -eq 0) ('Unsafe disk accepted: '+$field)
            }finally{$global:AutoDisk.$field=$old}
        }
    }
    Case 'Default workspace is outside source and is selected without creating directories' {
        $candidate=Resolve-PfPreparationWorkspace -Source (Split-Path $win -Parent) -Target $global:AutoDisk -SettingsPath $settings -RequiredBytes 100GB
        Require ($candidate -like '*\builds\build-*' -and -not (Test-Path -LiteralPath $candidate)) 'Default workspace was created during selection'
        Write-PfPreparationJson $settings @{Schema=1;Workspace=(Join-Path $root 'remembered');MediaBytes=$global:AutoDisk.Size}
        Require ((Resolve-PfPreparationWorkspace -Source (Split-Path $win -Parent) -Target $global:AutoDisk -SettingsPath $settings -RequiredBytes 100GB) -eq (Join-Path $root 'remembered')) 'Previous workspace was not selected'
        $fresh=Resolve-PfPreparationWorkspace -Source (Split-Path $win -Parent) -Target $global:AutoDisk -SettingsPath $settings -RequiredBytes 100GB -NewBuild
        Require ($fresh -ne (Join-Path $root 'remembered') -and -not (Test-Path -LiteralPath $fresh)) 'NewBuild reused the remembered workspace'
    }
    Case 'Workspace ownership and source isolation fail closed' {
        $foreign=Join-Path $root 'foreign';$null=[IO.Directory]::CreateDirectory($foreign)
        [IO.File]::WriteAllText((Join-Path $foreign 'keep.txt'),'user data')
        foreach($path in @($foreign,(Split-Path $win -Parent))){
            $caught=$false;try{Assert-PfPreparationWorkspace $path (Split-Path $win -Parent) 7|Out-Null}catch{$caught=$true}
            Require $caught 'Unowned/source workspace was accepted'
        }
        Require ([IO.File]::ReadAllText((Join-Path $foreign 'keep.txt')) -eq 'user data') 'Foreign contents changed'
    }
    Case 'Real subprocess boundary preserves spaces, apostrophes and Unicode' {
        $quoted=Join-Path $root "quoted path's test.ps1";$output=Join-Path $root 'child-result.json'
        [IO.File]::WriteAllText($quoted,'param([string]$Value,[string]$Output,[switch]$Enabled) [IO.File]::WriteAllText($Output,(@{Value=$Value;Enabled=[bool]$Enabled}|ConvertTo-Json)); exit 0',[Text.Encoding]::UTF8)
        $value="Каталог с пробелами и апострофом '"
        Invoke-PfPreparationScript $quoted @{Value=$value;Output=$output;Enabled=$true}
        $result=Get-Content -LiteralPath $output -Raw -Encoding UTF8|ConvertFrom-Json
        Require ($result.Value -ceq $value -and $result.Enabled) 'Subprocess argument quoting changed values'
    }
    # AST edits replace only imports, script-location constants and process exit.
    # All coordinator control flow and actual helper functions remain unchanged.
    $entry=Join-Path $win 'build-all.ps1';$tokens=$null;$errors=$null
    $ast=[Management.Automation.Language.Parser]::ParseFile($entry,[ref]$tokens,[ref]$errors)
    Require ($errors.Count -eq 0) 'Automatic entrypoint parse failed'
    $text=[IO.File]::ReadAllText($entry)
    $edits=@($ast.FindAll({param($n)
        $n -is [Management.Automation.Language.ExitStatementAst] -or
        ($n -is [Management.Automation.Language.CommandAst] -and ($n.GetCommandName() -eq 'Import-Module' -or $n.InvocationOperator -eq [Management.Automation.Language.TokenKind]::Dot))
    },$true)|ForEach-Object{[pscustomobject]@{Start=$_.Extent.StartOffset;Length=$_.Extent.EndOffset-$_.Extent.StartOffset;Text=''}})
    $edits+=@($ast.FindAll({param($n)$n -is [Management.Automation.Language.VariableExpressionAst] -and $n.VariablePath.UserPath -in 'PSScriptRoot','PSCommandPath'},$true)|Where-Object{
        $node=$_;@($edits|Where-Object{$node.Extent.StartOffset -ge $_.Start -and $node.Extent.EndOffset -le ($_.Start+$_.Length)}).Count -eq 0
    }|ForEach-Object{[pscustomobject]@{Start=$_.Extent.StartOffset;Length=$_.Extent.EndOffset-$_.Extent.StartOffset;Text=("'"+$(if($_.VariablePath.UserPath -eq 'PSScriptRoot'){$win}else{$entry}).Replace("'","''")+"'")}})
    foreach($edit in @($edits|Sort-Object Start -Descending)){$text=$text.Remove($edit.Start,$edit.Length).Insert($edit.Start,$edit.Text)}
    $coordinator=[scriptblock]::Create($text)
    function Test-PfIsAdmin {$true}
    function Start-Transcript {}
    function Stop-Transcript {}
    $global:AutoMessages=[Collections.Generic.List[string]]::new()
    function Write-Host {param($Object,$ForegroundColor) $global:AutoMessages.Add([string]$Object)}
    function Read-Host {param($Prompt) if(-not $global:Answers.Count){throw 'Unexpected interactive prompt'};$global:Answers.Dequeue()}
    function Get-PfPreparationDisks {
        param($MinimumBytes)
        $global:Enumerations++
        if(-not $global:NoUsb){[pscustomobject]@{Number=$global:AutoDisk.Number;Path=$global:AutoDisk.Path;SerialNumber=$global:AutoDisk.SerialNumber;Size=$global:AutoDisk.Size;Model='Test USB'}}
    }
    function Invoke-PfPreparationScript {
        param($Path,$Parameters)
        $global:Calls.Add([pscustomobject]@{Name=(Split-Path $Path -Leaf);Parameters=$Parameters})
        if((Split-Path $Path -Leaf) -eq 'build-debian.ps1'){
            Require ($Parameters.UsbBytes -eq $global:AutoDisk.Size -and -not $Parameters.WriteUsb) 'Factory did not receive target size or selected USB itself'
            $ws=$Parameters.Workspace;$out=Join-Path $ws 'artifacts';$null=[IO.Directory]::CreateDirectory($out)
            Write-PfPreparationJson (Join-Path $ws 'factory-state.json') @{schema=1;workspace=$ws;build_id='test-build';stages=@{}}
            if($global:BackendFailure -eq 'factory'){throw 'Injected factory failure'}
            $image=Join-Path $out 'linux-flashcard-usb.img';$stream=[IO.File]::Create($image)
            try{$stream.SetLength($global:AutoDisk.Size)}finally{$stream.Dispose()}
            $sha=(Get-FileHash -LiteralPath $image -Algorithm SHA256).Hash
            [IO.File]::WriteAllText(($image+'.sha256'),$sha)
            Write-PfPreparationJson (Join-Path $out 'build-result.json') @{complete=$true;build_id='test-build';image=$image;bytes=$global:AutoDisk.Size;sha256=$sha}
            if($global:BackendFailure -eq 'swap'){$global:AutoDisk.SerialNumber='replacement'}
            if($global:BackendFailure -eq 'renumber'){$global:AutoDisk.Number=8}
        }elseif((Split-Path $Path -Leaf) -eq 'write-image.ps1'){
            Require ($Parameters.Yes -and $Parameters.VerifyFull -and $Parameters.DeferPartitionTable -and $Parameters.VerifyBeforePublish) 'Writer verification switches were lost'
            Require ($Parameters.ExpectedDevicePath -eq $global:AutoDisk.Path -and $Parameters.ExpectedSize -eq $global:AutoDisk.Size -and $Parameters.DiskNumber -eq $global:AutoDisk.Number) 'Writer target identity changed'
            if($global:BackendFailure -eq 'writer'){throw 'Injected write failure'}
            $hash=(Get-FileHash -LiteralPath $Parameters.ImagePath -Algorithm SHA256).Hash
            Write-PfPreparationJson $Parameters.ResultPath @{
                Complete=$true;ImagePath=$Parameters.ImagePath;ImageBytes=$global:AutoDisk.Size;BytesWritten=$global:AutoDisk.Size
                BytesVerified=$(if($global:BackendFailure -eq 'receipt'){4MB}else{$global:AutoDisk.Size})
                Target=$global:AutoDisk;ExpectedSourceSha256=$hash;BeforePublicationBodyVerified=$true;VerificationMethod='DeferredBodyAndBootRegions'
            }
        }else{throw 'Unexpected subprocess'}
    }
    function Reset-Scenario {
        $global:AutoDisk.Number=7;$global:AutoDisk.SerialNumber='serial'
        $global:Calls=[Collections.Generic.List[object]]::new();$global:BackendFailure='';$global:NoUsb=$false;$global:RejectSource=$false;$global:Enumerations=0
        $global:Answers=[Collections.Generic.Queue[string]]::new()
        $global:AutoMessages.Clear()
    }
    function Run-Coordinator {
        param([string]$Directory,[hashtable]$Extra=@{},[switch]$Interactive)
        $arguments=@{Workspace=$Directory;NoPause=$true}
        if(-not $Interactive){$arguments+=@{DiskNumber=$global:AutoDisk.Number;ExpectedDevicePath=$global:AutoDisk.Path;ExpectedSerialNumber=$global:AutoDisk.SerialNumber;ExpectedSize=$global:AutoDisk.Size;Yes=$true}}
        foreach($key in $Extra.Keys){$arguments[$key]=$Extra[$key]}
        & {. $coordinator @arguments;return $exitCode}
    }
    Case 'Read-only plan creates no workspace and enumerates no USB' {
        Reset-Scenario;$path=Join-Path $root 'plan'
        Require ((Run-Coordinator $path @{Plan=$true} -Interactive) -eq 0) 'Plan failed'
        Require (-not (Test-Path -LiteralPath $path) -and $global:Enumerations -eq 0 -and $global:Calls.Count -eq 0) 'Plan caused side effects'
    }
    Case 'Noninteractive mode requires complete explicit target identity' {
        Reset-Scenario;$path=Join-Path $root 'identity'
        Require ((Run-Coordinator $path @{Yes=$true} -Interactive) -eq 1) 'Missing identity was accepted'
        Require ($global:Enumerations -eq 0 -and -not (Test-Path -LiteralPath $path)) 'Missing identity reached preparation'
    }
    Case 'Menu and erase-confirmation cancellation create no artifacts' {
        foreach($answers in @(@('Q'),@('0','no'))){
            Reset-Scenario;$path=Join-Path $root ('cancel-'+[guid]::NewGuid().ToString('N'))
            foreach($answer in $answers){$global:Answers.Enqueue($answer)}
            Require ((Run-Coordinator $path -Interactive) -eq 0) 'Cancellation failed'
            Require (-not (Test-Path -LiteralPath $path) -and $global:Calls.Count -eq 0) 'Cancelled run prepared artifacts'
        }
    }
    Case 'Missing USB and source-on-target fail before factory' {
        foreach($mode in @('NoUsb','RejectSource')){
            Reset-Scenario;Set-Variable -Scope Global -Name $mode -Value $true
            Require ((Run-Coordinator (Join-Path $root $mode)) -eq 1 -and $global:Calls.Count -eq 0) 'Unsafe source/target reached factory'
        }
    }
    Case 'One confirmed run builds, writes and persists only a matching full receipt' {
        Reset-Scenario;$path=Join-Path $root 'success'
        Require ((Run-Coordinator $path) -eq 0) ('Automatic preparation failed: '+($global:AutoMessages -join '; '))
        $session=Get-Content -LiteralPath (Join-Path $path 'bootstrap\usb-preparation.json') -Raw|ConvertFrom-Json
        Require ($session.Stage -eq 'ready' -and $global:Calls.Count -eq 2) 'Preparation was not completed'
        Require ((Run-Coordinator $path) -eq 0 -and $global:Calls.Count -eq 2) 'Ready USB was silently rewritten'
        Require ((Run-Coordinator $path @{Rewrite=$true}) -eq 0 -and $global:Calls.Count -eq 4) 'Explicit rewrite failed'
        $global:AutoDisk.SerialNumber='other-device'
        Require ((Run-Coordinator $path) -eq 1 -and $global:Calls.Count -eq 4) 'Saved workspace was silently rebound to another USB'
    }
    Case 'Failed factory resumes the existing workspace and never writes early' {
        Reset-Scenario;$path=Join-Path $root 'resume';$global:BackendFailure='factory'
        Require ((Run-Coordinator $path) -eq 1 -and $global:Calls.Count -eq 1) 'Failed factory reached writer'
        $global:BackendFailure=''
        Require ((Run-Coordinator $path) -eq 0 -and $global:Calls[1].Parameters.Resume) 'Factory did not resume'
    }
    Case 'USB replacement after build cannot reach writer' {
        Reset-Scenario;$global:BackendFailure='swap';$path=Join-Path $root 'swap'
        Require ((Run-Coordinator $path) -eq 1 -and $global:Calls.Count -eq 1) 'Replacement USB reached writer'
    }
    Case 'Disk renumbering resolves the same physical identity before write' {
        Reset-Scenario;$global:BackendFailure='renumber'
        Require ((Run-Coordinator (Join-Path $root 'renumber')) -eq 0 -and $global:Calls[1].Parameters.DiskNumber -eq 8) 'Stale disk number was used'
    }
    Case 'Incomplete writer or sampled receipt never marks USB ready' {
        foreach($failure in @('writer','receipt')){
            Reset-Scenario;$global:BackendFailure=$failure;$path=Join-Path $root $failure
            Require ((Run-Coordinator $path) -eq 1) 'Failed/partial write was accepted'
            $session=Get-Content -LiteralPath (Join-Path $path 'bootstrap\usb-preparation.json') -Raw|ConvertFrom-Json
            Require ($session.Stage -eq 'failed') 'Failed writer was marked ready'
        }
    }
    Write-Output ("Results: $passed automatic USB checks passed; no physical disk opened.")
}finally{Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue}
