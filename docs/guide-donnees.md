# Guide d'équipe : partie « Ingénieur données »

Chaque étape indique le rôle, la raison, les commandes et ce qu'on doit voir.
Les scripts sont déjà dans le dépôt : ce guide sert à les rejouer et à les expliquer.
Les adresses ci-dessous valent pour le groupe réseau par défaut (192.168.59.x) ;
elles suivent la variable GROUPE (192.168.(55+GROUPE).x).

## Prérequis (tous les rôles)

VirtualBox, Vagrant 2.4.9 ou plus. Sous Linux, les modules réseau de VirtualBox
doivent être chargés :

    sudo modprobe vboxnetadp
    sudo modprobe vboxnetflt

Puis cloner le dépôt et créer son propre .env (jamais versionné) :

    git clone <adresse-du-depot>
    cd Projet-resultats-bf
    cp .env.exemple .env      # remplir DB_PASSWORD, REPL_PASSWORD, VRRP_PASS

## D1. Base primaire bdd1 (Rôle : ingénieur données)

Pourquoi : la base est le seul endroit où vit l'état. Les serveurs applicatifs
n'en ont aucun, ce qui permet d'en ajouter ou d'en retirer sans douleur.
Fichier : scripts/bdd.sh

    vagrant up bdd1

Vérifications, une par une :

    vagrant ssh bdd1 -c "sudo -u postgres psql -d resultats -tc 'SELECT count(*) FROM resultats'" < /dev/null

Attendu : 50000.

    timeout 3 bash -c 'echo > /dev/tcp/192.168.59.31/5432' && echo PORT_OUVERT

Attendu : PORT_OUVERT (la base est joignable depuis le poste, via le réseau privé).

Idempotence (R2) :

    vagrant provision bdd1

Attendu : « INSERT 0 0 » et un compte toujours à 50000.

## D2. Réplique bdd2 (R5) (Rôle : ingénieur données)

Pourquoi : bdd2 copie bdd1 en continu (réplication en flux). Si bdd1 tombe,
bdd2 peut être promue et le service continue.
Fichier : scripts/replique.sh

    vagrant up bdd2

Vérifications :

    vagrant ssh bdd2 -c "sudo -u postgres psql -tc 'SELECT pg_is_in_recovery()'" < /dev/null

Attendu : t (bdd2 est une réplique).

    vagrant ssh bdd1 -c "sudo -u postgres psql -c 'SELECT client_addr, state FROM pg_stat_replication'" < /dev/null

Attendu : 192.168.59.32 en état streaming.

Preuve R5 : écrire sur bdd1, lire sur bdd2, puis tenter d'écrire sur bdd2.

    vagrant ssh bdd1 -c "sudo -u postgres psql -d resultats -c \"INSERT INTO resultats VALUES ('TEST000001','Test R5','A',12.50,true)\"" < /dev/null
    vagrant ssh bdd2 -c "sudo -u postgres psql -d resultats -c \"SELECT * FROM resultats WHERE matricule='TEST000001'\"" < /dev/null
    vagrant ssh bdd2 -c "sudo -u postgres psql -d resultats -c \"DELETE FROM resultats WHERE matricule='TEST000001'\"" < /dev/null

Attendu : INSERT 0 1, puis la ligne lue sur bdd2, puis l'erreur
« cannot execute DELETE in a read-only transaction ». Nettoyer ensuite sur bdd1
avec le même DELETE.

## D3. Bascule (R6, scénario V4) (Rôle : ingénieur données)

Pourquoi : quand bdd1 tombe, on promeut bdd2. Le script refuse de promouvoir si
bdd1 répond encore : deux bases qui acceptent des écritures divergeraient
(« split-brain »).
Fichier : scripts/bascule.sh

Garde-fou (bdd1 fonctionne encore) :

    ./scripts/bascule.sh

Attendu : « REFUS : bdd1 repond encore ».

Panne réelle :

    vagrant halt bdd1
    ./scripts/bascule.sh

Attendu : « [1/5] ... [5/5] » puis « OK : bdd2 est maintenant la base primaire,
applications reconfigurees. » et une durée proche de 10 s (elle inclut le délai de
détection, les connexions vagrant ssh et, depuis le choix C, la réécriture de
`DB_HOST` + le redémarrage des serveurs applicatifs). L'étape 5/5 liste les
applications détectées et signale celles qui n'ont pas pu être reconfigurées.

Ne jamais redémarrer l'ancienne bdd1 après une promotion : elle se croirait
encore primaire. On reconstruit la paire :

    vagrant destroy -f bdd1 bdd2
    vagrant up bdd1 bdd2

