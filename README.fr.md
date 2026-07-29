# Orange Pi 5B — Guide

<p align="center">
  <img src="OP5B.webp" alt="Orange Pi 5B">
</p>

*[Read in English](README.md)*

Notes de configuration pour mon Orange Pi 5B : choix de l'OS (Ubuntu
Server 24.04), installation, durcissement SSH/système, préservation de
l'eMMC (logs en RAM, gel du noyau vendor), pare-feu, et déploiement de
services systemd (bots Discord notamment).

Écrit pour mon usage, mais réutilisable tel quel ou comme base à adapter
à ta propre configuration — remplace les valeurs entre `<...>` par les tiennes.

Port SSH utilisé en exemple dans ce guide : **32412** (adapte à ta config).

## Sommaire

0. [Installation initiale](#0-installation-initiale)
1. [Premiers réglages système](#1-premiers-réglages-système)
2. [Mise à jour et gel des paquets](#2-mise-à-jour-et-gel-des-paquets)
3. [Pare-feu (UFW)](#3-pare-feu-ufw)
4. [Durcissement & préservation eMMC](#4-durcissement--préservation-emmc)
5. [Commandes utiles](#5-commandes-utiles)
6. [Installer les outils](#6-installer-les-outils)
7. [Déployer un service systemd](#7-déployer-un-service-systemd)

---

## 0. Installation initiale

### Flasher l'image sur l'Orange Pi 5B

Tutoriel vidéo : [Flashage de l'image sur l'Orange Pi 5B (mode Maskrom)](https://youtu.be/5q_tytwmseg)

Outils nécessaires pour le flashage, à utiliser en suivant la vidéo
ci-dessus : [RKDevTool-DriverAssitant-MiniLoader.zip](RKDevTool-DriverAssitant-MiniLoader.zip)

Image à flasher — Ubuntu Server 24.04 préinstallé pour Orange Pi 5B, projet
[ubuntu-rockchip de Joshua Riek](https://github.com/Joshua-Riek/ubuntu-rockchip) :
[ubuntu-24.04-preinstalled-server-arm64-orangepi-5b.img.xz](https://github.com/Joshua-Riek/ubuntu-rockchip/releases/download/v2.4.0/ubuntu-24.04-preinstalled-server-arm64-orangepi-5b.img.xz)

### Accès SSH

#### Générer une clé (côté Windows)

```powershell
ssh-keygen -t ed25519 -f %userprofile%\.ssh\sbc1 -C "orangepi5b"
```

#### Envoyer la clé publique au serveur

La clé **privée** ne quitte jamais Windows (`%USERPROFILE%\.ssh\sbc1`).

```powershell
type "%USERPROFILE%\.ssh\sbc1.pub" | ssh <UTILISATEUR>@<IP_SERVEUR> "mkdir -p ~/.ssh && cat >> ~/.ssh/authorized_keys && chmod 700 ~/.ssh && chmod 600 ~/.ssh/authorized_keys"
```

#### Tester

```powershell
ssh -i %USERPROFILE%\.ssh\sbc1 <UTILISATEUR>@<IP_SERVEUR>
```

#### Durcir la configuration SSH

```bash
sudo nano /etc/ssh/sshd_config
```

Contenu à adapter/coller (`Ctrl+O` puis `Entrée` pour sauvegarder, `Ctrl+X` pour quitter) :

```ini
Port 32412
LoginGraceTime 30s
PermitRootLogin no
MaxAuthTries 3
PubkeyAuthentication yes
AuthorizedKeysFile .ssh/authorized_keys
PasswordAuthentication no
KbdInteractiveAuthentication no
UsePAM yes
X11Forwarding no
AllowUsers <UTILISATEUR>   # si un seul utilisateur sur la machine
```

```bash
sudo systemctl restart ssh
```

#### Config SSH côté Windows (`%USERPROFILE%\.ssh\config`)

Sert à la fois pour `ssh <ALIAS>` en raccourci et pour VSCode Remote-SSH :

```
Host <ALIAS>
    HostName <IP_SERVEUR>
    User <UTILISATEUR>
    Port 32412
    IdentityFile ~/.ssh/sbc1
```

#### Vérifier les tentatives d'intrusion

Pas de `/var/log/auth.log` sur cette machine (rsyslog désactivé, voir
[section 4](#4-durcissement--préservation-emmc) ; journald en
`ForwardToSyslog=no` — voir [99-journald-emmc.conf](99-journald-emmc.conf)) :
passe par `journalctl` à la place.

```bash
sudo journalctl -u ssh -g "Invalid user"
```

⚠️ Si `Storage=volatile` (choix fait dans ce guide), ça ne couvre que le boot
en cours — pas d'historique après un reboot.

### Changer le nom d'utilisateur (et le hostname)

`usermod -l` refuse de renommer un utilisateur actuellement connecté ou avec
des process actifs — plus simple de créer un nouveau compte, migrer, puis
supprimer l'ancien.

```bash
sudo adduser <NOUVEAU>
sudo usermod -aG sudo <NOUVEAU>                  # droits sudo
sudo usermod -aG systemd-journal <NOUVEAU>       # lire journalctl sans sudo
sudo hostnamectl set-hostname <NOUVEAU_HOSTNAME> # nom de la machine sur le réseau (visible dans le prompt, mDNS, etc.)
```

⚠️ **Avant de supprimer l'ancien compte**, migre son contenu — la commande
`userdel -r` (utilisée plus loin) supprime `/home/<ANCIEN>` en entier, bots
compris :

```bash
sudo rsync -aAX /home/<ANCIEN>/ /home/<NOUVEAU>/
sudo chown -R <NOUVEAU>:<NOUVEAU> /home/<NOUVEAU>
```

(ça inclut `~/.ssh/authorized_keys` — ta clé SSH suit automatiquement)

Met à jour les fichiers qui référencent l'ancien nom en dur avant de basculer :
- `User=`/`WorkingDirectory=` dans tes `.service` (voir
  [discord-bot.service](discord-bot.service)) → `daemon-reload` + `restart` une fois corrigé
- `AllowUsers` dans `/etc/ssh/sshd_config` (voir Accès SSH ci-dessus) — oublié,
  le nouveau compte est bloqué en SSH même avec la bonne clé

Bascule et nettoie :

```bash
exit
ssh <NOUVEAU>@<IP_SERVEUR>
sudo pkill -u <ANCIEN>
sudo userdel -r <ANCIEN>
ls /home   # vérifier
```

### Fichiers à copier dans le `$HOME` de l'Orange Pi 5B

Compte renommé et SSH sécurisé (clé + port 32412, étapes ci-dessus) : copie
maintenant ces fichiers du dépôt dans le `$HOME` de l'utilisateur sur
l'Orange Pi 5B (`git clone`, `scp`, ou copier-coller manuel) :

- [.bashrc](.bashrc)
- [99-hardening.conf](99-hardening.conf)
- [99-journald-emmc.conf](99-journald-emmc.conf)
- [orangepi5b-kernel-freeze.sh](orangepi5b-kernel-freeze.sh)
- [systemd-journald-override.conf](systemd-journald-override.conf)
- [ufw-setup.sh](ufw-setup.sh)

---

## 1. Premiers réglages système

### Connexion automatique (console, sans écran/clavier ça ne sert à rien en pratique)

```bash
sudo mkdir -p /etc/systemd/system/getty@tty1.service.d
sudo nano /etc/systemd/system/getty@tty1.service.d/override.conf
```

Contenu à coller (`Ctrl+O` puis `Entrée` pour sauvegarder, `Ctrl+X` pour quitter) :

```ini
[Service]
ExecStart=
ExecStart=-/sbin/agetty --autologin <UTILISATEUR> --noclear --noissue %I $TERM
```

```bash
sudo systemctl daemon-reload
```

### Fuseau horaire et format 24h (France)

```bash
sudo timedatectl set-timezone Europe/Paris
sudo localectl set-locale LC_TIME="fr_FR.UTF-8"   # format 24h (en_US.UTF-8 donnerait du 12h AM/PM)
```

Déconnecte-toi/reconnecte-toi pour que le changement de format s'applique.

### Désactiver WiFi et Bluetooth (carte en Ethernet filaire)

```bash
rfkill list                   # état actuel des radios
sudo rfkill block wifi
sudo rfkill block bluetooth
```

Persistant automatiquement au reboot (`systemd-rfkill` sauvegarde l'état).
Pour couper complètement le démon Bluetooth :

```bash
sudo systemctl disable --now bluetooth.service
```

### `Wait for Network to be Configured` qui échoue au boot (connexion pourrie)

Sur une connexion pas toujours stable, `systemd-networkd-wait-online.service`
peut échouer au boot (`Failed to start Wait for Network to be Configured`) —
il attend une connexion propre jusqu'au délai par défaut (120s) avant de
lâcher l'affaire.

```bash
sudo systemctl edit --full systemd-networkd-wait-online.service
```

Sur la ligne `ExecStart=`, ajoute `--timeout=10` (raccourcit le délai d'attente à 10s) :

```ini
ExecStart=/lib/systemd/systemd-networkd-wait-online --timeout=10
```

```bash
sudo systemctl daemon-reload
```

### Services non-nécessaires sur Orange Pi 5B

```bash
sudo systemctl disable --now apport         # rapports de crash Ubuntu
sudo systemctl mask apport

sudo systemctl disable --now ModemManager   # pas de modem cellulaire sur cette carte

sudo systemctl disable --now multipathd     # pas de stockage multi-chemin (SAN/iSCSI)
sudo systemctl mask multipathd multipathd.socket

sudo systemctl disable --now plymouth-quit-wait plymouth-quit plymouth-read-write # écran de boot graphique, inutile en headless
```

⚠️ `lvm2-monitor` et `blk-availability` (même famille, device-mapper)
seulement si la carte n'utilise pas LVM — vérifie avant avec `lsblk` (pas de
volume group affiché = bon) :

```bash
sudo systemctl disable --now lvm2-monitor blk-availability
```

`cloud-init` ne sert que pour la configuration au tout premier boot — sans
risque à couper une fois la carte déjà configurée (ce qui est le cas à ce
stade du guide) :

```bash
sudo touch /etc/cloud/cloud-init.disabled
sudo systemctl disable --now cloud-init \
  cloud-config \
  cloud-final \
  cloud-init-local
```

### Purger snapd (optionnel)

Si tu n'utilises aucun paquet snap : `apt purge` retire le paquet en entier
(binaires, données dans `/var/lib/snapd`/`/var/cache/snapd`), ce qui
supprime au passage tous ses services (`snapd.service`, `snapd.socket`,
`snapd.apparmor.service`...) — pas besoin de les désactiver un par un avant.

```bash
sudo systemctl disable --now snapd.socket snapd.service snapd.apparmor.service
sudo apt purge -y snapd
sudo rm -rf /var/cache/snapd /var/lib/snapd ~/snap
sudo apt-mark hold snapd # évite qu'un futur paquet dépendant de snapd le réinstalle tout seul
```

---

## 2. Mise à jour et gel des paquets

⚠️ Sur une carte fraîchement installée, **fige d'abord le noyau vendor
Rockchip** avant tout `apt upgrade` — un upgrade générique peut le remplacer
par un noyau standard sans les pilotes Rockchip (eMMC/NVMe/GPU) et empêcher
le démarrage. Script prêt à l'emploi :
[orangepi5b-kernel-freeze.sh](orangepi5b-kernel-freeze.sh).

### Geler les paquets à la main

```bash
uname -r                # noyau réellement en cours d'exécution, ex: 6.1.0-1025-rockchip
dpkg -l | grep -i linux # repère les paquets contenant cette version
```

Deux catégories à geler, les deux comptent (adapte les noms à ta version) :

```bash
# Paquets versionnés (contiennent le numéro trouvé avec uname -r)
sudo apt-mark hold linux-image-6.1.0-1025-rockchip linux-headers-6.1.0-1025-rockchip \
  linux-modules-6.1.0-1025-rockchip linux-modules-extra-6.1.0-1025-rockchip \
  linux-rockchip-headers-6.1.0-1025

# Meta-paquets SANS numéro de version (faciles à oublier, ce sont eux qui
# peuvent tirer une nouvelle version au prochain upgrade)
sudo apt-mark hold linux-rockchip linux-headers-rockchip linux-image-rockchip linux-firmware
```

```bash
apt-mark showhold   # vérifie que tout y est
```

### Dégeler

```bash
sudo apt-mark unhold <PAQUET>              # un paquet précis
sudo apt-mark unhold $(apt-mark showhold)  # tout dégeler d'un coup
```

### Mettre à jour le reste sans toucher au noyau gelé

```bash
sudo apt update && sudo apt upgrade
sudo apt autoremove --dry-run # ⚠️ TOUJOURS en simulation d'abord
sudo apt autoremove           # seulement si aucun paquet noyau/firmware dans la simulation
```

`apt-mark hold` protège de l'upgrade, mais certaines versions d'apt ont par
le passé proposé de supprimer un paquet gelé devenu "orphelin" lors d'un
autoremove — d'où le `--dry-run` systématique.

⚠️ Ce gel n'est pas à vie : il bloque aussi les correctifs de sécurité du
noyau. Revérifie tous les 3-6 mois si une image plus récente existe, puis
dégèle → upgrade ciblé → regèle.

---

## 3. Pare-feu (UFW)

Voir [ufw-setup.sh](ufw-setup.sh) pour la configuration complète
(reproductible, avec filet de sécurité anti-lockout). Vérification rapide :

```bash
sudo ufw status verbose
```

Le port 80 dans `EXTRA_LAN_TCP_PORTS=(80)` correspond à l'interface web
d'AdGuard Home (voir section 6). Vérification effectuée avec
`sudo ss -tulpn` : le port 3000 (assistant d'installation initial) n'est
plus en écoute, seul le port 80 l'est — l'interface d'administration a donc
été basculée sur ce port.

### Bloquer une adresse IP

```bash
sudo ufw deny from <IP>          # bloque toutes les connexions entrantes depuis cette IP
sudo ufw insert 1 deny from <IP> # même règle, mais prioritaire sur celles déjà en place
```

Vérifier / retirer ensuite :

```bash
sudo ufw status numbered # affiche les règles avec un numéro
sudo ufw delete <NUMERO> # supprime la règle correspondante
```

---

## 4. Durcissement & préservation eMMC

Fichiers concernés : [99-hardening.conf](99-hardening.conf) (sysctl),
[99-journald-emmc.conf](99-journald-emmc.conf) +
[systemd-journald-override.conf](systemd-journald-override.conf) (logs),
`/etc/fstab` (dossiers en RAM, voir plus bas).

`cp` écrase directement l'ancien fichier au même chemin — pour mettre à jour
une config déjà installée, pas besoin de la supprimer avant, juste recopier
et recharger le service concerné :

```bash
sudo cp 99-hardening.conf /etc/sysctl.d/99-hardening.conf && sudo sysctl --system
sudo mkdir -p /etc/systemd/journald.conf.d
sudo cp 99-journald-emmc.conf /etc/systemd/journald.conf.d/99-journald-emmc.conf
sudo rm -f /etc/systemd/journald.conf
sudo systemctl restart systemd-journald
```

`/etc/sysctl.d/` existe déjà par défaut sur Ubuntu, mais `/etc/systemd/journald.conf.d/` doit être créé une première fois (`mkdir -p` ne râle pas s'il existe déjà, donc sans risque de le relancer plus tard).

⚠️ Le `rm` sur `/etc/systemd/journald.conf` est volontaire : si tu (ou une install précédente) avais déjà mis des valeurs en dur dans ce fichier, elles cohabiteraient avec le drop-in et rendraient la vérification confuse (même si le drop-in gagne toujours en cas de conflit). Le supprimer garantit que `99-journald-emmc.conf` est la seule source de config — journald retombe sur ses valeurs par défaut pour tout le reste, sans y perdre quoi que ce soit d'important.

Pourquoi `/etc/systemd/journald.conf.d/` et pas directement
`/etc/systemd/journald.conf` (la façon "classique", `sudo nano
/etc/systemd/journald.conf`) : un dossier `.d/` est un fichier qu'on a
nous-même créé, jamais géré par un paquet — un `apt upgrade` de systemd ne
demandera jamais "le fichier a été modifié localement, garder/remplacer ?"
comme ça peut arriver sur le fichier principal. Même logique que
`/etc/sysctl.d/` pour `99-hardening.conf`.

Vérifier ce qui est réellement actif (fusion fichier principal + drop-ins) :

```bash
systemd-analyze cat-config systemd/journald.conf
```

Vérifier concrètement que le journal tourne bien en RAM (`Storage=volatile`) et pas sur l'eMMC :

```bash
journalctl --header | grep -i "file path"
```

Le chemin affiché doit être sous `/run/log/journal/...` (tmpfs, RAM) — si tu vois `/var/log/journal/...`, ce n'est pas actif.

### Désactiver rsyslog (doublon avec journald)

Ubuntu Server installe `rsyslog` par défaut — s'il tourne encore, il écrit
en parallèle ses propres logs texte sur l'eMMC (`/var/log/syslog`,
`/var/log/auth.log`...), ce qui va à l'encontre du journal en RAM configuré
ci-dessus. Vérifier : `systemctl status rsyslog`. Le retirer :

```bash
sudo systemctl disable --now rsyslog
sudo apt purge -y rsyslog
```

### Priorité CPU/I/O de journald face aux bots

`99-journald-emmc.conf` règle CE QUE journald garde. Ce qui suit règle la
priorité d'exécution DU PROCESS journald lui-même — deux mécanismes
différents (l'un lu par journald, l'autre par systemd PID 1), donc deux
fichiers à deux emplacements différents, impossible de les fusionner.

```bash
sudo mkdir -p /etc/systemd/system/systemd-journald.service.d
sudo cp systemd-journald-override.conf /etc/systemd/system/systemd-journald.service.d/override.conf
sudo systemctl daemon-reload
sudo systemctl restart systemd-journald
```

Vérifier : `systemctl show systemd-journald --property=Nice,IOSchedulingClass,CPUWeight`

### AdGuard Home (query log / statistiques)

Angle mort par rapport à ce qui précède : AdGuard Home (voir section 6)
écrit son propre journal de requêtes DNS et ses statistiques sur l'eMMC,
dans `/opt/AdGuardHome/data/`, indépendamment de journald/rsyslog. Se
règle dans l'interface web, pas en fichier de config :

**Settings** → **General Settings** → décoche *Enable log* et *Enable
statistics* (ou au minimum réduis leur période de rétention), puis **Save**.

### `/etc/fstab`

`/etc/fstab` fait exception : contrairement aux fichiers précédents, il n'a
pas de dossier `.d/` — les lignes s'ajoutent/se remplacent directement
dedans, pas de drop-in.

⚠️ Sauvegarde avant de toucher au fichier — une erreur de syntaxe dans
`/etc/fstab` peut empêcher un démarrage propre :

```bash
sudo cp /etc/fstab /etc/fstab.bak
sudo nano /etc/fstab
```

Sur la ligne existante de la partition racine (`/`), ajoute
`,commit=60,x-systemd.growfs` à la fin des options déjà présentes (4ème
colonne) — pas besoin de retrouver l'UUID, tu ne touches pas au reste de la
ligne. `commit=60` espace les commits du journal ext4 (à coordonner avec
`dirty_writeback` dans `99-hardening.conf`) ; `x-systemd.growfs` étend la
partition au boot si besoin.

Ajoute ensuite les lignes `tmpfs` à la fin du fichier, sans toucher aux
autres lignes existantes (boot, swap) :

```
tmpfs /tmp              tmpfs rw,nosuid,nodev,noexec,noatime,mode=1777,size=512M 0 0  # noexec : casse npm install si dépendance native (node-gyp)
tmpfs /var/tmp          tmpfs rw,nosuid,nodev,noatime,mode=1777,size=128M 0 0         # contrairement à /tmp, ne survit plus au reboot une fois en tmpfs
tmpfs /var/cache/apt    tmpfs rw,noatime,mode=0755,size=1G 0 0                        # large volontairement, évite un ENOSPC en plein apt upgrade
tmpfs /var/log          tmpfs rw,nosuid,nodev,noatime,mode=0755,size=100M 0 0         # wtmp/btmp/lastlog repartent à zéro à chaque reboot
tmpfs /var/spool        tmpfs rw,nosuid,nodev,noatime,mode=0755,size=50M 0 0          # ⚠️ efface les crontabs utilisateur (crontab -e) à chaque reboot

# tmpfs /var/lib/fail2ban tmpfs rw,noatime,mode=0755,size=32M 0 0   # si fail2ban installé : configure ses jails en backend=systemd (pas de rsyslog ici)
```

Sauvegarde (`Ctrl+O` puis `Entrée`), quitte (`Ctrl+X`), puis applique sans
reboot pour vérifier que fstab est bien lu :

```bash
sudo systemctl daemon-reload
sudo mount -a
findmnt -t tmpfs   # confirme que les points de montage sont bien actifs
```

---

## 5. Commandes utiles

### nano (éditeur de texte, le strict minimum)

| Raccourci | Action |
|---|---|
| `Ctrl+O` puis `Entrée` | Sauvegarder sans quitter |
| `Ctrl+X` | Quitter (demande `Y`/`N` si modifs non sauvegardées, puis `Entrée` pour confirmer le nom de fichier) |

### Processus

```bash
ps -e         # liste tous les process
kill <PID>    # termine un process (SIGTERM, propre)
kill -9 <PID> # forcé (SIGKILL, en dernier recours)
htop          # vue interactive CPU/RAM par process
```

### Système & réseau — diagnostic rapide

| Commande | Utilité |
|---|---|
| `ip a` (ou `ifconfig`) | Adresses et interfaces réseau |
| `iwconfig` | Infos WiFi |
| `hostname -I` | Affiche uniquement l'IP de la machine |
| `hcitool dev` | État Bluetooth |
| `lsusb` | Périphériques USB connectés |
| `dmesg` | Logs noyau (boot, matériel) |
| `dmesg \| sed '/eth.*Link is/h;${x;p};d'` | Qualité du câble Ethernet |
| `dmesg \| grep -i Voltage` | Qualité de l'alimentation |
| `free -h` | RAM disponible/utilisée |
| `sensors` | Températures des composants |
| `lsb_release -a` | Version d'Ubuntu installée |

### Divers

```bash
clear  # nettoie le terminal
reboot # sudo reboot
exit   # ferme la session
```

---

## 6. Installer les outils

Rien d'obligatoire ici — installe uniquement ce dont tu as besoin.

### Node.js (via `n`, méthode recommandée — pas les paquets `nodejs` d'apt)

`n` s'installe lui-même via npm — il faut donc un npm de bootstrap avant de
pouvoir l'utiliser (il sera ensuite remplacé par la version que `n` installe) :

```bash
sudo apt install nodejs npm
sudo npm install -g n
sudo n latest
```

Retirer un ancien Node.js installé via apt (évite les conflits de chemin) :

```bash
sudo apt-get purge nodejs*
sudo rm -rf /var/lib/apt/lists/*
sudo rm -rf /etc/apt/sources.list.d/*
sudo apt-get update
```

Confirme que `node` pointe bien vers l'install de `n` (`/usr/local/bin/node`
— c'est justement le chemin codé en dur dans `ExecStart=` de
[discord-bot.service](discord-bot.service)) :

```bash
which node
node -v
```

Commandes utiles npm/Node :

```bash
sudo n latest                                           # mettre à jour Node.js
sudo npm install -g npm@latest                          # mettre à jour npm lui-même
sudo npm update -g                                      # mettre à jour les paquets npm globaux
sudo npm cache clean --force                            # vider le cache npm
npm cache verify                  
npm view <PAQUET> version                               # dernière version publiée d'un paquet
npm list <PAQUET>                                       # version installée localement
sudo rm -rf node_modules package.json package-lock.json # reset des dépendances d'un projet
npm pkg set type=module                                 # active la syntaxe ESM (import/export) au lieu de require/module.exports
```

### Java (JDK, install manuelle — ARM64)

Trouver la version actuelle : [oracle.com/java/technologies/downloads](https://www.oracle.com/java/technologies/downloads/)
→ repère le numéro de version majeure affiché (ex: 26), section Linux →
bouton "ARM 64 Compressed Archive" (clic droit → copier le lien pour
vérifier l'URL exacte).

Le lien suit toujours ce format, où seul le numéro de version majeure
change — inutile de connaître le numéro de build exact, `latest` dans l'URL
s'en charge automatiquement :

```
https://download.oracle.com/java/<VERSION>/latest/jdk-<VERSION>_linux-aarch64_bin.tar.gz
```

```bash
wget https://download.oracle.com/java/<VERSION>/latest/jdk-<VERSION>_linux-aarch64_bin.tar.gz
sudo mkdir -p /usr/lib/jvm
sudo tar -zxf jdk-*_linux-aarch64_bin.tar.gz -C /usr/lib/jvm
sudo mv /usr/lib/jvm/jdk-<VERSION>.* /usr/lib/jvm/jdk-<VERSION>

sudo update-alternatives --install /usr/bin/java java /usr/lib/jvm/jdk-<VERSION>/bin/java 100
sudo update-alternatives --install /usr/bin/javac javac /usr/lib/jvm/jdk-<VERSION>/bin/javac 100
sudo update-alternatives --config java
sudo update-alternatives --config javac

java --version
javac --version
```

Désinstaller :

```bash
sudo rm -R /usr/lib/jvm/jdk-<VERSION>
sudo rm -f /etc/profile.d/jdk.sh /etc/profile.d/jdk.csh
```

### Serveur Minecraft (PaperMC)

Nécessite le JDK installé ci-dessus. Télécharge la dernière build stable :
[papermc.io/downloads/paper](https://papermc.io/downloads/paper)

Lancement direct (garde le terminal ouvert) :

```bash
java -Xmx<RAM_MB>M -Xms<RAM_MB>M -jar paper.jar nogui
```

`-Xmx`/`-Xms` fixent la RAM allouée à la JVM (identiques pour éviter les
réallocations à chaud) — laisse de la marge pour l'OS et les autres
services (AdGuard Home, bots...) plutôt que de tout donner au serveur.

#### Garder le serveur actif sans terminal dédié (SSH sans VSCode)

```bash
sudo apt install screen
screen -S paper
java -Xmx<RAM_MB>M -Xms<RAM_MB>M -jar paper.jar nogui
```

`Ctrl+A` puis `D` détache la session sans arrêter le serveur, `screen -r`
la rouvre.

Pour un lancement automatique au boot (et redémarrage si crash) plutôt
qu'une session `screen` à relancer à la main après un reboot, réutilise le
template [discord-bot.service](discord-bot.service) de la section 7 :
adapte `ExecStart` à la commande `java` ci-dessus, `WorkingDirectory` au
dossier du serveur, retire les `Environment=` spécifiques à Node.js, monte
`MemoryMax` au-delà de `-Xmx` (marge hors-tas JVM), et augmente
`TimeoutStopSec` (le monde a besoin de temps pour sauvegarder à l'arrêt).

#### Ouvrir le port aux joueurs

Port par défaut : `25565/tcp` — à ajouter dans `EXTRA_LAN_TCP_PORTS` de
[ufw-setup.sh](ufw-setup.sh) (section 3), sinon le serveur tourne mais
personne ne peut s'y connecter depuis le reste du réseau.

#### Premier lancement et configuration

Le premier démarrage crée tous les dossiers/fichiers du serveur. Quelques
réglages utiles ensuite, dans la console du serveur :

```
whitelist on
whitelist add <JOUEUR>
op <ADMIN>
gamerule mobGriefing false   # les créatures ne peuvent plus modifier le terrain
gamerule doFireTick false    # le feu ne se propage plus
```

#### Plugins

Dépose le `.jar` du plugin dans le dossier `plugins/` puis relance le
serveur. Quelques commandes utiles pour le plugin WorldGuard :

```
rg flag -w world __global__ greeting-title
rg flag -w world __global__ block-break deny
rg flag -w world __global__ tnt deny
rg flag -w world __global__ other-explosion deny
```

### AdGuard Home

```bash
sudo curl -s -S -L https://raw.githubusercontent.com/AdguardTeam/AdGuardHome/master/scripts/install.sh | sh -s -- -v
```

Puis direction `http://<IP_SERVEUR>:3000/` (`ip a` pour retrouver l'IP si
besoin) → **Get Started**. Connecté via VSCode Remote-SSH (config plus
haut) : le port est auto-forwardé, `http://127.0.0.1:3000/` fonctionne
aussi directement depuis Windows.

Erreur classique sur Ubuntu : `validating ports: listen tcp 0.0.0.0:53: bind:
address already in use` (conflit avec `systemd-resolved`) :

```bash
sudo nano /etc/systemd/resolved.conf
```
```ini
DNS=127.0.0.1
FallbackDNS=1.1.1.1 1.0.0.1
DNSStubListener=no
DNSSEC=no
DNSOverTLS=no
```
```bash
sudo systemctl restart systemd-resolved
```

Actualise la page d'install, continue, puis renseigne un identifiant/mot de
passe pour l'interface. Une fois l'installation terminée, l'interface
bascule sur le port 80 (voir section 3) — accède-y ensuite via
`http://<IP_SERVEUR>/`, l'IP réelle de la machine et non plus `127.0.0.1`
(le tunnel VSCode ne vaut que pour l'assistant d'install sur le port 3000) ;
c'est aussi cette IP à utiliser comme DNS sur le reste du réseau.

Pense à désactiver le journal des requêtes et les statistiques (**Settings**
→ **General Settings** → décoche *Enable log* et *Enable statistics* →
**Save** — voir [section 4](#4-durcissement--préservation-emmc)) si tu veux
préserver l'eMMC : ce n'est pas fait par défaut.

Contrôle du service — AdGuard gère lui-même l'enregistrement de son service systemd via son propre binaire (pas besoin du template `discord-bot.service` habituel) :

```bash
sudo /opt/AdGuardHome/AdGuardHome -s start|stop|restart|status|install|uninstall
```

Si `/etc/hosts` se retrouve cassé après coup (`sudo: unable to resolve
host`) :

```bash
sudo nano /etc/hosts
```
```
127.0.0.1 localhost
127.0.1.1 <HOSTNAME>
```

Si `ping` casse en même temps :

```bash
sudo apt reinstall iputils-ping
```

Vérifier quel DNS une machine Windows utilise réellement :

```powershell
nslookup
```

Réinstaller (ex: pour réinitialiser le mot de passe admin) :

```bash
sudo curl -s -S -L https://raw.githubusercontent.com/AdguardTeam/AdGuardHome/master/scripts/install.sh | sh -s -- -r
```

### Evil Limiter (limiter/bloquer la bande passante d'un appareil sur le LAN)

⚠️ Fonctionne par ARP spoofing — n'a besoin d'aucun accès admin sur les
autres appareils pour agir sur eux. À utiliser uniquement sur un réseau que
tu administres toi-même.

Dépendances système :

```bash
sudo apt install iptables iproute2 python3-venv
```

Télécharge la dernière release (adapte `<VERSION>`) :
[github.com/bitbrute/evillimiter/releases](https://github.com/bitbrute/evillimiter/releases)

```bash
cd evillimiter-<VERSION>
```

Sur Ubuntu 24.04 (Python 3.12), `sudo python3 setup.py install` échoue en
général (`setuptools` absent + protection PEP 668
"externally-managed-environment") — installe plutôt dans un environnement
virtuel dédié :

```bash
python3 -m venv venv
source venv/bin/activate
pip install setuptools
python3 setup.py install
sudo venv/bin/evillimiter   # sudo nécessaire pour l'accès réseau bas niveau
```

Commandes utiles une fois lancé :

```
scan
hosts
quit
```

Exemples de limitation :

```
block 0                      # bloque la connexion de la première adresse listée
block all                    # bloque tout le monde
free all                     # libère tout
limit 0,1 100kbit --download # limite le débit descendant des deux premières adresses
```

`--upload`/`--download` ciblent respectivement l'un ou l'autre sens ; sans
préciser, la limite s'applique aux deux.

```
monitor   # visualise les connexions actuellement limitées/bloquées
```

### Fastfetch (infos système)

```bash
sudo add-apt-repository ppa:zhangsongcui3371/fastfetch
sudo apt update
sudo apt install fastfetch
```

Générer un fichier de config (personnalisable ensuite) :

```bash
fastfetch --gen-config
```

---

## 7. Déployer un service systemd

Template complet : [discord-bot.service](discord-bot.service) — remplace
`<NOM_BOT>`/`<UTILISATEUR>`, renomme en `<nom-bot>.service` (le nom du
fichier = le nom du service dans `systemctl`, au choix).

Deux façons d'obtenir le fichier au bon endroit, au choix :
- copier le template du repo puis l'éditer sur place :
  ```bash
  sudo cp discord-bot.service /etc/systemd/system/<nom-bot>.service
  sudo nano /etc/systemd/system/<nom-bot>.service
  ```
- ou directement créer/coller le contenu à la main dans le bon chemin, sans
  passer par le repo :
  ```bash
  sudo nano /etc/systemd/system/<nom-bot>.service
  ```

Avant de l'activer, vérifie que le fichier est syntaxiquement valide (utile
après une modification à la main, évite de découvrir une faute de frappe
seulement au démarrage) :

```bash
systemd-analyze verify /etc/systemd/system/<nom-bot>.service
```

```bash
sudo systemctl daemon-reload
sudo systemctl enable --now <nom-bot>.service
```

### Lister les services

```bash
systemctl --type=service                 # tous les services connus
systemctl --type=service --state=running # seulement ceux actifs
```

### Contrôler un service

```bash
sudo systemctl start <nom-bot>.service   # démarre maintenant
sudo systemctl stop <nom-bot>.service    # arrête maintenant
sudo systemctl restart <nom-bot>.service # redémarre
systemctl status <nom-bot>.service       # état + dernières lignes de log
sudo systemctl enable <nom-bot>.service  # démarre automatiquement au boot
sudo systemctl disable <nom-bot>.service # ne démarre plus au boot (sans l'arrêter maintenant)
journalctl -u <nom-bot>.service -f       # logs en direct
```

### Supprimer un service

```bash
sudo systemctl stop <nom-bot>.service    # arrête-le d'abord
sudo systemctl disable <nom-bot>.service # retire-le du démarrage automatique
sudo rm /etc/systemd/system/<nom-bot>.service
sudo rm -rf /etc/systemd/system/<nom-bot>.service.d # si un override existe (systemctl edit ou dossier .d manuel)
sudo systemctl daemon-reload             # oublie le service supprimé
sudo systemctl reset-failed              # nettoie un éventuel état "failed" resté affiché
```

Pour gérer plusieurs bots sans retaper le nom complet du service à chaque
fois, `.bashrc` (copié en [section 0](#0-installation-initiale)) contient
une fonction `bot` qui fait ça (`bot start <nom>`, `bot status`, `bot
logs`, etc.) — voir directement le fichier.

## License

Copyright (C) 2026 Nyaldee. Distribué sous licence [GNU General Public License v3.0](LICENSE) — voir le fichier `LICENSE` pour le texte complet.
