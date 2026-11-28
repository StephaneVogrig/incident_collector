# Spécification v1.3 : Option `-Sessions [N]` (Script de collecte d'incidents Windows)

> **Changement v1.2 → v1.3 :** refonte du §1 (déclaration des paramètres). `-Sessions` et la collecte post-crash deviennent deux jeux de paramètres mutuellement exclusifs. Les autres sections sont inchangées, sauf mentions de cohérence (§9).

## 1. Paramètre et mode d'exécution

### 1.1 Déclaration des paramètres

Deux jeux de paramètres PowerShell :

```powershell
[CmdletBinding(DefaultParameterSetName='Collecte', PositionalBinding=$false)]
param(
  # --- Jeu 'Sessions' : mode console ---
  [Parameter(ParameterSetName='Sessions', Mandatory)]
  [switch]$Sessions,

  [Parameter(ParameterSetName='Sessions', Position=0)]
  [ValidateRange(0,[int]::MaxValue)]
  [int]$N = 10,

  # --- Jeu 'Collecte' : comportement par défaut existant ---
  [Parameter(ParameterSetName='Collecte', Position=0)] [string]$HwinfoDir,
  [Parameter(ParameterSetName='Collecte', Position=1)] [string]$OutDir,
  [Parameter(ParameterSetName='Collecte', Position=2)] $Fenetre
)
```

- **`-Sessions` (switch) :** active le mode console. Utilisable seul (`N = 10`) ou suivi d'une valeur (`-Sessions 5`), la valeur étant liée par position à `$N`.
- **Défaut `10` :** porté par `$N`, appliqué uniquement dans le jeu `Sessions`.
- **Absence de `-Sessions` :** jeu `Collecte` par défaut, comportement inchangé (collecte post-crash, Markdown, HWiNFO).
- **Bascule de mode :** sur `$PSCmdlet.ParameterSetName -eq 'Sessions'`, jamais sur la présence ou la valeur de `$N`.
- **Exclusivité mutuelle :** `-Sessions` ne peut pas être combiné avec `-HwinfoDir`, `-OutDir` ou `-Fenetre`. PowerShell refuse la combinaison (erreur de jeu de paramètres) ; aucun paramètre n'est ignoré silencieusement.
- **Compatibilité :** les attributs `Position` du jeu `Collecte` doivent reproduire **l'ordre positionnel du script existant** afin de préserver les appels actuels (planificateur de tâches, scripts appelants). Les positions ci-dessus sont à aligner sur la signature réelle.
- **À valider avant implémentation :** comportement du binding sur Windows PowerShell 5.1 et PowerShell 7 (liaison de `-Sessions 5`, erreur sur combinaison de jeux).

### 1.2 Mode d'exécution

- **Mode console uniquement :** Lecture seule absolue ; aucun rapport, aucun fichier généré, ni création du dossier `Incidents\` (arrêt du script immédiatement après l'affichage).
- **Tri :** Antéchronologique (`0` pour la session en cours, `-1`, `-2`…).

### 1.3 Validation des entrées

- `-Sessions abc` (non numérique) ou `-Sessions -3` (négatif) → erreur bloquante levée **au binding** (conversion `[int]` et `[ValidateRange]`) ; aucune validation manuelle dans le corps du script.
- `-Sessions N` supérieur aux démarrages disponibles → afficher les sessions trouvées et conclure par le message `Historique insuffisant`.
- `-Sessions 0` affiche les données de la session courante.
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
- `Indéterminé` (aucun événement de fin exploitable, purge/rotation du journal, `1074` non qualifiable, ou événement corrompu).

## 4. Extraction du code BugCheck
- **Source :** Propriété XML `BugcheckCode` de l'événement `Kernel-Power 41` (indépendant de la langue de l'OS), formaté via `'0x{0:X}' -f $valeur`.
- **Rôle de `WER-SystemErrorReporting 1001` :** Confirme la présence d'un BSOD si le `41` est absent ou muet.
- **Affichage :** Code brut uniquement, sans table de correspondance symbolique (approche incrémentale). Ne jamais extrapoler un code manquant.

## 5. Calcul de l'uptime (`Durée`)
- **Unité :** Durée brute (périodes de veille incluses).
- **Arrêt propre :** Exacte (`horodatage 13/6006 − horodatage démarrage`).
- **Arrêt anormal ou `Indéterminé` :** Préfixée par `≥` (borne basse calculée sur le dernier événement présent dans le journal Système avant le démarrage suivant).
- **Légende conditionnelle :** Afficher la note explicative du symbole `≥` sous le tableau **uniquement** si au moins une ligne affichée comporte ce préfixe.

## 6. Rattachement, qualification et gestion des cas limites
- **Arrêts anormaux (`41`, `6008`, `1001`) :** Rattachés au **dernier démarrage précédant strictement leur horodatage** (sans fenêtre temporelle arbitraire).
- **Arrêts propres (`13`, `6006`) :** Recherchés dans l'intervalle `[démarrage k, démarrage k−1[`.
- **Qualification `User32 1074` :** Basée **exclusivement sur les champs XML/propriétés structurés** (type d'action, code raison et processus émetteurs tels que `MoUsoCoreWorker`, `TrustedInstaller`), sans analyse textuelle par mots-clés. **Règle de repli :** si les champs structurés sont absents, vides ou ne permettent pas de trancher avec certitude, la session est automatiquement classée en `Indéterminé`.
- **Démarrage rapide (*Fast Startup*) :** Lecture systématique de `Kernel-Boot 27` (type de démarrage) pour corriger l'interprétation des paires `12/13` lors des sorties d'hibernation hybride. **Règle de repli :** si l'événement `27` est absent du journal, le script considère par défaut un démarrage standard (désactivation silencieuse de la correction d'hibernation hybride pour cette session, sans notification spécifique).

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

## 9. Résilience, invariants et limites documentées
- **Protection granulaire à l'exécution :** Chaque itération de reconstruction de session ainsi que chaque extraction de propriétés XML (`BugcheckCode`, `User32 1074`) doivent être encapsulées dans des blocs `try/catch` dédiés avec vérification de non-nullité. Un événement malformé ou corrompu bascule la session concernée en statut `Indéterminé` (avec durée préfixée par `≥` si applicable) sans jamais interrompre l'exécution globale ni l'affichage des autres sessions.
- **Invariants :** Aucune altération du comportement par défaut (collecte post-crash, génération Markdown, extraction HWiNFO), garantie par le jeu de paramètres `Collecte` par défaut et la conservation de l'ordre positionnel existant (§1.1) ; mutualisation des fonctions de requêtage `Get-WinEvent`.
- **Limites à documenter en en-tête :** Profondeur de l'historique bornée par la rétention du journal Système Windows (aucun bridage artificiel par `-MaxEvents` fixe).