## D4. Avec l'application (choix C : primaire d'abord)

Pourquoi : l'application reçoit les deux adresses en commençant par la PRIMAIRE
(bdd1 puis bdd2), pour ne pas tenter à chaque requête une réplique qui refuse
l'écriture. Mesuré : ~86 req/s avec l'ancien ordre (bdd2,bdd1) contre ~156
req/s avec l'ordre primaire d'abord (bdd1,bdd2).

Le prix de ce choix : si bdd1 tombe, chaque requête attend environ 2 s (le
plancher de DB_TIMEOUT) avant de passer à bdd2, qui refuse encore, tant que la
bascule n'a pas été faite. C'est `scripts/bascule.sh` qui résout cela : après la
promotion de bdd2, il réécrit `DB_HOST` sur chaque serveur applicatif (bdd2
primaire en premier) et redémarre le service ciblé. Le redémarrage est indolore
puisque l'application n'a aucun état ; HAProxy reprend la main via /sante.

    vagrant up bdd1 bdd2 app1
    ./scripts/mesure_v4.sh

Attendu : 200 en fonctionnement normal, 503 pendant la panne, retour à 200
égal à la durée de la bascule (promotion + reconfiguration des apps), puis
l'étape 4 affiche `DB_HOST=<bdd2>,<bdd1>` côté application (preuve du choix C).
Résultats enregistrés dans docs/mesures/v4-application-final.txt.

À refaire après chaque `vagrant provision app1` : le provisionnement réécrit
`DB_HOST` en ordre initial (bdd1,bdd2), ce qui est normal tant que bdd1 est vivante.

### Arrêt puis redémarrage de toute la plateforme

Deux cas :

- **Sans bascule** : `vagrant halt` puis `vagrant up` est sans danger. Le disque
de chaque VM conserve son état : `DB_HOST` garde l'ordre primaire d'abord, bdd2
conserve `standby.signal` et reprend sa réplication, lb1 relance HAProxy (rôle
`always`). Aucun provisionnement ne se rejoue (rôle `once`), donc rien ne bouge.
- **Après une bascule** : ne faites PAS `vagrant up` sur bdd1. Elle se croirait
encore primaire alors que bdd2 l'est déjà : deux primaires qui divergent
(split-brain). Seule issue :

      vagrant destroy -f bdd1 bdd2
      vagrant up bdd1 bdd2
      vagrant provision app1        # remet DB_HOST en ordre initial (bdd1,bdd2)

  Sans cette dernière commande, les applications gardent l'ordre réécrit par la
  bascule (bdd2,bdd1) alors que bdd1 est redevenue la vraie primaire : le débit
  retomberait à ~86 req/s sans erreur apparente. Contrôle :

      vagrant ssh app1 -c "grep '^DB_HOST=' /etc/default/resultats"
      vagrant ssh bdd1 -c "sudo -u postgres psql -tAc 'SELECT pg_is_in_recovery()'"  # f
      vagrant ssh bdd2 -c "sudo -u postgres psql -tAc 'SELECT pg_is_in_recovery()'"  # t

## Pour répondre à l'oral

- Pourquoi un utilisateur « replicator » séparé de « appuser » ? Moindre privilège :
  l'application ne peut pas répliquer, la réplique ne peut pas lire l'application.
- Pourquoi pg_hba.conf liste des adresses précises ? Seul le réseau privé et
  l'adresse de bdd2 sont autorisés (R8).
- Pourquoi le script de bascule refuse-t-il de promouvoir bdd1 vivante ? Split-brain.
- Pourquoi l'ordre bdd1,bdd2 (primaire d'abord) plutôt que bdd2,bdd1 ? Débit :
  ~156 req/s contre ~86 req/s, car on ne tente plus d'abord une réplique qui
  refuse l'écriture. Le coût (2 s d'attente après panne de bdd1) est pris en
  charge par bascule.sh, qui réécrit l'ordre puis redémarre les apps.
- Pourquoi redémarrer les apps lors de la bascule ? Pour prendre le nouvel ordre
  sans redéployer, l'application étant sans état le redémarrage est indolore.
- Pourquoi DB_TIMEOUT=2 ? Une valeur de 1 donnait déjà 2 s (mesuré) : 2 s est le
  plancher de la bibliothèque cliente.
- Limites : mesures en essai unique ; durée de bascule mesurée depuis le poste ;
  réintégrer l'ancien primaire comme réplique n'est pas automatisé (on reconstruit).
