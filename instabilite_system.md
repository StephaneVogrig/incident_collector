# Instabilités Système

**Dernière mise à jour :** 21 octobre 2026 09h49

**Matériel :** ASUS ROG Strix G713QM (Ryzen 9 5900HX, RTX 3060, BIOS G713QM.331). Acheté neuf en novembre 2021, repris d'occasion en juin 2022 : **hors garantie**.
**Systèmes :** Dual-boot Windows 11 Famille (25H2) / Ubuntu 22.04 LTS (noyau `6.8.0-138`, Secure Boot ; noyau `6.8.0-136` conservé dans GRUB en filet de sécurité ; pilote `nvidia-driver-595-open`).
**Affichage :** écran interne et HDMI externe sur l'iGPU AMD (`card2`, `06:00.0`) ; la RTX 3060 (`card1`, `01:00.0`) ne pilote aucun écran.
**Méthode :** une seule action à la fois ; lecture seule / collecte de données avant toute modification du système.

---

## 1. Chronologie : Événements et Actions

Étiquettes : **Incident** · **Action** · **Résultat**.

### Avril – Juillet 2026
* **09/04 — Incident :** minidump Windows `040926-10609-01.dmp` (supprimé depuis).
* **Mai — Incident :** début des freezes sous Linux.
* **07/06 — Incident :** minidump Windows `060726-11093-01.dmp`.
* **20/06 — Incident :** BSOD `0x3B` (`SYSTEM_SERVICE_EXCEPTION`), minidump `062026-12812-01.dmp`.
* **12/07 — Incident :** BSOD `0x9F` (`DRIVER_POWER_STATE_FAILURE`).

### Août – Septembre 2026
* **01/08 — Incident :** BSOD `0xBE` (`ATTEMPTED_WRITE_TO_READONLY_MEMORY`), minidump `080126-13812-01.dmp`.
* **21/08, 25/08, 10/09, 24/09 — Incident :** coupures brutes Windows (`Kernel-Power 41`, `BugcheckCode = 0`).

### Interventions Linux (dates non consignées, antérieures au 11/10)
* **Action :** `processor.max_cstate=1` dans GRUB (toujours actif). **Résultat :** amélioration très nette des gels, mais non totale. Initialement noté « gels réglés », infirmé par l'incident du 11-12/10.
* **Action :** installation de `nvidia-driver-595-open` et `linux-modules-nvidia-595-open-generic-hwe-22.04` (modules signés Canonical, pas de MOK). **Résultat :** `nvidia-smi` OK, `nouveau` bloqué et absent de `lsmod`, aucune erreur graphique dans `journalctl -b -p err`.
* **Action :** `prime-select on-demand`. **Résultat :** NVIDIA `suspended` au repos, réveil à la demande (offload testé avec `glxinfo`).
* **Action :** nettoyage (`apt autoremove`, 4 paquets, 125 Mo) ; paquets `xserver-xorg-video-nouveau` et `libdrm-nouveau2` conservés volontairement.

### Octobre 2026
* **11/10 vers 15:2x, 15:30, 22:59 et 12/10 vers 00:01 — Incident :** 4 gels silencieux sous Linux, malgré `max_cstate=1`.
  * 15:2x : gel en session, redémarrage forcé.
  * 15:30 : portable noir, écran externe vert. Seule trace : `snd_hda_intel 06:00.1: Refused to change power state from D0 to D3hot` (une occurrence ; `06:00.1` = audio de l'iGPU AMD).
  * 22:59 : gel après ~6 h stables ; clavier, Verr. Maj et SysRq inopérants.
  * 00:01 : blocage à l'ouverture de session (deux écrans noirs) après un démarrage normal.
  * Aucune trace `amdgpu`, `nvidia`, `NVRM`, `Xid` ou `drm`.
* **Après l'incident (date non consignée) — Action :** analyse des logs. **Résultat :**
  * L'extension Chrome *Adblock Unlimited 1.1.13* bouclait sur `DidStartWorkerFail` : `syslog` à 17 Go, `journald` saturé (96 184 messages supprimés), donc **logs des gels potentiellement effacés** (l'absence de trace est à relativiser). Extension supprimée, `syslog` vidé, 32 Go libres.
  * `max_cstate=1` confirmé appliqué (seuls `POLL` et `C1` existent).
  * Gestion d'énergie dynamique NVIDIA à `0x02` dans deux fichiers (état actuel non consigné).
