# Journal de bord — RÉSULTATS-BF

Mis à jour le 25 octobre 2026 · rédaction : Malick (`malickabdoul`), à relire par le groupe

## Rôles

Chaque membre tient un domaine, et chacun a aussi contribué hors du sien, comme l'exige la rotation ; l'historique Git en fait foi.

| Membre (identités Git) | Rôle | Contributions principales |
| --- | --- | --- |
| William OUOBA (`Yoru002`, `William`) | Architecte réseau et répartition | dépôt et Vagrantfile, répartiteur HAProxy généré depuis `noeuds.yml`, E1 (keepalived), E2 (Prometheus, Grafana), `scale.sh`, mesures V1, V5 et V6, README ; relecture et fusion des pull requests |
| Pégué Judicaël OUÉDRAOGO (`pegueo2000`) | Ingénieur données | PostgreSQL et jeu de 50 000 lignes, réplication, bascule chronométrée, mesures V4 et R5, guide et journal de la partie données ; hors domaine : connexion de l'application à deux bases, correctif de `HEAD /sante` |
| Fatahou (`Fatahou980`, `TESTEUR04`) | Ingénieur applicatif | service applicatif sans état et son provisionnement ; hors domaine : bascule avec reconfiguration des serveurs (choix C), mesures V1 et V2 avec documentation |
| Malick (`malickabdoul`, `KAM`) | Ingénieur essais et observabilité | scripts V3 (montée en charge N=2 puis N=4) et R2 (preuve d'idempotence), correctif de `mesure_v1.sh` (PR #18), dossier d'architecture, journal de bord ; hors domaine : correctif de la recopie de bdd2 après bascule (PR #19), mise à jour du README |

Fatahou a travaillé sur deux machines, d'où ses deux identités Git ; le fichier `.mailmap` du dépôt les regroupe, comme celles des autres membres.

## Chronologie

Le socle a fonctionné de bout en bout dès le 11/10 ; la fin du projet porte sur les mesures et les livrables écrits. Les étapes suivent les pull requests fusionnées dans `main`, une branche par sujet.

| Date | Étape | Qui |
| --- | --- | --- |
| 25/10 | PR #19 fusionnée : bdd2 n'est plus recopiée après une bascule | Malick, fusion Pégué |
| 24/10 | PR #18 : scripts V3 et R2, correctif de V1 | Malick |
| 24/10 | PR #17 : mesures V1 et V2 documentées | Fatahou |
| 24/10 | PR #16 (E2) fusionnée, README complet, V5 refaite (18 min 26 s) | William |
| 13/10 | PR #15 : `scale.sh` pour ajouter ou retirer des serveurs | William |
| 12/10 | PR #14 : bascule qui reconfigure les serveurs (choix C) ; E2 développée | Fatahou, William |
| 11/10 | PR #9 à #13 : port 3000, répartiteur généré, E1 et V6, script V5, V1 avec N=2 | William |
| 10/10 | PR #2 à #7 : service sans état, connexion aux deux bases, mesures V4, guide et journal données | Fatahou, Pégué |
| 09/10 | PR #1 : réplication bdd2 et bascule chronométrée | Pégué |
| 08/10 | Visio de lancement, dépôt initialisé, Vagrantfile, bdd1 | groupe, William, Pégué |
| 05/10 | Lancement du projet dans le groupe | groupe |

## Décisions et pourquoi

La décision qui a le plus pesé est le choix C : il a fait passer le débit d'environ 86 à 156 req/s sans rendre la bascule plus lente.

| Décision | Pourquoi |
| --- | --- |
| Groupe réseau 4 (`192.168.59.0/24`) au lieu de 12 | VirtualBox refuse les adresses hors de `192.168.56.0/21` ; 12 a été ramené à 4 (12 − 8) |
| Une seule table des machines (`noeuds.yml`) lue par tous les scripts | aucune adresse écrite deux fois : ajouter un serveur ne peut pas oublier le répartiteur (R3) |
| Sonde `GET /sante` chaque seconde, 2 échecs pour écarter un serveur | détection en 2 à 3 s, sous la limite de 5 s (R4) ; une première version à 6 s a été rejetée |
| Service applicatif en Python, port 3000, une connexion par requête | sans état, moins de 100 lignes, aucune dépendance lourde ; port du sujet |
| Jeu de données déterministe, sans `random()` | une reconstruction redonne le même contenu : les mesures restent comparables |
| Deux rôles PostgreSQL (`appuser`, `replicator`) | moindre privilège : l'application ne peut que lire |
| Bascule manuelle qui refuse de promouvoir bdd2 si bdd1 répond | éviter deux primaires qui divergent ; un outil automatique demanderait plus de machines |
| Choix C : la primaire en premier dans `DB_HOST`, inversée par `bascule.sh` | débit ~86 → ~156 req/s (mesure unique) ; la bascule reconfigure les serveurs pour rester rapide |
| Après une bascule, reconstruire la paire de bases | plus simple et plus sûr que réintégrer l'ancienne primaire |
| Deux extensions seulement (E1 et E2) | le sujet en exige deux ; E3 et E4 n'apportent pas de points supplémentaires |
| Une branche et une pull request par sujet ; `main` toujours reconstructible | règle du groupe : une pull request n'est fusionnée que si `vagrant up` fonctionne |

## Difficultés et solutions

La plupart des problèmes ont été trouvés en reconstruisant la plateforme sur un clone neuf ou en relisant le code d'un autre membre ; un seul reste sans cause établie.

| Difficulté | Comment elle a été levée |
| --- | --- |
| Vagrant 2.3.4 incompatible avec VirtualBox 7.2 | passage à Vagrant 2.4.9 |
| Réseau privé impossible sous Linux : modules `vboxnetadp` et `vboxnetflt` absents | chargés par `modprobe`, puis rendus permanents |
| Adresses `192.168.67.x` (groupe 12) refusées par VirtualBox | groupe réseau 4, `192.168.59.0/24` |
| `apt-get update` en échec sur connexion lente (« Hash Sum mismatch ») | réessais automatiques et nettoyage des listes dans `common.sh` |
| `noeuds.yml` généré au mauvais endroit et versionné ; un commentaire mal placé cassait `lib.sh` | chemin absolu, `**/noeuds.yml` ignoré par Git, commentaires sur leur propre ligne |
| PR #8 : lb1 échouait sur un clone neuf (HAProxy non installé, calcul bash faux, backend inexistant, sonde TCP seulement, détection en ~6 s) | répartiteur réécrit et généré depuis `noeuds.yml` (PR #10), vérifié sur un clone neuf |
| Après une bascule, l'application restait en 503 : elle n'interrogeait que bdd1 | deux adresses de base avec `target_session_attrs=read-write` |
| Débit plafonné à ~86 req/s, avec 2 comme avec 4 serveurs : chaque requête tentait d'abord la réplique | choix C (primaire d'abord), ~156 req/s |
| `HEAD /sante` répondait 200 sans interroger la base ; `serveur.py` atteignait 100 lignes | `HEAD /sante` renvoie 404, fichier ramené à 99 lignes |
| Script V2 : verdict toujours « non conforme » (variable `awk` non transmise) | corrigé avant la mesure |
| Une mesure V1 avec 4 serveurs écrasait celle avec 2 | un fichier de résultat par nombre de serveurs (PR #18) |
| Après une bascule, `vagrant provision` effaçait bdd2 : la promotion supprime `standby.signal`, qui déclenchait une nouvelle copie | témoin de copie hors du répertoire de données (PR #19) ; vérifié sur un banc local, à valider sur les VM |
| `/sante` en 503 passager après des reconstructions partielles | cause non établie ; la sonde de HAProxy absorbe ces écarts |

- [x] Fichier `.mailmap` ajouté : il regroupe les identités Git de chaque membre (`git shortlog -sne` affiche une ligne par personne), comme le proposait le journal de la partie données.
