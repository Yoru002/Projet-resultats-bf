# RÉSULTATS-BF — Infrastructure résiliente et scalable avec Vagrant

> Projet de groupe — Master 1 Informatique, IBAM (Université Joseph Ki-Zerbo)
> Module **DevOps et infrastructures reproductibles** — enseignant : Dr SOMDA Flavien Hervé
> Année universitaire 2026 — 2027

RÉSULTATS-BF est une plateforme de consultation de résultats d'examens : un candidat saisit son matricule et obtient son résultat. L'application est volontairement minuscule (moins de 100 lignes de Python). **Ce qui compte, c'est l'infrastructure autour d'elle**, entièrement décrite en code, reconstructible en une commande, et qui continue de fonctionner quand une machine tombe.

Deux exigences priment sur tout le reste :

| Exigence | Comment elle est tenue |
|---|---|
| **Résilience** : la panne d'une machine n'interrompt pas le service | plusieurs serveurs applicatifs derrière un répartiteur qui sonde leur santé ; réplique PostgreSQL promouvable ; second répartiteur avec IP virtuelle (E1) |
| **Scalabilité** : plus de trafic = plus de machines, sans réécrire la configuration | serveurs applicatifs sans état ; nombre de serveurs passé en paramètre (`NB_APP`) ; configuration du répartiteur **générée** depuis la même table que le Vagrantfile |

---

## Sommaire

