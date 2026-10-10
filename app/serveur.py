#!/usr/bin/env python3
"""Service applicatif RESULTATS-BF — sans état (rôle : ingénieur applicatif).

Points d'entrée :
  GET /info                   nom d'hôte du serveur qui a répondu (V1)
  GET /sante                  200 si la base répond, 503 sinon (sonde HAProxy)
  GET /resultat?matricule=... résultat du candidat en JSON, lu dans PostgreSQL

Sans état : connexion ouverte par requête, refermée aussitôt. La base peut
être absente au démarrage : le service tourne et renvoie 503 (piège n°4).
Écoute sur 0.0.0.0 et non 127.0.0.1 (piège n°1).
"""
import json
import os
import socket
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


def requete(sql, params=()):
    """Première ligne du résultat, ou None. Sans état : connexion par requête."""
    cn = psycopg2.connect(**DB)          # échoue si la base est absente/injoignable
    try:
        with cn.cursor() as cur:
            cur.execute(sql, params)
            return cur.fetchone()
    finally:
        cn.close()

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
            except Exception:
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
        except Exception:
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
    port = int(os.environ.get("APP_PORT", "8000"))
    ThreadingHTTPServer(("0.0.0.0", port), Handler).serve_forever()