* **15/10 — Action :** essais côté Linux (analyse du `.crash`, piste du reset `MODE2` pour `amdgpu`). Résultat non consigné.
* **18/10 — Incident :** plantage Windows sur secteur, plus de 7 h après un réveil de veille.
* **19/10 — Incident :**
  * 15:05 : coupure brute sur batterie à ~7 % (événement 41, `CsEntryScenarioInstanceId = 3`).
  * Deux autres coupures brutes sur batterie, quelques minutes après sortie de veille moderne.
  * BSOD `0x00020001` (`HYPERVISOR_ERROR`), minidump `101926-29828-01.dmp`.
* **20/10 — Action :** MemTest86 sur une nuit complète. **Résultat :** 0 erreur (le Diagnostic Mémoire Windows, non daté, est aussi sans erreur).
* **20/10 — Action :** mesure de la batterie et `powercfg /energy`. **Résultat :** capacité ~66 % de l'origine (usure 33,9 % confirmée par HWiNFO le 21/10) ; aucun conflit de pilote ni réglage d'alimentation anormal.
* **21/10 11:52 — Incident :** redémarrage inopiné sur batterie (56 %), machine au repos (événement 41, `CsEntryScenarioInstanceId = 4`). **Résultat de l'analyse HWiNFO :** températures stables (41–46 °C), aucun throttling, 0 erreur PCIe/disque.
* **21/10 ≈ 13:52 — Incident :** freeze complet puis écran noir sous Windows, arrêt forcé. **Sur secteur**, ~2 h après le redémarrage de 11:53, **sans aucune veille depuis**, en navigation web (charge quasi nulle). Événement 41 à 13:53:41 (`BugcheckCode = 0`, `CsEntryScenarioInstanceId = 0`). Reflète les symptômes Linux.
  * **Action :** analyse du journal HWiNFO (`hwinfo_3.csv`, conservé comme preuve) et de l'Observateur d'événements (13:30–14:15).
  * **Résultat :** aucun signe avant-coureur ; CPU 3–9 % ; thermique, alimentation et limitations normaux ; **cœurs presque tous en C6 juste avant le gel** (seul élément notable) ; 0 erreur PCIe, `Recovery Count` du dGPU stable à 10 ; aucun événement `WHEA-Logger`, aucun TDR / `Display`. L'horodatage de l'événement `EventLog 6008` (13:39:49) n'est **pas** l'heure du gel.
  * **Après :** HWiNFO relancé dans un nouveau fichier.
