#requires -version 5.1

<#
.SYNOPSIS
    Windows 11 Upgrade Readiness Check

.DESCRIPTION
    Vérifie si la machine peut être mise à niveau vers Windows 11 25H2.

    Contrôles :
      - OS actuel / version / build
      - Prérequis OS pour upgrade Windows 10 -> Windows 11
      - Microsoft HardwareReadiness.ps1
      - CPU
      - RAM
      - TPM 2.0
      - Secure Boot / UEFI
      - Stockage
      - DirectX 12 / WDDM 2.0
      - Espace disque libre
      - Redémarrage en attente
      - GPO TargetReleaseVersion
      - Configuration WSUS
      - Service Windows Update
      - Microsoft Safeguard Hold
      - Nettoyage automatique des fichiers temporaires

.EXIT CODES
    0 = READY / déjà sur 25H2 / non applicable
    1 = NOT CAPABLE
    2 = UNDETERMINED / erreur du contrôle
    3 = CAPABLE mais temporairement bloqué par Windows Update / GPO / Safeguard Hold

.NOTES
    Target validé : Windows 11 25H2
    Révision : 2026-09-17
#>

[CmdletBinding()]
param(
    [int]$RecommendedFreeSpaceGB = 30,
    [switch]$KeepTemp
)

$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"

$TargetVersion = "25H2"
$ExitCode = 2
$FinalResult = "UNDETERMINED"

# ---------------------------------------------------------------------------
# Fonctions d'affichage
# ---------------------------------------------------------------------------

function Write-Title {
    param([string]$Text)

    Write-Host ""
    Write-Host ("=" * 78) -ForegroundColor Cyan
    Write-Host " $Text" -ForegroundColor Cyan
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
    }

    Write-Host ("[{0,-4}] {1,-28} {2}" -f $State, $Name, $Detail) `
        -ForegroundColor $Color
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

# ---------------------------------------------------------------------------
# Vérification droits administrateur
# ---------------------------------------------------------------------------

$Identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$Principal = New-Object Security.Principal.WindowsPrincipal($Identity)

$IsAdministrator = $Principal.IsInRole(
    [Security.Principal.WindowsBuiltInRole]::Administrator
)

if (-not $IsAdministrator) {
    Write-Host ""
    Write-Host "[FAIL] Le script doit être exécuté en administrateur." `
        -ForegroundColor Red
    exit 2
}

# ---------------------------------------------------------------------------
# Dossier temporaire unique
# ---------------------------------------------------------------------------

$TempFolder = Join-Path `
    ([System.IO.Path]::GetTempPath()) `
    ("TempW11UpgradeCheck_" + [guid]::NewGuid().ToString("N"))

$HardwareScript = Join-Path $TempFolder "HardwareReadiness.ps1"
$DxDiagFile     = Join-Path $TempFolder "DxDiag.xml"

# ---------------------------------------------------------------------------
# Téléchargement robuste
# ---------------------------------------------------------------------------

