# Process-local portable storage; does not change Windows user/machine settings.
function Get-PfStorageRoot {
    param([string]$SourceRoot)
    if($env:PF_STORAGE_ROOT){return [IO.Path]::GetFullPath($env:PF_STORAGE_ROOT).TrimEnd('\')}
    return Join-Path (Split-Path ([IO.Path]::GetFullPath($SourceRoot).TrimEnd('\')) -Parent) 'LinuxFlashcard-work'
}

function Set-PfStorageEnvironment {
    param([string]$Root,[switch]$Create)
    $Root=[IO.Path]::GetFullPath($Root).TrimEnd('\')
    if($Root -notmatch '^[A-Za-z]:\\.+'){throw 'Storage requires a dedicated local directory.'}
    $paths=@{TEMP=(Join-Path $Root 'temp');TMP=(Join-Path $Root 'temp');LOCALAPPDATA=(Join-Path $Root 'profile\local');APPDATA=(Join-Path $Root 'profile\roaming');USERPROFILE=(Join-Path $Root 'profile');HOME=(Join-Path $Root 'home');XDG_CONFIG_HOME=(Join-Path $Root 'config');XDG_CACHE_HOME=(Join-Path $Root 'cache')}
    foreach($name in $paths.Keys){
        if($Create){$null=[IO.Directory]::CreateDirectory($paths[$name])}
        [Environment]::SetEnvironmentVariable($name,$paths[$name],'Process')
    }
    $env:PSModuleAnalysisCachePath=Join-Path $paths.LOCALAPPDATA 'ModuleAnalysisCache'
    $env:PYTHONDONTWRITEBYTECODE='1'
}
