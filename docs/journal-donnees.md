# Journal de bord : partie « Ingénieur données »

À fusionner dans le journal commun (L3). Dates : octobre 2026.

## Répartition des rôles
- Ingénieur données : Pégué Judicaël Ouédraogo (identités Git : « Pégué Judicaël Ouédraogo » et « pegueo2000 »)
- Autres rôles : à compléter par le groupe

## Décisions et raisons

| Décision | Raison |
|---|---|
| Deux utilisateurs distincts : `appuser` (lecture seule) et `replicator` (réplication) | Moindre privilège : l'application ne peut pas répliquer, la réplique ne lit pas l'application |
| Règles `pg_hba.conf` restreintes (réseau privé pour `appuser`, adresse de bdd2 pour `replicator`) | R8 : tout le trafic reste dans le réseau privé |
| Mots de passe lus depuis `.env`, transmis par variables d'environnement | R7 : aucun secret dans Git (vérifié sur tout l'historique : `.env` jamais versionné, seules des valeurs fictives dans `.env.exemple`) |
| Jeu de données déterministe (pas de `random()`) | Une reconstruction redonne le même contenu : les mesures sont comparables |
| Scripts idempotents (fichiers réécrits, ajouts gardés par `grep -qxF`, données insérées seulement si la table est vide, copie de la réplique gardée par `standby.signal`) | R2 : `vagrant provision` rejoué ne change rien (vérifié : `INSERT 0 0`, compte stable à 50 000) |
| Le script de bascule refuse de promouvoir bdd2 si bdd1 répond encore | Éviter le « split-brain » : deux bases qui acceptent des écritures divergeraient |
| Après une bascule, on reconstruit la paire au lieu de réintégrer l'ancien primaire | Simple et sûr ; limite connue, non automatisée |
| L'application reçoit les deux adresses (bdd2 puis bdd1) avec `target_session_attrs=read-write` | Elle suit la base promue sans redémarrage ni réécriture de configuration, et reste sans état |
| Numéro de groupe réseau : 4 | Le groupe 12 est ramené dans la plage 1 à 8 en recommençant la numérotation après 8 (12 − 8 = 4) ; décision du groupe |

## Difficultés et résolution

1. **Vagrant 2.3.4 incompatible avec VirtualBox 7.2** (versions supportées jusqu'à 7.0).
   Résolu en passant à Vagrant 2.4.9 depuis le dépôt HashiCorp (Fedora 44).
2. **Réseau privé impossible** : `/dev/vboxnetctl` absent car les modules `vboxnetadp` et `vboxnetflt`
   n'étaient pas chargés. Résolu par `modprobe`, rendu permanent dans `/etc/modules-load.d/`.
3. **Plage d'adresses** : `192.168.67.11` (formule 55 + 12 pour le groupe 12) refusé par VirtualBox
   (plages autorisées : `192.168.56.0/21` et `fe80::/10`, aucun `networks.conf`). Mesuré sur le poste.
   Décision du groupe : le numéro 12 est ramené dans la plage 1 à 8 en recommençant la numérotation après 8 (12 − 8 = 4). Le dépôt utilise donc `GROUPE=4` (192.168.59.x) par défaut.
4. **Après une bascule réussie, l'application restait en 503** : elle n'interrogeait que bdd1.
   Corrigé avec les deux adresses (voir ci-dessus).
5. **Latence après bascule** : avec l'ordre bdd1,bdd2, `/sante` répondait en 2 à 3 s et le retour à 200 prenait 12,8 s.
   `DB_TIMEOUT=1` donnait 2,02 s (la bibliothèque cliente semble borner le délai à 2 s : observé, non vérifié dans sa documentation).
   Avec l'ordre bdd2,bdd1 : 200 en 0,013 s, retour à 200 en 9,7 s (durée de la bascule).
6. **503 passager de /sante**, observé à trois reprises : (a) un 503 de 2 s en fonctionnement normal juste après une reconstruction partielle (bases recréées, app1 conservée) ;
   (b) 9,1 s d'attente avant le premier 200 dans la même situation (enregistré par l'étape 0 de `mesure_v4.sh`) ;
   (c) deux 503 juste après `vagrant provision app1`, puis 200 sans intervention.
   Une entrée voisinage `FAILED` (app1 vers bdd1) a été observée dans (a) et (b) : simple corrélation.
   Un `systemctl restart resultats` seul, suivi de 20 appels espacés de 0,5 s, n'a produit aucun 503 (tous en 200, 0,02 à 0,03 s) : le redémarrage du service n'explique donc pas le phénomène à lui seul.
   **Cause non établie** ; la sonde de santé du répartiteur doit l'absorber.
7. **Historique Git** : six identités pour quatre membres (dont deux pour l'auteur de ce journal). À régler avec un fichier `.mailmap`.
8. **`HEAD /sante` renvoyait toujours 200 sans interroger la base**, et le fichier `serveur.py` atteignait 100 lignes (consigne : moins de cent).
   Relevé en relisant le code. Correction proposée : `HEAD /sante` renvoie 404 (la sonde doit utiliser `GET /sante`), fichier ramené à 99 lignes (branche `app-corrections`).

## Mesures (résultats bruts dans `docs/mesures/`)

| Mesure | Résultat |
|---|---|
| R5 : écriture sur bdd1, lecture sur bdd2, écriture refusée sur bdd2 | Conforme (`r5-replication.txt`) |
| V4, durée de la bascule, trois essais | 9,7 s, 10,4 s, 10,0 s (moyenne 10,0 s) |
| V4 avec l'application, retour à 200 | 9,7 s, bascule comprise |

## Limites
- Les durées de bascule incluent le délai de détection (3 s) et les connexions `vagrant ssh` : ce n'est pas la promotion seule.
- Mesures en essais peu nombreux, sur un seul poste, VM de 768 Mo et 1 processeur.
- Le scénario V4 n'a pas été mesuré avec le répartiteur (non disponible au moment des essais).
- Le sous-réseau 192.168.59.x est celui du groupe 4 du sujet : les réseaux hôte-seul sont propres à chaque poste, donc sans conflit, sauf si deux groupes partagent la même machine (démonstration).