1. [Démarrage rapide](#1-démarrage-rapide)
2. [Prérequis](#2-prérequis)
3. [Architecture](#3-architecture)
4. [Configuration](#4-configuration)
5. [Utiliser la plateforme](#5-utiliser-la-plateforme)
6. [Opérations](#6-opérations)
7. [Extensions](#7-extensions)
8. [Exigences du sujet et vérifications](#8-exigences-du-sujet-et-vérifications)
9. [Scénarios de validation V1 à V6](#9-scénarios-de-validation-v1-à-v6)
10. [Structure du dépôt](#10-structure-du-dépôt)
11. [Dépannage](#11-dépannage)
12. [Limites connues](#12-limites-connues)
13. [Équipe et organisation](#13-équipe-et-organisation)

---

## 1. Démarrage rapide

Depuis une machine vierge disposant des [prérequis](#2-prérequis), dans un terminal (Git Bash sous Windows) :

```bash
git clone https://github.com/Yoru002/Projet-resultats-bf.git
cd Projet-resultats-bf

cp .env.exemple .env          # puis éditer .env : choisir ses propres mots de passe

vagrant up                    # construit le socle : 5 machines, 15 à 20 minutes
```

Aucune autre commande n'est nécessaire. Vérifier que tout répond :

```bash
curl http://localhost:8080/info
curl "http://localhost:8080/resultat?matricule=BF000042"
```

Réponses attendues :

```json
{"host": "app1"}
{"matricule": "BF000042", "nom": "Candidat 42", "serie": "D", "moyenne": 15.54, "admis": true}
```

Deux appels successifs à `/info` répondent `app1` puis `app2` : le répartiteur alterne entre les serveurs.

**Avec les deux extensions** (second répartiteur et supervision) :

```bash
LB2=1 OBS=1 vagrant up        # environ 4,3 Go de mémoire pour les machines virtuelles
```

**Reconstruire de zéro** :

```bash
vagrant destroy -f
vagrant up
```

> Lancer toujours `vagrant` **depuis la racine du dépôt**. Les variables `GROUPE`, `NB_APP`, `LB2` et `OBS` doivent être positionnées dans **chaque terminal** où l'on utilise Vagrant (voir [§4](#4-configuration)).

---

## 2. Prérequis

| Outil | Version | Rôle |
|---|---|---|
| [VirtualBox](https://www.virtualbox.org/) | 7.x | hyperviseur |
| [Vagrant](https://developer.hashicorp.com/vagrant) | 2.4.9 ou plus (2.3.x est incompatible avec VirtualBox 7.1 et 7.2) | décrit et construit les machines |
| Git | récent | récupérer le dépôt |
| curl | récent | tests |
| Apache Bench (`ab`) | facultatif | mesures de charge (V3) — à installer **sur le poste hôte**, pas dans les VM |

**Matériel** : 8 Go de mémoire minimum (le socle seul utilise environ 3 Go pour les machines virtuelles) et environ 10 Go d'espace disque. Fermer les applications lourdes avant de reconstruire la plateforme : une mémoire saturée ralentit les VM et fausse les mesures.

**Windows** : travailler dans **Git Bash**. Les fins de ligne des scripts sont forcées en LF par `.gitattributes`. `ab` s'obtient en téléchargeant les binaires Apache (par exemple Apache Lounge) ou sous WSL avec `sudo apt install apache2-utils`.

**Linux** : charger les modules réseau de VirtualBox si besoin.

```bash
sudo modprobe vboxnetadp
sudo modprobe vboxnetflt
```

**Réseau** : VirtualBox n'autorise par défaut que la plage `192.168.56.0/21` pour les réseaux privés hôte-seul. Le projet s'y conforme (voir [§4](#4-configuration)) et **ne demande aucune modification** de `/etc/vbox/networks.conf`.

**Boîte Vagrant** : `bento/ubuntu-24.04`, version épinglée à `202404.26.0` dans le Vagrantfile, identique pour tous les membres du groupe. Elle est téléchargée automatiquement au premier `vagrant up`.

---

## 3. Architecture

```
                        Poste hôte
                  (navigateur, curl, ab)
                           │  localhost:8080   ← seul port exposé (R8)
                           ▼
   ┌──────────────── Réseau privé 192.168.59.0/24 ─────────────────┐
   │                                                                │
   │        IP virtuelle .5 (VRRP / keepalived)                     │
   │              │                                                 │
   │   ┌──────────┴──────────┐                                      │
   │   │ lb1 (.11) HAProxy   │  lb2 (.12) passif — extension E1     │
   │   └──────────┬──────────┘                                      │
   │              │ HTTP :3000 — sonde GET /sante                   │
   │     ┌────────┼────────┬─ … ─┐   N serveurs applicatifs         │
   │     ▼        ▼        ▼     ▼   (N paramétrable, N ≥ 2)        │
   │   app1 (.21) app2 (.22) app3 … appN (.2N)                      │
   │              │ SQL :5432                                       │
   │              ▼                                                 │
   │   bdd1 (.31) primaire ── réplication en flux ──▶ bdd2 (.32)    │
   │                                                                │
   │   obs (.41) Prometheus + Grafana — extension E2                │
   └────────────────────────────────────────────────────────────────┘
```

Les adresses ci-dessus sont celles du **groupe réseau n° 4**. Elles suivent la formule `192.168.(55 + GROUPE).x`.

### 3.1 Inventaire des machines

| Machine | Rôle | Adresse | RAM | Statut |
|---|---|---|---|---|
| `bdd1` | base PostgreSQL primaire (lecture et écriture) | `.31` | 768 Mo | socle |
| `bdd2` | réplique en flux, promouvable | `.32` | 768 Mo | socle |
| `app1` … `appN` | serveurs applicatifs sans état (N ≥ 2) | `.21` … `.2N` | 512 Mo | socle |
| `lb1` | répartiteur de charge actif (HAProxy), maître de la VIP | `.11` | 512 Mo | socle |
| `lb2` | répartiteur passif, reprend l'IP virtuelle `.5` | `.12` | 512 Mo | extension E1 |
| `obs` | supervision : Prometheus et Grafana | `.41` | 768 Mo | extension E2 |

Le socle (5 machines) représente environ **3 Go** ; avec E1 et E2, environ **4,3 Go**. Chaque machine a 1 processeur virtuel.

### 3.2 Ports

| Port | Où | Usage |
|---|---|---|
| `8080` (hôte) → `80` (lb1) | poste hôte | **seul port exposé vers l'hôte** |
| `80` | lb1, lb2 | HAProxy |
| `3000` | serveurs applicatifs | service HTTP |
| `5432` | bdd1, bdd2 | PostgreSQL |
| `8404` | lb1, lb2 | métriques HAProxy pour Prometheus (E2) |
| `9100` | toutes les machines | `node_exporter` (E2) |
| `9090`, `3000` | obs | Prometheus, Grafana (E2) |

Tout le trafic entre machines circule sur le réseau privé. Vagrant ajoute en plus, pour chaque VM, la redirection SSH habituelle sur le réseau NAT.

### 3.3 Les choix d'architecture

**Une source unique de vérité.** Le Vagrantfile construit une table des machines (`NOEUDS`) et l'écrit dans `config/noeuds.yml`. Tous les scripts la lisent : la configuration de HAProxy (`scripts/gen_haproxy.py`), celle de Prometheus (`scripts/gen_prometheus.py`) et la procédure de bascule (`scripts/bascule.sh`). Ajouter un serveur ne peut donc pas oublier le répartiteur, et **aucune adresse de serveur applicatif n'est écrite à la main** dans une configuration.

**Serveurs applicatifs sans état.** Ni session, ni fichier local, ni compteur : une connexion à la base est ouverte puis fermée à chaque requête. N'importe quel serveur peut répondre à n'importe quelle requête, ce qui rend l'ajout d'un serveur trivial et son retrait indolore.

**Sonde de santé réelle.** HAProxy interroge `GET /sante` toutes les secondes ; `/sante` exécute un `SELECT 1` et renvoie `503` si la base ne répond pas. Un serveur est écarté après 2 échecs consécutifs (environ 2 à 3 s) et réintégré après 2 succès. Une requête tombée sur un serveur qui vient de mourir est rejouée ailleurs (`retries 2`, `option redispatch`).

**Réplication PostgreSQL en flux.** bdd2 est une copie physique de bdd1 (`pg_basebackup`), qui rejoue en continu le journal d'écriture. Elle est en lecture seule tant qu'on ne la promeut pas. La réplication est asynchrone.

**Une bascule explicite plutôt qu'automatique.** `scripts/bascule.sh` promeut bdd2, **refuse** de le faire si bdd1 répond encore (risque de *split-brain*), puis reconfigure les serveurs applicatifs. Le détail est en [§6.2](#62-basculer-la-base-sur-bdd2).

**Connexion applicative à deux hôtes.** L'application reçoit `DB_HOST=<bdd1>,<bdd2>` avec `target_session_attrs=read-write` : la bibliothèque cliente ne retient que le serveur qui accepte les écritures. La primaire est placée **en premier** pour ne pas tenter à chaque requête une réplique qui refuse (mesuré : environ 156 req/s contre environ 86 req/s avec l'ordre inverse). Après une bascule, `bascule.sh` inverse cet ordre.

**Provisionnement idempotent.** Chaque script génère sa configuration dans `/tmp`, puis appelle `install_si_different` (`scripts/lib.sh`) : le fichier n'est remplacé, et le service redémarré ou rechargé, que si le contenu a changé. Rejouer `vagrant provision` ne modifie donc rien et ne redémarre aucun service, bases de données comprises.

**Aucun secret dans le dépôt.** Les mots de passe viennent du fichier `.env` (non versionné), lu par le Vagrantfile et transmis aux scripts sous forme de variables d'environnement. Dans les VM, ils ne sont écrits que dans des fichiers de droits `600`.

**Contrainte réseau et ressources.** Plage `192.168.(55+G).0/24` imposée par VirtualBox ; apt configuré avec réessais (le provisionnement doit fonctionner derrière une connexion lente) ; données PostgreSQL stockées **hors** du dossier synchronisé `/vagrant`.

---

## 4. Configuration

### 4.1 Variables d'environnement du Vagrantfile

| Variable | Défaut | Effet |
|---|---|---|
| `GROUPE` | `4` | numéro de groupe réseau (1 à 8) : sous-réseau `192.168.(55+GROUPE).0/24` |
| `NB_APP` | `2` | nombre de serveurs applicatifs (jusqu'à 10 avec le plan d'adressage actuel) |
| `LB2` | non défini | `LB2=1` ajoute le second répartiteur `lb2` (extension E1) |
| `OBS` | non défini | `OBS=1` ajoute la machine de supervision `obs` (extension E2) |

Exemples :

```bash
vagrant up                          # socle : 5 machines
NB_APP=4 vagrant up                 # socle avec 4 serveurs applicatifs
LB2=1 vagrant up                    # socle + E1
LB2=1 OBS=1 vagrant up              # socle + E1 + E2
```

Pour ne pas répéter la variable devant chaque commande, l'exporter dans le terminal :

```bash
export NB_APP=4 LB2=1 OBS=1
```

> **Piège à connaître.** Vagrant ne connaît que les machines que les variables déclarent. Si `NB_APP=4` est exporté dans un terminal mais pas dans un autre, `vagrant status` y affichera 2 serveurs seulement, et un `vagrant provision lb1` y **retirera** `app3` et `app4` de HAProxy sans message d'erreur. Vérifier avec `echo $NB_APP` avant une commande.

### 4.2 Fichier `.env` (secrets)

`.env.exemple` est versionné et ne contient que des valeurs factices. Chacun crée son propre `.env`, jamais versionné (il figure dans `.gitignore`) :

```bash
cp .env.exemple .env
```

| Variable | Usage |
|---|---|
| `DB_PASSWORD` | mot de passe de l'utilisateur `appuser` (l'application) |
| `REPL_PASSWORD` | mot de passe de l'utilisateur `replicator` (réplication) |
| `VRRP_PASS` | secret d'authentification VRRP entre lb1 et lb2 (**8 caractères maximum**) |
| `GRAFANA_PASSWORD` | mot de passe administrateur de Grafana (E2) |

Si `.env` est absent, le Vagrantfile s'arrête avec le message `Fichier .env manquant : cp .env.exemple .env`.

### 4.3 Fichier généré `config/noeuds.yml`

Il est réécrit **à chaque commande Vagrant** à partir de `NB_APP`, `LB2` et `OBS`, avec un chemin absolu : il atterrit toujours dans `config/` à la racine, même si Vagrant est lancé depuis un sous-dossier. Il n'est pas versionné (`**/noeuds.yml` dans `.gitignore`). Ne jamais l'éditer à la main.

---

## 5. Utiliser la plateforme

Tous les accès passent par `http://localhost:8080` (redirection vers lb1).

| Point d'entrée | Réponse |
|---|---|
| `GET /resultat?matricule=BF000042` | `200` et le résultat du candidat en JSON ; `404` si le matricule est inconnu ; `400` si le paramètre est absent ; `503` si la base est injoignable |
| `GET /sante` | `200` si la base répond, `503` sinon (c'est la sonde de HAProxy) |
| `GET /info` | nom d'hôte du serveur qui a répondu (sert à observer la répartition) |

Le jeu de données contient **50 000 candidats**, matricules `BF000001` à `BF050000`. Il est déterministe (aucun `random()`) : une reconstruction redonne exactement le même contenu.

Chaque ligne de la table `resultats` comporte `matricule`, `nom`, `serie` (A, C, D ou E), `moyenne` (0 à 20) et `admis` (vrai si la moyenne est supérieure ou égale à 10).

Pour tester un serveur applicatif sans passer par le répartiteur, utiliser son adresse privée, par exemple `curl http://192.168.59.21:3000/info` (le poste hôte joint le réseau privé).

**Supervision (E2)** : Grafana sur `http://192.168.59.41:3000` (tableau de bord **RESULTATS-BF**, accès anonyme en lecture) et Prometheus sur `http://192.168.59.41:9090`.

---

## 6. Opérations

### 6.1 Ajouter ou retirer des serveurs applicatifs

Sur une plateforme **vierge**, un seul paramètre suffit :

```bash
NB_APP=4 vagrant up
```

Sur une plateforme **déjà démarrée**, utiliser le script, qui crée les nouvelles machines puis régénère la configuration du répartiteur (un `vagrant up` ne reprovisionne pas une machine déjà démarrée) :

```bash
export NB_APP=4
bash scripts/scale.sh 4
```

Le script exécute `vagrant up`, puis `vagrant provision lb1`, et rejoue aussi `lb2` et `obs` si les variables `LB2` et `OBS` sont positionnées.

Vérifier :

```bash
vagrant ssh lb1 -c "grep ' server app' /etc/haproxy/haproxy.cfg"     # 4 lignes server, sur :3000
bash -c 'for i in $(seq 20); do curl -s http://localhost:8080/info; echo; done | sort | uniq -c'
```

**Retirer** des serveurs, dans cet ordre (d'abord les sortir de la rotation, ensuite les détruire) :

```bash
NB_APP=2 vagrant provision lb1                 # HAProxy n'envoie plus rien à app3 et app4
NB_APP=4 vagrant destroy -f app3 app4          # avec l'ancienne valeur, sinon Vagrant ne les connaît plus
export NB_APP=2
```

Rejouer aussi `lb2` et `obs` avec la nouvelle valeur si ces extensions sont actives.

Chaque serveur ajoute 512 Mo de mémoire. Le plan d'adressage (`.21` à `.30`) permet 10 serveurs au maximum.

### 6.2 Basculer la base sur bdd2

**Quand** : bdd1 est en panne. **Depuis** : le poste hôte, à la racine du dépôt.

```bash
vagrant halt bdd1                    # simule la panne
curl -i http://localhost:8080/sante  # 503 propre : aucune page blanche ni erreur brute
bash scripts/bascule.sh
curl -i http://localhost:8080/sante  # 200
```

Le script déroule cinq étapes et s'arrête à la première qui échoue :

| Étape | Contrôle ou action |
|---|---|
| 1/5 | bdd2 est démarrée |
| 2/5 | bdd1 est injoignable — sinon `REFUS : bdd1 repond encore`, pour éviter deux primaires |
| 3/5 | bdd2 est bien une réplique (`pg_is_in_recovery()` vaut `t`) |
| 4/5 | promotion de bdd2 (`pg_promote`), puis vérification que `pg_is_in_recovery()` vaut `f` |
| 5/5 | sur chaque serveur applicatif (liste lue dans `noeuds.yml`) : réécriture de `DB_HOST` avec bdd2 en premier, redémarrage du service `resultats`, vérification de `/info` |

Il affiche en fin d'exécution `Duree totale de la bascule : X s` (environ 10 s mesurées).

**Après une bascule**

- **Ne pas redémarrer l'ancienne bdd1** (`vagrant up bdd1`) : elle se croirait toujours primaire et il y aurait deux bases qui divergent. En revanche, rejouer `vagrant provision bdd2` est sans danger : `replique.sh` ne refait jamais la copie initiale sur une VM qui l'a déjà faite (marqueur `/var/lib/postgresql/.replique_initialisee`), ni sur une base qui contient déjà `resultats`.
- La réintégration de l'ancien primaire comme réplique n'est pas automatisée : on reconstruit la paire.

```bash
vagrant destroy -f bdd1 bdd2
vagrant up bdd1 bdd2
vagrant provision app1 app2          # remet DB_HOST dans l'ordre initial (bdd1, bdd2) ; ajouter app3... si NB_APP > 2
```

Sans cette dernière commande, les applications garderaient l'ordre inversé par la bascule alors que bdd1 est redevenue la primaire : le débit baisserait sans erreur visible. Contrôle :

```bash
vagrant ssh app1 -c "grep '^DB_HOST=' /etc/default/resultats"
vagrant ssh bdd1 -c "sudo -u postgres psql -tAc 'SELECT pg_is_in_recovery()'"     # f
vagrant ssh bdd2 -c "sudo -u postgres psql -tAc 'SELECT pg_is_in_recovery()'"     # t
```

### 6.3 Arrêter et reprendre le travail

```bash
vagrant halt                         # éteint proprement, les données sont conservées
vagrant up --no-provision            # redémarre sans rejouer les scripts
```

Les services (PostgreSQL, HAProxy, keepalived, application, Prometheus, Grafana) sont activés au démarrage et reviennent seuls. `vagrant suspend` puis `vagrant resume` fonctionne aussi pour une pause courte. **Ne jamais utiliser `vagrant destroy` pour se reposer** : la reconstruction dure 15 minutes ou plus.

Après une bascule, ne pas faire `vagrant up` sur bdd1 (voir §6.2).

### 6.4 Rejouer le provisionnement d'une machine

```bash
vagrant provision app1               # une machine
vagrant provision                    # toutes les machines démarrées
```

Les scripts sont idempotents (voir [§3.3](#33-les-choix-darchitecture)). Pour un répartiteur, le provisionnement est marqué `run: "always"` : sa configuration est régénérée à chaque démarrage depuis `noeuds.yml`.

### 6.5 Lire les journaux

```bash
vagrant ssh app1 -c "sudo journalctl -u resultats -n 30 --no-pager"      # application
vagrant ssh lb1  -c "sudo journalctl -u haproxy -n 30 --no-pager"        # HAProxy
vagrant ssh lb1  -c "sudo journalctl -u keepalived -n 30 --no-pager"     # keepalived
vagrant ssh bdd1 -c "sudo tail -30 /var/log/postgresql/*.log"            # PostgreSQL
```

---

## 7. Extensions

Le sujet demande au moins deux extensions. Deux sont réalisées.

### 7.1 E1 — Répartiteur redondant (keepalived et IP virtuelle)

lb1 et lb2 exécutent HAProxy avec la **même configuration** générée. keepalived leur fait partager l'adresse virtuelle `192.168.59.5` par le protocole VRRP.

| Élément | Valeur |
|---|---|
| lb1 | maître, priorité 150 |
| lb2 | secours, priorité 100 |
| Surveillance | `pgrep haproxy` toutes les secondes : si HAProxy meurt, la VIP passe à l'autre répartiteur |
| Annonces VRRP | 1 par seconde → reprise en environ 3 s lors d'une panne brutale |
| Identifiant VRRP | `50 + GROUPE` (54 pour le groupe 4) |
| Authentification | `VRRP_PASS` (fichier `.env`) |

Activation : `LB2=1 vagrant up`. Le script `keepalived.sh` détecte tout seul l'interface du réseau privé et choisit MASTER ou BACKUP d'après le nom de la machine.

```bash
curl http://192.168.59.5/info                          # répond via lb1
vagrant ssh lb1 -c "ip -4 addr show | grep 192.168.59.5"     # lb1 porte la VIP
vagrant halt lb1
curl http://192.168.59.5/info                          # répond toujours, via lb2
```

Si la VIP est injoignable depuis le poste hôte, activer le mode promiscuité de la carte privée des répartiteurs dans le Vagrantfile (`vb.customize ["modifyvm", :id, "--nicpromisc2", "allow-all"]`), puis `vagrant reload lb1 lb2`.

### 7.2 E2 — Observabilité (Prometheus, node_exporter, Grafana)

| Brique | Où | Rôle |
|---|---|---|
| `node_exporter` | toutes les machines, port 9100 | CPU, mémoire, réseau de chaque VM |
| Exportateur HAProxy intégré | lb1 et lb2, port 8404 | requêtes par seconde, état UP/DOWN de chaque serveur |
| Prometheus | obs, port 9090 | collecte toutes les 5 s |
| Grafana | obs, port 3000 | tableau de bord **RESULTATS-BF** |

Les cibles de Prometheus sont **générées depuis `noeuds.yml`** (`scripts/gen_prometheus.py`) : un serveur ajouté est supervisé sans rien éditer. Grafana est **entièrement provisionné par fichiers** (`config/grafana/`) : après un `vagrant destroy`, le tableau de bord réapparaît sans aucun clic.

Le tableau de bord comporte quatre panneaux : requêtes par seconde, CPU par machine, état des serveurs applicatifs vus par HAProxy (vert/rouge), et machines supervisées.

Activation : `OBS=1 vagrant up` (E1 d'abord si on l'utilise : `LB2=1 OBS=1 vagrant up`). Les cibles de Prometheus sont calculées à la création d'`obs` ; si une extension ou un serveur est ajouté ensuite, rejouer `vagrant provision obs`.

Vérifier :

```bash
curl -s http://192.168.59.41:9090/api/v1/targets | grep -o '"health":"[a-z]*"' | sort | uniq -c
curl -s http://192.168.59.41:3000/api/search          # contient le tableau de bord RESULTATS-BF
```

Toutes les cibles doivent être `up` : 6 machines `node` plus 1 `haproxy` pour le socle avec E2, 8 `node` plus 2 `haproxy` avec E1 et E2.

**Démonstration** : lancer une charge pendant que le tableau de bord est ouvert, puis arrêter un serveur.

```bash
seq 20000 | xargs -P 20 -I{} curl -s -o /dev/null "http://localhost:8080/resultat?matricule=BF000042"
vagrant halt app1          # dans un autre terminal : app1 passe en rouge en 2 à 3 s
vagrant up app1 --no-provision
```

---

## 8. Exigences du sujet et vérifications

| N° | Exigence | Comment elle est tenue | Vérification |
|---|---|---|---|
| **R1** | Reconstruction intégrale sans geste manuel | tout est dans le Vagrantfile et `scripts/` ; aucune étape après `vagrant up` | `bash scripts/mesure_v5.sh` |
| **R2** | Idempotence | fichiers réécrits et services redémarrés seulement si le contenu change (`install_si_different`) ; ajouts gardés par `grep -qxF` | `bash scripts/verif_r2.sh` (voir ci-dessous) |
| **R3** | Nombre de serveurs applicatifs paramétrable | `NB_APP` ; `gen_haproxy.py` lit `noeuds.yml` ; aucune IP d'application en dur | `NB_APP=4 vagrant up` puis V1 |
| **R4** | Sonde de santé, serveur défaillant écarté en moins de 5 s | `GET /sante` toutes les secondes, 2 échecs pour écarter (2 à 3 s) | V2 |
| **R5** | bdd2 est une réplique en flux de bdd1 | `pg_basebackup -R` puis réplication en flux | voir ci-dessous |
| **R6** | Procédure de bascule écrite, exécutable, chronométrée | `scripts/bascule.sh` | V4 (`scripts/mesure_v4.sh`) |
| **R7** | Aucun secret dans le dépôt | `.env` ignoré, `.env.exemple` factice | voir ci-dessous |
| **R8** | Trafic interne sur le réseau privé, un seul port exposé | une seule redirection de port (lb1, 8080 → 80) ; `pg_hba.conf` restreint | voir ci-dessous |

**R2 — rejouer deux fois et comparer.** `bash scripts/verif_r2.sh` le fait sur toutes les VM démarrées : empreinte md5 des fichiers écrits par le provisionnement, PID des services et nombre de lignes de `resultats`, puis deux `vagrant provision` et comparaison. Résultat dans `docs/mesures/r2-idempotence.txt`. Le script refuse de tourner si `NB_APP` ne correspond pas à HAProxy ou si une bascule a eu lieu (il abîmerait la plateforme). À la main :

```bash
vagrant ssh lb1 -c "sudo md5sum /etc/haproxy/haproxy.cfg /etc/keepalived/keepalived.conf"
vagrant provision
vagrant provision
vagrant ssh lb1 -c "sudo md5sum /etc/haproxy/haproxy.cfg /etc/keepalived/keepalived.conf"     # sommes identiques
vagrant ssh bdd1 -c "sudo -u postgres psql -d resultats -tAc 'SELECT count(*) FROM resultats'"   # 50000
vagrant ssh bdd1 -c "grep -c replicator /etc/postgresql/16/main/pg_hba.conf"                     # 1 : pas de doublon
```

**R5 — écrire sur bdd1, lire sur bdd2 :**

```bash
vagrant ssh bdd1 -c "sudo -u postgres psql -d resultats -c \"INSERT INTO resultats VALUES ('TEST000001','Test R5','A',12.50,true)\""
vagrant ssh bdd2 -c "sudo -u postgres psql -d resultats -c \"SELECT * FROM resultats WHERE matricule='TEST000001'\""
vagrant ssh bdd2 -c "sudo -u postgres psql -d resultats -c \"DELETE FROM resultats WHERE matricule='TEST000001'\""   # refusé : read-only
vagrant ssh bdd1 -c "sudo -u postgres psql -d resultats -c \"DELETE FROM resultats WHERE matricule='TEST000001'\""   # nettoyage
vagrant ssh bdd1 -c "sudo -u postgres psql -c 'SELECT client_addr, state FROM pg_stat_replication'"                    # streaming
```

**R7 — rien de sensible dans l'historique :**

```bash
git ls-files | grep -E '^\.env$'                       # ne doit rien afficher
git log --all -p | grep -E '^\+.*(PASSWORD|VRRP_PASS)='   # uniquement des valeurs factices ou des références ${...}
```

**R8 — un seul port exposé :**

```bash
grep -n forwarded_port Vagrantfile                     # une seule ligne (lb1)
```

---

## 9. Scénarios de validation V1 à V6

Les résultats bruts sont enregistrés dans `docs/mesures/`. Chaque scénario se rejoue avec les commandes ci-dessous (depuis la racine du dépôt).

| N° | Scénario | Commande | Mesure à relever |
|---|---|---|---|
| **V1** | Répartition de 20 appels à `/info` | `bash scripts/mesure_v1.sh` (écrit `v1-n<N>.txt`) | écart entre le serveur le plus et le moins sollicité (cible < 20 %) |
| **V2** | Panne d'un serveur applicatif | voir ci-dessous | requêtes perdues, durée de la période dégradée (cible < 5 s) |
| **V3** | Montée en charge, N=2 puis N=4 | `bash scripts/mesure_v3.sh` (`ab -n 2000 -c 50`, 3 essais par N) | requêtes par seconde dans chaque configuration |
| **V4** | Panne de la base primaire | `bash scripts/mesure_v4.sh` | 503 propre, durée de la bascule |
| **V5** | Reconstruction complète | `bash scripts/mesure_v5.sh` | durée totale |
| **V6** | Panne du répartiteur (E1) | `bash scripts/mesure_v6.sh` (ou `... brutal`) | requêtes perdues, durée de la coupure |

**V1** :

```bash
for i in $(seq 20); do curl -s http://localhost:8080/info; echo; done | sort | uniq -c
```

L'écart se calcule ainsi : (appels du serveur le plus sollicité − appels du moins sollicité) / 20.

**V2** : lancer cette boucle, puis `vagrant halt app1` dans un second terminal.

```bash
while true; do
  code=$(curl -s -o /dev/null -w "%{http_code}" -m 2 "http://localhost:8080/resultat?matricule=BF000042")
  echo "$(date +%T.%3N) $code"; sleep 0.1
done | tee docs/mesures/v2-panne-app.txt
```

Compter les lignes différentes de `200` et la durée entre la première et la dernière.

**V3** : `bash scripts/mesure_v3.sh` part du socle avec `NB_APP=2` et enchaîne seul : 3 essais `ab -n 2000 -c 50`, passage à 4 serveurs (`scripts/scale.sh 4`), attente que les 4 soient dans la rotation, répartition de 20 appels à `/info` (V1 pour N=4), 3 nouveaux essais. Il garde la médiane de chaque configuration et enregistre les sorties brutes de `ab` dans `docs/mesures/v3-charge.txt`. Éteindre les extensions pendant la mesure, et lancer `ab` depuis le **poste hôte**, jamais depuis une VM (il consommerait le processeur partagé et fausserait la mesure). La plateforme reste ensuite à 4 serveurs (retrait : [§6.1](#61-ajouter-ou-retirer-des-serveurs-applicatifs)).

**V4, V5, V6** : les scripts enregistrent leur résultat dans `docs/mesures/` (`v4-application-final.txt`, `v5-reconstruction.txt`, `v6-vrrp.txt`). `mesure_v5.sh` **détruit toutes les machines** et demande confirmation (option `-y` pour l'éviter). `mesure_v6.sh` laisse lb1 arrêtée : la relancer avec `vagrant up lb1` avant un nouvel essai.

### Résultats mesurés

| Scénario | Résultat | Fichier |
|---|---|---|
| **V1** (N=2) | app1 10, app2 10 sur 20 appels, écart de 0 % | `v1-n2.txt` |
| **V2** — panne d'app1 sous sonde continue | 2 requêtes en échec sur 152, période dégradée de 2,53 s (cible < 5 s) | `v2-panne-app.txt` |
| **V4** — bascule de la base | 9,7 s, 10,4 s et 10,0 s (moyenne 10,0 s) | `v4-bascule.txt` |
| **V4** — avec l'application | `/sante` répond 503 pendant la panne, retour à 200 en 9,7 s (bascule comprise) | `v4-application-final.txt` |
| **V5** — reconstruction du socle | 18 min 26 s (mesure du 24/10) ; plateforme fonctionnelle, `RESULTAT : OK` | `v5-reconstruction.txt` |
| **V6** — arrêt propre de lb1 | 1 requête perdue sur 253 (environ 200 ms) | `v6-vrrp.txt` |
| **V6** — arrêt brutal de lb1 | 3 requêtes perdues (environ 2,9 s) puis 2 requêtes perdues (environ 1,5 s) | `v6-vrrp.txt` |
| **R5** — réplication | ligne écrite sur bdd1, lue sur bdd2 | `r5-replication.txt` |
| Ordre des bases (avant V3) | environ 86 req/s avec la réplique en premier, environ 156 req/s avec la primaire d'abord (mesure unique) | `docs/journal-donnees.md` |

**En cours** : V3 (N=2 puis N=4, `scripts/mesure_v3.sh`), R2 (`scripts/verif_r2.sh`), V1 avec N=4, et une nouvelle mesure de V4 et V6 avec la version actuelle des scripts (la bascule compte désormais 5 étapes, keepalived fait partie du socle).

> **Honnêteté des mesures.** Toutes les machines virtuelles se partagent le processeur et la mémoire d'un seul poste : doubler le nombre de serveurs applicatifs ne double pas le débit et peut même le réduire. Les durées de bascule incluent le délai de détection et les connexions `vagrant ssh`, pas seulement la promotion. Les mesures sont peu nombreuses et faites sur un poste de 8 Go.

---

## 10. Structure du dépôt

```
.
├── Vagrantfile              # source unique de vérité : table des machines et provisionnement
├── README.md                # ce document
├── .env.exemple             # variables attendues, valeurs factices (versionné)
├── .env                     # vos mots de passe (jamais versionné)
├── .gitattributes           # fins de ligne LF forcées (scripts shell et Python)
├── .gitignore               # .env, .vagrant/, **/noeuds.yml, *.log
├── app/
│   └── serveur.py           # service HTTP sans état (99 lignes, bibliothèque standard + psycopg2)
├── config/
│   ├── noeuds.yml           # GÉNÉRÉ à chaque commande Vagrant (non versionné)
│   └── grafana/             # source de données et tableau de bord Grafana (E2)
├── scripts/
│   ├── lib.sh               # install_si_different : écrire/redémarrer seulement si le contenu change
│   ├── common.sh            # apt robuste (réessais) et outils communs, node_exporter
│   ├── bdd.sh               # PostgreSQL primaire, utilisateurs, table et 50 000 lignes
│   ├── replique.sh          # réplique en flux (pg_basebackup)
│   ├── app.sh               # service applicatif (systemd) sur chaque serveur
│   ├── lb.sh                # HAProxy + keepalived (répartiteurs)
│   ├── gen_haproxy.py       # génère haproxy.cfg depuis noeuds.yml
│   ├── keepalived.sh        # VRRP et IP virtuelle (E1)
│   ├── obs.sh               # Prometheus et Grafana (E2)
│   ├── gen_prometheus.py    # génère prometheus.yml depuis noeuds.yml
│   ├── bascule.sh           # promotion de bdd2 et reconfiguration des applications
│   ├── scale.sh             # change le nombre de serveurs applicatifs
│   ├── mesure_v1.sh … mesure_v6.sh   # scénarios V1 à V6 (résultats dans docs/mesures/)
│   └── verif_r2.sh          # preuve de l'idempotence (R2)
└── docs/
    ├── guide-donnees.md     # guide pas à pas de la partie données (D1 à D4)
    ├── journal-donnees.md   # journal de bord de la partie données
    └── mesures/             # résultats bruts des mesures
```

### Où est décrit quoi

| Besoin | Fichier |
|---|---|
| Les machines, leurs adresses, les options | `Vagrantfile` |
| Un script de provisionnement | `scripts/<role>.sh` (le rôle est celui de la table `NOEUDS`) |
| Pourquoi PostgreSQL est configuré ainsi, la bascule en détail | `docs/guide-donnees.md`, `docs/journal-donnees.md` |
| Les chiffres et sorties brutes | `docs/mesures/` |

---

## 11. Dépannage

| Symptôme | Cause probable | Solution |
|---|---|---|
| `Fichier .env manquant` | `.env` non créé | `cp .env.exemple .env` |
| `E: Failed to fetch ... Hash Sum mismatch` pendant `apt-get update` | miroir ou proxy qui sert des fichiers incohérents | rien à faire si le script réessaie ; sinon `vagrant provision <machine>` ou changer de connexion |
| `curl: (7) Failed to connect ... port 3000` dans la sortie du provisionnement d'un serveur applicatif | essai de la boucle de vérification avant que le service écoute | **sans gravité** : la ligne suivante `app provisionne, ecoute sur 0.0.0.0:3000` confirme le démarrage |
| Avertissement *guest additions do not match* | version des additions invités différente de VirtualBox | sans gravité tant que `/vagrant` est monté |
| `vagrant status` ne liste pas `lb2`, `obs` ou `app3` | variable non exportée dans ce terminal | `export NB_APP=… LB2=1 OBS=1` |
| `/sante` répond `503` | la base est injoignable | `vagrant status`, puis `vagrant ssh app1 -c "sudo cat /etc/default/resultats"` (`DB_HOST` doit contenir les deux bases) |
| `Empty reply from server` sur le port 8080 | HAProxy absent ou arrêté | `vagrant ssh lb1 -c "systemctl is-active haproxy"` puis `vagrant provision lb1` |
| Toujours le même serveur dans `/info` avec un navigateur | le navigateur réutilise sa connexion | vérifier avec `curl` (nouvelle connexion à chaque appel) |
| `502` ou `503` d'HAProxy, aucune application « UP » | applications non démarrées ou base absente | tester `curl http://192.168.59.21:3000/sante` |
| `REFUS : bdd1 repond encore` | `bascule.sh` protège contre le *split-brain* | arrêter bdd1 (`vagrant halt bdd1`) avant de lancer la bascule |
| La VIP `192.168.59.5` ne répond pas depuis l'hôte | carte privée filtrée par VirtualBox | voir [§7.1](#71-e1--répartiteur-redondant-keepalived-et-ip-virtuelle) |
| `\r: command not found` dans un script | fin de ligne Windows (CRLF) | `sed -i 's/\r$//' <script>` ; `.gitattributes` force le LF à l'enregistrement |
| Plateforme lente, requêtes en erreur sous charge, apps écartées brièvement par HAProxy | mémoire de l'hôte saturée, processeur partagé | fermer les applications, ne pas allumer les extensions pendant les mesures |
| Machine inconnue après `vagrant destroy` | variables différentes de celles de la construction | redéclarer `NB_APP`, `LB2`, `OBS` avec leurs anciennes valeurs |
| Réseau privé impossible sous Linux | modules VirtualBox absents | `sudo modprobe vboxnetadp vboxnetflt` |

---

## 12. Limites connues

- **Un seul poste.** Toutes les machines virtuelles partagent le processeur et la mémoire de l'hôte : la résilience est démontrée, pas garantie matériellement, et les mesures de débit sont indicatives.
- **Réplication asynchrone.** En cas de panne brutale de bdd1, les toutes dernières écritures peuvent être perdues.
- **Bascule manuelle.** Un outil comme Patroni, repmgr ou pg_auto_failover l'automatiserait ; ils demandent davantage de machines et de complexité.
- **Risque de *split-brain* après bascule.** L'ancienne primaire ne doit pas redémarrer telle quelle ; sa réintégration comme réplique n'est pas automatisée (on reconstruit la paire).
- **Copie initiale de bdd2 non rejouable automatiquement.** Pour refaire volontairement la copie depuis bdd1 (réplique abîmée), il faut supprimer `/var/lib/postgresql/.replique_initialisee` sur bdd2 avant `vagrant provision bdd2`, ou reconstruire la VM. C'est voulu : avant ce marqueur, un rejeu après une bascule effaçait la nouvelle primaire.
- **Connexion à la base par requête.** C'est simple et garantit l'absence d'état, mais un pool de connexions (pgBouncer) améliorerait le débit.
- **Latence après une panne de bdd1, avant la bascule.** Chaque requête attend environ 2 s (délai de connexion) tant que `bascule.sh` n'a pas été exécuté.
- **Sonde stricte.** Avec un délai de 1 s par vérification, une charge forte sur un poste saturé peut faire écarter brièvement des serveurs sains ; ils reviennent seuls.
- **Sous-réseau du groupe.** Les réseaux hôte-seul sont propres à chaque poste, donc sans conflit entre groupes, sauf si deux groupes partagent la même machine (démonstration).
- **Extensions E3 (Redis) et E4 (déploiement sans coupure)** : non réalisées.

---

## 13. Équipe et organisation

Quatre rôles, un par membre. Chacun est responsable de son domaine, mais tous savent démontrer l'ensemble de la plateforme.

| Membre | Rôle | Périmètre | Identités Git |
|---|---|---|---|
| William OUOBA | Architecte réseau et répartition | plan d'adressage, Vagrantfile, répartiteur, sonde de santé, E1, E2 | `Yoru002`, `William` |
| Pégué Judicaël OUÉDRAOGO | Ingénieur données | PostgreSQL, jeu de données, réplication, procédure de bascule | `Pégué Judicaël Ouédraogo`, `pegueo2000` |
| Fatahou | Ingénieur applicatif | service HTTP, absence d'état, gestion des erreurs de base | `Fatahou980`, `TESTEUR04` |
| Malick | Ingénieur essais et observabilité | scénarios V1 à V6, campagne de mesures, rédaction des résultats | `malickabdoul`, `KAM` |

Le fichier `.mailmap` regroupe les identités Git de chaque membre : `git shortlog -sne` affiche une ligne par personne.

**Organisation du travail**

- Une **branche par sujet**, une *pull request* par branche, fusionnée dans `main` seulement quand `vagrant up` fonctionne : `main` reste toujours reconstructible.
- Chaque fichier a un propriétaire ; les contributions hors de son domaine sont tracées dans l'historique Git (rotation).
- Rituel hebdomadaire : `vagrant destroy -f` puis `vagrant up` sur le poste d'un autre membre, pour découvrir les gestes manuels oubliés.

**Documents du groupe** : `docs/guide-donnees.md` (guide pas à pas de la partie données), `docs/journal-donnees.md` (décisions, difficultés et mesures de la partie données).

**Livrables du projet** : dépôt Git (ce dépôt), dossier d'architecture, journal de bord, démonstration de 20 minutes (destruction puis reconstruction en direct, puis trois scénarios tirés au sort).
