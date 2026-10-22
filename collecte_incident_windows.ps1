<#
 collecte_incident.ps1 — Collecte en LECTURE SEULE des informations post-crash.
 Seule écriture : le rapport (et la copie des dernières lignes HWiNFO) dans Documents\Incidents.
 À lancer juste après le redémarrage consécutif au crash, avant tout nouveau redémarrage.
 Idéalement dans un PowerShell « Exécuter en tant qu'administrateur » (accès à LiveKernelReports).

 Lancement sans modifier la stratégie d'exécution :
   powershell -ExecutionPolicy Bypass -File .\collecte_incident.ps1
#>
param(
    [string]$HwinfoDir = (Join-Path $env:USERPROFILE 'Documents'),
    [string]$OutDir    = '.\Incidents',
    [int]$Fenetre      = 30    # minutes d'événements examinées avant l'incident
)

$ci = [System.Globalization.CultureInfo]::InvariantCulture
$fr = [System.Globalization.CultureInfo]::GetCultureInfo('fr-FR')
$fence = '```'
$o = New-Object 'System.Collections.Generic.List[string]'

function L([string]$s = '') {
    $script:o.Add($s)
}

function ConvertFrom-HwinfoStamp([string]$d, [string]$t) {
    $s = ("$d $t").Trim('"', ' ')
    $formats = [string[]]@('dd.MM.yyyy HH:mm:ss.fff','dd.MM.yyyy HH:mm:ss','dd/MM/yyyy HH:mm:ss.fff','dd/MM/yyyy HH:mm:ss','yyyy-MM-dd HH:mm:ss.fff','yyyy-MM-dd HH:mm:ss')
    $r = [datetime]::MinValue
    if ([datetime]::TryParseExact($s, $formats, $ci, 'None', [ref]$r)) { return $r }
    if ([datetime]::TryParse($s, $fr, 'None', [ref]$r)) { return $r }
    return $null
}

function Format-Ev($ev) {
    $m = ''
    if ($ev.Message) {
        $m = ($ev.Message -split "`r?`n")[0]
        if ($m.Length -gt 170) { $m = $m.Substring(0, 170) + '…' }
    }
    '{0:HH:mm:ss} | {1} | {2} | {3}' -f $ev.TimeCreated, $ev.ProviderName, $ev.Id, $m
}

# --- Repères de démarrage -----------------------------------------------------
$boot = (Get-CimInstance Win32_OperatingSystem).LastBootUpTime
$boots = @(Get-WinEvent -FilterHashtable @{LogName='System'; ProviderName='Microsoft-Windows-Kernel-General'; Id=12} -MaxEvents 4 -ErrorAction SilentlyContinue)
$prevBootEv = $boots | Where-Object { $_.TimeCreated -lt $boot.AddMinutes(-1) } | Select-Object -First 1
$prevBoot = if ($prevBootEv) { $prevBootEv.TimeCreated } else { $null }

# --- Détermination de l'heure de l'incident -------------------------------------
$incident = $null
$source = ''
$estime = $false
$hw = $null
$hwHeader = $null
$hwLines = @()
$hwNote = ''

$hw = Get-ChildItem -Path $HwinfoDir -Filter 'hwinfo*.csv' -File -ErrorAction SilentlyContinue |
      Where-Object { $_.LastWriteTime -lt $boot } |
      Sort-Object LastWriteTime -Descending | Select-Object -First 1

