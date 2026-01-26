# Check for Administrator privileges
if (!([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole] "Administrator")) {
    Write-Warning "Please run this script as Administrator!"
    return
}

# CONFIGURATION
$RamDiskRoot = "R:\Cache"
$UserName = $env:USERNAME

# Verify RamDisk exists
if (!(Test-Path "R:\")) {
    Write-Error "Drive R: not found. Please mount your RAMDisk first."
    return
}

# Create RamDisk root folder
if (!(Test-Path $RamDiskRoot)) {
    New-Item -Path $RamDiskRoot -ItemType Directory -Force | Out-Null
    Write-Host "Created $RamDiskRoot" -ForegroundColor Green
}

# --- Function to Create Junctions ---
function Redirect-Cache {
    param (
        [string]$AppName,
        [string[]]$ProcessNames,
        [string]$SourcePath,
        [string]$DestPath
    )

    Write-Host "`n========================================" -ForegroundColor Cyan
    Write-Host "Processing $AppName..." -ForegroundColor Cyan
    Write-Host "  Source: $SourcePath"
    Write-Host "  Destination: $DestPath"
    Write-Host "========================================" -ForegroundColor Cyan

    # 1. Stop ALL related processes
    foreach ($ProcessName in $ProcessNames) {
        $procs = Get-Process -Name $ProcessName -ErrorAction SilentlyContinue
        if ($procs) {
            Write-Host "  Stopping $ProcessName ($($procs.Count) processes)..." -ForegroundColor Yellow
            $procs | Stop-Process -Force -ErrorAction SilentlyContinue
        }
    }
    Start-Sleep -Seconds 3

    # 2. Double-check processes are stopped
    foreach ($ProcessName in $ProcessNames) {
        $stillRunning = Get-Process -Name $ProcessName -ErrorAction SilentlyContinue
        if ($stillRunning) {
            Write-Warning "  $ProcessName is still running! Trying taskkill..."
            taskkill /F /IM "$ProcessName.exe" /T 2>$null
            Start-Sleep -Seconds 2
        }
    }

    # 3. Check if Source exists
    if (Test-Path $SourcePath) {
        $item = Get-Item $SourcePath -Force -ErrorAction SilentlyContinue
        
        # Check if it is already a reparse point (Junction/Symlink)
        if ($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) {
            Write-Host "  $AppName is already redirected (junction exists)." -ForegroundColor Green
            return
        }

        # 4. Remove existing cache
        Write-Host "  Removing old cache from source location..." -ForegroundColor Yellow
        
        $retryCount = 0
        $maxRetries = 3
        $deleted = $false
        
        while (-not $deleted -and $retryCount -lt $maxRetries) {
            try {
                Remove-Item -Path $SourcePath -Recurse -Force -ErrorAction Stop
                $deleted = $true
                Write-Host "  Old cache removed successfully." -ForegroundColor Green
            }
            catch {
                $retryCount++
                Write-Warning "  Removal attempt $retryCount failed: $($_.Exception.Message)"
                if ($retryCount -lt $maxRetries) {
                    Write-Host "  Retrying in 3 seconds..."
                    Start-Sleep -Seconds 3
                }
            }
        }
        
        if (-not $deleted) {
            Write-Error "  Failed to remove $SourcePath after $maxRetries attempts. Skipping $AppName."
            return
        }
    } else {
        Write-Host "  Source path does not exist (clean install or already removed)." -ForegroundColor Gray
    }

    # 5. Ensure PARENT directory exists
    $parentPath = Split-Path -Path $SourcePath -Parent
    if (!(Test-Path $parentPath)) {
        Write-Host "  Creating parent directory: $parentPath"
        New-Item -Path $parentPath -ItemType Directory -Force | Out-Null
    }

    # 6. Create Destination Directory on R:
    if (!(Test-Path $DestPath)) {
        New-Item -Path $DestPath -ItemType Directory -Force | Out-Null
        Write-Host "  Created destination folder: $DestPath" -ForegroundColor Green
    }

    # 7. Create the Junction using PowerShell
    Write-Host "  Creating junction link..." -ForegroundColor Cyan
    
    try {
        New-Item -ItemType Junction -Path $SourcePath -Target $DestPath -Force -ErrorAction Stop | Out-Null
        Write-Host "  SUCCESS! $AppName cache redirected to $DestPath" -ForegroundColor Green
    }
    catch {
        Write-Error "  Failed to create junction: $($_.Exception.Message)"
        return
    }

    # 8. Verify junction was created
    if (Test-Path $SourcePath) {
        $verify = Get-Item $SourcePath -Force
        if ($verify.Attributes -band [System.IO.FileAttributes]::ReparsePoint) {
            Write-Host "  Verified: Junction is working!" -ForegroundColor Green
        }
    }
}

# ============================================================
# GOOGLE CHROME
# ============================================================
Write-Host "`n========================================" -ForegroundColor Magenta
Write-Host "GOOGLE CHROME - Redirecting all caches" -ForegroundColor Magenta
Write-Host "========================================" -ForegroundColor Magenta

$ChromeProfile = "Profile 5"  # Change to your active profile
$ChromeUserData = "C:\Users\$UserName\AppData\Local\Google\Chrome\User Data\$ChromeProfile"

# All cache directories to redirect
$ChromeCacheFolders = @(
    "Cache",
    "Code Cache", 
    "GPUCache",
    "Service Worker",
    "DawnCache"
)

foreach ($folder in $ChromeCacheFolders) {
    $sourcePath = Join-Path $ChromeUserData $folder
    $destPath = Join-Path "$RamDiskRoot\Chrome" $folder
    
    Redirect-Cache -AppName "Chrome: $folder" `
                   -ProcessNames @("chrome", "GoogleCrashHandler", "GoogleCrashHandler64") `
                   -SourcePath $sourcePath `
                   -DestPath $destPath
}

# GrShaderCache (shared across profiles)
$GrShaderSource = "C:\Users\$UserName\AppData\Local\Google\Chrome\User Data\GrShaderCache"
$GrShaderDest = "$RamDiskRoot\Chrome\GrShaderCache"
Redirect-Cache -AppName "Chrome: GrShaderCache" `
               -ProcessNames @("chrome") `
               -SourcePath $GrShaderSource `
               -DestPath $GrShaderDest

# ============================================================
# MICROSOFT EDGE
# ============================================================
Write-Host "`n========================================" -ForegroundColor Magenta
Write-Host "MICROSOFT EDGE - Redirecting all caches" -ForegroundColor Magenta
Write-Host "========================================" -ForegroundColor Magenta

# Detect active Edge profile
$EdgeBasePath = "C:\Users\$UserName\AppData\Local\Microsoft\Edge\User Data"
$EdgeProfileCandidates = @("Default", "Profile 1", "Profile 2", "Profile 3", "Profile 4", "Profile 5")

$EdgeActiveProfile = $null
foreach ($profile in $EdgeProfileCandidates) {
    $prefFile = Join-Path $EdgeBasePath "$profile\Preferences"
    if (Test-Path $prefFile) {
        if (-not $EdgeActiveProfile) {
            $EdgeActiveProfile = $profile
        }
        # Check most recently used
        $lastWrite = (Get-Item $prefFile).LastWriteTime
        $currentLastWrite = (Get-Item (Join-Path $EdgeBasePath "$EdgeActiveProfile\Preferences")).LastWriteTime
        if ($lastWrite -gt $currentLastWrite) {
            $EdgeActiveProfile = $profile
        }
    }
}

if ($EdgeActiveProfile) {
    Write-Host "Detected Edge Profile: $EdgeActiveProfile" -ForegroundColor Cyan
    
    $EdgeUserData = Join-Path $EdgeBasePath $EdgeActiveProfile
    
    $EdgeCacheFolders = @(
        "Cache",
        "Code Cache",
        "GPUCache",
        "Service Worker",
        "DawnCache"
    )
    
    foreach ($folder in $EdgeCacheFolders) {
        $sourcePath = Join-Path $EdgeUserData $folder
        $destPath = Join-Path "$RamDiskRoot\Edge" $folder
        
        Redirect-Cache -AppName "Edge: $folder" `
                       -ProcessNames @("msedge", "MicrosoftEdgeUpdate", "msedgewebview2") `
                       -SourcePath $sourcePath `
                       -DestPath $destPath
    }
    
    # Edge GrShaderCache (shared)
    $EdgeGrShaderSource = "C:\Users\$UserName\AppData\Local\Microsoft\Edge\User Data\GrShaderCache"
    $EdgeGrShaderDest = "$RamDiskRoot\Edge\GrShaderCache"
    Redirect-Cache -AppName "Edge: GrShaderCache" `
                   -ProcessNames @("msedge") `
                   -SourcePath $EdgeGrShaderSource `
                   -DestPath $EdgeGrShaderDest
} else {
    Write-Warning "Microsoft Edge not found or never run."
}

# ============================================================
# MOZILLA FIREFOX
# ============================================================
Write-Host "`n========================================" -ForegroundColor Magenta
Write-Host "MOZILLA FIREFOX - Redirecting cache" -ForegroundColor Magenta
Write-Host "========================================" -ForegroundColor Magenta

$FirefoxBasePath = "C:\Users\$UserName\AppData\Local\Mozilla\Firefox\Profiles"

if (Test-Path $FirefoxBasePath) {
    # Find the most recently used profile
    $FirefoxProfiles = Get-ChildItem -Path $FirefoxBasePath -Directory | 
        Where-Object { $_.Name -match "\.default" -or $_.Name -match "\.release" } |
        Sort-Object LastWriteTime -Descending
    
    if ($FirefoxProfiles) {
        $FirefoxProfile = $FirefoxProfiles[0]
        Write-Host "Detected Firefox Profile: $($FirefoxProfile.Name)" -ForegroundColor Cyan
        
        # Firefox cache locations
        $FirefoxCacheFolders = @(
            "cache2",           # HTTP cache
            "startupCache",     # Startup cache
            "jumpListCache"     # Windows jump list cache
        )
        
        foreach ($folder in $FirefoxCacheFolders) {
            $sourcePath = Join-Path $FirefoxProfile.FullName $folder
            $destPath = Join-Path "$RamDiskRoot\Firefox" $folder
            
            Redirect-Cache -AppName "Firefox: $folder" `
                           -ProcessNames @("firefox") `
                           -SourcePath $sourcePath `
                           -DestPath $destPath
        }
        
        # Optional: OfflineCache (if exists)
        $offlineCachePath = Join-Path $FirefoxProfile.FullName "OfflineCache"
        if (Test-Path $offlineCachePath) {
            Redirect-Cache -AppName "Firefox: OfflineCache" `
                           -ProcessNames @("firefox") `
                           -SourcePath $offlineCachePath `
                           -DestPath "$RamDiskRoot\Firefox\OfflineCache"
        }
        
    } else {
        Write-Warning "Firefox profile not found."
    }
} else {
    Write-Warning "Firefox not installed or never run."
}

# ============================================================
# VERIFICATION
# ============================================================
Write-Host "`n========================================" -ForegroundColor Green
Write-Host "VERIFICATION SUMMARY" -ForegroundColor Green
Write-Host "========================================" -ForegroundColor Green

# Chrome verification
Write-Host "`n--- CHROME ---" -ForegroundColor Cyan
$ChromeCacheFolders | ForEach-Object {
    $path = Join-Path $ChromeUserData $_
    if (Test-Path $path) {
        $item = Get-Item $path -Force
        if ($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) {
            Write-Host "  [✓] $_" -ForegroundColor Green
        } else {
            Write-Host "  [✗] $_ (not a junction)" -ForegroundColor Red
        }
    } else {
        Write-Host "  [?] $_ (not found)" -ForegroundColor Yellow
    }
}

# Edge verification
if ($EdgeActiveProfile) {
    Write-Host "`n--- EDGE ---" -ForegroundColor Cyan
    $EdgeCacheFolders | ForEach-Object {
        $path = Join-Path $EdgeUserData $_
        if (Test-Path $path) {
            $item = Get-Item $path -Force
            if ($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) {
                Write-Host "  [✓] $_" -ForegroundColor Green
            } else {
                Write-Host "  [✗] $_ (not a junction)" -ForegroundColor Red
            }
        } else {
            Write-Host "  [?] $_ (not found)" -ForegroundColor Yellow
        }
    }
}

# Firefox verification
if ($FirefoxProfiles) {
    Write-Host "`n--- FIREFOX ---" -ForegroundColor Cyan
    $FirefoxCacheFolders | ForEach-Object {
        $path = Join-Path $FirefoxProfile.FullName $_
        if (Test-Path $path) {
            $item = Get-Item $path -Force
            if ($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) {
                Write-Host "  [✓] $_" -ForegroundColor Green
            } else {
                Write-Host "  [✗] $_ (not a junction)" -ForegroundColor Red
            }
        } else {
            Write-Host "  [?] $_ (not found)" -ForegroundColor Yellow
        }
    }
}

# Display RAMDisk usage
Write-Host "`n========================================" -ForegroundColor Cyan
Write-Host "RAMDISK CONTENTS (R:\Cache)" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan

@("Chrome", "Edge", "Firefox") | ForEach-Object {
    $browserPath = Join-Path $RamDiskRoot $_
    if (Test-Path $browserPath) {
        $fileCount = (Get-ChildItem $browserPath -Recurse -File -ErrorAction SilentlyContinue | Measure-Object).Count
        $size = (Get-ChildItem $browserPath -Recurse -File -ErrorAction SilentlyContinue | Measure-Object -Property Length -Sum).Sum
        $sizeMB = [math]::Round($size / 1MB, 2)
        Write-Host "  $_ : $fileCount files, $sizeMB MB" -ForegroundColor White
    } else {
        Write-Host "  $_ : Not created" -ForegroundColor Gray
    }
}

Write-Host "`n========================================" -ForegroundColor Yellow
Write-Host "IMPORTANT NOTES" -ForegroundColor Yellow
Write-Host "========================================" -ForegroundColor Yellow
Write-Host "1. Configure RAMDisk to recreate R:\Cache folder on every boot"
Write-Host "2. RAM contents are lost on shutdown/restart"
Write-Host "3. Run this script again after Windows updates if caches break"
Write-Host "4. Test each browser to verify cache is being written to RAMDisk"
Write-Host "`nTo verify, browse with each browser for 30 seconds, then run:"
Write-Host "  Get-ChildItem 'R:\Cache' -Recurse -File | Measure-Object -Property Length -Sum"
