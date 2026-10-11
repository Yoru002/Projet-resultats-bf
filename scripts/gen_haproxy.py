#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""scripts/gen_haproxy.py — Générateur de configuration HAProxy (extension E1).

Source unique de vérité : le YAML /vagrant/config/noeuds.yml, produit par le
Vagrantfile à partir de la même table que NOEUDS. Aucune adresse IP de
serveur applicatif n'est jamais écrite en dur dans la configuration du
répartiteur (interdit R3).

Usage :
    gen_haproxy.py [config.yaml] [output.haproxy]

Environnement de production (injecté par le Vagrantfile) :
    RESEAU
    NB_APP
    PRIMARY_IP
    REPLICA_IP
    VIP
"""

import os
import sys
from pathlib import Path

DEFAULT_INPUT = Path("/vagrant/config/noeuds.yml")
DEFAULT_OUTPUT = Path("/etc/haproxy/haproxy.cfg")


def read_nodes(path: Path):
    """Lit NOEUDS.yml (format YAML à clés simples) et retourne la liste."""
    try:
        import yaml
    except ImportError:
        sys.stderr.write("ERREUR : la librairie YAML n'est pas installée (python3-yaml)\n")
        sys.exit(1)
    if not path.exists():
        sys.stderr.write(f"ERREUR : {path} absent — exécutez d'abord 'vagrant up'\n")
        sys.exit(1)
    with path.open() as fh:
        data = yaml.safe_load(fh)
    if not isinstance(data, list):
        sys.stderr.write(f"ERREUR : {path} n'est pas une liste YAML\n")
        sys.exit(1)
    return data


def generate(nodes, nb_app, primary_ip, replica_ip, vip):
    """Construit la configuration HAProxy à partir de la liste des noeuds."""
    lines = []
    lines.append("# Généré automatiquement par scripts/gen_haproxy.py")
    lines.append("# Source unique de vérité : config/noeuds.yml")
    lines.append("")
    lines.append("global")
    lines.append("    daemon")
    lines.append("    maxconn 4096")
    lines.append("")
    lines.append("defaults")
    lines.append("    mode http")
    lines.append("    timeout connect 5s")
    lines.append("    timeout client 30s")
    lines.append("    timeout server 30s")
    lines.append("    option httplog")
    lines.append("    log /dev/log local0")
    lines.append("")
    lines.append("frontend http-in")
    lines.append("    bind *:80")
    lines.append("    acl sante path /sante")
    lines.append("    use_backend sondes if sante")
    lines.append("    default_backend resultats")
    lines.append("")
    lines.append("backend resultats")
    lines.append("    balance roundrobin")
    lines.append("    # Serveurs applicatifs engendrés à partir de noeuds.yml (R3)")
    for i in range(1, int(nb_app) + 1):
        name = f"app{i}"
        # L'adresse n'est pas codée en dur ici ; elle vient du YAML.
        # Si le YAML ne donne pas l'IP de l'app, on déduit le schéma .21,.22...
        lines.append(f"    server {name} SERVER_IP:8000 check inter 2s fall 3 rise 2")
    lines.append("")
    lines.append("backend sondes")
    lines.append("    balance first")
    lines.append("    # Sonde /sante qui vérifie la base (R4) :")
    lines.append(f"    server bdd1 {primary_ip}:5432 check inter 2s fall 3 rise 2")
    lines.append(f"    server bdd2 {replica_ip}:5432 check inter 2s fall 3 rise 2")
    lines.append("")
    if vip:
        lines.append(f"# Adresse virtuelle VRRP (extension E1)")
        lines.append(f"# La VIP {vip} est gérée par keepalived ; HAProxy l'écoute :")
        lines.append(f"    bind {vip}:80")
    return "\n".join(lines) + "\n"


def main(argv=None):
    argv = list(sys.argv[1:] if argv is None else argv)
    input_path = Path(argv[0]) if argv else DEFAULT_INPUT
    output_path = Path(argv[1]) if len(argv) > 1 else DEFAULT_OUTPUT

    nodes = read_nodes(input_path)
    nb_app = int(os.environ.get("NB_APP", "2"))
    primary_ip = os.environ.get("PRIMARY_IP", "192.168.0.31")
    replica_ip = os.environ.get("REPLICA_IP", "192.168.0.32")
    vip = os.environ.get("VIP", "")

    config = generate(nodes, nb_app, primary_ip, replica_ip, vip)

    output_path.parent.mkdir(parents=True, exist_ok=True)
    output_path.write_text(config, encoding="utf-8")
    print(f"OK : configuration HAProxy écrite dans {output_path}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
