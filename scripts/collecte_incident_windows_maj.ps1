<#
 collecte_incident_windows.ps1 — Collecte en LECTURE SEULE des informations post-crash.
 Seule écriture : le rapport (et la copie des dernières lignes HWiNFO) dans Documents\Incidents.
 À lancer juste après le redémarrage consécutif au crash, avant tout nouveau redémarrage.
 Idéalement dans un PowerShell « Exécuter en tant qu'administrateur » (accès à LiveKernelReports).

 Lancement sans modifier la stratégie d'exécution :
   powershell -ExecutionPolicy Bypass -File .\collecte_incident_windows.ps1

 Sélection de la session à analyser (voir specification_v2_0.md) :
   .\collecte_incident_windows.ps1 -Sessions        # affiche les démarrages Windows (lecture seule, aucun fichier créé)
   .\collecte_incident_windows.ps1 -Sessions 10     # limite l'affichage aux 10 dernières sessions
   .\collecte_incident_windows.ps1 -Session -2      # collecte sur la 2e session précédant le démarrage actuel
 Sans -Session, le comportement historique est conservé (session précédant le démarrage actuel).
 Les indices sont relatifs : les relire après chaque redémarrage.
 Pour -Sessions N, placer N juste après -Sessions et ne pas mélanger avec d'autres arguments positionnels.
#>
param(
    [string]$HwinfoDir = (Join-Path $env:USERPROFILE 'Documents'),
    [string]$OutDir    = '.\Incidents',
    [int]$Fenetre      = 30,   # minutes d'événements examinées avant l'incident
    [switch]$Sessions,         # mode affichage des sessions
    [int]$Session              # mode collecte sur une session (indice négatif : -1, -2, ...)
)

$ci = [System.Globalization.CultureInfo]::InvariantCulture
$fr = [System.Globalization.CultureInfo]::GetCultureInfo('fr-FR')
$fence = '```'
$o = New-Object 'System.Collections.Generic.List[string]'

function L([string]$s = '') {
    $script:o.Add($s)
}