* **21/10 16:02:19 — Incident :** freeze complet sur secteur, 2 h 09 après le démarrage de 13:53, sans veille ni changement de source. Bugcheck 0x00020001 (HYPERVISOR_ERROR, 0x32, 0x1, 0, 0), redémarrage automatique à 16:04:52, minidump 102126-20765-01.dmp. Journal Système (30 min), WHEA-Logger et Display : rien. HWiNFO (hwinfo_4.csv) : CPU 2–4 %, 53–58 °C, 0 erreur PCIe, Recovery Count 16. Dernier échantillon : pic de boost (cœurs 6/7 à 4,44 GHz, ~1,3 V) après repos profond en C6. Antérieur au test IDLEDISABLE de 19h15.
*Remarques :* 15 événements `Kernel-Power 41` entre le 20/06 et le 21/10 16:05 (recompté ; aucun avant le 20/06). 5 ont un code d'erreur explicite, pour 4 codes distincts : `0x3B` (20/06), `0x9F` (12/07, sans minidump), `0xBE` (01/08) et `0x20001` (19/10 et 21/10 16:02) ; les autres sont des coupures brutes (`BugcheckCode = 0`). Le dossier `C:\Windows\Minidump\` contient 5 fichiers (`060726-11093-01`, `062026-12812-01`, `080126-13812-01`, `101926-29828-01`, `102126-20765-01`) ; celui du 09/04 (`040926-10609-01`) a disparu. Ils ne couvrent que les BSOD et ne sont pas encore analysés avec WinDbg (priorité : les deux `HYPERVISOR_ERROR` des 19/10 et 21/10). Des `LiveKernelReports` (WATCHDOG 06/10, 25/09, 26/01 ; AMD_REPORT_UM 25/09) sont aussi présents et non analysés.
* **23/10 ≈ 19:11 (heure réelle ; journal : 21:11, RTC décalée de +2 h) — Incident :** gel Linux (`6.8.0-138`, `tsc=nowatchdog processor.max_cstate=1`), sur secteur, démarrage depuis Windows. Boot 19:10:49, session GNOME (X11) ouverte à 19:11:01, dernier message journalisé 19:11:07 (uptime 22 s, borne basse). Gel dans une fenêtre de l'explorateur de fichiers, Verr. Maj inopérant.
  * **Résultat (`collecte_incident_linux.sh` v2.3) :** aucun message `amdgpu`, `nvidia`, `Xid`, `MCE`, `AER`, `hung task`, erreur NVMe/NTFS ; `pstore` et `/var/crash` vides. Seules anomalies : `usb 3-2: device descriptor read/64, error -110` (1 occurrence, 19:11:02, périphérique non identifié), `atkbd serio0: Failed to deactivate/enable keyboard` au démarrage (à comparer à un boot sain), deux `(EE)` Xorg probablement bénins. Machine vivante à 19:11:07, gel dans la minute suivante. Pilote NVIDIA non chargé (`prime-select` = `intel`) : NVIDIA hors de cause pour ce gel.
* **23/10 ≈ 19:38–19:43 — Incident :** gel du boot recovery (voir §4). Dernier message journalisé 19:41:43 (journal : 21:41:43), uptime 3 min 15 s. À confirmer : correspondance avec le boot de 19:38.
---
## 2. État du Diagnostic

**Hypothèse de travail.** Cause commune à Linux et Windows, au niveau matériel / firmware (SoC AMD, BIOS, microcode), liée à la gestion d'énergie du processeur : **états d'idle (C-states) et transitions de fréquence/tension** (boost ; `amd-pstate-epp` sous Linux).
* **Indices en faveur :**
  * gels à bas régime, sans charge ni thermique, sous les deux systèmes ;
  * cœurs en C6 puis pic de boost (4,44 GHz, ~1,3 V) juste avant les gels Windows du 21/10 ;
  * `max_cstate=1` améliore très nettement Linux (indice le plus fort) ;
  * gel du boot recovery du 23/10 (`recovery nomodeset dis_ucode_ldr`, sans `max_cstate=1`) : il survient sans pilote graphique et sans microcode de l'OS, ce qui le place au niveau BIOS/matériel.
* **Limite :** `max_cstate=1` ne protège pas de tout. Les gels du 11-12/10, celui du 23/10 à 19:11 (22 s après le démarrage) et celui de fin de séance du 23/10 ont eu lieu avec `max_cstate=1`. Les C-states profonds ne suffisent donc pas à tout expliquer. Le résidu pointe vers les transitions de fréquence ou la gestion d'énergie PCIe/plateforme.

