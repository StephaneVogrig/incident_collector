# Spécification – Sélection de session pour la collecte post-crash

## 1. Objectif

Permettre à l'utilisateur de choisir le démarrage Windows sur lequel effectuer une collecte post-crash.

La fonctionnalité doit permettre de :
- Consulter les derniers démarrages Windows.
- Identifier comment chaque session s'est terminée.
- Distinguer les arrêts volontaires, les redémarrages et les mises à jour Windows.
- Lancer la collecte existante sur la session sélectionnée.

Il ne s'agit pas de développer un outil d'analyse des causes de crash, mais de faciliter le repérage et la sélection d'une session pertinente.

## 2. Utilisation

Deux modes sont disponibles.

**Affichage des sessions :**

```powershell
.\collecte_incident_windows.ps1 -Sessions
.\collecte_incident_windows.ps1 -Sessions 10
```

Le second exemple limite l'affichage aux dix dernières sessions.

**Collecte sur une session choisie :**

```powershell
.\collecte_incident_windows.ps1 -Session -2
```

L'indice `-2` désigne la deuxième session précédant le démarrage actuel.

Sans paramètre `-Session`, le comportement actuel est conservé.

## 3. Présentation des sessions

Chaque session doit présenter les informations suivantes :

- **Indice** : identifiant relatif du démarrage.
- **Début** : date et heure du démarrage.
- **Durée** : durée de la session (voir §8).
- **État** : résultat de la fermeture.
- **Type** : contexte de l'arrêt ou du redémarrage.

Exemple :

| Indice | Début | Durée | État | Type |
|---:|---|---:|---|---|
| 0 | 15/11/26 18:42 | 01h12 | En cours | — |
| -1 | 14/11/26 09:17 | 09h25 | Arrêt normal | Redémarrage |
| -2 | 12/11/26 21:06 | 11h40 | Arrêt normal | Mise à jour |
| -3 | 10/11/26 14:32 | ≥ 03h18 | Arrêt anormal | Non déterminé |
| -4 | 09/11/26 08:15 | 04h20 | Arrêt normal | Arrêt volontaire |

Les états sont distingués par couleur :
- Vert : arrêt normal.
- Rouge : arrêt anormal.
- Jaune : état indéterminé.
- Cyan : session en cours.

La couleur représente le résultat technique de la fermeture, indépendamment de son contexte.

## 4. Identification des sessions

Un démarrage Windows est identifié par l'événement `Kernel-General 12` du journal `System`.

Les démarrages sont présentés du plus récent au plus ancien et reçoivent un indice relatif :

- `0` : démarrage actuel.
- `-1` : démarrage précédent.
- `-2` : démarrage antérieur.
- Etc.

Une session correspond à la période comprise entre deux démarrages successifs.

La session `0` est en cours. Elle est affichée mais ne peut pas être sélectionnée pour une collecte post-crash.

Les indices doivent être strictement identiques dans les modes affichage et collecte.

## 5. Détermination de l'état de fermeture

L'état est déterminé à partir des événements rattachés à la session (§7). Trois états sont possibles.

**Arrêt anormal (rouge)**

La session est classée en arrêt anormal dès qu'au moins un des événements suivants lui est rattaché :
- `Kernel-Power 41`.
- `EventLog 6008`.
- `WER-SystemErrorReporting 1001` signalant un bugcheck.

Cet état prime sur tout événement de fermeture normale éventuellement présent.

Lorsqu'il est disponible, le code BugCheck est extrait des propriétés structurées de l'événement 41 ou 1001 et présenté au format hexadécimal.

**Arrêt normal (vert)**

Aucun événement d'anormalité n'est rattaché à la session, et au moins un des événements suivants l'est :
- `Kernel-General 13`.
- `EventLog 6006`.

**Indéterminé (jaune)**

Aucun événement de fermeture normale ni d'anormalité n'est rattaché à la session. Un événement `1001` ne signalant pas de bugcheck n'est pas un signal d'anormalité.

## 6. Identification du type de fermeture

En complément de l'état technique, le script doit identifier le contexte de fermeture lorsque les informations disponibles le permettent :

- **Arrêt volontaire** : arrêt demandé par l'utilisateur.
- **Redémarrage** : redémarrage demandé explicitement.
- **Mise à jour** : arrêt ou redémarrage associé à une opération de mise à jour Windows.
- **Non déterminé** : informations insuffisantes.

L'événement `User32 1074` du journal `System` constitue la source de cette identification. Ses propriétés structurées sont exploitées : processus demandeur, code de raison et action demandée.

Le type est déterminé par le dernier `User32 1074` rattaché à la session (§7), selon l'ordre de priorité suivant :

1. Si le processus demandeur ou le code de raison indique une mise à jour Windows : **Mise à jour**.
2. Sinon, selon l'action demandée : **Redémarrage** (restart) ou **Arrêt volontaire** (shutdown, power off).
3. Si l'événement est absent, ou si ses propriétés sont inexploitables ou ne correspondent à aucun cas : **Non déterminé**.

Sur une session classée anormale ou Indéterminée (§5), le marqueur `?` est ajouté à tout type déterminé (par exemple `Mise à jour ?`), car la demande ne prouve pas la fermeture. Le type « Non déterminé » ne reçoit jamais de marqueur.

