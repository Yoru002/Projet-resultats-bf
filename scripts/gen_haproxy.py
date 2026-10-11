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
    timeout check 1s
    retries 2
    option redispatch

frontend web
    bind *:80
    default_backend apps

backend apps
    balance roundrobin
    option httpchk
    http-check send meth GET uri /sante
    http-check expect status 200
    default-server inter 1s fall 2 rise 2
"""
for n in apps:
    cfg += "    server %s %s:3000 check\n" % (n["nom"], n["ip"])
print(cfg)