function Invoke-RobustDownload {
    param(
        [Parameter(Mandatory)]
        [string]$Uri,

        [Parameter(Mandatory)]
        [string]$Destination,

        [int]$MaxAttempts = 3
    )

    for ($Attempt = 1; $Attempt -le $MaxAttempts; $Attempt++) {

        try {
            Write-Check `
                "Téléchargement Microsoft" `
                "INFO" `
                "Tentative $Attempt/$MaxAttempts"

            Invoke-WebRequest `
                -Uri $Uri `
                -OutFile $Destination `
                -UseBasicParsing `
                -MaximumRedirection 10 `
                -ErrorAction Stop

            if (
                (Test-Path $Destination) -and
                ((Get-Item $Destination).Length -gt 1000)
            ) {
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

# ---------------------------------------------------------------------------
# Redémarrage Windows en attente
# ---------------------------------------------------------------------------

function Test-PendingReboot {

    $Pending = $false
    $Reasons = New-Object System.Collections.Generic.List[string]

    if (
        Test-Path `
        "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending"
    ) {
        $Pending = $true
        $Reasons.Add("Component Based Servicing")
    }

    if (
        Test-Path `
        "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired"
    ) {
        $Pending = $true
        $Reasons.Add("Windows Update")
    }

    try {
        $SessionManager = Get-ItemProperty `
            "HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager" `
            -ErrorAction SilentlyContinue

        $PendingRename = Get-PropertyValue `
            $SessionManager `
            "PendingFileRenameOperations"

        if ($null -ne $PendingRename) {
            $Pending = $true
            $Reasons.Add("PendingFileRenameOperations")
        }
    }
    catch {
    }

    return [PSCustomObject]@{
        Pending = $Pending
        Reasons = $Reasons
    }
}

# ---------------------------------------------------------------------------
# Contrôle DirectX / WDDM
# ---------------------------------------------------------------------------

function Get-GraphicsReadiness {

    param(
        [string]$OutputFile
    )

    try {

        $DxDiag = Join-Path $env:SystemRoot "System32\dxdiag.exe"

        if (-not (Test-Path $DxDiag)) {
            throw "dxdiag.exe introuvable."
        }

        $Arguments = "/whql:off /x `"$OutputFile`""

        $Process = Start-Process `
            -FilePath $DxDiag `
            -ArgumentList $Arguments `
            -WindowStyle Hidden `
            -PassThru

        if (-not $Process.WaitForExit(30000)) {
            Stop-Process -Id $Process.Id -Force -ErrorAction SilentlyContinue
            throw "Timeout lors de l'exécution de DxDiag."
        }

        if (-not (Test-Path $OutputFile)) {
            throw "DxDiag n'a pas généré de fichier XML."
        }

        [xml]$DxDiagXml = Get-Content `
            -Path $OutputFile `
            -Raw `
            -ErrorAction Stop

        $Devices = @(
            $DxDiagXml.DxDiag.DisplayDevices.DisplayDevice
        )

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
                $DDIVersion = [double]::Parse(
                    $Matches[1],
                    [Globalization.CultureInfo]::InvariantCulture
                )
            }

            if ($DriverModelText -match 'WDDM\s+(\d+(?:\.\d+)?)') {
                $WDDMVersion = [double]::Parse(
                    $Matches[1],
                    [Globalization.CultureInfo]::InvariantCulture
                )
            }

            if (
                ($null -ne $DDIVersion) -and
                ($null -ne $WDDMVersion)
            ) {
                $AtLeastOneKnown = $true

                if (
                    ($DDIVersion -ge 12) -and
                    ($WDDMVersion -ge 2.0)
                ) {
                    $AtLeastOneCompatible = $true
                }
            }

            $Results += [PSCustomObject]@{
                CardName     = $CardName
                DDIVersion   = $DDIVersion
                WDDMVersion  = $WDDMVersion
                DriverModel  = $DriverModelText
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

        return [PSCustomObject]@{
            State   = "FAIL"
            Capable = $false
            Detail  = "Aucun GPU DirectX 12 + WDDM 2.0 compatible détecté."
            Devices = $Results
        }
    }
    catch {

        return [PSCustomObject]@{
            State   = "WARN"
            Capable = $null
            Detail  = $_.Exception.Message
            Devices = @()
        }
    }
}

# ---------------------------------------------------------------------------
# Safeguard Hold Microsoft
# ---------------------------------------------------------------------------

function Get-SafeguardStatus {

    param(
        [string]$TargetVersion
    )

    $Known = $false
    $Hold = $false
    $BlockIDs = @()
    $Reasons = @()
    $FailedPrereqs = @()

    $BaseKey =
        "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\AppCompatFlags\" +
        "TargetVersionUpgradeExperienceIndicators"

    if (Test-Path $BaseKey) {

        $Keys = Get-ChildItem `
            -Path $BaseKey `
            -ErrorAction SilentlyContinue |
            Where-Object {
                $_.PSChildName -like "*$TargetVersion*"
            }

        foreach ($Key in $Keys) {

            try {
                $Values = Get-ItemProperty `
                    -Path $Key.PSPath `
                    -ErrorAction Stop

                $GStatus = Get-PropertyValue $Values "GStatus"

                if ($null -ne $GStatus) {

                    $Known = $true

                    if ([string]$GStatus -eq "0") {
                        $Hold = $true
                    }
                }

                $GatedBlockId = Get-PropertyValue `
                    $Values `
                    "GatedBlockId"

                if (
                    ($null -ne $GatedBlockId) -and
                    ([string]$GatedBlockId -ne "None")
                ) {
                    $BlockIDs += @($GatedBlockId)
                }

                $GatedBlockReason = Get-PropertyValue `
                    $Values `
                    "GatedBlockReason"

                if (
                    ($null -ne $GatedBlockReason) -and
                    ([string]$GatedBlockReason -ne "None")
                ) {
                    $Reasons += @($GatedBlockReason)
                }

                $Failed = Get-PropertyValue `
                    $Values `
                    "FailedPrereqs"

                if (
                    ($null -ne $Failed) -and
                    ([string]$Failed -ne "None")
                ) {
                    $FailedPrereqs += @($Failed)
                }
            }
            catch {
            }
        }
    }

    # Microsoft documente également ce GStatus global.
    $GWXKey =
        "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\" +
        "AppCompatFlags\Appraiser\GWX"

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

    return [PSCustomObject]@{
        Known         = $Known
        Hold          = $Hold
        BlockIDs      = $BlockIDs
        Reasons       = $Reasons
        FailedPrereqs = $FailedPrereqs
    }
}

# ===========================================================================
# MAIN
# ===========================================================================

try {

    Write-Title "WINDOWS 11 $TargetVersion - UPGRADE READINESS CHECK"

    Write-Check `
        "Machine" `
        "INFO" `
        $env:COMPUTERNAME

    Write-Check `
        "Utilisateur" `
        "INFO" `
        $Identity.Name

    # TLS 1.2 pour Windows PowerShell 5.1
    try {
        [Net.ServicePointManager]::SecurityProtocol =
            [Net.ServicePointManager]::SecurityProtocol -bor
            [Net.SecurityProtocolType]::Tls12
    }
    catch {
    }

    New-Item `
        -Path $TempFolder `
        -ItemType Directory `
        -Force |
        Out-Null

    # -----------------------------------------------------------------------
    # OS actuel
    # -----------------------------------------------------------------------

    Write-Title "1. SYSTEME D'EXPLOITATION"

    $CurrentVersion = Get-ItemProperty `
        "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion"

    $OS = Get-CimInstance Win32_OperatingSystem

    $ProductName = [string](
        Get-PropertyValue $CurrentVersion "ProductName" "Windows"
    )

    $DisplayVersion = [string](
        Get-PropertyValue `
            $CurrentVersion `
            "DisplayVersion" `
            (Get-PropertyValue $CurrentVersion "ReleaseId" "Unknown")
    )

    $EditionID = [string](
        Get-PropertyValue $CurrentVersion "EditionID" "Unknown"
    )

    $Build = [int](
        Get-PropertyValue $CurrentVersion "CurrentBuildNumber" 0
    )

    $UBR = [int](
        Get-PropertyValue $CurrentVersion "UBR" 0
    )

    $FullBuild = "$Build.$UBR"

    Write-Check `
        "Windows actuel" `
        "INFO" `
        "$ProductName $DisplayVersion - Build $FullBuild - $EditionID"

    $OSBlockers = New-Object System.Collections.Generic.List[string]

    if ($OS.ProductType -ne 1) {
        $OSBlockers.Add(
            "Windows Server détecté : ce contrôle concerne Windows Client."
        )
    }

    $IsWindows11 = ($Build -ge 22000)

    if (-not $IsWindows11) {

        if ($Build -lt 19041) {
            $OSBlockers.Add(
                "Windows 10 version 2004 ou supérieure requise."
            )
        }
        elseif (
            ($Build -ge 19041) -and
            ($Build -le 19043) -and
            ($UBR -lt 1237)
        ) {
            $OSBlockers.Add(
                "La mise à jour de sécurité du 14 septembre 2021 ou " +
                "une version ultérieure est requise."
            )
        }
    }

    if ($OSBlockers.Count -eq 0) {
        Write-Check `
            "OS source" `
            "OK" `
            "Version source compatible avec un upgrade Windows 11."
    }
    else {
        foreach ($Blocker in $OSBlockers) {
            Write-Check "OS source" "FAIL" $Blocker
        }
    }

    $AlreadyTarget = ($DisplayVersion -eq $TargetVersion)
    $Is26H1 = ($DisplayVersion -eq "26H1" -or $Build -eq 28000)

    if ($AlreadyTarget) {
        Write-Check `
            "Version cible" `
            "OK" `
            "Windows 11 $TargetVersion est déjà installé."
    }
    elseif ($Is26H1) {
        Write-Check `
            "Version cible" `
            "INFO" `
            "Windows 11 26H1 détecté : branche matérielle spécifique."
    }
    else {
        Write-Check `
            "Version cible" `
            "INFO" `
            "Cible de mise à niveau : Windows 11 $TargetVersion"
    }

    # -----------------------------------------------------------------------
    # Disque
    # -----------------------------------------------------------------------

    $SystemDisk = Get-CimInstance Win32_LogicalDisk |
        Where-Object {
            $_.DeviceID -eq $env:SystemDrive
        } |
        Select-Object -First 1

    if ($null -ne $SystemDisk) {

        $FreeGB = [Math]::Round(
            $SystemDisk.FreeSpace / 1GB,
            1
        )

        if ($FreeGB -ge $RecommendedFreeSpaceGB) {

            Write-Check `
                "Espace disque libre" `
                "OK" `
                "$FreeGB Go disponibles"
        }
        else {

            Write-Check `
                "Espace disque libre" `
                "WARN" `
                "$FreeGB Go disponibles ; " +
                "$RecommendedFreeSpaceGB Go recommandés avant upgrade."
        }
    }

    # -----------------------------------------------------------------------
    # Microsoft Hardware Readiness
    # -----------------------------------------------------------------------

    Write-Title "2. MICROSOFT WINDOWS 11 HARDWARE READINESS"

    $Url = "https://aka.ms/HWReadinessScript"

    Invoke-RobustDownload `
        -Uri $Url `
        -Destination $HardwareScript

    Write-Check `
        "HardwareReadiness.ps1" `
        "OK" `
        "Script Microsoft téléchargé."

    # Vérification signature Authenticode
    $Signature = Get-AuthenticodeSignature `
        -FilePath $HardwareScript

    if (
        ($Signature.Status -eq "Valid") -and
        ($null -ne $Signature.SignerCertificate) -and
        ($Signature.SignerCertificate.Subject -match "Microsoft")
    ) {

        Write-Check `
            "Signature script" `
            "OK" `
            "Signature Microsoft valide."
    }
    elseif ($Signature.Status -eq "NotSigned") {

        Write-Check `
            "Signature script" `
            "WARN" `
            "Script non signé ; source HTTPS officielle aka.ms utilisée."
    }
    else {

        Write-Check `
            "Signature script" `
            "WARN" `
            "Etat Authenticode : $($Signature.Status)"
    }

    # On utilise explicitement Windows PowerShell 5.1 car certaines versions
    # du script Microsoft utilisent des composants historiques Windows.
    $WindowsPowerShell =
        "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"

    if (-not (Test-Path $WindowsPowerShell)) {
        throw "Windows PowerShell 5.1 introuvable."
    }

    $RawOutput = @(
        & $WindowsPowerShell `
            -NoLogo `
            -NoProfile `
            -NonInteractive `
            -ExecutionPolicy Bypass `
            -File $HardwareScript 2>&1 |
        ForEach-Object {
            [string]$_
        }
    )

    $HardwareResult = $null

    for (
        $Index = $RawOutput.Count - 1;
        $Index -ge 0;
        $Index--
    ) {

        $Line = $RawOutput[$Index].Trim()

        if (
            $Line.StartsWith("{") -and
            $Line.EndsWith("}")
        ) {

            try {
                $HardwareResult =
                    $Line | ConvertFrom-Json -ErrorAction Stop

                break
            }
            catch {
            }
        }
    }

    if ($null -eq $HardwareResult) {

        Write-Host ""
        Write-Host "Sortie brute HardwareReadiness :" `
            -ForegroundColor Yellow

        $RawOutput | ForEach-Object {
            Write-Host $_
        }

        throw "Impossible d'analyser le résultat JSON HardwareReadiness."
    }

    # Affichage détaillé des tests Microsoft
    $HardwareLogging = [string](
        Get-PropertyValue $HardwareResult "logging" ""
    )

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

    $HWReturnCode = [int](
        Get-PropertyValue $HardwareResult "returnCode" -2
    )

    $HWReturnResult = [string](
        Get-PropertyValue `
            $HardwareResult `
            "returnResult" `
            "UNKNOWN"
    )

    $HWReason = [string](
        Get-PropertyValue `
            $HardwareResult `
            "returnReason" `
            ""
    )

    $HardwareCapable = $false
    $HardwareUndetermined = $false

    switch ($HWReturnCode) {

        0 {
            $HardwareCapable = $true

            Write-Check `
                "Résultat matériel" `
                "OK" `
                "CAPABLE"
        }

        1 {
            Write-Check `
                "Résultat matériel" `
                "FAIL" `
                "NOT CAPABLE"

            if (-not [string]::IsNullOrWhiteSpace($HWReason)) {

                $CleanReason = $HWReason.Trim().TrimEnd(",")

                Write-Check `
                    "Blocage matériel" `
                    "FAIL" `
                    $CleanReason
            }
        }

        default {
            $HardwareUndetermined = $true

            Write-Check `
                "Résultat matériel" `
                "WARN" `
                "$HWReturnResult - contrôle indéterminé."
        }
    }

    # -----------------------------------------------------------------------
    # GPU DirectX / WDDM
    # -----------------------------------------------------------------------

    Write-Title "3. DIRECTX / WDDM"

    $Graphics = Get-GraphicsReadiness `
        -OutputFile $DxDiagFile

    Write-Check `
        "Carte graphique" `
        $Graphics.State `
        $Graphics.Detail

    foreach ($GPU in $Graphics.Devices) {

        Write-Check `
            "GPU" `
            "INFO" `
            "$($GPU.CardName) | DDI=$($GPU.DDIVersion) | " +
            "WDDM=$($GPU.WDDMVersion)"
    }

    # -----------------------------------------------------------------------
    # Pending reboot
    # -----------------------------------------------------------------------

    Write-Title "4. ETAT WINDOWS"

    $PendingReboot = Test-PendingReboot

    if ($PendingReboot.Pending) {

        Write-Check `
            "Redémarrage en attente" `
            "WARN" `
            ($PendingReboot.Reasons -join ", ")
    }
    else {

        Write-Check `
            "Redémarrage en attente" `
            "OK" `
            "Aucun redémarrage en attente détecté."
    }

    # -----------------------------------------------------------------------
    # Windows Update
    # -----------------------------------------------------------------------

    try {

        $WindowsUpdateService = Get-CimInstance `
            Win32_Service `
            -Filter "Name='wuauserv'"

        if ($WindowsUpdateService.StartMode -eq "Disabled") {

            Write-Check `
                "Windows Update" `
                "WARN" `
                "Service wuauserv désactivé."
        }
        else {

            Write-Check `
                "Windows Update" `
                "OK" `
                "Service disponible - StartMode=$($WindowsUpdateService.StartMode)"
        }
    }
    catch {

        Write-Check `
            "Windows Update" `
            "WARN" `
            "Impossible de contrôler le service."
    }

    # -----------------------------------------------------------------------
    # GPO Windows Update / Target Release
    # -----------------------------------------------------------------------

    $PolicyBlock = $false

    $WUPolicyPath =
        "HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate"

    $WUPolicy = Get-ItemProperty `
        $WUPolicyPath `
        -ErrorAction SilentlyContinue

    if ($null -ne $WUPolicy) {

        $TargetReleaseEnabled = Get-PropertyValue `
            $WUPolicy `
            "TargetReleaseVersion" `
            0

        $TargetReleaseInfo = [string](
            Get-PropertyValue `
                $WUPolicy `
                "TargetReleaseVersionInfo" `
                ""
        )

        $TargetProduct = [string](
            Get-PropertyValue `
                $WUPolicy `
                "ProductVersion" `
                ""
        )

        if ([int]$TargetReleaseEnabled -eq 1) {

            if (
                -not [string]::IsNullOrWhiteSpace(
                    $TargetReleaseInfo
                )
            ) {

                if ($TargetReleaseInfo -ne $TargetVersion) {

                    $PolicyBlock = $true

                    Write-Check `
                        "TargetReleaseVersion" `
                        "WARN" `
                        "GPO verrouillée sur $TargetReleaseInfo ; " +
                        "cible attendue $TargetVersion."
                }
                else {

                    Write-Check `
                        "TargetReleaseVersion" `
                        "OK" `
                        "GPO autorise $TargetVersion."
                }
            }

            if (
                ($TargetProduct -eq "Windows 10") -and
                (-not $IsWindows11)
            ) {

                $PolicyBlock = $true

                Write-Check `
                    "ProductVersion GPO" `
                    "WARN" `
                    "La GPO maintient explicitement la machine sur Windows 10."
            }
        }

        $FeatureDeferral = Get-PropertyValue `
            $WUPolicy `
            "DeferFeatureUpdatesPeriodInDays"

        if ($null -ne $FeatureDeferral) {

            Write-Check `
                "Feature Update Deferral" `
                "INFO" `
                "$FeatureDeferral jour(s)"
        }
    }

    # -----------------------------------------------------------------------
    # WSUS
    # -----------------------------------------------------------------------

    $AUPath =
        "HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU"

    $AUPolicy = Get-ItemProperty `
        $AUPath `
        -ErrorAction SilentlyContinue

    $UseWUServer = Get-PropertyValue `
        $AUPolicy `
        "UseWUServer" `
        0

    if ([int]$UseWUServer -eq 1) {

        $WUServer = [string](
            Get-PropertyValue `
                $WUPolicy `
                "WUServer" `
                "WSUS configuré"
        )

        Write-Check `
            "WSUS" `
            "INFO" `
            "Machine gérée par WSUS : $WUServer"
    }
    else {

        Write-Check `
            "WSUS" `
            "INFO" `
            "Windows Update Microsoft / WUfB."
    }

    # -----------------------------------------------------------------------
    # Microsoft Safeguard Hold
    # -----------------------------------------------------------------------

    Write-Title "5. MICROSOFT SAFEGUARD HOLD"

    $Safeguard = Get-SafeguardStatus `
        -TargetVersion $TargetVersion

    if (-not $Safeguard.Known) {

        Write-Check `
            "Safeguard Hold" `
            "INFO" `
            "Aucune donnée Appraiser exploitable pour $TargetVersion."
    }
    elseif ($Safeguard.Hold) {

        Write-Check `
            "Safeguard Hold" `
            "WARN" `
            "Microsoft bloque actuellement l'upgrade sur cette machine."

        if ($Safeguard.BlockIDs.Count -gt 0) {

            Write-Check `
                "Safeguard ID" `
                "WARN" `
                ($Safeguard.BlockIDs -join ", ")
        }

        if ($Safeguard.Reasons.Count -gt 0) {

            Write-Check `
                "Safeguard Reason" `
                "WARN" `
                ($Safeguard.Reasons -join ", ")
        }

        if ($Safeguard.FailedPrereqs.Count -gt 0) {

            Write-Check `
                "Failed prerequisites" `
                "WARN" `
                ($Safeguard.FailedPrereqs -join ", ")
        }
    }
    else {

        Write-Check `
            "Safeguard Hold" `
            "OK" `
            "Aucun safeguard hold détecté."
    }

    # -----------------------------------------------------------------------
    # RESULTAT FINAL
    # -----------------------------------------------------------------------

    Write-Title "RESULTAT FINAL"

    $PermanentBlock =
        ($OSBlockers.Count -gt 0) -or
        (-not $HardwareCapable) -or
        ($Graphics.Capable -eq $false)

    if ($Is26H1) {

        $FinalResult = "NOT_APPLICABLE"

        Write-Host ""
        Write-Host `
            "WINDOWS 11 26H1 DETECTE" `
            -ForegroundColor Green

        Write-Host `
            "Cette machine utilise la branche matérielle spécifique 26H1." `
            -ForegroundColor Green

        Write-Host `
            "Ne pas tenter de la rétrograder vers 25H2." `
            -ForegroundColor Green

        $ExitCode = 0
    }
    elseif ($AlreadyTarget) {

        $FinalResult = "ALREADY_CURRENT"

        Write-Host ""
        Write-Host `
            "WINDOWS 11 $TargetVersion EST DEJA INSTALLE" `
            -ForegroundColor Green

        $ExitCode = 0
    }
    elseif ($HardwareUndetermined) {

        $FinalResult = "UNDETERMINED"

        Write-Host ""
        Write-Host `
            "UPGRADE WINDOWS 11 $TargetVersion : RESULTAT INDETERMINE" `
            -ForegroundColor Yellow

        Write-Host `
            "Le contrôle matériel Microsoft n'a pas pu être validé." `
            -ForegroundColor Yellow

        $ExitCode = 2
    }
    elseif ($PermanentBlock) {

        $FinalResult = "NOT_CAPABLE"

        Write-Host ""
        Write-Host `
            "UPGRADE WINDOWS 11 $TargetVersion : NOT CAPABLE" `
            -ForegroundColor Red

        Write-Host `
            "Au moins un prérequis obligatoire n'est pas respecté." `
            -ForegroundColor Red

        $ExitCode = 1
    }
    elseif ($Safeguard.Hold -or $PolicyBlock) {

        $FinalResult = "CAPABLE_BUT_BLOCKED"

        Write-Host ""
        Write-Host `
            "UPGRADE WINDOWS 11 $TargetVersion : CAPABLE MAIS BLOQUE" `
            -ForegroundColor Yellow

        Write-Host `
            "Le matériel est compatible, mais Windows Update / une GPO / " +
            "un Safeguard Hold empêche actuellement le déploiement." `
            -ForegroundColor Yellow

        $ExitCode = 3
    }
    else {

        $FinalResult = "READY"

        Write-Host ""
        Write-Host `
            "WINDOWS 11 $TargetVersion UPGRADE IS OK ON THIS COMPUTER" `
            -ForegroundColor Green

        Write-Host ""
        Write-Host `
            "La machine satisfait les prérequis détectables pour " +
            "Windows 11 $TargetVersion." `
            -ForegroundColor Green

        if ($PendingReboot.Pending) {

            Write-Host `
                "ATTENTION : redémarrer Windows avant de lancer l'upgrade." `
                -ForegroundColor Yellow
        }

        $ExitCode = 0
    }

    Write-Host ""
    Write-Host "FinalResult : $FinalResult"
    Write-Host "ExitCode    : $ExitCode"
}
catch {

    $FinalResult = "ERROR"
    $ExitCode = 2

    Write-Host ""
    Write-Host "============================================================" `
        -ForegroundColor Red

    Write-Host " ERREUR WINDOWS 11 UPGRADE CHECK" `
        -ForegroundColor Red

    Write-Host "============================================================" `
        -ForegroundColor Red

    Write-Host ""
    Write-Host $_.Exception.Message -ForegroundColor Red
}
finally {

    Write-Host ""

    if ($KeepTemp) {

        Write-Check `
            "Nettoyage" `
            "INFO" `
            "Dossier conservé : $TempFolder"
    }
    else {

        if (Test-Path $TempFolder) {

            try {

                Remove-Item `
                    -Path $TempFolder `
                    -Recurse `
                    -Force `
                    -ErrorAction Stop

                Write-Check `
                    "Nettoyage" `
                    "OK" `
                    "Dossier temporaire supprimé."
            }
            catch {

                Write-Check `
                    "Nettoyage" `
                    "WARN" `
                    "Impossible de supprimer $TempFolder : $($_.Exception.Message)"
            }
        }
    }
}

exit $ExitCode