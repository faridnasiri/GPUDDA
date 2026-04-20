# vioscsi-registry-fix.ps1
# ============================================================
# Run via WinRM on target Windows VM (booted from sata0).
# Sets all required registry values so vioscsi.sys loads as
# a BOOT_START driver when the disk is later moved to scsi0.
#
# Usage (from management machine):
#   $so   = New-PSSessionOption -SkipCACheck -SkipCNCheck -SkipRevocationCheck
#   $cred = New-Object PSCredential(".\farid", (ConvertTo-SecureString "..." -AsPlainText -Force))
#   $s    = New-PSSession -ComputerName <IP> -Credential $cred -SessionOption $so -Authentication Negotiate
#   Invoke-Command -Session $s -FilePath .\vioscsi-registry-fix.ps1
# ============================================================

$paths = @(
    "HKLM:\SYSTEM\CurrentControlSet\Services\vioscsi",
    "HKLM:\SYSTEM\ControlSet001\Services\vioscsi",
    "HKLM:\SYSTEM\ControlSet002\Services\vioscsi"
)

$SCSI_CLASS_GUID = "{4D36E97B-E325-11CE-BFC1-08002BE10318}"

# ---- 1. Service registry keys ----
foreach ($p in $paths) {
    New-Item -Path $p -Force | Out-Null
    Set-ItemProperty -Path $p -Name "Start"        -Value 0 -Type DWord          # BOOT_START
    Set-ItemProperty -Path $p -Name "Type"         -Value 1 -Type DWord          # SERVICE_KERNEL_DRIVER
    Set-ItemProperty -Path $p -Name "ErrorControl" -Value 1 -Type DWord          # SERVICE_ERROR_NORMAL
    Set-ItemProperty -Path $p -Name "Group"        -Value "SCSI miniport" -Type String
    Set-ItemProperty -Path $p -Name "Tag"          -Value 21 -Type DWord
    Set-ItemProperty -Path $p -Name "ImagePath"    -Value "\SystemRoot\System32\drivers\vioscsi.sys" -Type ExpandString

    # PnpInterface subkey - tells kernel this driver handles bus type 5 (PCI)
    $pnp = "$p\Parameters\PnpInterface"
    New-Item -Path $pnp -Force | Out-Null
    Set-ItemProperty -Path $pnp -Name "5" -Value 1 -Type DWord

    $vals = Get-ItemProperty -Path $p
    Write-Host "OK: $p  Start=$($vals.Start) Type=$($vals.Type) Group='$($vals.Group)' Tag=$($vals.Tag)"
}

# ---- 2. CriticalDeviceDatabase (all VirtIO SCSI PCI IDs) ----
# Windows uses this table during early boot to find a driver for a device
# it has never booted from before.
$cdb = "HKLM:\SYSTEM\CurrentControlSet\Control\CriticalDeviceDatabase"
$deviceIds = @(
    "pci#ven_1af4&dev_1048&subsys_11001af4&rev_01",   # modern virtio-scsi
    "pci#ven_1af4&dev_1048&subsys_00001af4&rev_00",
    "pci#ven_1af4&dev_1048",
    "pci#ven_1af4&dev_1004&subsys_00081af4&rev_00",   # pass-through controller
    "pci#ven_1af4&dev_1004&subsys_11001af4&rev_00",
    "pci#ven_1af4&dev_1004",
    "pci#ven_1af4&dev_1001",                           # legacy block device
    "pci#ven_1af4&dev_1041"                            # virtio 1.0 block
)
foreach ($id in $deviceIds) {
    $key = "$cdb\$id"
    New-Item -Path $key -Force | Out-Null
    Set-ItemProperty -Path $key -Name "ClassGUID" -Value $SCSI_CLASS_GUID -Type String
    Set-ItemProperty -Path $key -Name "Service"   -Value "vioscsi"        -Type String
    Write-Host "CDB: $id"
}

# ---- 3. Register INF via pnputil (publishes to DriverStore properly) ----
$infPath = (Get-ChildItem "C:\Windows\System32\DriverStore\FileRepository" `
            -Recurse -Filter "vioscsi.inf" -EA SilentlyContinue).FullName
if ($infPath) {
    Write-Host "Running pnputil on: $infPath"
    pnputil.exe /add-driver $infPath /install
} else {
    Write-Warning "vioscsi.inf not found in DriverStore - copy virtio-win ISO drivers first"
}

# ---- 4. Verify ----
Write-Host "`n=== Verification ==="
Write-Host "Driver file: $(Test-Path 'C:\Windows\System32\drivers\vioscsi.sys')"
sc.exe qc vioscsi 2>&1 | Select-String "START_TYPE|BINARY_PATH"

Write-Host "`nAll done. Shut down the VM and switch disk to scsi0."
