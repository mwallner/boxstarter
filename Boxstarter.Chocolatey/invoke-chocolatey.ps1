# dupe - see Install-BoxstarterPackage
function Expand-ZipFile {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ZipFilePath,
        [Parameter(Mandatory = $true)]
        [string]$DestinationFolder
    )
        
    # Ensure destination exists
    if (!(Test-Path $DestinationFolder)) {
        New-Item -ItemType Directory -Path $DestinationFolder -Force | Out-Null
    }
        
    # PowerShell 5+ on Windows: Use System.IO.Compression.ZipFile
    if ($PSVersionTable.PSVersion.Major -ge 5 -and $IsWindows) {
        try {
            Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction Stop
            [System.IO.Compression.ZipFile]::ExtractToDirectory($ZipFilePath, $DestinationFolder)
            return
        }
        catch {}
    }
        
    # PowerShell Core (6+) on any OS: Use System.IO.Compression.ZipFile from .NET Core
    if ($PSVersionTable.PSVersion.Major -ge 6) {
        try {
            Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction Stop
        }
        catch {
            # On Linux/macOS, FileSystem may not be available, but ZipFile usually is
            try {
                Add-Type -AssemblyName System.IO.Compression -ErrorAction Stop
            }
            catch {}
        }
        try {
            [System.IO.Compression.ZipFile]::ExtractToDirectory($ZipFilePath, $DestinationFolder)
            return
        }
        catch {}
    }
        
    # PowerShell 2-4 on Windows: Use Shell.Application COM object
    if ($IsWindows) {
        try {
            $shell = New-Object -ComObject Shell.Application
            $zip = $shell.NameSpace($ZipFilePath)
            $dest = $shell.NameSpace($DestinationFolder)
            if ($zip -and $dest) {
                $dest.CopyHere($zip.Items(), 0x10)
                return
            }
        }
        catch {}
    }
        
    # Fallback: Use .NET DeflateStream/ZipArchive (works on all platforms, but slower)
    try {
        Add-Type -TypeDefinition @'
        using System;
        using System.IO;
        using System.IO.Compression;
        public class ZipExtract {
            public static void Extract(string zipPath, string extractPath) {
                using (var archive = ZipFile.OpenRead(zipPath)) {
                    foreach (var entry in archive.Entries) {
                        string filePath = Path.Combine(extractPath, entry.FullName);
                        string dir = Path.GetDirectoryName(filePath);
                        if (!Directory.Exists(dir)) Directory.CreateDirectory(dir);
                        if (!String.IsNullOrEmpty(entry.Name)) entry.ExtractToFile(filePath, true);
                    }
                }
            }
        }
'@ -ReferencedAssemblies 'System.IO.Compression.FileSystem.dll', 'System.IO.Compression.dll' -ErrorAction Stop
        [ZipExtract]::Extract($ZipFilePath, $DestinationFolder)
        return
    }
    catch {
        throw 'Could not extract zip file. No supported extraction method found for this platform/PowerShell version.'
    }
}


function Invoke-Chocolatey($chocoArgs) {
    Write-BoxstarterMessage "Current runtime is $($PSVersionTable.CLRVersion)" -Verbose
    # be sure not to include empty arguments when calling Start-Process
    $chocoArgs = $chocoArgs.Where({ $_ -ne "" })

    if (-Not $env:ChocolateyInstall) {
        [System.Environment]::SetEnvironmentVariable('ChocolateyInstall', "$env:programdata\chocolatey", 'Machine')
        $env:ChocolateyInstall = "$env:programdata\chocolatey"
    }

    if (-Not (Test-Path $env:ChocolateyInstall)) {
        Write-BoxstarterMessage "SNAP! Chocolatey seems to be missing! - installing NOW!"
        $boxstarterZip = Get-Item "$($boxstarter.BaseDir)\Boxstarter.Chocolatey\Boxstarter.zip"
        $tmpBoxstarterUnzipPath = "$($env:temp)\boxstarter_temp"
        Expand-ZipFile -ZipFilePath $boxstarterZip.FullName -DestinationFolder $tmpBoxstarterUnzipPath
        $chocoNupkg = Get-Item "$tmpBoxstarterUnzipPath\Boxstarter.Chocolatey\chocolatey\*.nupkg" | Select-Object -First 1
        Expand-ZipFile -ZipFilePath $chocoNupkg.FullName -DestinationFolder $env:temp\boxstarter_chocolatey
        Import-Module $env:temp\boxstarter_chocolatey\tools\chocolateysetup.psm1 -DisableNameChecking
        Initialize-Chocolatey
    }

    if (-Not (Test-Path "$env:ChocolateyInstall\lib")) {
        mkdir "$env:ChocolateyInstall\lib" | Out-Null
    }
    
    Install-BoxstarterExtension

    Enter-BoxstarterLogable {

        $cd = [System.IO.Directory]::GetCurrentDirectory()
        try {
            $targetWdir = $((Get-Location).Path)
            Write-BoxstarterMessage "setting current directory location to $targetWdir" -Verbose
            [System.IO.Directory]::SetCurrentDirectory("$(Convert-Path $targetWdir)")
            
            Write-BoxstarterMessage "BoxstarterWrapper::Run($chocoArgs)..." -Verbose
            <#
            $chocoArgs | ForEach-Object {
              Write-BoxstarterMessage " -> $_" -Verbose
            }
            #>

            $pargs = @{
                FilePath          = Join-Path $env:ChocolateyInstall 'choco.exe'
                ArgumentList      = $chocoArgs
                NoNewWindow       = $true
                PassThru          = $true
                UseNewEnvironment = $false
                Wait              = $false
                WorkingDirectory  = $targetWdir
                Verbose           = ($global:VerbosePreference -eq "Continue")
            }
            
            $p = Start-Process @pargs

            $dummy = $p.Handle # Cache the handle => https://github.com/PowerShell/PowerShell/issues/20400
            Wait-Process -Id $p.Id
            Write-Verbose "choco process handle: $dummy"
            
            Write-BoxstarterMessage "BoxstarterWrapper::Run => $($p.ExitCode)" -Verbose
            [System.Environment]::ExitCode = $p.ExitCode

        }
        finally {
            Write-BoxstarterMessage "restoring current directory location to $cd" -Verbose
            [System.IO.Directory]::SetCurrentDirectory($cd)
        }
            
    }

}
