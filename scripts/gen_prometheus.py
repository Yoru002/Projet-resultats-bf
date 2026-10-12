#!/usr/bin/env python3
import yaml
noeuds = yaml.safe_load(open("/vagrant/config/noeuds.yml"))

def job(nom, cibles, port):
    out = "  - job_name: %s\n    static_configs:\n" % nom
    for n in cibles:
        out += "      - targets: ['%s:%d']\n        labels: {nom: %s}\n" % (n["ip"], port, n["nom"])
    return out

cfg = "global:\n  scrape_interval: 5s\n\nscrape_configs:\n"
cfg += job("node", noeuds, 9100)
cfg += job("haproxy", [n for n in noeuds if n["role"] == "lb"], 8404)
print(cfg)
