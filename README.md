# RÉSULTATS-BF

Plateforme de consultation des résultats d'examens : un candidat donne son matricule et obtient son résultat. L'application est très simple, le projet porte sur l'infrastructure. Toutes les machines sont décrites en code avec Vagrant, se reconstruisent en une commande, et le service continue quand une machine tombe.

Projet de groupe, Master 1 Informatique, IBAM (Université Joseph Ki-Zerbo). Module DevOps et infrastructures reproductibles, Dr SOMDA Flavien Hervé.

## Sommaire

1. [Prérequis](#1-prérequis)
2. [Démarrage rapide](#2-démarrage-rapide)
3. [Architecture](#3-architecture)
4. [Configuration](#4-configuration)
5. [Utiliser la plateforme](#5-utiliser-la-plateforme)
6. [Opérations courantes](#6-opérations-courantes)
7. [Extensions E1 et E2](#7-extensions-e1-et-e2)
8. [Tests et vérifications](#8-tests-et-vérifications)
9. [Dépannage](#9-dépannage)
10. [Organisation du dépôt](#10-organisation-du-dépôt)

## 1. Prérequis

| Outil | Version |
|---|---|
| [VirtualBox](https://www.virtualbox.org/) | 7.x |
| [Vagrant](https://developer.hashicorp.com/vagrant) | 2.4.9 ou plus (la 2.3 ne fonctionne pas avec VirtualBox 7.1 et 7.2) |
| Git et curl | versions récentes |
| Apache Bench (`ab`) | seulement pour le test de charge V3, à installer sur le poste hôte |

Il faut au moins 8 Go de mémoire et environ 10 Go d'espace disque. Le socle utilise à lui seul environ 3 Go pour les machines virtuelles : fermez les applications lourdes avant de lancer la plateforme.

- **Windows** : travaillez dans Git Bash. `ab` s'obtient avec les binaires Apache (Apache Lounge) ou sous WSL avec `sudo apt install apache2-utils`.
- **Linux** : si le réseau privé ne se crée pas, chargez les modules de VirtualBox avec `sudo modprobe vboxnetadp vboxnetflt`.

La boîte Vagrant (`bento/ubuntu-24.04`, version `202404.26.0`) est téléchargée automatiquement au premier lancement.

## 2. Démarrage rapide

```bash
git clone https://github.com/Yoru002/Projet-resultats-bf.git
cd Projet-resultats-bf
cp .env.exemple .env      # puis mettre ses propres mots de passe dans .env
vagrant up                # crée les 5 machines du socle, 15 à 20 minutes
```

Il n'y a rien d'autre à faire. Pour vérifier que tout répond :

```bash
curl http://localhost:8080/info
curl "http://localhost:8080/resultat?matricule=BF000042"
```

On doit obtenir :

```json
{"host": "app1"}
{"matricule": "BF000042", "nom": "Candidat 42", "serie": "D", "moyenne": 15.54, "admis": true}
```

En relançant `/info`, la réponse passe de `app1` à `app2` : le répartiteur envoie les requêtes chacune son tour.

Pour démarrer aussi les deux extensions (environ 4,3 Go de mémoire au total) :

```bash
LB2=1 OBS=1 vagrant up
```

Pour tout reconstruire de zéro : `vagrant destroy -f` puis `vagrant up`.

Toutes les commandes `vagrant` se lancent depuis la racine du dépôt.

## 3. Architecture

```
                    Poste hôte (navigateur, curl, ab)
                                  |
                                  |  http://localhost:8080
                                  v
        lb1 (HAProxy)  <---- adresse virtuelle .5 ---->  lb2 (secours, E1)
                                  |
                 +----------------+----------------+
                 |                |                |
                 v                v                v
               app1             app2      ...    appN
                 |                |                |
                 +----------------+----------------+
                                  |
                                  v
        bdd1 (PostgreSQL primaire)  ---- réplication ---->  bdd2 (réplique)

        obs (Prometheus et Grafana, E2) surveille toutes les machines
```

Une requête arrive sur lb1 par le port 8080 du poste hôte, le seul port ouvert vers l'extérieur. HAProxy l'envoie à un serveur applicatif en bonne santé : chaque seconde, il appelle `/sante` sur chaque serveur et retire ceux qui ne répondent plus. Le serveur choisi lit le résultat dans bdd1. bdd2 garde une copie à jour de bdd1 et ne sert qu'après une bascule (voir [6.2](#62-basculer-la-base-sur-bdd2)).

| Machine | Rôle | Adresse | Mémoire | Démarrée |
|---|---|---|---|---|
| bdd1 | base PostgreSQL primaire (port 5432) | 192.168.59.31 | 768 Mo | toujours |
| bdd2 | réplique de bdd1 (port 5432) | 192.168.59.32 | 768 Mo | toujours |
| app1 à appN | serveurs applicatifs (port 3000), au moins 2 | 192.168.59.21 à .2N | 512 Mo chacun | toujours |
| lb1 | répartiteur HAProxy (port 80, 8080 sur l'hôte) | 192.168.59.11 | 512 Mo | toujours |
| lb2 | répartiteur de secours | 192.168.59.12 | 512 Mo | avec `LB2=1` |
| obs | supervision Prometheus et Grafana | 192.168.59.41 | 768 Mo | avec `OBS=1` |

Ces adresses sont celles de notre groupe réseau (4). Elles suivent la règle `192.168.(55 + GROUPE).x`.

## 4. Configuration

### 4.1 Variables

On choisit la forme de la plateforme avec quatre variables, placées devant la commande `vagrant` :

| Variable | Par défaut | Effet |
|---|---|---|
| `NB_APP` | 2 | nombre de serveurs applicatifs (10 au maximum) |
| `LB2` | absente | `LB2=1` ajoute le répartiteur de secours lb2 (E1) |
| `OBS` | absente | `OBS=1` ajoute la machine de supervision obs (E2) |
| `GROUPE` | 4 | numéro de groupe réseau, de 1 à 8 |

```bash
NB_APP=4 vagrant up              # socle avec 4 serveurs applicatifs
export NB_APP=4 LB2=1 OBS=1      # ou une fois pour toutes dans le terminal
```

**Attention** : Vagrant ne voit que les machines déclarées par les variables du terminal où on tape la commande. Si `NB_APP=4` a été utilisé, il faut le remettre dans chaque nouveau terminal. Sinon, un `vagrant provision lb1` lancé dans un autre terminal retire app3 et app4 de HAProxy sans prévenir. En cas de doute : `echo $NB_APP`.

### 4.2 Mots de passe

Les mots de passe sont dans le fichier `.env`, que chacun crée à partir de `.env.exemple` et qui n'est jamais envoyé sur Git.

| Variable | Sert pour |
|---|---|
| `DB_PASSWORD` | le compte `appuser` de l'application |
| `REPL_PASSWORD` | le compte `replicator` de la réplication |
| `VRRP_PASS` | lb1 et lb2 entre eux (8 caractères au maximum) |
| `GRAFANA_PASSWORD` | le compte administrateur de Grafana |

Le fichier `config/noeuds.yml` est recréé automatiquement à chaque commande Vagrant : il ne faut pas le modifier à la main.

## 5. Utiliser la plateforme

Tout passe par `http://localhost:8080` :

| Adresse | Réponse |
|---|---|
| `/resultat?matricule=BF000042` | le résultat du candidat en JSON ; 404 si le matricule n'existe pas, 400 s'il manque, 503 si la base ne répond pas |
| `/sante` | 200 si la base répond, 503 sinon |
| `/info` | le nom du serveur qui a répondu |

La base contient 50 000 candidats, de `BF000001` à `BF050000`.

Pour interroger un serveur sans passer par le répartiteur, on utilise son adresse privée, par exemple `curl http://192.168.59.21:3000/info`.

## 6. Opérations courantes

### 6.1 Ajouter ou retirer des serveurs

Si la plateforme n'est pas encore créée, `NB_APP=4 vagrant up` suffit.

Si elle tourne déjà, utilisez `scale.sh` : il crée les nouvelles machines puis met à jour HAProxy (et lb2 et obs si `LB2` et `OBS` sont définies).

```bash
export NB_APP=4
bash scripts/scale.sh 4
vagrant ssh lb1 -c "grep ' server app' /etc/haproxy/haproxy.cfg"    # doit afficher 4 lignes
```

Pour retirer des serveurs, on les sort d'abord de HAProxy, puis on détruit les machines :

```bash
NB_APP=2 vagrant provision lb1          # HAProxy n'envoie plus rien à app3 et app4
NB_APP=4 vagrant destroy -f app3 app4   # avec l'ancienne valeur, sinon Vagrant ne les voit plus
export NB_APP=2
```

Si les extensions tournent, relancez aussi `vagrant provision lb2 obs` avec la nouvelle valeur.

### 6.2 Basculer la base sur bdd2

À faire quand bdd1 est en panne :

```bash
vagrant halt bdd1                     # simule la panne
curl -i http://localhost:8080/sante   # 503 : la base ne répond plus
bash scripts/bascule.sh
curl -i http://localhost:8080/sante   # 200 : bdd2 a pris le relais
```

`bascule.sh` vérifie que bdd2 est démarrée et que bdd1 ne répond vraiment plus (sinon il refuse, pour ne pas avoir deux bases primaires). Il promeut ensuite bdd2, puis met à jour les serveurs applicatifs. Il affiche la durée totale à la fin.

Après une bascule, ne redémarrez pas l'ancienne bdd1 : elle se croirait encore primaire. Pour revenir à la situation de départ, on reconstruit les deux bases :

```bash
vagrant destroy -f bdd1 bdd2
vagrant up bdd1 bdd2
vagrant provision app1 app2            # ajouter app3, app4... si NB_APP est plus grand
```

### 6.3 Arrêter et reprendre

```bash
vagrant halt                    # arrête tout, les données sont gardées
vagrant up --no-provision       # redémarre sans relancer les scripts
```

Tous les services repartent seuls au démarrage. N'utilisez pas `vagrant destroy` pour faire une pause : la reconstruction prend 15 à 20 minutes.

### 6.4 Relancer la configuration d'une machine

```bash
vagrant provision app1          # une seule machine
vagrant provision               # toutes les machines démarrées
```

Relancer les scripts ne change rien si rien n'a changé dans le dépôt.

### 6.5 Lire les journaux

```bash
vagrant ssh app1 -c "sudo journalctl -u resultats -n 30 --no-pager"      # application
vagrant ssh lb1  -c "sudo journalctl -u haproxy -n 30 --no-pager"        # HAProxy
vagrant ssh lb1  -c "sudo journalctl -u keepalived -n 30 --no-pager"     # keepalived
vagrant ssh bdd1 -c "sudo tail -30 /var/log/postgresql/*.log"            # PostgreSQL
```

## 7. Extensions E1 et E2

### 7.1 E1 : second répartiteur

Avec `LB2=1`, lb1 et lb2 partagent l'adresse virtuelle `192.168.59.5`. Si lb1 tombe, lb2 la reprend en quelques secondes.

```bash
LB2=1 vagrant up
curl http://192.168.59.5/info          # répond, par lb1
vagrant halt lb1
curl http://192.168.59.5/info          # répond toujours, par lb2
vagrant up lb1                         # remettre lb1 en route
```

Si l'adresse `192.168.59.5` ne répond pas depuis le poste hôte, ajoutez au Vagrantfile, pour les répartiteurs, `vb.customize ["modifyvm", :id, "--nicpromisc2", "allow-all"]`, puis `vagrant reload lb1 lb2`.

### 7.2 E2 : supervision

Avec `OBS=1`, la machine obs collecte les mesures de toutes les machines et de HAProxy toutes les 5 secondes.

- Grafana : http://192.168.59.41:3000/d/resultats-bf/resultats-bf (tableau de bord RESULTATS-BF, sans compte)
- Prometheus : http://192.168.59.41:9090

```bash
OBS=1 vagrant up        # ou LB2=1 OBS=1 vagrant up avec les deux extensions
curl -s http://192.168.59.41:9090/api/v1/targets | grep -o '"health":"[a-z]*"' | sort | uniq -c   # tout doit être "up"
curl -s http://192.168.59.41:3000/api/search          # doit contenir RESULTATS-BF
```

Si on ajoute un serveur ou une extension après avoir créé obs, il faut relancer `vagrant provision obs` pour qu'il soit surveillé.

Pour voir une panne en direct : ouvrez le tableau de bord, lancez une charge, puis arrêtez un serveur dans un second terminal. app1 passe en rouge au bout de 2 à 3 secondes.

```bash
seq 20000 | xargs -P 20 -I{} curl -s -o /dev/null "http://localhost:8080/resultat?matricule=BF000042"
vagrant halt app1                      # dans un second terminal
vagrant up app1 --no-provision         # pour le remettre
```

## 8. Tests et vérifications

Toutes les commandes se lancent sur le poste hôte, depuis la racine du dépôt. Les scripts de mesure écrivent leur résultat dans `docs/mesures/`.

### 8.1 Scénarios V1 à V6

| Test | Ce qu'on vérifie | Commande |
|---|---|---|
| V1 | les 20 appels à `/info` sont bien répartis (écart de moins de 20 %) | `bash scripts/mesure_v1.sh` |
| V2 | la panne d'un serveur applicatif est absorbée en moins de 5 s | `NB_APP=2 bash scripts/mesure_v2.sh` |
| V3 | débit avec 2 puis 4 serveurs | `bash scripts/mesure_v3.sh` |
| V4 | panne de bdd1 : erreur 503 propre, puis bascule chronométrée | `bash scripts/mesure_v4.sh` |
| V5 | reconstruction complète sans intervention | `bash scripts/mesure_v5.sh` |
| V6 | panne de lb1 avec E1 : lb2 prend le relais | `bash scripts/mesure_v6.sh` (ou `brutal`) |

À savoir avant de lancer :

- **V2** arrête app1. Pour le remettre : `vagrant up app1 --no-provision`.
- **V3** se lance avec 2 serveurs et les extensions éteintes. Il passe lui-même à 4 serveurs et laisse la plateforme ainsi (pour revenir à 2, voir [6.1](#61-ajouter-ou-retirer-des-serveurs)). `ab` doit tourner sur le poste hôte, pas dans une VM.
- **V4** laisse bdd2 en primaire. Avant de le refaire, reconstruire les deux bases (voir [6.2](#62-basculer-la-base-sur-bdd2)).
- **V5** détruit toutes les machines avant de les reconstruire. Il demande confirmation (`-y` pour ne pas la demander).
- **V6** laisse lb1 arrêtée. Avant un nouvel essai, la remettre avec `vagrant up lb1` et attendre qu'elle reprenne l'adresse virtuelle (`vagrant ssh lb1 -c "ip addr | grep 192.168.59.5"` doit afficher une ligne). Sinon, l'essai ne mesure aucune panne : lb2 a déjà l'adresse.

### 8.2 Exigences du sujet

| Exigence | Comment la vérifier |
|---|---|
| R1 : reconstruction sans geste manuel | `bash scripts/mesure_v5.sh` |
| R2 : relancer la configuration ne change rien | `bash scripts/verif_r2.sh` |
| R3 : nombre de serveurs réglable | `NB_APP=4 vagrant up`, puis V1 |
| R4 : un serveur en panne est retiré en moins de 5 s | V2 |
| R5 : bdd2 est une réplique de bdd1 | commandes ci-dessous |
| R6 : bascule écrite, exécutable et chronométrée | V4 |
| R7 : aucun mot de passe dans le dépôt | commandes ci-dessous |
| R8 : un seul port ouvert vers l'hôte | `grep -n forwarded_port Vagrantfile` (une seule ligne) |

`verif_r2.sh` relance deux fois `vagrant provision` et vérifie qu'aucun fichier ni aucune donnée n'a changé. Il refuse de tourner si `NB_APP` ne correspond pas à la plateforme ou si une bascule a eu lieu.

**R5** : une ligne écrite sur bdd1 doit apparaître sur bdd2, et bdd2 doit refuser les écritures.

```bash
vagrant ssh bdd1 -c "sudo -u postgres psql -d resultats -c \"INSERT INTO resultats VALUES ('TEST000001','Test R5','A',12.50,true)\""
vagrant ssh bdd2 -c "sudo -u postgres psql -d resultats -c \"SELECT * FROM resultats WHERE matricule='TEST000001'\""
vagrant ssh bdd2 -c "sudo -u postgres psql -d resultats -c \"DELETE FROM resultats WHERE matricule='TEST000001'\""   # refusé
vagrant ssh bdd1 -c "sudo -u postgres psql -d resultats -c \"DELETE FROM resultats WHERE matricule='TEST000001'\""   # nettoyage
```

**R7** : les deux commandes ne doivent rien montrer d'autre que les fausses valeurs de `.env.exemple`.

```bash
git ls-files | grep -E '^\.env$'
git log --all -p | grep -E '^\+.*(PASSWORD|VRRP_PASS)='
```

## 9. Dépannage

| Problème | Solution |
|---|---|
| `Fichier .env manquant` | `cp .env.exemple .env` |
| `Hash Sum mismatch` pendant l'installation | les scripts réessaient seuls ; sinon relancer `vagrant provision <machine>` |
| `curl: (7) Failed to connect ... port 3000` pendant la création d'un serveur | sans gravité si la ligne suivante dit `app provisionne, ecoute sur 0.0.0.0:3000` |
| `vagrant status` ne montre pas lb2, obs ou app3 | remettre les variables dans ce terminal : `export NB_APP=4 LB2=1 OBS=1` |
| `/sante` répond 503 | la base ne répond pas : vérifier `vagrant status`, puis `vagrant ssh app1 -c "sudo cat /etc/default/resultats"` |
| `Empty reply from server` sur le port 8080 | HAProxy est arrêté : `vagrant provision lb1` |
| Toujours le même serveur dans `/info` avec un navigateur | le navigateur garde sa connexion : tester avec `curl` |
| `REFUS : bdd1 repond encore` | arrêter bdd1 (`vagrant halt bdd1`) avant de lancer la bascule |
| L'adresse 192.168.59.5 ne répond pas | voir [7.1](#71-e1--second-répartiteur) |
| `\r: command not found` | fichier enregistré avec des fins de ligne Windows : `sed -i 's/\r$//' <script>` |
| Plateforme lente, erreurs sous charge | mémoire du poste saturée : fermer des applications, éteindre les extensions |
| Machine inconnue après `vagrant destroy` | remettre les mêmes valeurs de `NB_APP`, `LB2` et `OBS` qu'à la création |

## 10. Organisation du dépôt

```
Vagrantfile          liste des machines et leur configuration
.env.exemple         modèle du fichier .env (fausses valeurs)
app/serveur.py       l'application (moins de 100 lignes de Python)
config/grafana/      tableau de bord Grafana (E2)
scripts/             un script par type de machine (bdd.sh, replique.sh, app.sh, lb.sh, obs.sh...)
                     bascule.sh, scale.sh, mesure_v1.sh à mesure_v6.sh, verif_r2.sh
docs/                guide et journal de la partie données, résultats des mesures (docs/mesures/)
```