**Observations récentes (23/10), à confirmer.**
* **Gels Linux précoces :** 19:11 (≤ 1 min après l'ouverture de session, uptime 22 s au dernier message) et recovery (~3 min), contre ~6 h stables le 11/10. Ce schéma reste à confirmer sur davantage d'incidents.
* **Absence de trace :** gel total (ping muet, SysRq et Verr. Maj morts), `pstore` et `/var/crash` vides, aucun message `amdgpu`, `nvidia`, `Xid`, `MCE`, `AER`, `hung task`, erreur NVMe ou NTFS. Le journal reste muet, la borne « dernier message » étant inférieure à l'heure réelle du gel.
* **Anomalies isolées, sans lien démontré :**
  * `usb 3-2: device descriptor read/64, error -110` (19:11:02, périphérique non identifié) ;
  * `atkbd serio0: Failed to deactivate/enable keyboard` au démarrage (à comparer à un boot sain) ;
  * refus D0→D3hot sur `06:00.1` (11/10).
  * Les contrôleurs xHCI `06:00.3/.4`, l'audio `06:00.1` et l'iGPU `06:00.0` appartiennent au même bloc matériel AMD.
* **Microcode :** `0xa50000b`, BIOS `G713QM.331` (02/2023). Le noyau signale « IBPB-extending microcode not applied » (SRSO) et « no microcode » (TSA). Cela renforce la piste firmware sans la prouver.
* **Configuration relevée le 23/10 (écarts avec les notes précédentes) :**
  * `prime-select` = `intel`, pilote NVIDIA non chargé, `nvidia-smi` en échec (date du changement non consignée) ;
  * `NVreg_DynamicPowerManagement=0x00` dans les deux fichiers ;
  * `amd-pstate-epp` actif (governor `powersave`, EPP `performance`) ;
  * noms NVMe instables d'un boot à l'autre (le Kingston était `nvme1` au gel de 19:11, `nvme0` ensuite).

**Hypothèses secondaires (ordre de probabilité actuel).**
1. **Idle / transitions de fréquence / firmware-microcode** (hypothèse de travail ci-dessus).
2. **Veille profonde du Kingston (APST/ASPM)**, seul composant partagé entre Windows et Linux. Aucune preuve directe. APST actif (`default_ps_max_latency_us = 100000`).
3. **Gestion d'énergie PCIe/plateforme** : bloc `06:00.x` (iGPU, audio, xHCI), root port du dGPU `00:01.1` en D3cold, forte rotation des cycles d'alimentation (SSD : 39 337 et 51 969 power cycles).

**Causes partielles (certains incidents seulement).**
* Veille moderne : `0x9F` du 12/07, coupures après réveil sur batterie les 19 et 21/10 (mais le freeze du 21/10 à 13:52 a eu lieu sans veille).
* Batterie usée (usure ~34 %) : coupure à ~7 % du 19/10 ; n'explique pas les gels sur secteur ni ceux de Linux.
* `CsEntryScenarioInstanceId` non nul : suggère une entrée en veille moderne dans la session (probable, non certain).

**Écarté ou peu probable (avec les incidents concernés).**
* **RAM** : MemTest86 (nuit complète) et Diagnostic Mémoire Windows sans erreur.
* **Surchauffe, throttling, limite de puissance** : mesurés sous Windows (HWiNFO, 21/10) ; non mesurés sous Linux.
* **Erreur disque / NVMe** : SMART propre (Kingston 2 % d'usure, 0 erreur) ; aucune erreur NVMe ou NTFS dans les journaux du 23/10.
* **Pilote NVIDIA** : non chargé lors du gel du 23/10 à 19:11 (`intel`) ; les gels existent aussi sous Windows ; l'installation du pilote n'est pas en cause.
* **amdgpu / PSR** : affaibli par le gel recovery en `nomodeset` (23/10) ; non exclu pour le résidu du 11-12/10.
* **TDR / pilote graphique Windows** : écarté pour le 21/10.
* **`ntfs-3g`, TRIM, `smartctl`** : écartés pour les gels du 23/10 (voir §4).
* **Extension Adblock** : a seulement pollué les logs.
* **Horloge** : le décalage RTC de +2 h dégrade la lecture des journaux, pas d'effet sur les gels.

**Limites des données.** HWiNFO ne voit pas l'instant précis du blocage, et le journal Linux perd les dernières secondes. Le script de collecte a des défauts connus : indices de boot peu fiables, heure non corrigée, USB non identifié, NVMe nommés par `nvmeN`.

**Prochaines actions (une à la fois).**
0. **Sauvegarder `DocumentsSSD` sur l'iMac** (le disque suspect contient tous les documents ; ~15 arrêts non propres Linux depuis le 12/10).
1. **Lecture seule :** `lsusb -t` et lien `usb 3-2` → contrôleur PCI, pour identifier le périphérique de l'erreur -110.
2. **Corriger `collecte_incident_linux.sh` :** IDs de boot plutôt qu'indices, heure réelle corrigée, `lsusb -t`, filtre `usb|xhci`, NVMe par modèle/numéro de série, diff avec un boot sain.
3. **`netconsole` vers l'iMac** (Ethernet filaire) pour capter le dernier message du noyau sans passer par le disque.
4. **Test Windows `IDLEDISABLE` (en cours depuis le 21/10 19h15, voir §3)** : le poursuivre sans le modifier.
5. **Prochain test Linux (un seul à la fois, à décider) :**
   * `amd_pstate=passive` (ou `disable`) : hypothèse transitions de fréquence ;
   * `nvme_core.default_ps_max_latency_us=0` : hypothèse APST ;
   * secondaires : `amdgpu.dcdebugmask=0x10` (PSR), `amdgpu.runpm=0`.
6. Après chaque gel : lancer le script de collecte, vérifier que `syslog` ne regrossit pas.

**Non explorés.** BIOS plus récent que `G713QM.331` (lire les notes ASUS, mise à jour secteur branché, jamais sans accord préalable) ; microcode à jour (pistes BIOS ou paquet) ; « Load Optimized Defaults », absence d'XMP/DOCP et d'undervolt (Armoury Crate, Ryzen Controller) ; démarrage rapide de Windows désactivé ; `fwupdmgr get-updates` ; test sur batterie sans veille moderne (`powercfg /setdcvalueindex ... STANDBYIDLE 0`) ; WinDbg sur les 5 minidumps (priorité : les deux `HYPERVISOR_ERROR`) et `LiveKernelReports` ; SMART complet du Samsung ; sources `stornvme`, `disk`, `Ntfs` de l'Observateur d'événements ; réglage RTC Windows/Linux.

**Suivi à chaque incident.** Relever l'heure, le système, secteur/batterie, l'activité, l'ancienneté du dernier réveil de veille et le mode de démarrage (arrêt complet, redémarrage ou démarrage depuis Windows).
1. **Sous Windows :** 40 dernières lignes du CSV HWiNFO, journal Système (`Kernel-Power`, `WHEA-Logger`, `Display`) et paramètres de l'événement 41.
* Extraction HWiNFO (adapter le nom du fichier) : `$f="C:\Users\cromi\Documents\hwinfo_3.csv"; (Get-Content $f -TotalCount 1), (Get-Content $f -Tail 40) | Set-Content "$env:USERPROFILE\Documents\hwinfo_extrait.csv" -Encoding UTF8`
* Recompte des événements 41 : `Get-WinEvent -FilterHashtable @{LogName='System';Id=41}`
2. **Sous Linux :** `collecte_incident_linux.sh` (par ID de boot). Heure réelle = heure du journal − 2 h tant que la RTC n'est pas resynchronisée.

---

## 3. Test en cours — Windows : désactivation de l'inactivité du processeur

**Date de début :** 21/10/2026 19h15.

**Objectif :** tester l'hypothèse d'une instabilité liée aux états d'inactivité profonds du processeur, compte tenu de l'amélioration nette observée sous Linux avec `processor.max_cstate=1` et du freeze Windows du 21/10 précédé d'états C6.

**Action réalisée :**
- Lecture préalable de la configuration du profil d'alimentation Windows `SCHEME_BALANCED` (Utilisation normale).
- Valeurs initiales de `IDLEDISABLE` (`5d76a2ca-e8c0-402f-a133-2158492d58ad`) : secteur (`AC`) = `0` ; batterie (`DC`) = `0`.
- Modification de la valeur secteur à `1` avec `powercfg /setacvalueindex SCHEME_CURRENT SUB_PROCESSOR 5d76a2ca-e8c0-402f-a133-2158492d58ad 1`.
- Application du profil actif avec `powercfg /setactive SCHEME_CURRENT`.
- Vérification finale avec `powercfg /qh SCHEME_CURRENT SUB_PROCESSOR 5d76a2ca-e8c0-402f-a133-2158492d58ad`.

**Résultat de la vérification :**
- `AC = 0x00000001` : inactivité du processeur désactivée sur secteur.
- `DC = 0x00000000` : réglage sur batterie inchangé.
- Aucune autre modification de paramètres réalisée dans le cadre de ce test.

**Protocole d'observation :**
- Durée prévue : 2 à 3 jours d'utilisation normale, sur secteur.
- Ne pas modifier simultanément les paramètres Linux, NVIDIA ou les autres réglages énergétiques Windows.
- Consigner pour chaque incident : date/heure, alimentation secteur ou batterie, activité en cours, éventuelle veille récente et symptômes (gel, écran noir, redémarrage).
- Surveiller toute hausse anormale de température, ventilation excessive ou consommation inhabituelle ; interrompre le test si le comportement devient préoccupant.

**Interprétation prévue :**
- Aucun gel durant la période : résultat encourageant, mais non concluant à lui seul compte tenu du caractère intermittent des incidents.
- Gel similaire : la désactivation testée ne suffit pas à stabiliser le système ; cela n'exclut pas un problème de gestion énergétique au niveau du firmware ou du matériel.
- Réduction de la fréquence des gels : indice possible d'une contribution des états d'inactivité, à confirmer par une observation plus longue.

**Statut : TEST EN COURS — aucun résultat de stabilité disponible à ce stade.**

**Retour arrière, si nécessaire :** rétablir la valeur secteur à `0` puis réactiver le profil avec `powercfg /setacvalueindex SCHEME_CURRENT SUB_PROCESSOR 5d76a2ca-e8c0-402f-a133-2158492d58ad 0` et `powercfg /setactive SCHEME_CURRENT`.

## 4. Séance du 23/10/2026 : exploration Linux / stockage

**Contexte :** gel en mode recovery juste après un `cd` dans la partition NTFS `DocumentsSSD`, puis second gel en session normale pendant l'analyse. Le script d'analyse n'a jamais été lancé.

### Incidents
* **Gel en boot recovery**, quelques minutes après le démarrage, après un `cd` dans un répertoire déjà visité de `/mnt/DocumentSSD`. Ligne de commande de ce boot : `recovery nomodeset dis_ucode_ldr`. Donc **sans `processor.max_cstate=1` ni `tsc=nowatchdog`**, sans pilote graphique (nomodeset) et sans microcode CPU de l'OS. Le TSC y a été marqué instable (écart de 1,7 ms sur 496 ms).
* **Gel en session normale** (boot avec `max_cstate=1`), en fin de séance. Ping sans réponse et machine absente de l'interface de la box : blocage complet de la machine, réseau compris. SSH non testable (`openssh-server` non confirmé).
* La dernière ligne écrite dans le journal de ce boot est ton `smartctl` de 20:34:39, mais ce n'est **pas** l'heure du gel : journald n'écrit sur disque que toutes les 5 minutes, les dernières secondes avant un arrêt forcé peuvent manquer, et `smartctl` avait répondu normalement.

### Configuration constatée
* **Kingston NV1 1 To** (`nvme0`, firmware `S8B40103`, sans DRAM, 64 Mo de HMB prélevés sur la RAM) : contient Ubuntu (`/` en ext4, p4), l'EFI Linux (p3) et la partition NTFS `DocumentsSSD` (p2), **accessible depuis Windows et Linux** (montée via `ntfs-3g`, donc en espace utilisateur).
* **Samsung** (`nvme1`) : disposition d'origine ASUS avec Windows (`OS`), `SYSTEM`, `RESTORE`, `MYASUS`.
* Kingston : états de veille profonde PS3/PS4 supportés, `default_ps_max_latency_us = 100000` (autorisés).
* Ligne de commande du boot normal : `tsc=nowatchdog processor.max_cstate=1`.
* Journal Linux déjà persistant, mais il ne remonte qu'au 12/10 08:30 (les gels du 11-12/10 ont été effacés par la saturation de `syslog`).
* `fwupd` signale 7 appareils mis à jour possibles, dont **2 avec une mise à jour publiée** (non identifiés).

### Mesures SMART
|  | Kingston (`nvme0`) | Samsung (`nvme1`) |
|---|---|---|
| Critical Warning / erreurs d'intégrité / journal d'erreurs | 0x00 / 0 / 0 | non relevés |
| Usure (Percentage Used) | 2 % | 8 % |
| Power Cycles | 39 337 (≈ 2,8/h) | 51 969 (≈ 6,4/h) |
| Unsafe Shutdowns | 506 | 340 |
| Heures de fonctionnement | 14 253 | 8 091 |

Les deux SSD ont des compteurs élevés de cycles et d'arrêts non propres : ils reflètent la plateforme (veille, coupures), pas un défaut propre au Kingston.

### Bilan des boots Linux (12/10 → 23/10)
* Sur 21 boots terminés, **environ 15 se terminent sans arrêt propre** (tu forces le redémarrage à chaque gel : ce sont donc en grande partie de vrais gels, bien plus que les 4 consignés). Un faux « propre » a été corrigé (le boot de `smartctl`).
* Les 4 premiers (12-13/10) finissent sur des messages de début d'arrêt (« Exit the Session », « Closed Speech Dispatcher Socket »). Observation brute, aucune conclusion.
* Le boot du 14/10 à 11:14 finit sur une erreur `KMS: DRM_IOCTL_MODE_C…` de GNOME Shell (ligne tronquée).
* **Les heures des journaux Linux ne sont pas fiables** : l'horloge matérielle est décalée d'environ 2 h au démarrage (probablement Windows en heure locale, Linux en UTC), puis corrigée par le réseau. Plusieurs boots ont une fin antérieure à leur début. Ne pas croiser ces heures avec Windows. Cause probable des erreurs d'horloge, pas des gels.

### Pistes écartées ou très affaiblies
* **Script d'analyse** : jamais lancé.
* **Pilote NTFS** : `ntfs-3g` tourne en espace utilisateur et ne peut pas figer toute la machine (Verr. Maj et SysRq morts, ping muet).
* **`smartctl`** : la commande a répondu normalement.
* **TRIM (`fstrim`)** : un seul passage visible dans le journal (23/10 20:30) ; le gel en recovery est survenu sans TRIM.
* **Défaut visible du flash Kingston** : SMART propre, 2 % d'usure, 0 erreur.
* **Le `cd` sur NTFS comme cause** : possible déclencheur ou coïncidence. Le gel recovery a eu lieu sans les protections C-state, donc il ne permet pas de conclure.
* **Pistes amdgpu/PSR** : légèrement affaiblies par le gel en `nomodeset`, mais le résidu du 11-12/10 (D0→D3hot sur `06:00.1`) reste sans explication.

### Hypothèses ouvertes (ordre de probabilité actuel)
1. **C-states / firmware / BIOS** (SoC AMD). Gels sans charge ni thermique, `max_cstate=1` qui améliore nettement, gel recovery survenu sans cette protection, `HYPERVISOR_ERROR` Windows.
2. **Veille profonde du Kingston (APST/ASPM)**, seul composant partagé entre Windows et Linux. Aucune preuve directe, le journal étant toujours muet.
3. **Plateforme PCIe / gestion d'énergie** en général (les deux SSD ont des compteurs de cycles élevés).

### Non fait / à faire (une seule action à la fois)
* **Sauvegarder `DocumentsSSD` sur l'iMac** (le disque suspect contient tous les documents).
* Vérifier que le démarrage rapide de Windows est désactivé (partition NTFS partagée).
* **Test APST** : ajouter `nvme_core.default_ps_max_latency_us=0` dans `GRUB_CMDLINE_LINUX_DEFAULT`, `sudo update-grub`, redémarrer, vérifier la valeur `0` dans `/sys/module/nvme_core/parameters/`. Décision à prendre : le lancer maintenant (chevauchement avec le test Windows IDLEDISABLE en cours depuis le 21/10 19h15) ou attendre la fin de ce dernier.
* **`netconsole`** vers l'iMac (portable en Ethernet filaire) pour capter le dernier message du noyau avant un gel, sans passer par le disque.
* `fwupdmgr get-updates` : identifier les 2 mises à jour publiées (ne rien installer sans accord préalable).
* Observateur d'événements Windows : sources `stornvme`, `disk`, `Ntfs` (ID 129, 153, 140, 55) autour des incidents.
* Réglage de l'horloge Windows/Linux (RTC) : à traiter plus tard, sans lien avec les gels.
* Restent non explorés : BIOS plus récent, WinDbg sur les 5 minidumps, SMART complet du Samsung.