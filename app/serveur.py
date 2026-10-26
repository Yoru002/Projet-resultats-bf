#!/usr/bin/env python3
"""Service applicatif RESULTATS-BF, sans état (moins de 100 lignes : consigne du sujet).
GET /info (nom d'hôte, V1) ; GET /sante (200 si la base répond, 503 sinon : sonde HAProxy, R4) ;
GET /resultat?matricule=... (résultat JSON lu dans PostgreSQL). Aucune session ni cache : tout
l'état vit dans la base. Le pool de connexions (DB_POOL) n'est pas un état métier : il évite une
connexion authentifiée par requête, qui saturait la base sous charge (V3). Base absente au
démarrage : le service tourne et répond 503. Écoute sur 0.0.0.0, pas 127.0.0.1 (piège n°1)."""
import json, os, queue, socket, threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlparse
import psycopg2
E = os.environ.get
DB = {"host": E("DB_HOST", "127.0.0.1"), "port": int(E("DB_PORT", "5432")),
      "dbname": E("DB_NAME", "resultats"), "user": E("DB_USER", "appuser"),
      "password": E("DB_PASSWORD", ""), "target_session_attrs": E("DB_TARGET", "any"),
      "connect_timeout": int(E("DB_TIMEOUT", "3"))}
TAILLE, ATTENTE = int(E("DB_POOL", "10")), float(E("DB_POOL_TIMEOUT", "0.5"))
_libres = queue.Queue(maxsize=TAILLE)          # connexions disponibles
_places = threading.BoundedSemaphore(TAILLE)   # connexions vivantes <= TAILLE

def _connexion(neuve=False):
    """Connexion du pool (sauf si `neuve`), sinon une nouvelle tant qu'il reste de la place."""
    while not neuve:
        try:
            cn = _libres.get_nowait()
        except queue.Empty:
            break
        if not cn.closed:
            return cn
        _places.release()                      # connexion périmée : place rendue
    if not _places.acquire(timeout=ATTENTE):   # pool saturé : un 503 rapide, pas une file
        raise RuntimeError("pool de connexions sature")
    try:
        cn = psycopg2.connect(**DB)            # échoue si la base est absente
        cn.autocommit = True                   # sinon : connexion « idle in transaction »
        return cn
    except BaseException:
        _places.release()
        raise

def requete(sql, params=()):
    """Première ligne du résultat, ou None. 2e essai sur connexion neuve (après bascule)."""
    for essai in (1, 2):
        cn = _connexion(neuve=essai == 2)
        try:
            with cn.cursor() as cur:
                cur.execute(sql, params)
                ligne = cur.fetchone()
        except Exception:
            try:
                cn.close()
            finally:
                _places.release()
            if essai == 2:
                raise
        else:
            _libres.put_nowait(cn)             # jamais plein : <= TAILLE connexions vivantes
            return ligne

class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"              # keep-alive : nécessaire pour les mesures ab

    def _json(self, code, objet):
        corps = json.dumps(objet).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(corps)))
        self.end_headers()
        self.wfile.write(corps)

    def do_GET(self):
        url, hote = urlparse(self.path), socket.gethostname()
        if url.path == "/info":
            return self._json(200, {"host": hote})
        if url.path == "/sante":               # R4 : vérifie la base, jamais 200 par principe
            try:
                requete("SELECT 1")
                return self._json(200, {"ok": True, "host": hote})
            except Exception as exc:
                self.log_error("sante : base injoignable (%s)", exc)
                return self._json(503, {"ok": False, "host": hote})
        if url.path != "/resultat":
            return self._json(404, {"erreur": "inconnu"})
        matricule = (parse_qs(url.query).get("matricule") or [""])[0]
        if not matricule:
            return self._json(400, {"erreur": "paramètre matricule manquant"})
        try:
            ligne = requete("SELECT nom, serie, moyenne, admis FROM resultats "
                            "WHERE matricule = %s", (matricule,))   # requête paramétrée
        except Exception as exc:
            self.log_error("resultat : base indisponible (%s)", exc)
            return self._json(503, {"erreur": "base indisponible"})
        if ligne is None:
            return self._json(404, {"erreur": "matricule inconnu", "matricule": matricule})
        self._json(200, {"matricule": matricule, "nom": ligne[0], "serie": ligne[1],
                         "moyenne": float(ligne[2]), "admis": bool(ligne[3])})

if __name__ == "__main__":
    ThreadingHTTPServer(("0.0.0.0", int(E("APP_PORT", "3000"))), Handler).serve_forever()
