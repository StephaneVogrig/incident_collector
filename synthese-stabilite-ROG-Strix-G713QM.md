# Synthèse stabilité ROG Strix G713QM

Ce document regroupe ce qui est établi, pour reprendre dans une nouvelle discussion sans refaire les mêmes commandes. Faits, déclarations de l'utilisateur et hypothèses sont distingués.

Mise à jour : 27 nov 2026 22:46:00

## Consignes générales

- Une étape, une action à la fois. Attendre le retour de l'utilisateur avant d'enchaîner.
- Réponses courtes, objectives, sans flatterie. Distinguer faits, consensus, hypothèses. Signaler erreurs, biais et incertitudes.
- Ne pas proposer plusieurs pistes en même temps. Ne pas redemander ce qui figure ici.

## Machine

ASUS ROG Strix G713QM version 1.0, AMD Ryzen 9 5900HX with Radeon Graphics, NVIDIA GeForce RTX 3060 Mobile / Max-Q, iGPU AMD Cezanne.
Ubuntu 22.04, noyau 6.8.0-138-generic. Sur secteur uniquement (adaptateur secteur d'origine ; son état n'est pas vérifié). BIOS G713QM.331. Double démarrage avec Windows.

## Problème

Gels totaux (Caps Lock mort, parfois écran noir), à faible charge. Depuis mai 2026, certains gels surviennent très tôt (juste après le boot ou avant l'apparition du bureau) (déclaratif).

## Base et sauvegardes

Base : `GRUB_CMDLINE_LINUX_DEFAULT="quiet splash tsc=nowatchdog processor.max_cstate=1"`. L'amélioration attribuée à `max_cstate=1` n'a jamais été mesurée.

Sauvegardes dans `~/stab/` : `grub.orig`, `cmdline.orig`, `etat-origine.txt`, `fstab.orig`, `last-wtmp1.txt` (sortie complète de `last -F -f /var/log/wtmp.1`, si créé). Script `stab-etat.sh` (lecture seule, modes `origine` et `courant`). Procédure détaillée : `stab-procedure.md` (7 sections).

`/etc/default/grub.d/init-select.cfg` existe mais ne définit aucune ligne `GRUB_CMDLINE` (la cmdline effective a été vérifiée).

## Faits vérifiés (machine)

- cpuidle : driver `acpi_idle`, états POLL et C1 seulement. `max_cstate=1` est appliqué.
- Driver fréquence d'origine : `amd-pstate-epp`, mode `active`. Aucun fichier `boost` sur la machine.
- `prime-select query` = `intel` (mode iGPU, y compris pour AMD). L'affichage passe par l'iGPU AMD Cezanne (`06:00.0`).
- RTX 3060 en `01:00.0`, `power/control` = `auto` à l'origine. `lsmod | grep nvidia` est vide : pilote NVIDIA non chargé, donc hors de cause dans ce mode.
- ASPM d'origine : `default`. NVMe `pm_qos_latency_tolerance_us` d'origine : 100000.
- Deux NVMe avec HMB de 64 MiB (`04:00.0`, `05:00.0`). Wi-Fi MT7921. Affichage hybride ATPX.
- Journal systemd persistant (depuis le 2026-10-23). `kern.log` présent.
- BIOS 331 (2023-03-30) : c'est la dernière version. Piste BIOS probablement fermée.
- Volume NTFS `/dev/nvme1n1p2` (`/mnt/DocumentSSD`, ntfs-3g) : monté via `/etc/fstab` ligne 14, désormais commentée.
- Noyaux installés : 6.8.0-138 (en cours) et 6.8.0-149 (jamais démarré, aucun boot dans `wtmp`). Les noyaux 6.8.0-124 et -106 sont purgés (non disponibles via `apt`).
- Règles udev `/lib/udev/rules.d/71-nvidia.rules` : ligne 28, sur `ACTION=="bind"` d'un périphérique NVIDIA de classe VGA/3D (0x03xxxx), écrit `power/control=auto` ; lignes 31 à 37, mêmes écritures sur `add` pour l'audio, l'USB xHCI et l'UCSI NVIDIA. Journal du boot du 27 nov : aucun bind de pilote `nouveau`/`nvidia` vu sur `01:00.0` (sortie limitée à `tail -20` ; `readlink` et `lsmod` non collés). Ce qui a remis `auto` reste **inconnu** ; piste abandonnée.
- Services : `tlp` et `nvidia-powerd` inactifs, `power-profiles-daemon` actif (probablement sans effet sur le contrôle PCI du GPU, non vérifié).
- Le 27 nov à 22:28 : `power/control` = `auto`, `runtime_status` = `suspended` (GPU en suspension runtime) : bloc F **non actif** à ce moment.

## Lire `last` et le journal : règles

- `last` : « crash » = pas d'arrêt propre enregistré (gel, reset forcé, coupure, panique). La durée affichée court jusqu'au démarrage suivant et inclut le temps gelé : **borne haute**.
- Journal systemd : dernière entrée du boot = **borne basse** du temps tenu. Exemple : boot du 26 nov 01:26 = 21 min dans le journal, 8 h 30 dans `last`.
- `last -f /var/log/wtmp.1` lit l'archive (déc. 2023 → 5 mars 2026). Le `awk` utilisé pour lister les noyaux affiche le **démarrage le plus récent** de chaque bloc de noyau, pas le premier. Ne pas s'en servir pour dater le début d'un noyau.
- Les heures de `wtmp` comportent des sauts d'horloge (durées négatives, par ex. `-1:12`), cause non vérifiée.
- Les redémarrages courts pour choisir Windows (Linux démarre avant le choix dans GRUB) sont normalement des « down ». Un « crash » court suppose une extinction non propre, y compris un bouton maintenu : le journal seul ne distingue pas gel et reset volontaire.

## Historique `last` / `wtmp` (faits)

- **Déc. 2023 → mars 2026 (`wtmp.1`)** : 26 « crash », tous avec durées de 13 h à 7 jours (le plus court : 29 min le 17 mars 2024). Incompatibles avec des gels subis. Le plus ancien date de janvier 2024. Pas de gel vécu à l'époque (déclaratif). Régime sans rapport démontré avec l'état actuel.
- **Mars 2026 →** : stable jusqu'au 10 avril. Premiers « crash » courts le 11, 16, 17 et 19 avril 2026 (premiers gels vécus, déclaratif). Aggravation à partir du 16 mai : « crash » nombreux, souvent très courts. Changement de type de session vers le 18-19 mai : correspond aux premiers essais de résolution (déclaratif, probablement Wayland vers Xorg, non vérifié). Bascule en grande partie sous Windows à cette période (déclaratif).
- **22 mai → 30 sept.** : seulement 2 « crash » dans `wtmp`, longs (27 mai, 10 h ; 6 sept., 17 h), sessions de 4 à 17 h. **Correction de l'utilisateur (déclaratif)** : ce n'est pas une rémission, mais un non-usage de Linux, car les sessions finissaient la plupart du temps en gel. Cohérent avec `wtmp` : un gel suivi d'un démarrage sous Windows ne laisse aucun « crash » côté Linux, et les deux « crash » longs peuvent être des gels. La rémission n'est donc pas un fait établi (biais de sélection). Non vérifiable dans les logs Linux ; les événements Windows ne datent que les gels Windows.
- **30 sept. 2026 →** : retour des gels, avec rafales les 30 sept., 10-11 oct., 22-23 oct., 24-26 nov. La cause du retour est inconnue.
- **Boots récents du journal** (heure début → dernière entrée) : -7 : 21:07 → 21:11 (4,5 min) ; -6 : 22:27 → 23:31 (64 min) ; -5 : 23:35:24 → 23:35:55 (31 s) ; -4 : 01:26 → 01:47 (21 min) ; -3 : 09:56 → 10:33 (36 min) ; -2 : 10:34 → 11:08 (33 min) ; -1 : 11:09 → 22:55 (11 h 45). Maximum récent hors run 1 : ~65-71 min.
- **Boot -5 (25 nov, 31 s)** : le journal s'arrête sur des warnings gnome-shell d'initialisation des raccourcis clavier, sans message d'arrêt, `last` le classe « crash ». Cohérent avec un gel ou un reset forcé pendant l'initialisation de la session graphique. Ne prouve rien sur le composant en cause.
- Noyau : série 6.8 depuis sept. 2024. En 2026, les « crash » courts apparaissent dès les premiers boots sous 6.8.0-107 (après -106, stable en mars-avril), mais aussi sous -111 et -117 (alternés en mai). Détail des blocs noyau disponible dans `wtmp` ; la frontière exacte entre noyaux est incertaine (heures peu fiables).
- Windows : redémarrages inexpliqués sur batterie en septembre (déclaratif, non daté, aucun log relevé). Aucun vécu sur secteur. Journal Windows non encore lu.

## Essai 0 (base seule) : terminé

- Gel n°1 (0a) : début 09:57:20 le 26 nov, fin du journal 10:33:09, tenue ≥ 35 min. Cmdline conforme. Aucun log utile (pas de MCE, AER, erreur `amdgpu`, `nvme` ou `pcie`).
- Gel n°2 (0b) : boot 10:34:42, NTFS monté, dernière entrée du journal 11:08:06, soit tenue ≥ 33 min. Gel avec écran noir et Caps Lock mort. Logs détaillés non relevés.
- Interprétation (hypothèse) : noyau figé sans trace, ce qui oriente vers un blocage bas niveau (CPU, firmware, alimentation, bus). Mais journald peut perdre les dernières secondes : l'absence de trace n'est pas une preuve.
- `max_cstate=1` ne suffit pas (fait).

## Essai 1 : configuration

Changements appliqués en même temps (essai groupé, volontairement non isolé ; le bloc F est finalement non vérifié, voir run 1 et run 2) :

- Cmdline : base + `idle=poll amd_pstate=disable pcie_aspm=off pcie_port_pm=off nvme_core.default_ps_max_latency_us=0 amdgpu.dcdebugmask=0x10 amdgpu.sg_display=0 amdgpu.runpm=0`. Vérifiée dans `/proc/cmdline` (encore le 27 nov, avec `vt.handoff=7` ajouté par le système).
- Effets vérifiés : `scaling_driver` = `acpi-cpufreq`, `pm_qos_latency_tolerance_us` = 0 sur nvme0 et nvme1.
- Bloc F (à chaud) : `echo on | sudo tee /sys/bus/pci/devices/0000:01:00.0/power/control`. **Abandonné le 27 nov** : constaté non actif (`auto`, GPU `suspended`) alors que le run 2 tenait sans gel (voir run 2). L'écho `on` de `tee` ne prouve pas la valeur effective.
- Volume NTFS démonté (ligne 14 de `/etc/fstab` commentée). Ne pas le remonter à la main pendant l'essai.

Critère : 3 h sans gel, à répéter une fois avant de conclure. Choisi car nettement supérieur au maximum récent observé (71 min). **Limite reconnue** : ce critère ne sépare pas l'effet des paramètres d'une « bonne période » (cf. rémission mai-septembre sans réglage).

## Essai 1, run 1 (26 nov) : critère atteint (bloc F non revérifié)

- Début 11:09:12 pour le boot (journal), bloc F appliqué vers 11:14:18 (`power/control` jamais relu ensuite). Tenue : **11 h 45 sans gel** (journal : dernière entrée 22:55:04). Fin de session : **arrêt volontaire** (déclaratif), donc durée = borne basse (observation censurée).
- Charge : travail réel (Codium, 3 terminaux, Chrome 3 à 5 onglets), avec environ 3 h de pauses (estimation). **Nature des pauses non précisée** (veille, écran éteint ou machine éveillée inactive). Une veille ne compte pas comme durée éveillée et peut masquer un défaut.
- Durée effective estimée ≈ 8 h 45, soit ≥ 7 fois le maximum récent (71 min).
- **Lecture prudente** : une seule observation, six blocs changés ensemble : cause non localisée. Compatible avec un effet des paramètres, avec un contournement, ou avec une bonne période (alternative affaiblie depuis la correction sur mai-septembre, voir Historique).

## Essai 1, run 2 (27 nov) : critère atteint, bloc F constaté non actif

- Boot à 09:41:11 (journal 09:41:17), `uptime -s` inchangé à 22:29 : aucun redémarrage. Cmdline complète, `acpi-cpufreq`, `pm_qos_latency_tolerance_us` = 0 sur nvme0 et nvme1 (vérifiés ~22:28).
- Bloc F oublié après le boot, puis réappliqué : début de la répétition 11:17:15, fin du critère 14:17:15.
- **Aucun gel (déclaratif) jusqu'à 22:29** : 12 h 48 depuis le boot, 11 h 12 depuis 11:17:15. Critère de 3 h largement dépassé. Fin de session prévue : arrêt volontaire pour passer sous Windows (heure à noter).
- **Écart de protocole** : à 22:28, `power/control` = `auto` et `runtime_status` = `suspended`. Le bloc F n'était donc pas actif. Moment du retour à `auto` inconnu ; il est possible que F n'ait jamais été effectif (la sortie `on` de `tee` est un écho). Cause non identifiée (voir faits vérifiés, piste abandonnée par choix de l'utilisateur).
- **Conséquence** : la configuration tenue sans gel sur ≥ 12 h est A à E, avec F actif sur une durée indéterminée (peut-être nulle). F n'est pas nécessaire en pratique à ce stade (hypothèse non prouvée, le même doute vaut pour le run 1).
- Thermique (22:28) : Tctl 82,8 °C (acpitz 82 °C), amdgpu edge 68 °C, PPT 63 W, ventilateurs 3600/3700 RPM, NVMe 35,9 °C. Seuil de throttling Ryzen 5000H ≈ 95 °C (valeur habituelle, non vérifiée sur ce modèle). Coût de `idle=poll` : chaleur, bruit, usure thermique.
- Nature des pauses (veille ou inactivité éveillée) : toujours non précisée.
- **Déclaratif** : l'utilisateur retrouve un usage de Linux qu'il n'avait pas connu depuis mai. Indice, non preuve.
- Limite : sans contrôle (retour à la base seule), on ne sépare pas l'effet des paramètres d'une période favorable.

## Suite prévue

1. **Maintenant : passage sous Windows.** Lecture des événements : `Get-WinEvent -FilterHashtable @{LogName='System'; Id=41,6008} | Select TimeCreated, Id, @{n='Bugcheck';e={$_.Properties[0].Value}}` (lecture de `Bugcheck` pour l'Id 41 à confirmer sur le résultat). Les dates comptent plus que le code : croiser avec les « crash » Linux (surtout autour du 30 sept. et mai-septembre). Si Windows gèle aussi sans lien avec Linux, les réglages Linux ne sont pas la cause : orienter vers matériel, alimentation, batterie. Les événements Windows ne datent que les gels survenus sous Windows.
2. **Retour sous Linux** : vérifier `uptime -s`, `/proc/cmdline`, `scaling_driver`. Ne pas réappliquer le bloc F. Utiliser la machine avec la configuration A à E sans la modifier. Si gel : noter l'heure et la durée, redémarrer, lire les logs du boot précédent (commandes ci-dessous) **avant** toute modification.
3. Optionnel, test de contrôle : retour à la base seule pendant plusieurs jours pour voir si les gels reviennent. C'est ce test qui sépare paramètres et bonne période. Non nécessaire si l'objectif est seulement de travailler.
4. Optionnel, réduire la chaleur : retirer **un** paramètre à la fois (`idle=poll` en premier ; `max_cstate=1` est déjà l'alternative), quelques jours par étape, même critère de charge. Un gel ramène aux logs avant toute autre modification.
5. Bisection complète (blocs A à E, NTFS compris) seulement si le contrôle ou un retrait fait revenir les gels.
6. Optionnel : noyau 6.8.0-149 avec la **base seule** (une variable à la fois). Un gel exclurait une régression propre à -136/-138 sans trancher entre matériel et paramètres. Un résultat stable serait ambigu. Retrouver -124 non recommandé.
7. Optionnel : un essai sans `max_cstate=1` pour valider l'impression d'amélioration.

## Hypothèses ouvertes (non établies)

- Les paramètres du run 1 et du run 2 seraient un contournement plutôt qu'un correctif. L'alternative « bonne période » est affaiblie par la correction de l'utilisateur sur mai-septembre (non-usage, pas rémission) et par 0a/0b (base seule : gels en ~35 min), mais pas écartée faute de contrôle.
- Rôle du bloc F : inconnu, probablement nul ou faible puisque le run 2 tient avec le GPU suspendu (non prouvé).
- Régression noyau (corrélation partielle avec -107 à -117 et -136/-138, affaiblie par les gels sous -111 et -117 et par Windows).
- Cause matérielle ou alimentation (batterie, adaptateur d'origine éventuellement usé, carte mère, RAM) : appuyée par les redémarrages Windows sur batterie en septembre (peu documentés), les gels précoces et l'absence de trace dans les logs.
- Événement déclencheur vers le 10-11 avril 2026 : **non identifié**.
- Gels précoces : défaut touchant l'initialisation (GPU/affichage, firmware, bus). Observation : au boot, `01:00.0` est désigné « boot VGA device » par `vgaarb` avant que l'affichage passe par l'iGPU ; aucune conclusion.
- NVIDIA hors de cause dans ce mode : maintenu, sous réserve de `readlink`/`lsmod` non collés.

## Commandes utiles

Logs du boot précédent après un gel :

```bash
journalctl --list-boots | tail -3
sudo journalctl -b -1 -n 30 --no-pager
sudo journalctl -b -1 -p warning --no-pager | tail -40
sudo journalctl -b -1 -k --no-pager | grep -i -E 'mce|amdgpu|nvme|pcie|aer|xid'
sudo journalctl -b -1 -k -g 'Kernel command line' --no-pager | tail -1
```

Vérifier l'essai en cours :

```bash
uptime -s
cat /proc/cmdline
cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_driver
grep -H . /sys/class/nvme/nvme*/power/pm_qos_latency_tolerance_us
cat /sys/bus/pci/devices/0000:01:00.0/power/control
sensors
```

Historique (lecture seule) :

```bash
last -F | head -60
last -F -f /var/log/wtmp.1 > ~/stab/last-wtmp1.txt
grep crash ~/stab/last-wtmp1.txt | tail -30
dpkg -l 'linux-image-6.8*' | grep ^ii
```

## Retour arrière

```bash
sudo cp ~/stab/grub.orig /etc/default/grub
sudo cp ~/stab/fstab.orig /etc/fstab
sudo update-grub
sudo reboot
```

Si le système ne démarre plus : au démarrage, maintenir Échap (UEFI) pour afficher GRUB, sélectionner Ubuntu, touche `e`, retirer les paramètres ajoutés sur la ligne `linux`, démarrer avec `Ctrl+X`. Modification valable pour ce démarrage seulement.

## Informations encore manquantes

- Heure de l'arrêt volontaire du run 2 (passage sous Windows) et nature des pauses (veille ou inactivité éveillée).
- Dates et codes des événements Windows Id 41/6008.
- Événement survenu vers le 10-11 avril 2026 (mise à jour firmware/BIOS, matériel, choc, déplacement, usage, environnement thermique).
- Les boots courts « crash » récents sont-ils des gels ou des resets volontaires ? Seul le boot -5 (25 nov) a été examiné : fin sans message d'arrêt, non tranché.
- Logs détaillés du gel 0b ; fin des boots -3 et -2 (message d'arrêt ou non).
- Résultat de memtest86+ (déjà passé, résultat à préciser).
- État de l'adaptateur secteur (d'origine) et de la batterie.
- Noyau 149 : jamais testé.
- Cause du retour de `power/control` à `auto` (abandonnée) ; sorties de `readlink` du pilote de `01:00.0` et de `lsmod`.
- Heure exacte de l'arrêt volontaire du run 1 (26 nov), si utile.

## Journal des essais

| Essai | Paramètres (en plus de la base) | Début | Durée tenue | Résultat |
| --- | --- | --- | --- | --- |
| 0a | Aucun | 26 nov 09:57:20 | ≥ 35 min | Gel complet, aucun log utile |
| 0b | Aucun (NTFS monté) | 26 nov 10:34:42 | ≥ 33 min (journal) | Gel, écran noir, Caps Lock mort |
| 1, run 1 | A à F, NTFS démonté | 26 nov 11:09:12 (bloc F vers 11:14:18, non revérifié) | 11 h 45 (dont ~3 h de pauses) | Stable, critère atteint ; arrêt volontaire (durée = borne basse) |
| 1, run 2 | A à E (F constaté non actif à 22:28), NTFS démonté | 27 nov, boot 09:41:11 (répétition 11:17:15) | ≥ 12 h 48 depuis le boot, ≥ 11 h 12 depuis 11:17:15 (à 22:29) | Stable, critère atteint ; arrêt volontaire prévu (durée = borne basse) |

## En cours

Session Linux du 27 nov toujours sans gel à 22:29. L'utilisateur passe sous Windows (arrêt volontaire). Prochaine étape : lecture des événements Windows (Suite prévue, point 1).

## Consignes pour la suite

- Au retour sous Linux : vérifier `uptime -s`, `/proc/cmdline`, `scaling_driver`, puis utiliser la machine sans modifier la configuration. Ne pas réappliquer le bloc F.
- La ligne 14 de `/etc/fstab` (NTFS) reste commentée : ne pas la rétablir sans décision explicite.
- Ne rien modifier avant d'avoir lu les logs du boot précédent en cas de gel.