if ($hw) {
    $hwHeader = Get-Content -Path $hw.FullName -TotalCount 1
    $nCols = ($hwHeader -split ',').Count
    $tail = @(Get-Content -Path $hw.FullName -Tail 10)
    $valid = @($tail | Where-Object { ($_ -split ',').Count -eq $nCols })   # écarte une ligne tronquée par le crash
    if ($valid.Count -eq 0) {
        $valid = $tail
        $hwNote = 'Nombre de colonnes non vérifiable : dernière ligne possiblement tronquée.'
    }
    if ($valid.Count -gt 0) {
        $p = $valid[-1] -split ','
        $ts = ConvertFrom-HwinfoStamp $p[0] $p[1]
        if ($ts -and $ts -lt $boot -and (-not $prevBoot -or $ts -gt $prevBoot)) {
            $incident = $ts
            $source = "Dernière ligne valide du journal HWiNFO ($($hw.Name))"
            $hwLines = @($valid | Select-Object -Last 40)
        } else {
            $hwNote = "Fichier $($hw.Name) ignoré : sa dernière ligne ($ts) n'appartient pas à la session qui a planté."
        }
    }
} else {
    $hwNote = 'Aucun journal HWiNFO antérieur au démarrage actuel trouvé (HWiNFO réutilisant peut-être le même fichier après redémarrage).'
}

if (-not $incident) {
    $estime = $true
    $last = Get-WinEvent -FilterHashtable @{LogName='System'; EndTime=$boot} -MaxEvents 1 -ErrorAction SilentlyContinue
    if ($last) {
        $incident = $last.TimeCreated
        $source = "ESTIMÉE (borne basse) : dernier événement du journal Système avant le démarrage actuel"
    } else {
        $incident = $boot
        $source = "ESTIMÉE : heure du démarrage actuel (aucun repère trouvé)"
    }
}

# --- Nom du fichier --------------------------------------------------------------
New-Item -ItemType Directory -Path $OutDir -Force | Out-Null
$base = '{0:yyyy-MM-dd}_incident_windows_{0:HH}h{0:mm}' -f $incident
if ($estime) { $base += '_estime' }
$report = Join-Path $OutDir "$base.md"
$n = 2
while (Test-Path $report) { $report = Join-Path $OutDir "${base}_$n.md"; $n++ }
$csvOut = $report -replace '\.md$', '_hwinfo.csv'

# --- Rapport -------------------------------------------------------------------
L ('# Incident du {0:dd/MM/yyyy} à {0:HH:mm:ss}' -f $incident)
L ''
L "- **Heure de l'incident :** $('{0:dd/MM/yyyy HH:mm:ss}' -f $incident)$(if ($estime) { ' (ESTIMÉE)' })"
L "- **Source de l'heure :** $source"
L "- **Démarrage suivant (LastBootUpTime) :** $('{0:dd/MM/yyyy HH:mm:ss}' -f $boot) (soit $([math]::Round(($boot - $incident).TotalMinutes, 1)) min après l'incident)"
if ($prevBoot) {
    L "- **Démarrage précédent (Kernel-General 12, indicatif) :** $('{0:dd/MM/yyyy HH:mm:ss}' -f $prevBoot)"
    L "- **Uptime au moment de l'incident :** $([math]::Round(($incident - $prevBoot).TotalHours, 2)) h"
} else {
    L "- **Démarrage précédent :** introuvable"
}
if ($hwNote) { L "- **Note HWiNFO :** $hwNote" }
L ''

L '## À compléter à la main'
L ''
L '- Type : freeze / écran noir / redémarrage spontané / BSOD visible :'
L '- Alimentation : Secteur / batterie (niveau %)'
L '- Activité au moment des faits :'
L '- Veille depuis le dernier démarrage :  oui/non, quand'
L '- Redémarrage : automatique (après combien de temps) / arrêt forcé'
L '- Autres observations (ventilateurs, voyants, périphériques branchés) :'
L ''

# Événement 41
L '## Événement Kernel-Power 41 (le plus récent)'
L ''
$e41 = Get-WinEvent -FilterHashtable @{LogName='System'; ProviderName='Microsoft-Windows-Kernel-Power'; Id=41} -MaxEvents 1 -ErrorAction SilentlyContinue
if ($e41) {
    L ('Enregistré à {0:dd/MM/yyyy HH:mm:ss}' -f $e41.TimeCreated)
    L ''
    L $fence
    $x = [xml]$e41.ToXml()
    $x.Event.EventData.Data | ForEach-Object { L ("{0} = {1}" -f $_.Name, $_.'#text') }
    L $fence
} else { L 'Aucun événement 41 trouvé.' }
$count41 = @(Get-WinEvent -FilterHashtable @{LogName='System'; ProviderName='Microsoft-Windows-Kernel-Power'; Id=41} -ErrorAction SilentlyContinue).Count
L ''
L "Total d'événements 41 dans le journal : **$count41**"
L ''

