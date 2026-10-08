# -*- mode: ruby -*-
require 'yaml'
require 'fileutils'

GROUPE   = (ENV['GROUPE'] || 4).to_i
NB_APP   = (ENV['NB_APP'] || 2).to_i
AVEC_LB2 = ENV['LB2'] == '1'            # extension E1
RESEAU   = "192.168.#{55 + GROUPE}"
VIP      = "#{RESEAU}.5"
BOITE    = "bento/ubuntu-24.04"
VERSION  = "202404.26.0"

# Lecture du .env (Vagrant ne le lit pas tout seul)
def charger_env(chemin)
  abort "Fichier .env manquant : cp .env.exemple .env" unless File.exist?(chemin)
  File.readlines(chemin).map(&:strip)
      .reject { |l| l.empty? || l.start_with?('#') }
      .map { |l| l.split('=', 2) }.to_h
end
SECRETS = charger_env(File.join(__dir__, '.env'))

# Source unique de vérité (clés en chaînes : lisibles par Python)
NOEUDS = []
NOEUDS << { "nom" => "bdd1", "ip" => "#{RESEAU}.31", "mem" => 768, "role" => "bdd" }
NOEUDS << { "nom" => "bdd2", "ip" => "#{RESEAU}.32", "mem" => 768, "role" => "replique" }
(1..NB_APP).each do |i|
  NOEUDS << { "nom" => "app#{i}", "ip" => "#{RESEAU}.#{20 + i}", "mem" => 512, "role" => "app" }
end
NOEUDS << { "nom" => "lb1", "ip" => "#{RESEAU}.11", "mem" => 512, "role" => "lb" }
NOEUDS << { "nom" => "lb2", "ip" => "#{RESEAU}.12", "mem" => 512, "role" => "lb" } if AVEC_LB2

FileUtils.mkdir_p("config")
File.write("config/noeuds.yml", NOEUDS.to_yaml)

Vagrant.configure("2") do |config|
  config.vm.box = BOITE
  config.vm.box_version = VERSION
  config.vm.box_check_update = false

  NOEUDS.each do |n|
    config.vm.define n["nom"] do |m|
      m.vm.hostname = n["nom"]
      m.vm.network "private_network", ip: n["ip"]
      # R8 : seul lb1 expose un port vers l'hôte
      m.vm.network "forwarded_port", guest: 80, host: 8080 if n["nom"] == "lb1"

      m.vm.provider "virtualbox" do |vb|
        vb.memory = n["mem"]
        vb.cpus = 1
        # utile pour la VIP VRRP si elle n'est pas joignable depuis l'hôte :
        # vb.customize ["modifyvm", :id, "--nicpromisc2", "allow-all"]
      end

      env = SECRETS.merge(
        "NODE_IP" => n["ip"], "NB_APP" => NB_APP.to_s, "GROUPE" => GROUPE.to_s,
        "PRIMARY_IP" => "#{RESEAU}.31", "REPLICA_IP" => "#{RESEAU}.32",
        "VIP" => VIP, "LB2" => AVEC_LB2 ? "1" : "0"
      )
      m.vm.provision "shell", path: "scripts/common.sh", env: env
      # lb : "always" pour régénérer HAProxy à chaque démarrage
      m.vm.provision "shell", path: "scripts/#{n['role']}.sh", env: env,
                     run: (n["role"] == "lb" ? "always" : "once")
    end
  end
end