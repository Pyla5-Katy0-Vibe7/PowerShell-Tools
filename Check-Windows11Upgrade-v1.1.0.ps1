#requires -version 5.1

<#
.SYNOPSIS
    KissLabs - Windows 11 Upgrade Readiness Check

.DESCRIPTION
    Vérifie si la machine est prête pour une mise à niveau vers Windows 11 25H2.

    Contrôles principaux :
      - Version Windows actuelle
      - Prérequis Microsoft Windows 11 via HardwareReadiness.ps1
      - CPU / RAM / TPM 2.0 / Secure Boot / stockage
      - DirectX 12 / WDDM 2.0
      - Espace disque libre
      - Redémarrage en attente
      - Service Windows Update
      - GPO TargetReleaseVersion / ProductVersion
      - WSUS
      - Safeguard Hold Microsoft
      - Nettoyage automatique du dossier temporaire

.EXITCODES
    0 = READY / ALREADY_CURRENT
    1 = NOT_CAPABLE
    2 = UNDETERMINED / erreur de contrôle
    3 = CAPABLE_BUT_BLOCKED (GPO / Safeguard Hold)
    4 = ALREADY_CURRENT_NOT_COMPLIANT

.NOTES
    Cible de déploiement : Windows 11 25H2
    Compatible Windows PowerShell 5.1
#>

[CmdletBinding()]
param(
    [int]$RecommendedFreeSpaceGB = 30,
    [switch]$KeepTemp
)

$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"

$ScriptVersion = "1.1.0"
$TargetVersion = "25H2"
$ExitCode = 2
$FinalResult = "UNDETERMINED"

function Write-Title {
    param([string]$Text)

    Write-Host ""
    Write-Host ("=" * 78) -ForegroundColor Cyan
    Write-Host (" " + $Text) -ForegroundColor Cyan
    Write-Host ("=" * 78) -ForegroundColor Cyan
}

function Write-Check {
    param(
        [string]$Name,
        [ValidateSet("OK", "WARN", "FAIL", "INFO")]
        [string]$State,
        [string]$Detail
    )

    $Color = switch ($State) {
        "OK"   { "Green" }
        "WARN" { "Yellow" }
        "FAIL" { "Red" }
        "INFO" { "Cyan" }
        default { "White" }
    }

    Write-Host ("[{0,-4}] {1,-28} {2}" -f $State, $Name, $Detail) -ForegroundColor $Color
}

function Get-PropertyValue {
    param(
        [object]$Object,
        [string]$Name,
        $Default = $null
    )

    if ($null -eq $Object) {
        return $Default
    }

    $Property = $Object.PSObject.Properties[$Name]

    if ($null -ne $Property) {
        return $Property.Value
    }

    return $Default
}

function Invoke-RobustDownload {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Uri,

        [Parameter(Mandatory = $true)]
        [string]$Destination,

        [int]$MaxAttempts = 3
    )

    for ($Attempt = 1; $Attempt -le $MaxAttempts; $Attempt++) {
        try {
            Write-Check "Téléchargement Microsoft" "INFO" ("Tentative {0}/{1}" -f $Attempt, $MaxAttempts)

            $IwrParams = @{
                Uri                = $Uri
                OutFile            = $Destination
                UseBasicParsing    = $true
                MaximumRedirection = 10
                ErrorAction        = "Stop"
            }

            Invoke-WebRequest @IwrParams

            if ((Test-Path $Destination) -and ((Get-Item $Destination).Length -gt 1000)) {
                return
            }

            throw "Le fichier téléchargé est vide ou invalide."
        }
        catch {
            if ($Attempt -eq $MaxAttempts) {
                throw
            }

            Start-Sleep -Seconds (2 * $Attempt)
        }
    }
}

