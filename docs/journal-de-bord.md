# Journal de bord : projet RÉSULTATS-BF

Mis à jour le 25 octobre 2026 par Malick, à relire par le groupe.

## Rôles

Chaque membre avait un domaine. Comme le demande le sujet, chacun a aussi travaillé en dehors du sien, ce que montre l'historique Git.

| Membre (identités Git) | Rôle | Ce qu'il a fait |
| --- | --- | --- |
| William OUOBA (`Yoru002`, `William`) | Architecte réseau et répartition | dépôt et Vagrantfile, répartiteur HAProxy, E1 (keepalived), E2 (Prometheus et Grafana), `scale.sh`, mesures V1, V5 et V6, README, relecture et fusion des pull requests |
| Pégué Judicaël OUÉDRAOGO (`pegueo2000`) | Ingénieur données | PostgreSQL et les 50 000 lignes de données, réplication, bascule, mesures V4 et R5, guide et journal de la partie données. En dehors de son domaine : connexion de l'application aux deux bases, correction de `HEAD /sante` |
| Fatahou (`Fatahou980`, `TESTEUR04`) | Ingénieur applicatif | service applicatif sans état et son installation. En dehors de son domaine : bascule qui reconfigure les serveurs (choix C), mesures V1 et V2 |
| Malick (`malickabdoul`, `KAM`) | Ingénieur essais et observabilité | scripts V3 (montée en charge) et R2 (idempotence), correction de `mesure_v1.sh`, dossier d'architecture, journal de bord. En dehors de son domaine : correction de la copie de bdd2 après une bascule (PR #19), mise à jour du README |

Fatahou a travaillé sur deux machines, d'où ses deux identités Git. Le fichier `.mailmap` du dépôt regroupe les identités de chaque membre.

## Chronologie

Le socle fonctionnait en entier dès le 11/10. Ensuite, nous avons surtout travaillé sur les mesures et les documents. Chaque étape correspond à une pull request fusionnée dans `main`.

| Date | Étape | Qui |
| --- | --- | --- |
| 25/10 | PR #19 : bdd2 n'est plus recopiée après une bascule (fusionnée par Pégué) | Malick |
| 24/10 | PR #18 : scripts V3 et R2, correction de V1 | Malick |
| 24/10 | PR #17 : mesures V1 et V2 | Fatahou |
| 24/10 | PR #16 : supervision E2, README complet, nouvelle mesure V5 (18 min 26 s) | William |
| 13/10 | PR #15 : script `scale.sh` pour ajouter ou retirer des serveurs | William |
| 12/10 | PR #14 : la bascule reconfigure les serveurs (choix C) ; travail sur E2 | Fatahou, William |
| 11/10 | PR #9 à #13 : port 3000, répartiteur généré automatiquement, E1 et V6, script V5, V1 avec 2 serveurs | William |
| 10/10 | PR #2 à #7 : service sans état, connexion aux deux bases, mesures V4, guide et journal de la partie données | Fatahou, Pégué |
| 09/10 | PR #1 : réplication de bdd2 et bascule chronométrée | Pégué |
| 08/10 | réunion en visio, création du dépôt, Vagrantfile, bdd1 | tout le groupe, William, Pégué |
| 05/10 | lancement du projet dans le groupe | tout le groupe |

## Décisions et pourquoi

La décision la plus importante a été de mettre la base primaire en premier (choix C) : le débit est passé d'environ 86 à 156 requêtes par seconde, sans ralentir la bascule.

