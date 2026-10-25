#!/usr/bin/env python3
import yaml
noeuds = yaml.safe_load(open("/vagrant/config/noeuds.yml"))
apps = [n for n in noeuds if n["role"] == "app"]

cfg = """global
    log /dev/log local0
    maxconn 2000

defaults
    mode http
    timeout connect 2s
    timeout client 30s
    timeout server 30s
    timeout check 2s
    retries 2
    option redispatch

frontend web
    bind *:80
    default_backend apps

frontend metrics
    bind *:8404
    http-request use-service prometheus-exporter if { path /metrics }
    no log

backend apps
    balance roundrobin
    option httpchk
    http-check send meth GET uri /sante
    http-check expect status 200
    # Budget de la sonde : 0,5 s d'attente du pool + 1 s de connexion = 1,5 s
    # au pire ; 2 s laisse la marge nécessaire pour que /sante réponde 503
    # franchement au lieu d'être coupée par le timeout (1 s écoulait des
    # serveurs sains sous charge, voir V3).
    default-server inter 1s fall 2 rise 2
"""
for n in apps:
    cfg += "    server %s %s:3000 check\n" % (n["nom"], n["ip"])
print(cfg)