Une demande d'arrêt ou de redémarrage ne constitue pas une preuve de réussite de l'opération. Le type de fermeture reste donc distinct de son état technique et n'influence pas la couleur de l'état.

## 7. Rattachement des événements

Un événement est rattaché à la session pendant laquelle il a été enregistré, c'est-à-dire entre deux démarrages successifs, selon leur ordre d'enregistrement dans le journal.

Exception : certains événements constatent une fermeture anormale et ne peuvent être écrits qu'au démarrage suivant. Ils sont rattachés à la session précédente, en raison de leur nature et non de leur date ou ordre d'écriture :
- `Kernel-Power 41`.
- `EventLog 6008`.
- `WER-SystemErrorReporting 1001` signalant un bugcheck.
- Les erreurs WHEA fatales (à valider, voir §11).

Aucune fenêtre temporelle arbitraire ne doit être utilisée pour le rattachement.

## 8. Calcul des durées

Les durées doivent être calculées a partir d'horaire en UTC afin de tenir compte correctement des changements d'heure.

- Session en cours : durée écoulée depuis le démarrage.
- Arrêt normal : durée entre le démarrage et l'événement de fermeture.
- Arrêt anormal ou indéterminé : estimation à partir du dernier événement par ordre d’enregistrement avant le démarrage suivant.

Les durées estimées sont précédées du symbole `≥`, car elles constituent une borne inférieure et non une mesure exacte de la durée de la session.

Les périodes de veille sont incluses dans les durées de session.

## 9. Collecte sur la session sélectionnée

La collecte porte sur les événements rattachés à la session selon les règles du §7.

La sélection du CSV HWiNFO repose sur le contenu du fichier. Un fichier est candidat s’il contient au moins une mesure comprise entre le démarrage de la session et le démarrage suivant. Parmi les candidats, est retenu celui dont la dernière mesure dans cette période est la plus tardive ; à égalité, celui dont le nom ou la date de modification est le plus récent. Un seul fichier est retenu.

Si le fichier retenu couvre plusieurs sessions, seules les lignes comprises dans la période de la session sont exploitées. Un fichier tronqué par un crash reste valide s’il contient des mesures dans cette période.

Si aucun fichier candidat n’existe, le comportement de signalement existant est conservé.

Le rapport Markdown doit indiquer les dates de la session (en UTC), son état de fermeture, et son type lorsqu'il est déterminé.

## 10. Contraintes et gestion des erreurs

- Le mode affichage est strictement en lecture seule : aucune création de fichier ou de répertoire, aucune collecte.
- Un indice inexistant ou une session dont les bornes ne peuvent pas être établies entraîne une erreur explicite et l'arrêt de la collecte.
- Aucun remplacement automatique par une autre session n'est autorisé.
- Un événement absent ou inexploitable ne doit pas interrompre l'affichage des autres sessions.
- La profondeur de l'historique dépend de la rétention du journal Windows.
- Les indices sont relatifs et doivent être consultés à nouveau après chaque redémarrage.
- Les fonctionnalités existantes de collecte et de génération des rapports doivent être préservées.
- La signature et les paramètres positionnels existants doivent rester compatibles.
- Le script doit fonctionner sous Windows PowerShell 5.1 et PowerShell 7.

## 11. Points à valider

Les comportements suivants doivent être vérifiés sur des journaux Windows réels avant validation définitive :

- Identification des démarrages avec Fast Startup et hibernation.
- Ordre d'enregistrement et rattachement des événements 41, 6008 et 1001.
- Disponibilité des propriétés structurées de `User32 1074`.
- Identification fiable des redémarrages associés aux mises à jour Windows.
- Comportement en présence de journaux purgés ou incomplets.
- Classification des erreurs WHEA : lesquelles sont consignées au démarrage suivant (fatales) et lesquelles pendant la session.
- Présence et fiabilité de l’événement EventLog 6008 dans les cas de crash réels (BSOD, coupure, gel) : à mesurer sur des journaux réels pour évaluer la précision de l’estimation de durée du §8 (dernier événement avant le démarrage suivant), qui peut sous-estimer la durée lorsque le journal System est peu actif.

## 12. Tests de validation

Les tests doivent couvrir au minimum :

1. Arrêt normal.
2. Arrêt volontaire.
3. Redémarrage volontaire.
4. Redémarrage après mise à jour Windows.
5. Coupure ou arrêt anormal.
6. BSOD avec code BugCheck.
7. BSOD sans code exploitable.
8. Journal incomplet ou purgé.
9. Fast Startup activé.
10. Sélection de plusieurs indices historiques.
11. Correspondance exacte entre la session affichée et la période collectée.
12. Absence de création de fichiers en mode affichage.
13. Conservation du fonctionnement historique sans paramètre `-Session`.

## 13. Critères d'acceptation

La fonctionnalité est validée lorsque l'utilisateur peut :
- Visualiser les derniers démarrages Windows.
- Distinguer les fermetures normales, anormales et indéterminées.
- Repérer les arrêts volontaires, redémarrages et mises à jour.
- Sélectionner précisément une session par son indice.
- Obtenir une collecte limitée à cette session.
- Continuer à utiliser le script comme auparavant sans modifier ses appels existants.