# 6008 et BugCheck 1001
L '## Arrêt inattendu (6008) et BugCheck (1001)'
L ''
$e6008 = Get-WinEvent -FilterHashtable @{LogName='System'; ProviderName='EventLog'; Id=6008} -MaxEvents 1 -ErrorAction SilentlyContinue
if ($e6008) {
    $msg6008 = (($e6008.Message -split "`r?`n")[0]) -replace '[\u200E\u200F\u202A\u202B\u202C\u202D\u202E]', ''
    L ('- 6008 enregistré à {0:dd/MM/yyyy HH:mm:ss} : {1}' -f $e6008.TimeCreated, $msg6008)
} else {
    L '- Aucun 6008.'
}
L '- Rappel : l’heure citée dans le 6008 est un repère mis à jour périodiquement, **pas** l’heure réelle du gel.'
$e1001 = Get-WinEvent -FilterHashtable @{LogName='System'; ProviderName='Microsoft-Windows-WER-SystemErrorReporting'; Id=1001; StartTime=$boot.AddMinutes(-1)} -MaxEvents 1 -ErrorAction SilentlyContinue
if ($e1001) { L ('- BugCheck 1001 : ' + (($e1001.Message -split "`r?`n")[0])) } else { L '- Aucun BugCheck 1001 depuis le démarrage : pas de BSOD enregistré par Windows.' }
L ''

# Journal Système avant l'incident
L "## Journal Système : erreurs et avertissements dans les $Fenetre min avant l'incident"
L ''
$ctx = @(Get-WinEvent -FilterHashtable @{LogName='System'; StartTime=$incident.AddMinutes(-$Fenetre); EndTime=$boot; Level=1,2,3} -ErrorAction SilentlyContinue | Sort-Object TimeCreated)
L $fence
if ($ctx.Count -gt 0) { $ctx | Select-Object -Last 80 | ForEach-Object { L (Format-Ev $_) } } else { L '(aucun)' }
L $fence
L ''

# Session plantée : WHEA, Display, alimentation
$since = if ($prevBoot) { $prevBoot } else { $boot.AddDays(-1) }
L '## Session plantée : WHEA-Logger et Display (tous niveaux)'
L ''
L $fence
$hardw = @(Get-WinEvent -FilterHashtable @{LogName='System'; ProviderName='Microsoft-Windows-WHEA-Logger'; StartTime=$since; EndTime=$boot} -ErrorAction SilentlyContinue) +
         @(Get-WinEvent -FilterHashtable @{LogName='System'; ProviderName='Display'; StartTime=$since; EndTime=$boot} -ErrorAction SilentlyContinue)
if ($hardw.Count -gt 0) { $hardw | Sort-Object TimeCreated | Select-Object -Last 40 | ForEach-Object { L (Format-Ev $_) } } else { L '(aucun)' }
L $fence
L ''

L "## Session plantée : source d'alimentation et veille (derniers événements)"
L ''
L $fence
$pw = @(Get-WinEvent -FilterHashtable @{LogName='System'; ProviderName='Microsoft-Windows-Kernel-Power'; Id=42,105,107,506,507; StartTime=$since; EndTime=$boot} -ErrorAction SilentlyContinue) +
      @(Get-WinEvent -FilterHashtable @{LogName='System'; ProviderName='Microsoft-Windows-Power-Troubleshooter'; Id=1; StartTime=$since; EndTime=$boot} -ErrorAction SilentlyContinue)
