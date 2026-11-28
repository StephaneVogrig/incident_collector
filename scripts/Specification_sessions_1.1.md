# Spécification : Option `-Sessions [N]` (Script de collecte d'incidents Windows)

## 1. Paramètre et mode d'exécution
- **Paramètre :** `-Sessions [N]`, valeur par défaut : `10`.
- **Signature :** `[CmdletBinding(PositionalBinding=$false)]` pour accepter l'argument optionnel ; les autres paramètres (`$HwinfoDir`, `$OutDir`, `$Fenetre`) deviennent strictement nommés.
- **Mode console uniquement :** Lecture seule absolue ; aucun rapport, aucun fichier généré, ni création du dossier `Incidents\` (arrêt du script immédiatement après l'affichage).
- **Tri :** Antéchronologique (`0` pour la session en cours, `-1`, `-2`…).
- **Validation des entrées :**
  - `-Sessions N` non numerique ou negatif → erreur bloquante.
  - `-Sessions N` supérieur aux démarrages disponibles → afficher les sessions trouvées et conclure par le message `Historique insuffisant`.
  - `-Sessions 0` affiche les donnees de la sessions courante.
- **Portée de `N` :** S'applique strictement aux démarrages (indices `0` à `-(N-1)`). Les lignes de veille intercalées s'ajoutent en sus (le total de lignes affichées peut excéder `N`).

## 2. Structure des colonnes et calcul des sessions
- **Colonnes :** `Indice` | `Début` (18 caractères) | `Durée` | `Fin de session` (en dernière position pour absorber les libellés longs).
- **Ligne `0` (session en cours) :** `Durée` = heure courante − démarrage ; `Fin de session` = `En cours`.
- **Optimisation de lecture :** Pour `N` sessions demandées, lire uniquement les `N` derniers événements de démarrage (`Kernel-General 12`). L'uptime de la session `-(N-1)` se déduit du démarrage précédent déjà en mémoire (ou du premier événement disponible). Signaler `Historique insuffisant` uniquement si le journal contient strictement moins de `N` démarrages.

## 3. Statuts de fin de session (vocabulaire fermé)
- `Arrêt normal` (`Kernel-General 13` ou `EventLog 6006`, hors redémarrage/mise à jour).
- `Redémarrage` (`User32 1074` qualifié en redémarrage).
- `Mise à jour` (`User32 1074` qualifié en mise à jour).
- `Coupure / gel` (`Kernel-Power 41` ou `EventLog 6008`, sans BSOD).
- `Erreur fatale (Écran bleu - BSOD) : 0x…` (code hexadécimal issu du `BugcheckCode`).
- `Erreur fatale (Écran bleu - BSOD) : code non enregistré` (`WER 1001` présent mais `BugcheckCode` absent ou nul dans le `41`).
- `Indéterminé` (aucun événement de fin exploitable, purge/rotation du journal, ou `1074` non qualifiable).

## 4. Extraction du code BugCheck
- **Source :** Propriété XML `BugcheckCode` de l'événement `Kernel-Power 41` (indépendant de la langue de l'OS), formaté via `'0x{0:X}' -f $valeur`.
- **Rôle de `WER-SystemErrorReporting 1001` :** Confirme la présence d'un BSOD si le `41` est absent ou muet.
- **Affichage :** Code brut uniquement, sans table de correspondance symbolique (approche incrémentale). Ne jamais extrapoler un code manquant.

## 5. Calcul de l'uptime (`Durée`)
- **Unité :** Durée brute (périodes de veille incluses).
- **Arrêt propre :** Exacte (`horodatage 13/6006 − horodatage démarrage`).
- **Arrêt anormal ou `Indéterminé` :** Préfixée par `≥` (borne basse calculée sur le dernier événement présent dans le journal Système avant le démarrage suivant).
- **Légende conditionnelle :** Afficher la note explicative du symbole `≥` sous le tableau **uniquement** si au moins une ligne affichée comporte ce préfixe.

## 6. Rattachement et qualification des événements
- **Arrêts anormaux (`41`, `6008`, `1001`) :** Rattachés au **dernier démarrage précédant strictement leur horodatage** (sans fenêtre temporelle arbitraire).
- **Arrêts propres (`13`, `6006`) :** Recherchés dans l'intervalle `[démarrage k, démarrage k−1[`.
- **Qualification `User32 1074` :** Basée **exclusivement sur les champs XML/propriétés structurés** (type d'action, code raison et processus émetteurs tels que `MoUsoCoreWorker`, `TrustedInstaller`), sans analyse textuelle par mots-clés. Si les champs structurés ne permettent pas de trancher, classer en `Indéterminé`.
- **Démarrage rapide (*Fast Startup*) :** Lecture systématique de `Kernel-Boot 27` (type de démarrage) pour corriger automatiquement l'interprétation des paires `12/13` lors des sorties d'hibernation hybride.

## 7. Gestion des veilles et hibernations
- **Événements :** Entrée en veille (`Kernel-Power 42`, `506`) et sortie (`Kernel-Power 107`, `507`, `Power-Troubleshooter 1`). Hibernation et veille connectée fusionnées sous le libellé unique `Veille`.
- **Positionnement :** Lignes intercalées chronologiquement entre les démarrages (veilles de la session en cours affichées au-dessus de la ligne `0`), sans numéro d'indice.
- **Formatage :**
  - Colonne `Début` : `HH:mm → HH:mm` (ajouter `+1j` si changement de jour).
  - Colonne `Durée` : durée de la veille (ou `?` si coupure pendant la veille, avec `HH:mm → ?` en colonne `Début`).
  - Colonne `Fin de session` : `Veille`.

## 8. Codes couleur console (`Write-Host`)
- **Vert :** `Arrêt normal`, `Redémarrage`, `Mise à jour`.
- **Rouge :** `Coupure / gel`, `Erreur fatale (Écran bleu - BSOD)…`.
- **Jaune :** `Indéterminé`.
- **Cyan :** `En cours`.
- **Couleur console par défaut :** Lignes de `Veille` (aucune couleur forcée pour préserver la lisibilité sur fond clair ou sombre).
- **Accessibilité :** La couleur accompagne le statut textuel complet sans jamais s'y substituer.

## 9. Invariants et limites documentées
- **Invariants :** Aucune altération du comportement par défaut (collecte post-crash, génération Markdown, extraction HWiNFO) ; mutualisation des fonctions de requêtage `Get-WinEvent`.
- **Limites à documenter en en-tête :** Profondeur de l'historique bornée par la rétention du journal Système Windows (aucun bridage artificiel par `-MaxEvents` fixe).