function Test-PendingReboot {
    $Pending = $false
    $Reasons = New-Object System.Collections.Generic.List[string]

    if (Test-Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending") {
        $Pending = $true
        $Reasons.Add("Component Based Servicing")
    }

    if (Test-Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired") {
        $Pending = $true
        $Reasons.Add("Windows Update")
    }

    try {
        $SessionManager = Get-ItemProperty "HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager" -ErrorAction SilentlyContinue
        $PendingRename = Get-PropertyValue $SessionManager "PendingFileRenameOperations"

        if ($null -ne $PendingRename) {
            $Pending = $true
            $Reasons.Add("PendingFileRenameOperations")
        }
    }
    catch {
    }

    [PSCustomObject]@{
        Pending = $Pending
        Reasons = $Reasons
    }
}

function Get-GraphicsReadiness {
    param(
        [string]$OutputFile
    )

    try {
        $DxDiag = Join-Path $env:SystemRoot "System32\dxdiag.exe"

        if (-not (Test-Path $DxDiag)) {
            throw "dxdiag.exe introuvable."
        }

        $Process = Start-Process -FilePath $DxDiag -ArgumentList ("/whql:off /x `"{0}`"" -f $OutputFile) -WindowStyle Hidden -PassThru

        if (-not $Process.WaitForExit(30000)) {
            Stop-Process -Id $Process.Id -Force -ErrorAction SilentlyContinue
            throw "Timeout lors de l'exécution de DxDiag."
        }

        if (-not (Test-Path $OutputFile)) {
            throw "DxDiag n'a pas généré de fichier XML."
        }

        [xml]$DxDiagXml = Get-Content -Path $OutputFile -Raw -ErrorAction Stop
        $Devices = @($DxDiagXml.DxDiag.DisplayDevices.DisplayDevice)

        if ($Devices.Count -eq 0) {
            throw "Aucun périphérique graphique détecté."
        }

        $Results = @()
        $AtLeastOneCompatible = $false
        $AtLeastOneKnown = $false

        foreach ($Device in $Devices) {
            if ($null -eq $Device) {
                continue
            }

            $CardName = [string]$Device.CardName
            $DDIText = [string]$Device.DDIVersion
            $DriverModelText = [string]$Device.DriverModel

            $DDIVersion = $null
            $WDDMVersion = $null

            if ($DDIText -match '(\d+(?:\.\d+)?)') {
                $DDIVersion = [double]::Parse($Matches[1], [Globalization.CultureInfo]::InvariantCulture)
            }

            if ($DriverModelText -match 'WDDM\s+(\d+(?:\.\d+)?)') {
                $WDDMVersion = [double]::Parse($Matches[1], [Globalization.CultureInfo]::InvariantCulture)
            }

            if (($null -ne $DDIVersion) -and ($null -ne $WDDMVersion)) {
                $AtLeastOneKnown = $true

                if (($DDIVersion -ge 12) -and ($WDDMVersion -ge 2.0)) {
                    $AtLeastOneCompatible = $true
                }
            }

            $Results += [PSCustomObject]@{
                CardName    = $CardName
                DDIVersion  = $DDIVersion
                WDDMVersion = $WDDMVersion
                DriverModel = $DriverModelText
            }
        }

        if (-not $AtLeastOneKnown) {
            return [PSCustomObject]@{
                State   = "WARN"
                Capable = $null
                Detail  = "Version DirectX/WDDM non déterminée."
                Devices = $Results
            }
        }

        if ($AtLeastOneCompatible) {
            return [PSCustomObject]@{
                State   = "OK"
                Capable = $true
                Detail  = "DirectX 12 / WDDM 2.0 ou supérieur détecté."
                Devices = $Results
            }
        }

        [PSCustomObject]@{
            State   = "FAIL"
            Capable = $false
            Detail  = "Aucun GPU DirectX 12 + WDDM 2.0 compatible détecté."
            Devices = $Results
        }
    }
    catch {
        [PSCustomObject]@{
            State   = "WARN"
            Capable = $null
            Detail  = $_.Exception.Message
            Devices = @()
        }
    }
}

function Get-SafeguardStatus {
    param(
        [string]$TargetVersion
    )

    $Known = $false
    $Hold = $false
    $BlockIDs = @()
    $Reasons = @()
    $FailedPrereqs = @()

    $BaseKey = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\AppCompatFlags\TargetVersionUpgradeExperienceIndicators"

    if (Test-Path $BaseKey) {
        $Keys = Get-ChildItem -Path $BaseKey -ErrorAction SilentlyContinue | Where-Object {
            $_.PSChildName -like ("*{0}*" -f $TargetVersion)
        }

        foreach ($Key in $Keys) {
            try {
                $Values = Get-ItemProperty -Path $Key.PSPath -ErrorAction Stop
                $GStatus = Get-PropertyValue $Values "GStatus"

                if ($null -ne $GStatus) {
                    $Known = $true
                    if ([string]$GStatus -eq "0") {
                        $Hold = $true
                    }
                }

                $GatedBlockId = Get-PropertyValue $Values "GatedBlockId"
                if (($null -ne $GatedBlockId) -and ([string]$GatedBlockId -ne "None")) {
                    $BlockIDs += @($GatedBlockId)
                }

                $GatedBlockReason = Get-PropertyValue $Values "GatedBlockReason"
                if (($null -ne $GatedBlockReason) -and ([string]$GatedBlockReason -ne "None")) {
                    $Reasons += @($GatedBlockReason)
                }

                $Failed = Get-PropertyValue $Values "FailedPrereqs"
                if (($null -ne $Failed) -and ([string]$Failed -ne "None")) {
                    $FailedPrereqs += @($Failed)
                }
            }
            catch {
            }
        }
    }

    $GWXKey = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\AppCompatFlags\Appraiser\GWX"

    if (Test-Path $GWXKey) {
        try {
            $GWX = Get-ItemProperty $GWXKey -ErrorAction Stop
            $GWXStatus = Get-PropertyValue $GWX "GStatus"

            if ($null -ne $GWXStatus) {
                $Known = $true
                if ([string]$GWXStatus -eq "0") {
                    $Hold = $true
                }
            }
        }
        catch {
        }
    }

    [PSCustomObject]@{
        Known         = $Known
        Hold          = $Hold
        BlockIDs      = $BlockIDs
        Reasons       = $Reasons
        FailedPrereqs = $FailedPrereqs
    }
}

# ----------------------------------------------------------------------------
# Vérification des droits administrateur
# ----------------------------------------------------------------------------

$Identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$Principal = New-Object Security.Principal.WindowsPrincipal($Identity)
$IsAdministrator = $Principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

if (-not $IsAdministrator) {
    Write-Host ""
    Write-Host "[FAIL] Le script doit être exécuté en administrateur." -ForegroundColor Red
    exit 2
}

# ----------------------------------------------------------------------------
# Dossier temporaire unique
# ----------------------------------------------------------------------------

$TempFolder = Join-Path ([System.IO.Path]::GetTempPath()) ("TempW11UpgradeCheck_" + [guid]::NewGuid().ToString("N"))
$HardwareScript = Join-Path $TempFolder "HardwareReadiness.ps1"
$DxDiagFile = Join-Path $TempFolder "DxDiag.xml"

try {
    Write-Title ("WINDOWS 11 {0} - UPGRADE READINESS CHECK" -f $TargetVersion)

    Write-Check "Machine" "INFO" $env:COMPUTERNAME
    Write-Check "Utilisateur" "INFO" $Identity.Name

    try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    }
    catch {
    }

    New-Item -Path $TempFolder -ItemType Directory -Force | Out-Null

    # ------------------------------------------------------------------------
    # 1. Système d'exploitation
    # ------------------------------------------------------------------------

    Write-Title "1. SYSTEME D'EXPLOITATION"

    $CurrentVersion = Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion"
    $OS = Get-CimInstance Win32_OperatingSystem

    $ProductName = [string](Get-PropertyValue $CurrentVersion "ProductName" "Windows")
    $DisplayVersion = [string](Get-PropertyValue $CurrentVersion "DisplayVersion" (Get-PropertyValue $CurrentVersion "ReleaseId" "Unknown"))
    $EditionID = [string](Get-PropertyValue $CurrentVersion "EditionID" "Unknown")
    $Build = [int](Get-PropertyValue $CurrentVersion "CurrentBuildNumber" 0)
    $UBR = [int](Get-PropertyValue $CurrentVersion "UBR" 0)
    $FullBuild = "{0}.{1}" -f $Build, $UBR
    $IsWindows11 = ($Build -ge 22000)

    # Le registre peut encore exposer "Windows 10" sur certaines installations
    # Windows 11. Le numéro de build reste la référence la plus fiable ici.
    if ($IsWindows11) {
        $FriendlyProductName = "Windows 11"
    }
    else {
        $FriendlyProductName = $ProductName
    }

    Write-Check "Script" "INFO" ("Version {0}" -f $ScriptVersion)
    Write-Check "Windows actuel" "INFO" ("{0} {1} - Build {2} - {3}" -f $FriendlyProductName, $DisplayVersion, $FullBuild, $EditionID)

    # Détection VM / hyperviseur. Le contrôle GPU DirectX est moins pertinent
    # comme blocage absolu dans une VM car le guest voit un adaptateur virtuel.
    $ComputerSystem = Get-CimInstance Win32_ComputerSystem
    $VirtualizationText = ("{0} {1}" -f $ComputerSystem.Manufacturer, $ComputerSystem.Model).Trim()
    $IsVirtualMachine = $false

    if (
        $VirtualizationText -match '(?i)VMware' -or
        $VirtualizationText -match '(?i)Virtual Machine' -or
        $VirtualizationText -match '(?i)VirtualBox' -or
        $VirtualizationText -match '(?i)KVM' -or
        $VirtualizationText -match '(?i)QEMU' -or
        $VirtualizationText -match '(?i)HVM domU' -or
        $VirtualizationText -match '(?i)Parallels'
    ) {
        $IsVirtualMachine = $true
        Write-Check "Environnement" "INFO" ("Machine virtuelle détectée : {0}" -f $VirtualizationText)
    }
    else {
        Write-Check "Environnement" "INFO" ("Machine physique / non identifiée comme VM : {0}" -f $VirtualizationText)
    }

    $OSBlockers = New-Object System.Collections.Generic.List[string]

    if ($OS.ProductType -ne 1) {
        $OSBlockers.Add("Windows Server détecté : ce contrôle concerne Windows Client.")
    }

    if (-not $IsWindows11) {
        if ($Build -lt 19041) {
            $OSBlockers.Add("Windows 10 version 2004 ou supérieure requise.")
        }
        elseif (($Build -ge 19041) -and ($Build -le 19043) -and ($UBR -lt 1237)) {
            $OSBlockers.Add("La mise à jour de sécurité du 14 septembre 2021 ou une version ultérieure est requise.")
        }
    }

    if ($OSBlockers.Count -eq 0) {
        Write-Check "OS source" "OK" "Version source compatible avec un upgrade Windows 11."
    }
    else {
        foreach ($Blocker in $OSBlockers) {
            Write-Check "OS source" "FAIL" $Blocker
        }
    }

    $AlreadyTarget = ($DisplayVersion -eq $TargetVersion)

    if ($AlreadyTarget) {
        Write-Check "Version cible" "OK" ("Windows 11 {0} est déjà installé." -f $TargetVersion)
    }
    else {
        Write-Check "Version cible" "INFO" ("Cible de mise à niveau : Windows 11 {0}" -f $TargetVersion)
    }

    # ------------------------------------------------------------------------
    # Espace disque
    # ------------------------------------------------------------------------

    $SystemDisk = Get-CimInstance Win32_LogicalDisk | Where-Object {
        $_.DeviceID -eq $env:SystemDrive
    } | Select-Object -First 1

    if ($null -ne $SystemDisk) {
        $FreeGB = [Math]::Round($SystemDisk.FreeSpace / 1GB, 1)

        if ($FreeGB -ge $RecommendedFreeSpaceGB) {
            Write-Check "Espace disque libre" "OK" ("{0} Go disponibles" -f $FreeGB)
        }
        else {
            Write-Check "Espace disque libre" "WARN" ("{0} Go disponibles ; {1} Go recommandés avant upgrade." -f $FreeGB, $RecommendedFreeSpaceGB)
        }
    }

    # ------------------------------------------------------------------------
    # 2. Microsoft Hardware Readiness
    # ------------------------------------------------------------------------

    Write-Title "2. MICROSOFT WINDOWS 11 HARDWARE READINESS"

    $Url = "https://aka.ms/HWReadinessScript"
    Invoke-RobustDownload -Uri $Url -Destination $HardwareScript

    Write-Check "HardwareReadiness.ps1" "OK" "Script Microsoft téléchargé."

    $Signature = Get-AuthenticodeSignature -FilePath $HardwareScript

    if (($Signature.Status -eq "Valid") -and ($null -ne $Signature.SignerCertificate) -and ($Signature.SignerCertificate.Subject -match "Microsoft")) {
        Write-Check "Signature script" "OK" "Signature Microsoft valide."
    }
    elseif ($Signature.Status -eq "NotSigned") {
        Write-Check "Signature script" "WARN" "Script non signé ; source HTTPS officielle aka.ms utilisée."
    }
    else {
        Write-Check "Signature script" "WARN" ("Etat Authenticode : {0}" -f $Signature.Status)
    }

    $WindowsPowerShell = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"

    if (-not (Test-Path $WindowsPowerShell)) {
        throw "Windows PowerShell 5.1 introuvable."
    }

    $RawOutput = @(
        & $WindowsPowerShell -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $HardwareScript 2>&1 |
        ForEach-Object { [string]$_ }
    )

    $HardwareResult = $null

    for ($Index = $RawOutput.Count - 1; $Index -ge 0; $Index--) {
        $Line = $RawOutput[$Index].Trim()

        if ($Line.StartsWith("{") -and $Line.EndsWith("}")) {
            try {
                $HardwareResult = $Line | ConvertFrom-Json -ErrorAction Stop
                break
            }
            catch {
            }
        }
    }

    if ($null -eq $HardwareResult) {
        Write-Host ""
        Write-Host "Sortie brute HardwareReadiness :" -ForegroundColor Yellow
        $RawOutput | ForEach-Object { Write-Host $_ }
        throw "Impossible d'analyser le résultat JSON HardwareReadiness."
    }

    $HardwareLogging = [string](Get-PropertyValue $HardwareResult "logging" "")

    foreach ($Entry in ($HardwareLogging -split ';\s*')) {
        if ([string]::IsNullOrWhiteSpace($Entry)) {
            continue
        }

        if ($Entry -match '\bFAIL\b') {
            Write-Check "Microsoft HW" "FAIL" $Entry
        }
        elseif ($Entry -match '\bPASS\b') {
            Write-Check "Microsoft HW" "OK" $Entry
        }
        else {
            Write-Check "Microsoft HW" "INFO" $Entry
        }
    }

    $HWReturnCode = [int](Get-PropertyValue $HardwareResult "returnCode" -2)
    $HWReturnResult = [string](Get-PropertyValue $HardwareResult "returnResult" "UNKNOWN")
    $HWReason = [string](Get-PropertyValue $HardwareResult "returnReason" "")

    $HardwareCapable = $false
    $HardwareUndetermined = $false

    switch ($HWReturnCode) {
        0 {
            $HardwareCapable = $true
            Write-Check "Résultat matériel" "OK" "CAPABLE"
        }

        1 {
            Write-Check "Résultat matériel" "FAIL" "NOT CAPABLE"

            if (-not [string]::IsNullOrWhiteSpace($HWReason)) {
                $CleanReason = $HWReason.Trim().TrimEnd(",")
                Write-Check "Blocage matériel" "FAIL" $CleanReason
            }
        }

        default {
            $HardwareUndetermined = $true
            Write-Check "Résultat matériel" "WARN" ("{0} - contrôle indéterminé." -f $HWReturnResult)
        }
    }

    # ------------------------------------------------------------------------
    # 3. DirectX / WDDM
    # ------------------------------------------------------------------------

    Write-Title "3. DIRECTX / WDDM"

    $Graphics = Get-GraphicsReadiness -OutputFile $DxDiagFile
    $GraphicsBlocking = $false
    $VirtualGraphicsWarning = $false

    if ($Graphics.Capable -eq $false) {
        if ($IsVirtualMachine) {
            $VirtualGraphicsWarning = $true
            Write-Check "Carte graphique" "WARN" ("{0} VM détectée : le GPU virtuel est traité comme avertissement non bloquant." -f $Graphics.Detail)
        }
        else {
            $GraphicsBlocking = $true
            Write-Check "Carte graphique" "FAIL" $Graphics.Detail
        }
    }
    elseif ($Graphics.Capable -eq $true) {
        Write-Check "Carte graphique" "OK" $Graphics.Detail
    }
    else {
        Write-Check "Carte graphique" "WARN" $Graphics.Detail
    }

    foreach ($GPU in $Graphics.Devices) {
        Write-Check "GPU" "INFO" ("{0} | DDI={1} | WDDM={2}" -f $GPU.CardName, $GPU.DDIVersion, $GPU.WDDMVersion)
    }

    if ($VirtualGraphicsWarning) {
        Write-Check "GPU virtuel" "WARN" "DirectX 12 non détecté dans le guest, mais ce point ne bloque pas à lui seul le résultat sur une VM."
    }

    # ------------------------------------------------------------------------
    # 4. Etat Windows
    # ------------------------------------------------------------------------

    Write-Title "4. ETAT WINDOWS"

    $PendingReboot = Test-PendingReboot

    if ($PendingReboot.Pending) {
        Write-Check "Redémarrage en attente" "WARN" ($PendingReboot.Reasons -join ", ")
    }
    else {
        Write-Check "Redémarrage en attente" "OK" "Aucun redémarrage en attente détecté."
    }

    try {
        $WindowsUpdateService = Get-CimInstance Win32_Service -Filter "Name='wuauserv'"

        if ($WindowsUpdateService.StartMode -eq "Disabled") {
            Write-Check "Windows Update" "WARN" "Service wuauserv désactivé."
        }
        else {
            Write-Check "Windows Update" "OK" ("Service disponible - StartMode={0}" -f $WindowsUpdateService.StartMode)
        }
    }
    catch {
        Write-Check "Windows Update" "WARN" "Impossible de contrôler le service."
    }

    # ------------------------------------------------------------------------
    # GPO Windows Update / Target Release
    # ------------------------------------------------------------------------

    $PolicyBlock = $false
    $WUPolicyPath = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate"
    $WUPolicy = Get-ItemProperty $WUPolicyPath -ErrorAction SilentlyContinue

    if ($null -ne $WUPolicy) {
        $TargetReleaseEnabled = Get-PropertyValue $WUPolicy "TargetReleaseVersion" 0
        $TargetReleaseInfo = [string](Get-PropertyValue $WUPolicy "TargetReleaseVersionInfo" "")
        $TargetProduct = [string](Get-PropertyValue $WUPolicy "ProductVersion" "")

        if ([int]$TargetReleaseEnabled -eq 1) {
            if (-not [string]::IsNullOrWhiteSpace($TargetReleaseInfo)) {
                if ($TargetReleaseInfo -ne $TargetVersion) {
                    $PolicyBlock = $true
                    Write-Check "TargetReleaseVersion" "WARN" ("GPO verrouillée sur {0} ; cible attendue {1}." -f $TargetReleaseInfo, $TargetVersion)
                }
                else {
                    Write-Check "TargetReleaseVersion" "OK" ("GPO autorise {0}." -f $TargetVersion)
                }
            }

            if (($TargetProduct -eq "Windows 10") -and (-not $IsWindows11)) {
                $PolicyBlock = $true
                Write-Check "ProductVersion GPO" "WARN" "La GPO maintient explicitement la machine sur Windows 10."
            }
        }

        $FeatureDeferral = Get-PropertyValue $WUPolicy "DeferFeatureUpdatesPeriodInDays"

        if ($null -ne $FeatureDeferral) {
            Write-Check "Feature Update Deferral" "INFO" ("{0} jour(s)" -f $FeatureDeferral)
        }
    }

    # ------------------------------------------------------------------------
    # WSUS
    # ------------------------------------------------------------------------

    $AUPath = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU"
    $AUPolicy = Get-ItemProperty $AUPath -ErrorAction SilentlyContinue
    $UseWUServer = Get-PropertyValue $AUPolicy "UseWUServer" 0

    if ([int]$UseWUServer -eq 1) {
        $WUServer = [string](Get-PropertyValue $WUPolicy "WUServer" "WSUS configuré")
        Write-Check "WSUS" "INFO" ("Machine gérée par WSUS : {0}" -f $WUServer)
    }
    else {
        Write-Check "WSUS" "INFO" "Windows Update Microsoft / WUfB."
    }

    # ------------------------------------------------------------------------
    # 5. Safeguard Hold
    # ------------------------------------------------------------------------

    Write-Title "5. MICROSOFT SAFEGUARD HOLD"

    $Safeguard = Get-SafeguardStatus -TargetVersion $TargetVersion

    if (-not $Safeguard.Known) {
        Write-Check "Safeguard Hold" "INFO" ("Aucune donnée Appraiser exploitable pour {0}." -f $TargetVersion)
    }
    elseif ($Safeguard.Hold) {
        Write-Check "Safeguard Hold" "WARN" "Microsoft bloque actuellement l'upgrade sur cette machine."

        if ($Safeguard.BlockIDs.Count -gt 0) {
            Write-Check "Safeguard ID" "WARN" ($Safeguard.BlockIDs -join ", ")
        }

        if ($Safeguard.Reasons.Count -gt 0) {
            Write-Check "Safeguard Reason" "WARN" ($Safeguard.Reasons -join ", ")
        }

        if ($Safeguard.FailedPrereqs.Count -gt 0) {
            Write-Check "Failed prerequisites" "WARN" ($Safeguard.FailedPrereqs -join ", ")
        }
    }
    else {
        Write-Check "Safeguard Hold" "OK" "Aucun safeguard hold détecté."
    }

    # ------------------------------------------------------------------------
    # Résultat final
    # ------------------------------------------------------------------------

    Write-Title "RESULTAT FINAL"

    # Le script Microsoft reste l'autorité principale pour CPU / RAM / TPM /
    # Secure Boot / stockage. Le GPU devient bloquant uniquement sur une
    # machine physique. Sur une VM, un GPU virtuel insuffisant est un WARN.
    $PermanentBlock = ($OSBlockers.Count -gt 0) -or (-not $HardwareCapable) -or $GraphicsBlocking

    if ($AlreadyTarget) {
        if ($HardwareUndetermined) {
            $FinalResult = "ALREADY_CURRENT_CHECK_INCOMPLETE"

            Write-Host ""
            Write-Host ("WINDOWS 11 {0} EST DEJA INSTALLE" -f $TargetVersion) -ForegroundColor Green
            Write-Host "Le contrôle matériel Microsoft n'a pas pu être déterminé complètement." -ForegroundColor Yellow

            $ExitCode = 2
        }
        elseif ($PermanentBlock) {
            $FinalResult = "ALREADY_CURRENT_NOT_COMPLIANT"

            Write-Host ""
            Write-Host ("WINDOWS 11 {0} EST DEJA INSTALLE" -f $TargetVersion) -ForegroundColor Green
            Write-Host "ATTENTION : la configuration matérielle actuelle ne respecte pas tous les prérequis contrôlés pour Windows 11." -ForegroundColor Yellow

            if (-not $HardwareCapable) {
                Write-Host "Le contrôle Microsoft HardwareReadiness retourne NOT CAPABLE." -ForegroundColor Red
            }

            if ($GraphicsBlocking) {
                Write-Host "Le contrôle DirectX / WDDM est bloquant sur cette machine physique." -ForegroundColor Red
            }

            $ExitCode = 4
        }
        else {
            $FinalResult = "ALREADY_CURRENT"

            Write-Host ""
            Write-Host ("WINDOWS 11 {0} EST DEJA INSTALLE" -f $TargetVersion) -ForegroundColor Green
            Write-Host "Les prérequis matériels principaux contrôlés sont conformes." -ForegroundColor Green

            if ($VirtualGraphicsWarning) {
                Write-Host "Avertissement : GPU virtuel sans DirectX 12 détecté ; non bloquant pour le résultat de cette VM." -ForegroundColor Yellow
            }

            if ($PendingReboot.Pending) {
                Write-Host "ATTENTION : un redémarrage Windows est actuellement en attente." -ForegroundColor Yellow
            }

            $ExitCode = 0
        }
    }
    elseif ($HardwareUndetermined) {
        $FinalResult = "UNDETERMINED"

        Write-Host ""
        Write-Host ("UPGRADE WINDOWS 11 {0} : RESULTAT INDETERMINE" -f $TargetVersion) -ForegroundColor Yellow
        Write-Host "Le contrôle matériel Microsoft n'a pas pu être validé." -ForegroundColor Yellow

        $ExitCode = 2
    }
    elseif ($PermanentBlock) {
        $FinalResult = "NOT_CAPABLE"

        Write-Host ""
        Write-Host ("UPGRADE WINDOWS 11 {0} : NOT CAPABLE" -f $TargetVersion) -ForegroundColor Red
        Write-Host "Au moins un prérequis obligatoire n'est pas respecté." -ForegroundColor Red

        $ExitCode = 1
    }
    elseif ($Safeguard.Hold -or $PolicyBlock) {
        $FinalResult = "CAPABLE_BUT_BLOCKED"

        Write-Host ""
        Write-Host ("UPGRADE WINDOWS 11 {0} : CAPABLE MAIS BLOQUE" -f $TargetVersion) -ForegroundColor Yellow
        Write-Host "Le matériel est compatible, mais Windows Update / une GPO / un Safeguard Hold empêche actuellement le déploiement." -ForegroundColor Yellow

        $ExitCode = 3
    }
    else {
        $FinalResult = "READY"

        Write-Host ""
        Write-Host ("WINDOWS 11 {0} UPGRADE IS OK ON THIS COMPUTER" -f $TargetVersion) -ForegroundColor Green
        Write-Host ""
        Write-Host ("La machine satisfait les prérequis détectables pour Windows 11 {0}." -f $TargetVersion) -ForegroundColor Green

        if ($VirtualGraphicsWarning) {
            Write-Host "Avertissement : GPU virtuel sans DirectX 12 détecté ; non bloquant pour le résultat de cette VM." -ForegroundColor Yellow
        }

        if ($PendingReboot.Pending) {
            Write-Host "ATTENTION : redémarrer Windows avant de lancer l'upgrade." -ForegroundColor Yellow
        }

        $ExitCode = 0
    }

    Write-Host ""
    Write-Host ("FinalResult : {0}" -f $FinalResult)
    Write-Host ("ExitCode    : {0}" -f $ExitCode)
}
catch {
    $FinalResult = "ERROR"
    $ExitCode = 2

    Write-Host ""
    Write-Host "============================================================" -ForegroundColor Red
    Write-Host " ERREUR WINDOWS 11 UPGRADE CHECK" -ForegroundColor Red
    Write-Host "============================================================" -ForegroundColor Red
    Write-Host ""
    Write-Host $_.Exception.Message -ForegroundColor Red
}
finally {
    Write-Host ""

    if ($KeepTemp) {
        Write-Check "Nettoyage" "INFO" ("Dossier conservé : {0}" -f $TempFolder)
    }
    else {
        if (Test-Path $TempFolder) {
            try {
                Remove-Item -Path $TempFolder -Recurse -Force -ErrorAction Stop
                Write-Check "Nettoyage" "OK" "Dossier temporaire supprimé."
            }
            catch {
                Write-Check "Nettoyage" "WARN" ("Impossible de supprimer {0} : {1}" -f $TempFolder, $_.Exception.Message)
            }
        }
    }
}

exit $ExitCode