if ($pw.Count -gt 0) { $pw | Sort-Object TimeCreated | Select-Object -Last 14 | ForEach-Object { L (Format-Ev $_) } } else { L '(aucun : pas de changement de source ni de veille dans la session)' }
L $fence
L ''

# Minidump
L '## Fichiers Minidump'
L ''
L $fence
$miniPath = 'C:\Windows\Minidump'
$mini = @()
$miniAccessDenied = $false

if (Test-Path $miniPath) {
    try {
        $mini = @(Get-ChildItem $miniPath -File -ErrorAction Stop | Sort-Object LastWriteTime -Descending | Select-Object -First 5)
    } catch {
        $miniAccessDenied = $true
    }
}
if ($miniAccessDenied) {
    L 'Minidump : Accès refusé (relancer en administrateur)'
} elseif ($mini.Count -gt 0) {
    $mini | ForEach-Object { L ('Minidump  {0:dd/MM/yyyy HH:mm:ss}  {1,8:N0} Ko  {2}{3}' -f $_.LastWriteTime, ($_.Length / 1KB), $_.Name, $(if ($prevBoot -and $_.LastWriteTime -gt $prevBoot) { '  <-- NOUVEAU' } else { '' })) }
} else {
    L 'Minidump : Aucun fichier'
}
L $fence
L ''

# MEMORY.DMP
L '## Fichiers MEMORY.DMP'
L ''
L $fence
$memPath = 'C:\Windows\MEMORY.DMP'
$mem = $null
$memAccessDenied = $false
try {
    $mem = Get-Item $memPath -ErrorAction Stop
} catch {
    if ($_.Exception.Message -like '*accès*') { $memAccessDenied = $true }
}

if ($memAccessDenied) {
    L 'MEMORY.DMP : Accès refusé'
} elseif ($mem) {
    L ('MEMORY.DMP {0:dd/MM/yyyy HH:mm:ss}  {1:N0} Mo' -f $mem.LastWriteTime, ($mem.Length / 1MB))
} else {
    L 'MEMORY.DMP : Absent'
}
L $fence
L ''

# LiveKernelReports
L '## Fichiers LiveKernelReports'
L ''
L $fence
$lkrPath = 'C:\Windows\LiveKernelReports'
$lkr = @()
$lkrAccessDenied = $false
if (Test-Path $lkrPath) {
    try {
        $lkr = @(Get-ChildItem $lkrPath -Recurse -File -ErrorAction Stop | Sort-Object LastWriteTime -Descending | Select-Object -First 8)
    } catch {
        $lkrAccessDenied = $true
    }
}
if ($lkrAccessDenied) {
    L 'LiveKernelReports : Accès refusé (relancer en administrateur)'
} elseif ($lkr.Count -gt 0) {
    $lkr | ForEach-Object { L ('LiveKernelReports  {0:dd/MM/yyyy HH:mm:ss}  {1}{2}' -f $_.LastWriteTime, $_.FullName.Replace('C:\Windows\LiveKernelReports\', ''), $(if ($prevBoot -and $_.LastWriteTime -gt $prevBoot) { '  <-- NOUVEAU' } else { '' })) }
} else {
    L 'LiveKernelReports : Aucun fichier'
}
L $fence
L ''

# HWiNFO
L '## Journal HWiNFO'
L ''
if ($hwLines.Count -gt 0) {
    @($hwHeader) + $hwLines | Set-Content -Path $csvOut -Encoding UTF8
    L "- Fichier source : $($hw.FullName)"
    L ('- Dernière ligne valide : {0:dd/MM/yyyy HH:mm:ss}' -f $incident)
    L "- Copie des $($hwLines.Count) dernières lignes (+ en-tête) : $(Split-Path $csvOut -Leaf)"
} else {
    L '- Aucune donnée HWiNFO exploitable pour cet incident.'
}

Set-Content -Path $report -Value $o -Encoding UTF8
Write-Host "Rapport : $report"
if ($hwLines.Count -gt 0) {
    Write-Host "HWiNFO  : $csvOut"
}