function Stop-Collecte([string]$msg) {
    Write-Error $msg
    exit 1
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

# =============================================================================
# Sélection de session (spécification v2.0)
# =============================================================================

$PROV_GENERAL = 'Microsoft-Windows-Kernel-General'
$PROV_POWER   = 'Microsoft-Windows-Kernel-Power'
$PROV_WER     = 'Microsoft-Windows-WER-SystemErrorReporting'
$PROV_WHEA    = 'Microsoft-Windows-WHEA-Logger'
$PROV_EVLOG   = 'EventLog'
$PROV_USER32  = 'User32'

# WHEA fatales consignées au démarrage suivant (spec §7 / §11 : liste À VALIDER sur journaux réels).
$WheaFatalIds = @(18)

# Identification d'une mise à jour Windows dans User32 1074 (spec §6 / §11 : À VALIDER sur journaux réels).
$UpdateProcRegex = '(?i)TrustedInstaller|TiWorker|MoUsoCoreWorker|UsoClient|wuauclt|wuauserv|MusNotification|WindowsUpdate|SetupHost|Windows10Upgrade|SIHClient|UpdateAssistant'
# Codes de raison « Système d'exploitation » (planifiés) : 0x2 installation/récupération, 0x3 mise à niveau, 0x10 service pack, 0x11 correctif, 0x12 correctif de sécurité.
$UpdateMinors = @(0x2, 0x3, 0x10, 0x11, 0x12)

$hwFormats = [string[]]@('dd.MM.yyyy HH:mm:ss.fff','dd.MM.yyyy HH:mm:ss','dd/MM/yyyy HH:mm:ss.fff','dd/MM/yyyy HH:mm:ss','yyyy-MM-dd HH:mm:ss.fff','yyyy-MM-dd HH:mm:ss')

function Get-EvData($ev) {
    $h = @{}
    try {
        $x = [xml]$ev.ToXml()
        foreach ($d in @($x.Event.EventData.Data)) {
            if ($d.Name) { $h[[string]$d.Name] = [string]$d.'#text' }
        }
    } catch { }
    return $h
}

function ConvertTo-UInt32Safe($v) {
    if ($null -eq $v) { return $null }
    $s = ([string]$v).Trim()
    $u = [uint32]0
    if ($s -match '^0x([0-9a-fA-F]{1,8})$') {
        if ([uint32]::TryParse($Matches[1], 'AllowHexSpecifier', $ci, [ref]$u)) { return $u }
        return $null
    }
    if ([uint32]::TryParse($s, 'Integer', $ci, [ref]$u)) { return $u }
    return $null
}

# Code BugCheck (hors 0) lu dans les propriétés structurées de l'événement 41 ou 1001.
function Get-BugCheckCode($ev) {
    if ($ev.ProviderName -eq $PROV_POWER -and $ev.Id -eq 41) {
        $d = Get-EvData $ev
        if ($d.ContainsKey('BugcheckCode')) {
            $c = ConvertTo-UInt32Safe $d['BugcheckCode']
            if ($c) { return $c }
        }
        return $null
    }
    if ($ev.ProviderName -eq $PROV_WER -and $ev.Id -eq 1001) {
        $v = $null
        try { $v = [string]$ev.Properties[0].Value } catch { return $null }
        if ($v -match '0x([0-9a-fA-F]{1,8})') {
            $c = ConvertTo-UInt32Safe ('0x' + $Matches[1])
            if ($c) { return $c }
        }
    }
    return $null
}

# 1001 (WER-SystemErrorReporting) signalant un bugcheck : code lisible dans les propriétés, sinon repli sur le message.
function Test-IsBugcheck1001($ev) {
    if (-not ($ev.ProviderName -eq $PROV_WER -and $ev.Id -eq 1001)) { return $false }
    if (Get-BugCheckCode $ev) { return $true }
    $m = [string]$ev.Message
    return [bool]($m -match 'bug\s?check|v[ée]rification de bogue')
}

# Signaux d'arrêt anormal (spec §5).
function Test-IsAbnormalEvent($ev) {
    if ($ev.ProviderName -eq $PROV_POWER -and $ev.Id -eq 41) { return $true }
    if ($ev.ProviderName -eq $PROV_EVLOG -and $ev.Id -eq 6008) { return $true }
    return (Test-IsBugcheck1001 $ev)
}

# Événements écrits au démarrage suivant : rattachés à la session précédente (spec §7).
function Test-AttachedToPrevious($ev) {
    if (Test-IsAbnormalEvent $ev) { return $true }
    return ($ev.ProviderName -eq $PROV_WHEA -and ($WheaFatalIds -contains $ev.Id))
}

function Test-IsNormalCloseEvent($ev) {
    if ($ev.ProviderName -eq $PROV_GENERAL -and $ev.Id -eq 13) { return $true }
    return ($ev.ProviderName -eq $PROV_EVLOG -and $ev.Id -eq 6006)
}

# Type de fermeture d'après le dernier User32 1074 rattaché à la session (spec §6).
function Get-ClosureType($attached) {
    $e = @($attached | Where-Object { $_.ProviderName -eq $PROV_USER32 -and $_.Id -eq 1074 }) |
         Sort-Object RecordId | Select-Object -Last 1
    if (-not $e) { return 'Non déterminé' }
    $proc = ''; $codeS = ''; $action = ''
    try {
        $p = $e.Properties
        $proc   = [string]$p[0].Value
        $codeS  = [string]$p[3].Value
        $action = [string]$p[4].Value
    } catch { return 'Non déterminé' }

    $upd = $false
    if ($proc -match $UpdateProcRegex) { $upd = $true }
    $c = ConvertTo-UInt32Safe $codeS
    if ($null -ne $c) {
        $c = [long]$c
        $planned = (($c -band 2147483648) -ne 0)
        $major = ($c -shr 16) -band 0x7FFF
        $minor = $c -band 0xFFFF
        if ($planned -and $major -eq 2 -and ($UpdateMinors -contains [int]$minor)) { $upd = $true }
    }
    if ($upd) { return 'Mise à jour' }
    if ($action -match '(?i)restart|reboot|red[ée]marr') { return 'Redémarrage' }
    if ($action -match '(?i)shut\s?down|power\s?off|arr[êe]t|[ée]teind|extinction|hors tension') { return 'Arrêt volontaire' }
    return 'Non déterminé'
}

# État et type de fermeture d'une session d'après ses événements rattachés (spec §5 et §6).
function Get-SessionClassification($attached) {
    $attached = @($attached)
    $abn  = @($attached | Where-Object { Test-IsAbnormalEvent $_ })
    $norm = @($attached | Where-Object { Test-IsNormalCloseEvent $_ } | Sort-Object RecordId)
    $code = $null
    foreach ($e in (@($abn | Where-Object { $_.Id -eq 41 }) + @($abn | Where-Object { $_.Id -eq 1001 }))) {
        if (-not $code) { $code = Get-BugCheckCode $e }
    }
    $etat = 'Indéterminé'
    if ($abn.Count -gt 0) { $etat = 'Anormal' } elseif ($norm.Count -gt 0) { $etat = 'Normal' }
    $type = Get-ClosureType $attached
    $label = $type
    if ($etat -ne 'Normal' -and $type -ne 'Non déterminé') { $label = "$type ?" }
    [pscustomobject]@{
        Etat      = $etat
        BugCheck  = $code
        CloseEv   = ($norm | Select-Object -Last 1)
        Type      = $type
        TypeLabel = $label
    }
}

function Get-EtatLibelle($cls) {
    switch ($cls.Etat) {
        'Normal'      { return 'Arrêt normal' }
        'Anormal'     {
            if ($cls.BugCheck) { return ('Arrêt anormal (BugCheck 0x{0:X8})' -f $cls.BugCheck) }
            return 'Arrêt anormal'
        }
        default       { return 'Indéterminé' }
    }
}

function New-RidXPath([long]$From, $To = $null, [int[]]$Ids = @()) {
    $c = @("EventRecordID >= $From")
    if ($null -ne $To) { $c += "EventRecordID < $To" }
    if ($Ids.Count -gt 0) { $c = @('(' + (($Ids | ForEach-Object { "EventID=$_" }) -join ' or ') + ')') + $c }
    return ('*[System[' + ($c -join ' and ') + ']]')
}

# Démarrages (Kernel-General 12), du plus récent au plus ancien, par ordre d'enregistrement (RecordId).
function Get-BootEvents([int]$Max) {
    $f = @{ LogName = 'System'; ProviderName = $PROV_GENERAL; Id = 12 }
    if ($Max -gt 0) {
        $r = @(Get-WinEvent -FilterHashtable $f -MaxEvents $Max -ErrorAction SilentlyContinue)
    } else {
        $r = @(Get-WinEvent -FilterHashtable $f -ErrorAction SilentlyContinue)
    }
    return @($r | Where-Object { $null -ne $_.RecordId -and $null -ne $_.TimeCreated } | Sort-Object RecordId -Descending)
}

function New-SessionObjects($bootEvs) {
    $res = @()
    for ($i = 0; $i -lt $bootEvs.Count; $i++) {
        $b = $bootEvs[$i]
        $endRid = [long]::MaxValue
        $endUtc = $null
        if ($i -gt 0) { $endRid = [long]$bootEvs[$i - 1].RecordId; $endUtc = $bootEvs[$i - 1].TimeCreated.ToUniversalTime() }
        $res += [pscustomobject]@{
            Index    = (-$i)
            Pos      = $i
            Start    = $b.TimeCreated
            StartUtc = $b.TimeCreated.ToUniversalTime()
            StartRid = [long]$b.RecordId
            EndRid   = $endRid
            EndUtc   = $endUtc
        }
    }
    return $res
}

# Dernier événement (ordre d'enregistrement) de la session, hors événements écrits au démarrage suivant.
function Get-LastActivityEvent([long]$StartRid, [long]$EndRid) {
    $evs = @(Get-WinEvent -LogName System -FilterXPath (New-RidXPath $StartRid $EndRid) -MaxEvents 30 -ErrorAction SilentlyContinue)
    foreach ($e in @($evs | Sort-Object RecordId -Descending)) {
        if (-not (Test-AttachedToPrevious $e)) { return $e }
    }
    return $null
}

# Durée en UTC (spec §8). Estimated = borne inférieure.
function Get-SessionDuration($s, $cls, $lastEv) {
    $end = $null; $est = $false
    try {
        if ($cls.Etat -eq 'Normal' -and $cls.CloseEv) {
            $end = $cls.CloseEv.TimeCreated.ToUniversalTime()
        } elseif ($lastEv) {
            $end = $lastEv.TimeCreated.ToUniversalTime(); $est = $true
        }
    } catch { $end = $null }
    $span = $null
    if ($end) {
        $span = $end - $s.StartUtc
        if ($span.Ticks -lt 0) { $span = $null }
    }
    [pscustomobject]@{ Span = $span; Estimated = $est }
}

function Format-Duree($span, [bool]$est = $false) {
    if ($null -eq $span) { return '—' }
    $t = '{0:00}h{1:00}' -f [math]::Floor($span.TotalHours), $span.Minutes
    if ($est) { return "≥ $t" }
    return $t
}

function Show-Sessions([int]$Max) {
    $boots = @(Get-BootEvents $Max)
    if ($boots.Count -eq 0) {
        Write-Host 'Aucun démarrage (Kernel-General 12) trouvé dans le journal Système.'
        return
    }
    $ss = @(New-SessionObjects $boots)

    # Événements utiles à la classification, depuis le plus ancien démarrage affiché.
    $ids = @(13, 41, 1001, 1074, 6006, 6008)
    $xp = New-RidXPath $ss[$ss.Count - 1].StartRid $null $ids
    $provOk = @($PROV_GENERAL, $PROV_POWER, $PROV_WER, $PROV_EVLOG, $PROV_USER32)
    $evs = @(Get-WinEvent -LogName System -FilterXPath $xp -ErrorAction SilentlyContinue |
             Where-Object { $provOk -contains $_.ProviderName })

    $bk = @{}
    foreach ($s in $ss) { $bk[$s.Pos] = New-Object 'System.Collections.Generic.List[object]' }
    foreach ($e in $evs) {
        try {
            $rid = [long]$e.RecordId
            $pos = -1
            for ($j = 0; $j -lt $ss.Count; $j++) {
                if ($rid -ge $ss[$j].StartRid -and $rid -lt $ss[$j].EndRid) { $pos = $j; break }
            }
            if ($pos -lt 0) { continue }
            $t = $pos
            if (Test-AttachedToPrevious $e) { $t = $pos + 1 }   # écrit au démarrage suivant : session précédente
            if ($t -ge $ss.Count) { continue }
            $bk[$t].Add($e)
        } catch { }
    }

    Write-Host ('{0,6}  {1,-14}  {2,9}  {3,-36}  {4}' -f 'Indice', 'Début', 'Durée', 'État', 'Type')
    $nowUtc = (Get-Date).ToUniversalTime()
    foreach ($s in $ss) {
        $debut = $s.Start.ToString('dd/MM/yy HH:mm', $ci)
        try {
            if ($s.Pos -eq 0) {
                $dur = Format-Duree ($nowUtc - $s.StartUtc) $false
                Write-Host ('{0,6}  {1,-14}  {2,9}  {3,-36}  {4}' -f $s.Index, $debut, $dur, 'En cours', '—') -ForegroundColor Cyan
                continue
            }
            $cls = Get-SessionClassification ($bk[$s.Pos].ToArray())
            $lastEv = $null
            if ($cls.Etat -ne 'Normal') { $lastEv = Get-LastActivityEvent $s.StartRid $s.EndRid }
            $d = Get-SessionDuration $s $cls $lastEv
            $color = 'Yellow'
            if ($cls.Etat -eq 'Normal') { $color = 'Green' } elseif ($cls.Etat -eq 'Anormal') { $color = 'Red' }
            Write-Host ('{0,6}  {1,-14}  {2,9}  {3,-36}  {4}' -f $s.Index, $debut, (Format-Duree $d.Span $d.Estimated), (Get-EtatLibelle $cls), $cls.TypeLabel) -ForegroundColor $color
        } catch {
            Write-Host ('{0,6}  {1,-14}  {2,9}  {3,-36}  {4}' -f $s.Index, $debut, '—', 'Indéterminé', 'Non déterminé') -ForegroundColor Yellow
        }
    }
    Write-Host ''
    Write-Host 'Heures locales ; durées calculées en UTC (≥ : borne inférieure estimée). Indices relatifs : à relire après chaque redémarrage.'
}

# Analyse d'un CSV HWiNFO limitée à la période [StartUtc, EndUtc) (spec §9). Lecture en partage, aucune écriture.
function Get-HwinfoPeriodInfo([string]$Path, [datetime]$StartUtc, [datetime]$EndUtc, [int]$Keep = 40) {
    $fs = $null; $sr = $null
    try {
        $fs = New-Object System.IO.FileStream($Path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
        $sr = New-Object System.IO.StreamReader($fs, [System.Text.Encoding]::Default, $true)
        $header = $sr.ReadLine()
        if (-not $header) { return $null }
        $nCols = $header.Split(',').Length
        $queue = New-Object 'System.Collections.Generic.Queue[string]'
        $count = 0; $lastTs = $null; $lastUtc = $null
        $stop = $EndUtc.AddHours(2)   # marge d'arrêt de lecture seulement (heure d'été) ; fichiers supposés chronologiques
        while ($null -ne ($line = $sr.ReadLine())) {
            $i1 = $line.IndexOf(',')
            if ($i1 -lt 1) { continue }
            $i2 = $line.IndexOf(',', $i1 + 1)
            if ($i2 -lt 0) { continue }
            $d = $line.Substring(0, $i1).Trim('"', ' ')
            $t = $line.Substring($i1 + 1, $i2 - $i1 - 1).Trim('"', ' ')
            $ts = [datetime]::MinValue
            if (-not [datetime]::TryParseExact("$d $t", $hwFormats, $ci, 'None', [ref]$ts)) {
                $ts = ConvertFrom-HwinfoStamp $d $t
                if (-not $ts) { continue }
            }
            $u = $ts.ToUniversalTime()
            if ($u -lt $StartUtc) { continue }
            if ($u -ge $EndUtc) {
                if ($u -ge $stop) { break }
                continue
            }
            if ($line.Split(',').Length -ne $nCols) { continue }   # ligne tronquée par le crash
            $count++
            $lastTs = $ts; $lastUtc = $u
            $queue.Enqueue($line)
            if ($queue.Count -gt $Keep) { [void]$queue.Dequeue() }
        }
        return [pscustomobject]@{ Header = $header; Count = $count; LastTs = $lastTs; LastUtc = $lastUtc; Lines = @($queue.ToArray()) }
    } finally {
        if ($sr) { $sr.Dispose() }
        if ($fs) { $fs.Dispose() }
    }
}

# --- Aiguillage des modes ------------------------------------------------------
$modeSessions = [bool]$Sessions
$modeSession  = $PSBoundParameters.ContainsKey('Session')

if ($modeSessions -and $modeSession) {
    Stop-Collecte '-Sessions (affichage) et -Session (collecte) sont exclusifs.'
}

if ($modeSessions) {
    # « -Sessions 10 » : PowerShell lie le « 10 » au premier paramètre positionnel libre.
    $sessionsMax = 0
    if ($PSBoundParameters.ContainsKey('HwinfoDir') -and $HwinfoDir -match '^\d+$') {
        $sessionsMax = [int]$HwinfoDir
    } elseif ($PSBoundParameters.ContainsKey('OutDir') -and $OutDir -match '^\d+$') {
        $sessionsMax = [int]$OutDir
    }
    Show-Sessions $sessionsMax
    return
}

# --- Repères de démarrage -----------------------------------------------------
$incident = $null
$source = ''
$estime = $false
$hw = $null
$hwHeader = $null
$hwLines = @()
$hwNote = ''
$cls = $null
$sessEvents = @()
$actA = @()
$markUpper = $null

if ($modeSession) {
    # ---- Collecte sur la session sélectionnée (spec §9, §10) ----
    if ($Session -ge 0) {
        Stop-Collecte "Indice de session invalide ($Session) : la session 0 (en cours) n'est pas sélectionnable ; utiliser -1, -2, ..."
    }
    $k = -$Session
    $bootsSel = @(Get-BootEvents ($k + 1))
    if ($bootsSel.Count -lt ($k + 1)) {
        Stop-Collecte "Session $Session introuvable : le journal Système ne contient que $($bootsSel.Count) démarrage(s) (Kernel-General 12). Aucun remplacement automatique."
    }
    $bStart = $bootsSel[$k]
    $bNext  = $bootsSel[$k - 1]
    $rA = [long]$bStart.RecordId
    $rB = [long]$bNext.RecordId
    if ($rB -le $rA) {
        Stop-Collecte "Session $Session : bornes incohérentes (ordre d'enregistrement). Collecte annulée."
    }
    $prevBoot = $bStart.TimeCreated
    $boot     = $bNext.TimeCreated
    $sessStartUtc = $prevBoot.ToUniversalTime()
    $sessEndUtc   = $boot.ToUniversalTime()

    $upper = $null
    if ($k -ge 2) { $upper = [long]$bootsSel[$k - 2].RecordId; $markUpper = $bootsSel[$k - 2].TimeCreated }

    # A : événements enregistrés pendant la session. B : événements de fermeture anormale écrits au démarrage suivant.
    $evA = @(Get-WinEvent -LogName System -FilterXPath (New-RidXPath $rA $rB) -ErrorAction SilentlyContinue)
    $evB = @(Get-WinEvent -LogName System -FilterXPath (New-RidXPath $rB $upper (@(41, 6008, 1001) + $WheaFatalIds)) -ErrorAction SilentlyContinue)
    $actA = @($evA | Where-Object { -not (Test-AttachedToPrevious $_) })
    $sessEvents = @($actA) + @($evB | Where-Object { Test-AttachedToPrevious $_ })

    $cls = Get-SessionClassification $sessEvents
    $lastEv = $actA | Sort-Object RecordId -Descending | Select-Object -First 1

    # CSV HWiNFO : sélection sur le contenu (spec §9).
    $cands = @(Get-ChildItem -Path $HwinfoDir -Filter 'hwinfo*.csv' -File -ErrorAction SilentlyContinue |
               Where-Object { $_.LastWriteTimeUtc -ge $sessStartUtc })   # un fichier dont la dernière écriture précède le début ne peut contenir de mesure de la session
    $res = @()
    foreach ($f in $cands) {
        try {
            $info = Get-HwinfoPeriodInfo $f.FullName $sessStartUtc $sessEndUtc
            if ($info -and $info.Count -gt 0) {
                $res += [pscustomobject]@{ File = $f; Info = $info; LastUtc = $info.LastUtc }
            }
        } catch { }
    }
    $best = $res | Sort-Object @{ Expression = { $_.LastUtc }; Descending = $true },
                               @{ Expression = { $_.File.LastWriteTimeUtc }; Descending = $true },
                               @{ Expression = { $_.File.Name }; Descending = $true } | Select-Object -First 1
    if ($best) {
        $hw = $best.File
        $hwHeader = $best.Info.Header
        $hwLines = @($best.Info.Lines)
    } else {
        $hwNote = 'Aucun journal HWiNFO ne contient de mesure dans la période de la session.'
    }

    # Heure de l'incident.
    if ($cls.Etat -eq 'Normal' -and $cls.CloseEv) {
        $incident = $cls.CloseEv.TimeCreated
        $source = "Événement de fermeture normale ($($cls.CloseEv.ProviderName) $($cls.CloseEv.Id)) rattaché à la session"
    } elseif ($best) {
        $incident = $best.Info.LastTs
        $source = "Dernière ligne valide du journal HWiNFO ($($hw.Name)) dans la période de la session"
    } else {
        $estime = $true
        if ($lastEv) {
            $incident = $lastEv.TimeCreated
            $source = "ESTIMÉE (borne basse) : dernier événement du journal Système de la session (par ordre d'enregistrement)"
        } else {
            $incident = $prevBoot
            $source = "ESTIMÉE : début de la session (aucun repère trouvé)"
        }
    }
} else {
    # ---- Comportement historique (sans -Session) ----
    $boot = (Get-CimInstance Win32_OperatingSystem).LastBootUpTime
    $boots = @(Get-WinEvent -FilterHashtable @{LogName='System'; ProviderName='Microsoft-Windows-Kernel-General'; Id=12} -MaxEvents 4 -ErrorAction SilentlyContinue)
    $prevBootEv = $boots | Where-Object { $_.TimeCreated -lt $boot.AddMinutes(-1) } | Select-Object -First 1
    $prevBoot = if ($prevBootEv) { $prevBootEv.TimeCreated } else { $null }

    # --- Détermination de l'heure de l'incident -------------------------------------
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
}

# Marqueur des fichiers récents (dumps, LiveKernelReports).
function Get-FileMark([datetime]$t) {
    if ($modeSession) {
        if ($t -ge $prevBoot -and (-not $markUpper -or $t -lt $markUpper)) { return '  <-- SESSION' }
        return ''
    }
    if ($prevBoot -and $t -gt $prevBoot) { return '  <-- NOUVEAU' }
    return ''
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
if ($modeSession) {
    L "- **Session analysée :** indice $Session"
    L "- **Période de la session (UTC) :** $($sessStartUtc.ToString('yyyy-MM-dd HH:mm:ss', $ci))Z → $($sessEndUtc.ToString('yyyy-MM-dd HH:mm:ss', $ci))Z"
    L "- **État de fermeture :** $(Get-EtatLibelle $cls)"
    if ($cls.Type -ne 'Non déterminé') { L "- **Type de fermeture :** $($cls.TypeLabel)" }
}
$lblBoot = if ($modeSession) { 'Démarrage suivant (Kernel-General 12)' } else { 'Démarrage suivant (LastBootUpTime)' }
L "- **${lblBoot} :** $('{0:dd/MM/yyyy HH:mm:ss}' -f $boot) (soit $([math]::Round(($boot.ToUniversalTime() - $incident.ToUniversalTime()).TotalMinutes, 1)) min après l'incident)"
if ($prevBoot) {
    $lblPrev = if ($modeSession) { 'Début de la session (Kernel-General 12)' } else { 'Démarrage précédent (Kernel-General 12, indicatif)' }
    L "- **${lblPrev} :** $('{0:dd/MM/yyyy HH:mm:ss}' -f $prevBoot)"
    L "- **Uptime au moment de l'incident :** $([math]::Round(($incident.ToUniversalTime() - $prevBoot.ToUniversalTime()).TotalHours, 2)) h"
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
if ($modeSession) { L '## Événement Kernel-Power 41 (rattaché à la session)' } else { L '## Événement Kernel-Power 41 (le plus récent)' }
L ''
if ($modeSession) {
    $e41 = @($sessEvents | Where-Object { $_.ProviderName -eq $PROV_POWER -and $_.Id -eq 41 }) | Sort-Object RecordId -Descending | Select-Object -First 1
} else {
    $e41 = Get-WinEvent -FilterHashtable @{LogName='System'; ProviderName='Microsoft-Windows-Kernel-Power'; Id=41} -MaxEvents 1 -ErrorAction SilentlyContinue
}
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
if ($modeSession) {
    $e6008 = @($sessEvents | Where-Object { $_.ProviderName -eq $PROV_EVLOG -and $_.Id -eq 6008 }) | Sort-Object RecordId -Descending | Select-Object -First 1
} else {
    $e6008 = Get-WinEvent -FilterHashtable @{LogName='System'; ProviderName='EventLog'; Id=6008} -MaxEvents 1 -ErrorAction SilentlyContinue
}
if ($e6008) {
    $msg6008 = (($e6008.Message -split "`r?`n")[0]) -replace '[\u200E\u200F\u202A\u202B\u202C\u202D\u202E]', ''
    L ('- 6008 enregistré à {0:dd/MM/yyyy HH:mm:ss} : {1}' -f $e6008.TimeCreated, $msg6008)
} else {
    L '- Aucun 6008.'
}
L "- Rappel : l’heure citée dans le 6008 est un repère mis à jour périodiquement, **pas** l’heure réelle du gel."
if ($modeSession) {
    $e1001 = @($sessEvents | Where-Object { Test-IsBugcheck1001 $_ }) | Sort-Object RecordId -Descending | Select-Object -First 1
} else {
    $e1001 = Get-WinEvent -FilterHashtable @{LogName='System'; ProviderName='Microsoft-Windows-WER-SystemErrorReporting'; Id=1001; StartTime=$boot.AddMinutes(-1)} -MaxEvents 1 -ErrorAction SilentlyContinue
}
if ($e1001) {
    L ('- BugCheck 1001 : ' + (($e1001.Message -split "`r?`n")[0]))
} elseif ($modeSession) {
    L '- Aucun BugCheck 1001 rattaché à cette session : pas de BSOD enregistré par Windows.'
} else {
    L '- Aucun BugCheck 1001 depuis le démarrage : pas de BSOD enregistré par Windows.'
}
if ($modeSession -and $cls.BugCheck) { L ('- Code BugCheck : 0x{0:X8}' -f $cls.BugCheck) }
L ''

# Journal Système avant l'incident
L "## Journal Système : erreurs et avertissements dans les $Fenetre min avant l'incident"
L ''
if ($modeSession) {
    $tmin = $incident.AddMinutes(-$Fenetre)
    $ctx = @($actA | Where-Object { ($_.Level -in 1, 2, 3) -and $_.TimeCreated -ge $tmin } | Sort-Object RecordId)
} else {
    $ctx = @(Get-WinEvent -FilterHashtable @{LogName='System'; StartTime=$incident.AddMinutes(-$Fenetre); EndTime=$boot; Level=1,2,3} -ErrorAction SilentlyContinue | Sort-Object TimeCreated)
}
L $fence
if ($ctx.Count -gt 0) { $ctx | Select-Object -Last 80 | ForEach-Object { L (Format-Ev $_) } } else { L '(aucun)' }
L $fence
L ''

# Session plantée : WHEA, Display, alimentation
$since = if ($prevBoot) { $prevBoot } else { $boot.AddDays(-1) }
L '## Session plantée : WHEA-Logger et Display (tous niveaux)'
L ''
L $fence
if ($modeSession) {
    $hardw = @($sessEvents | Where-Object { $_.ProviderName -eq $PROV_WHEA -or $_.ProviderName -eq 'Display' } | Sort-Object RecordId)
} else {
    $hardw = @(Get-WinEvent -FilterHashtable @{LogName='System'; ProviderName='Microsoft-Windows-WHEA-Logger'; StartTime=$since; EndTime=$boot} -ErrorAction SilentlyContinue) +
             @(Get-WinEvent -FilterHashtable @{LogName='System'; ProviderName='Display'; StartTime=$since; EndTime=$boot} -ErrorAction SilentlyContinue)
    $hardw = @($hardw | Sort-Object TimeCreated)
}
if ($hardw.Count -gt 0) { $hardw | Select-Object -Last 40 | ForEach-Object { L (Format-Ev $_) } } else { L '(aucun)' }
L $fence
L ''

L "## Session plantée : source d'alimentation et veille (derniers événements)"
L ''
L $fence
if ($modeSession) {
    $pw = @($sessEvents | Where-Object {
            ($_.ProviderName -eq $PROV_POWER -and (42, 105, 107, 506, 507) -contains $_.Id) -or
            ($_.ProviderName -eq 'Microsoft-Windows-Power-Troubleshooter' -and $_.Id -eq 1)
        } | Sort-Object RecordId)
} else {
    $pw = @(Get-WinEvent -FilterHashtable @{LogName='System'; ProviderName='Microsoft-Windows-Kernel-Power'; Id=42,105,107,506,507; StartTime=$since; EndTime=$boot} -ErrorAction SilentlyContinue) +
          @(Get-WinEvent -FilterHashtable @{LogName='System'; ProviderName='Microsoft-Windows-Power-Troubleshooter'; Id=1; StartTime=$since; EndTime=$boot} -ErrorAction SilentlyContinue)
    $pw = @($pw | Sort-Object TimeCreated)
}
if ($pw.Count -gt 0) { $pw | Select-Object -Last 14 | ForEach-Object { L (Format-Ev $_) } } else { L '(aucun : pas de changement de source ni de veille dans la session)' }
L $fence
L ''

# Minidump
L '## Fichiers Minidump'
L ''
if ($modeSession) {
    L 'Marqueur SESSION : fichier écrit entre le début de la session et le début de la session suivant celle qui la suit (un dump est écrit au démarrage consécutif au crash).'
    L ''
}
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
    $mini | ForEach-Object { L ('Minidump  {0:dd/MM/yyyy HH:mm:ss}  {1,8:N0} Ko  {2}{3}' -f $_.LastWriteTime, ($_.Length / 1KB), $_.Name, (Get-FileMark $_.LastWriteTime)) }
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
    $lkr | ForEach-Object { L ('LiveKernelReports  {0:dd/MM/yyyy HH:mm:ss}  {1}{2}' -f $_.LastWriteTime, $_.FullName.Replace('C:\Windows\LiveKernelReports\', ''), (Get-FileMark $_.LastWriteTime)) }
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
    L ('- Dernière ligne valide : {0:dd/MM/yyyy HH:mm:ss}' -f $(if ($modeSession) { $best.Info.LastTs } else { $incident }))
    L "- Copie des $($hwLines.Count) dernières lignes (+ en-tête) : $(Split-Path $csvOut -Leaf)"
} else {
    L '- Aucune donnée HWiNFO exploitable pour cet incident.'
}

Set-Content -Path $report -Value $o -Encoding UTF8
Write-Host "Rapport : $report"
if ($hwLines.Count -gt 0) {
    Write-Host "HWiNFO  : $csvOut"
}
