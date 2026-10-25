#!/usr/bin/env python3
"""Service applicatif RESULTATS-BF — sans état (rôle : ingénieur applicatif).

Points d'entrée :
  GET /info                   nom d'hôte du serveur qui a répondu (V1)
  GET /sante                  200 si la base répond, 503 sinon (sonde HAProxy)
  GET /resultat?matricule=... résultat du candidat en JSON, lu dans PostgreSQL

Sans état : aucune session, aucun cache de résultat ; n'importe quel serveur
peut prendre la suite d'un autre (V1, V2). Les connexions à PostgreSQL sont
réutilisées via un pool borné (DB_POOL) : ouvrir une connexion authentifiée
par requête saturait la base sous charge (50 requêtes concourantes : 1 à 2 s
par connexion, sonde /sante au-delà du timeout de HAProxy, rafale de 503).
La base peut être absente au démarrage : le service tourne et renvoie 503
(piège n°4). Écoute sur 0.0.0.0 et non 127.0.0.1 (piège n°1).
"""
import json
import os
import queue
import socket
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlparse

import psycopg2

DB = {
    "host": os.environ.get("DB_HOST", "127.0.0.1"),
    "port": int(os.environ.get("DB_PORT", "5432")),
    "dbname": os.environ.get("DB_NAME", "resultats"),
    "user": os.environ.get("DB_USER", "appuser"),
    "password": os.environ.get("DB_PASSWORD", ""),
    "target_session_attrs": os.environ.get("DB_TARGET", "any"),
    "connect_timeout": int(os.environ.get("DB_TIMEOUT", "3")),
}


TAILLE_POOL = int(os.environ.get("DB_POOL", "10"))
ATTENTE_POOL = float(os.environ.get("DB_POOL_TIMEOUT", "0.5"))

_libres = queue.Queue(maxsize=TAILLE_POOL)         # connexions disponibles
_places = threading.BoundedSemaphore(TAILLE_POOL)  # connexions vivantes <= TAILLE


class BaseIndisponible(Exception):
    """Pool saturé : un 503 rapide vaut mieux qu'une file d'attente infinie."""


def _connexion():
    """Connexion du pool, ou une nouvelle si le pool n'est pas plein."""
    try:
        cn = _libres.get_nowait()
        if not cn.closed:
            return cn
        _places.release()          # connexion périmée : la place est rendue
    except queue.Empty:
        pass
    if not _places.acquire(timeout=ATTENTE_POOL):
        raise BaseIndisponible("pool de connexions sature")
    try:
        return psycopg2.connect(**DB)   # échoue si la base est absente/injoignable
    except BaseException:
        _places.release()
        raise


def _rendre(cn):
    _libres.put_nowait(cn)         # jamais plein : <= TAILLE connexions vivantes


def _abandonner(cn):
    try:
        cn.close()
    finally:
        _places.release()


def requete(sql, params=()):
    """Première ligne du résultat, ou None. Connexion empruntée puis rendue."""
    for essai in (1, 2):           # 2e essai : élimine une connexion périmée (bascule)
        cn = _connexion()
        try:
            with cn.cursor() as cur:
                cur.execute(sql, params)
                ligne = cur.fetchone()
        except Exception:
            _abandonner(cn)
            if essai == 2:
                raise
            continue
        _rendre(cn)
        return ligne


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"        # keep-alive : nécessaire pour les mesures ab

    def _json(self, code, objet):
        corps = json.dumps(objet).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(corps)))
        self.end_headers()
        self.wfile.write(corps)

    def do_GET(self):
        url = urlparse(self.path)
        if url.path == "/info":   # V1 : observe la répartition entre serveurs
            self._json(200, {"host": socket.gethostname()})
        elif url.path == "/sante":
            # R4 : la sonde doit VÉRIFIER la base, jamais renvoyer 200 par principe
            try:
                requete("SELECT 1")
                self._json(200, {"ok": True, "host": socket.gethostname()})
            except Exception as exc:
                self.log_error("sante : base injoignable (%s)", exc)
                self._json(503, {"ok": False, "host": socket.gethostname()})
        elif url.path == "/resultat":
            self._resultat(parse_qs(url.query))
        else:
            self._json(404, {"erreur": "inconnu"})

    def _resultat(self, query):
        matricule = (query.get("matricule") or [""])[0]
        if not matricule:
            self._json(400, {"erreur": "paramètre matricule manquant"})
            return
        try:
            ligne = requete(   # requête paramétrée : pas d'injection possible
                "SELECT nom, serie, moyenne, admis FROM resultats WHERE matricule = %s",
                (matricule,))
        except Exception as exc:
            self.log_error("resultat : base indisponible (%s)", exc)
            self._json(503, {"erreur": "base indisponible"})
            return
        if ligne is None:
            self._json(404, {"erreur": "matricule inconnu", "matricule": matricule})
            return
        nom, serie, moyenne, admis = ligne
        self._json(200, {"matricule": matricule, "nom": nom, "serie": serie,
                         "moyenne": float(moyenne), "admis": bool(admis)})

    def do_HEAD(self):   # en-têtes seuls, sans corps ni accès à la base
        code = 200 if urlparse(self.path).path == "/info" else 404
        self.send_response(code)
        self.send_header("Content-Length", "0")
        self.end_headers()

    def do_POST(self):
        self._json(405, {"erreur": "méthode non autorisée"})

if __name__ == "__main__":
    port = int(os.environ.get("APP_PORT", "3000"))
    ThreadingHTTPServer(("0.0.0.0", port), Handler).serve_forever()