| Décision | Pourquoi |
| --- | --- |
| Groupe réseau 4 (`192.168.59.0/24`) au lieu de 12 | VirtualBox refuse les adresses en dehors de `192.168.56.0/21`. Nous avons donc pris 12 − 8 = 4. |
| Une seule table des machines (`noeuds.yml`), lue par tous les scripts | Aucune adresse n'est écrite deux fois, donc on ne peut pas oublier un serveur dans le répartiteur (R3). |
| Sonde `GET /sante` toutes les secondes, serveur retiré après 2 échecs | Détection en 2 à 3 s, sous la limite de 5 s (R4). Une première version mettait environ 6 s, nous l'avons corrigée. |
| Service en Python sur le port 3000, une connexion par requête | Pas d'état, moins de 100 lignes, pas de dépendance lourde, et c'est le port du sujet. |
| Données toujours identiques (pas de `random()`) | Une reconstruction redonne les mêmes données, donc les mesures restent comparables. |
| Deux comptes PostgreSQL (`appuser` et `replicator`) | L'application ne peut que lire : elle a seulement les droits dont elle a besoin. |
| Bascule à la main, refusée si bdd1 répond encore | Pour ne jamais avoir deux bases primaires. Un outil automatique demanderait plus de machines. |
| Choix C : la base primaire en premier dans `DB_HOST`, ordre inversé par `bascule.sh` | Débit d'environ 86 à 156 req/s (une seule mesure). La bascule reconfigure les serveurs pour rester rapide. |
| Après une bascule, on reconstruit les deux bases | Plus simple et plus sûr que de remettre l'ancienne primaire en réplique. |
| Seulement deux extensions (E1 et E2) | Le sujet en demande deux. E3 et E4 ne rapportent pas de points en plus. |
| Une branche et une pull request par sujet | Règle du groupe : une pull request n'est fusionnée que si `vagrant up` marche. |

## Difficultés et solutions

La plupart des problèmes ont été trouvés en reconstruisant la plateforme sur un clone neuf, ou en relisant le code d'un autre membre. Un seul reste sans explication.

| Difficulté | Solution |
| --- | --- |
| Vagrant 2.3.4 ne marche pas avec VirtualBox 7.2 | passage à Vagrant 2.4.9 |
| Sous Linux, réseau privé impossible : modules `vboxnetadp` et `vboxnetflt` non chargés | chargés avec `modprobe`, puis à chaque démarrage |
| Adresses `192.168.67.x` (groupe 12) refusées par VirtualBox | passage au groupe réseau 4, `192.168.59.0/24` |
| `apt-get update` échoue sur une connexion lente (« Hash Sum mismatch ») | `common.sh` réessaie et nettoie les listes |
| `noeuds.yml` créé au mauvais endroit et envoyé sur Git ; un commentaire mal placé cassait `lib.sh` | chemin absolu, `noeuds.yml` ignoré par Git, commentaires sur leur propre ligne |
| PR #8 : lb1 ne démarrait pas sur un clone neuf (HAProxy pas installé, calcul bash faux, sonde qui ne testait que le port, environ 6 s pour retirer un serveur) | répartiteur réécrit et généré depuis `noeuds.yml` (PR #10), testé sur un clone neuf |
| Après une bascule, l'application restait en 503 car elle ne connaissait que bdd1 | l'application reçoit les deux adresses, avec `target_session_attrs=read-write` |
| Débit bloqué à environ 86 req/s, avec 2 comme avec 4 serveurs, car chaque requête essayait d'abord la réplique | choix C (primaire en premier) : environ 156 req/s |
| `HEAD /sante` répondait 200 sans tester la base, et `serveur.py` faisait 100 lignes | `HEAD /sante` renvoie 404, fichier ramené à 99 lignes |
| Le script V2 disait toujours « non conforme » (variable `awk` mal passée) | corrigé avant la mesure |
| Une mesure V1 avec 4 serveurs écrasait celle avec 2 | un fichier de résultat par nombre de serveurs (PR #18) |
| Après une bascule, `vagrant provision` effaçait bdd2 : la promotion supprime `standby.signal`, ce qui relançait la copie | un fichier témoin placé hors des données de PostgreSQL (PR #19), à vérifier sur les VM |
| `/sante` répond parfois 503 quelques secondes après une reconstruction partielle | cause pas trouvée ; la sonde de HAProxy compense |

Nous avons aussi ajouté le fichier `.mailmap` : `git shortlog -sne` affiche maintenant une seule ligne par membre.
