# Tests de stabilité ROG Strix G713QM : procédure manuelle (Ubuntu 22.04)

Mis à jour le 2026-11-26. Environnement : Ubuntu 22.04, GRUB régénéré avec `sudo update-grub`. Fichier complémentaire : `stab-etat.sh` (capture de l'état, lecture seule).

## 1. Sauvegarde de l'état d'origine

À faire une seule fois, avant la moindre modification. Sans ces fichiers, le retour arrière repose sur ta mémoire.

**Avec le script (sans `sudo`)** :

```bash
chmod +x stab-etat.sh
./stab-etat.sh origine
```

Il crée `~/stab/` avec `grub.orig`, `cmdline.orig` et `etat-origine.txt`, et refuse d'écraser une sauvegarde existante. Relis `etat-origine.txt` : une erreur y signale un chemin absent sur ta machine.

**Équivalent à la main** :

```bash
mkdir -p ~/stab && cd ~/stab
cp /etc/default/grub grub.orig
cp /proc/cmdline cmdline.orig
```

puis le bloc de lecture sysfs du script (fonction `etat`), redirigé vers `etat-origine.txt`.

**Vérifications propres à Ubuntu**

1. Un fichier de `/etc/default/grub.d/` peut redéfinir `GRUB_CMDLINE_LINUX_DEFAULT` et annuler tes modifications, car `update-grub` lit ces fichiers après `/etc/default/grub`. Vérifie :

   ```bash
   grep -H '^GRUB_CMDLINE' /etc/default/grub /etc/default/grub.d/* 2>/dev/null
   ```

   Sur une installation standard, seule la ligne de `/etc/default/grub` apparaît (`quiet splash`). Si un autre fichier redéfinit la variable, modifie celui-là ou prends-le en compte avant de tester.

2. Journal persistant. Ubuntu 22.04 ne conserve pas le journal systemd entre deux démarrages par défaut, donc `journalctl -b -1` est vide :

   ```bash
   sudo mkdir -p /var/log/journal
   sudo systemctl restart systemd-journald
   journalctl --list-boots
   ```

   Ubuntu garde aussi les messages noyau dans `/var/log/kern.log` via rsyslog (à vérifier chez toi : `ls -l /var/log/kern.log`).

## 2. Blocs de paramètres et ordre des essais

Les huit paramètres se regroupent en cinq blocs, testés ensemble puis séparément. Les cibles sont des hypothèses de diagnostic, pas des causes établies pour ta machine.

| Bloc | Paramètres noyau | Cible supposée | Effets de bord |
| --- | --- | --- | --- |
| A. Idle CPU | `idle=poll` | C-states profonds (gel à l'idle) | CPU actif en permanence : chauffe, conso, batterie. Diagnostic uniquement |
| B. Driver fréquence | `amd_pstate=disable` | Driver amd-pstate (bascule vers acpi-cpufreq) | Sans effet si `scaling_driver` affiche déjà `acpi-cpufreq` |
| C. PCIe | `pcie_aspm=off` `pcie_port_pm=off` | États de veille des liens PCIe | Conso en hausse sur SSD, Wi-Fi, GPU |
| D. NVMe | `nvme_core.default_ps_max_latency_us=0` | États d'énergie profonds du SSD (APST) | SSD plus chaud, conso en hausse |
| E. GPU AMD (iGPU) | `amdgpu.dcdebugmask=0x10` `amdgpu.sg_display=0` `amdgpu.runpm=0` | PSR, allocation mémoire d'affichage, runtime PM | Sans effet si l'affichage passe par le NVIDIA. Le RTX 3060 n'est pas concerné |

Points à vérifier sur ta machine avant de planifier :

- **Bloc B** : `cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_driver`. Le noyau 5.15 d'origine d'Ubuntu 22.04 n'a pas le driver amd-pstate (absent avant le noyau 5.17), donc le bloc B n'a de sens que si tu es sur un noyau HWE plus récent et que le driver est actif. Sinon, retire-le de la bisection. Vérifie ton noyau avec `uname -r`.
- **Bloc E** : `prime-select query` indique le mode GPU actuel (NVIDIA utilisé seul, ou iGPU AMD pour l'affichage). Le bloc E n'a de cible que si l'iGPU AMD est utilisé.

Ordre des essais :

1. **Essai 0 : origine.** Aucune modification. Reproduis le plantage et note l'intervalle moyen entre deux plantages : il fixe la durée minimale d'un essai (voir le journal).
2. **Essai 1 : tous les blocs A à E.** Toujours instable : la cause n'est probablement pas dans ces paramètres (matériel, thermique, RAM, alimentation, pilote NVIDIA, firmware). Arrête la bisection et change de piste. Stable : étape 3.
3. **Bisection.** Retire la moitié des blocs, teste, puis resserre sur la moitié fautive. Avec cinq blocs, trois à quatre essais suffisent.
4. **Bloc fautif identifié.** Isole ses paramètres un par un. Si c'est `idle=poll`, cherche une alternative viable (par exemple `processor.max_cstate=1`) plutôt que de le garder.

## 3. Test d'un bloc via GRUB

Chaque essai repart du fichier d'origine : les essais restent indépendants et rien ne s'accumule d'un test à l'autre.

1. Repars de l'original et ouvre le fichier :

   ```bash
   sudo cp ~/stab/grub.orig /etc/default/grub
   sudo nano /etc/default/grub
   ```

2. Ajoute les paramètres du bloc testé à la fin de `GRUB_CMDLINE_LINUX_DEFAULT`, dans les guillemets, séparés par des espaces. Exemple pour les blocs C et D :

   ```text
   GRUB_CMDLINE_LINUX_DEFAULT="quiet splash pcie_aspm=off pcie_port_pm=off nvme_core.default_ps_max_latency_us=0"
   ```

3. Vérifie la ligne, régénère GRUB, redémarre :

   ```bash
   grep '^GRUB_CMDLINE_LINUX_DEFAULT' /etc/default/grub
   sudo update-grub
   sudo reboot
   ```

   `update-grub` doit lister les noyaux trouvés (`Found linux image`) sans erreur.

4. Après le redémarrage, contrôle la cmdline effective. Si un paramètre manque, ne lance pas le test :

   ```bash
   cat /proc/cmdline
   ```

5. Vérifie que les réglages ont pris effet (selon le bloc testé) :

   ```bash
   cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_driver              # bloc B
   grep -H . /sys/class/nvme/nvme*/power/pm_qos_latency_tolerance_us    # bloc D
   sudo dmesg | grep -i -E 'aspm|nvme|amdgpu' | head -30                # blocs C, D, E
   ```

   `sudo` est nécessaire pour `dmesg` sur Ubuntu 22.04.

6. Note l'heure de début dans le journal (section 7), puis utilise la machine comme d'habitude (ou lance ta charge habituelle) pendant la durée prévue.

7. Après un plantage et le redémarrage qui suit, récupère les logs du boot précédent :

   ```bash
   sudo journalctl -b -1 -p warning --no-pager | tail -100
   sudo journalctl -b -1 -k --no-pager | grep -i -E 'mce|amdgpu|nvme|pcie|aer'
   sudo tail -n 200 /var/log/kern.log
   ```

Un gel complet qui ne laisse aucune ligne utile dans les logs est une information à noter. Hypothèse, à confirmer : ça oriente vers un blocage matériel ou bas niveau (CPU, idle, firmware) plutôt que vers un plantage logiciel.

## 4. Tests à chaud (sysfs)

Utile pour un essai rapide sans redémarrer, mais moins fidèle que le test via GRUB : ne conclus pas sur un essai à chaud seul. Les valeurs sysfs reviennent à leur état d'origine au redémarrage.

```bash
# CPU : boost off
echo 0 | sudo tee /sys/devices/system/cpu/cpufreq/boost

# CPU : C-states C2 et plus désactivés (C1 conservé)
for f in /sys/devices/system/cpu/cpu*/cpuidle/state[2-9]*/disable; do echo 1 | sudo tee "$f" > /dev/null; done

# NVMe : APST désactivé
for f in /sys/class/nvme/nvme*/power/pm_qos_latency_tolerance_us; do echo 0 | sudo tee "$f"; done

# PCIe : politique ASPM performance
echo performance | sudo tee /sys/module/pcie_aspm/parameters/policy

# GPU(s) : pas de runtime PM
for d in /sys/bus/pci/devices/*; do [ "$(cut -c1-4 "$d/class")" = 0x03 ] && echo on | sudo tee "$d/power/control"; done

# Wi-Fi et Bluetooth coupés
sudo rfkill block wifi bluetooth
```

Limites à garder en tête :

- `idle=poll` n'a pas d'équivalent à chaud : le bloc A se teste uniquement par GRUB.
- La politique ASPM `performance` n'est pas `pcie_aspm=off`. Elle peut aussi être refusée si le firmware garde le contrôle d'ASPM : une écriture en échec est normale et biaise le test.
- `amd_pstate=disable` change de driver au démarrage, ce qui est impossible à chaud.
- La valeur d'origine de `pm_qos_latency_tolerance_us` peut être `auto` : consulte `etat-origine.txt`.
- Couper le Wi-Fi coupe aussi une session SSH sans fil.

Retour à l'état d'origine après un test à chaud : redémarre, puis réactive explicitement Wi-Fi et Bluetooth, car l'état rfkill peut être restauré au démarrage.

```bash
sudo rfkill unblock wifi bluetooth
```

## 5. Retour arrière

À la fin des tests, restaure la copie, régénère GRUB, redémarre et vérifie : le retour n'est terminé qu'une fois la cmdline contrôlée.

1. Si tu as pu modifier `/etc/default/grub` légitimement depuis la sauvegarde (timeout, thème, autre paramètre), compare d'abord : `grub.orig` écrase le fichier en entier.

   ```bash
   diff ~/stab/grub.orig /etc/default/grub
   ```

2. Restauration :

   ```bash
   sudo cp ~/stab/grub.orig /etc/default/grub
   sudo update-grub
   sudo reboot
   ```

3. Vérification après redémarrage :

   ```bash
   diff /proc/cmdline ~/stab/cmdline.orig && echo identique
   ./stab-etat.sh courant
   rfkill list
   ```

   Une différence limitée à `BOOT_IMAGE` (chemin du noyau) est normale après une mise à jour de noyau. Toute autre différence signifie que la restauration n'a pas pris. `./stab-etat.sh courant` compare l'état actuel à `etat-origine.txt` (la ligne de date diffère toujours).

## 6. Si le système ne démarre plus

Le premier réflexe est de retirer les paramètres ajoutés depuis le menu GRUB, sans rien réécrire sur le disque.

**Niveau 1 : édition temporaire dans GRUB.**

1. Au démarrage, fais apparaître le menu GRUB. Sur Ubuntu, il est masqué quand le système est seul sur la machine : maintiens Échap (UEFI, cas probable sur un ROG Strix) ou Maj (BIOS hérité) dès l'allumage.
2. Sélectionne l'entrée d'Ubuntu et appuie sur `e`.
3. Repère la ligne qui commence par `linux`, va à sa fin et supprime les paramètres ajoutés pour le test.
4. Démarre avec `Ctrl+X` ou `F10`.

Cette modification n'est valable que pour ce démarrage. Une fois dans le système, applique la procédure de retour arrière pour la rendre définitive.

**Niveau 2 : dernier recours, depuis une clé USB live Ubuntu.** À utiliser seulement si le menu GRUB est inaccessible ou si le niveau 1 échoue. Les noms de partitions sont à adapter (`lsblk` les liste), et ce schéma ne couvre ni le chiffrement LUKS ni les sous-volumes btrfs :

```bash
sudo mount /dev/<racine> /mnt
sudo mount /dev/<efi> /mnt/boot/efi
for d in dev proc sys; do sudo mount --bind /$d /mnt/$d; done
sudo chroot /mnt
cp /home/<utilisateur>/stab/grub.orig /etc/default/grub
update-grub
exit
```

Puis redémarre en retirant la clé.

## 7. Journal de test

Une ligne par essai, remplie au fur et à mesure : sans elle, la comparaison entre essais n'est plus possible. Durée minimale d'un essai : au moins trois fois l'intervalle moyen entre deux plantages mesuré à l'essai 0. Cette règle est une heuristique, pas une garantie : un plantage rare exige un essai long.

| Essai | Date | Paramètres actifs | À chaud | Début | Durée tenue | Résultat | Symptôme et logs |
| --- | --- | --- | --- | --- | --- | --- | --- |
| 0 | | Aucun (origine) | Non | | | | |
| 1 | | Blocs A à E | Non | | | | |
| 2 | | | | | | | |
| 3 | | | | | | | |
| 4 | | | | | | | |
| 5 | | | | | | | |