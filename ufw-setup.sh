#!/usr/bin/env bash
# =============================================================================
# ufw-setup.sh
# Configuration ufw reproductible — Ubuntu Server (ARM64), Orange Pi 5B / RK3588(S)
# Cible : "serveur maison toujours allumé" (AdGuard Home, bots Node.js, petit
# dashboard web), même usage que 99-hardening.conf (sysctl).
# =============================================================================
#
# PRINCIPE
#   Ce script est la "source de vérité" pour tes règles ufw : au lieu d'éditer
#   /etc/ufw/user.rules à la main (déconseillé, ufw gère ce fichier lui-même),
#   tu modifies la CONFIGURATION ci-dessous et tu relances le script — il
#   réinitialise ufw et réapplique tout depuis zéro, de façon reproductible.
#
# ⚠️ RISQUE DE LOCKOUT SSH
#   Si SSH_PORT ou LAN_CIDR est mal renseigné, tu peux perdre l'accès distant
#   à la machine. Avant de lancer ce script :
#     - Garde une deuxième session SSH ouverte (ne ferme pas celle-ci)
#     - Ou un accès physique/série (UART) en secours
#     - Le script programme par défaut un rollback automatique via `at`
#       (voir ENABLE_SAFETY_NET ci-dessous) : sans confirmation de ta part,
#       ufw se désactive tout seul après quelques minutes
#
# UTILISATION
#   1. Place ce fichier sur ta machine (ex: dans ton $HOME) et relis-le une
#      fois avant de l'exécuter — c'est un script qui touche au firewall et
#      appelle sudo, ne l'exécute jamais en aveugle.
#   2. Modifie la section CONFIGURATION ci-dessous pour l'adapter à ton
#      réseau (LAN_CIDR, SSH_PORT, etc.).
#   3. Rends-le exécutable :
#        chmod +x ufw-setup.sh
#   4. Lance-le SANS sudo devant (le script appelle sudo lui-même sur
#      chaque commande qui en a besoin) :
#        ./ufw-setup.sh
#
#   Si tu obtiens une erreur du type "$'\r': command not found" ou
#   "bad interpreter" au lancement, le fichier a des fins de ligne Windows
#   (CRLF) — corrige avec :
#        sed -i 's/\r$//' ufw-setup.sh
#
#   Le script est rejouable : si tu modifies une variable en CONFIGURATION,
#   relance-le simplement, il réinitialise ufw et réapplique tout proprement.
#
# =============================================================================

set -euo pipefail

# =============================================================================
# CONFIGURATION — adapte ces valeurs à TON réseau avant de lancer le script
# =============================================================================

# Ton sous-réseau local. Trouve-le avec : ip -4 -o addr show scope global
# (ex: si ton IP est 192.168.1.42/24, mets "192.168.1.0/24")
LAN_CIDR="192.168.1.0/24"

# Port SSH utilisé sur cette machine (22 si tu ne l'as jamais changé).
SSH_PORT="22"

# true  = tu as besoin de te connecter en SSH depuis l'extérieur de ton LAN
#         (le port reste ouvert à Internet mais throttlé anti brute-force)
# false = SSH restreint à ton LAN uniquement (recommandé si pas de besoin
#         d'accès distant pour l'instant — reste modifiable plus tard)
SSH_ALLOW_FROM_ANYWHERE=false

# DNS (AdGuard Home ou équivalent). true = LAN uniquement (recommandé —
# un DNS ouvert à tout Internet peut être détourné en résolveur ouvert pour
# des attaques par amplification DNS contre un tiers). Ne passe à false que
# si tu as un besoin réel et assumé de résolution DNS publique.
DNS_ENABLED=true
DNS_LAN_ONLY=true

# Ports web/dashboard supplémentaires (AdGuard Home admin, bot dashboard,
# etc.) à n'exposer qu'au LAN. Laisse le tableau vide si non applicable.
EXTRA_LAN_TCP_PORTS=(80)

# true = programme une désactivation automatique d'ufw via `at` avant de
# l'activer, annulée seulement si tu confirmes explicitement que l'accès
# fonctionne encore (protège d'un lockout distant en cas d'erreur de config).
# Installe le paquet `at` automatiquement si absent. Recommandé pour tout
# déploiement à distance ; tu peux passer à false si tu configures en local
# avec écran/clavier branchés (aucun risque de lockout dans ce cas).
ENABLE_SAFETY_NET=true
SAFETY_NET_MINUTES=5

# =============================================================================
# FIN CONFIGURATION — ne pas modifier en dessous de cette ligne
# =============================================================================

echo "--- Interfaces réseau détectées sur cette machine ---"
ip -4 -o addr show scope global | awk '{print $2, $4}'
echo
echo "Configuration actuelle du script :"
echo "  LAN_CIDR                = ${LAN_CIDR}"
echo "  SSH_PORT                = ${SSH_PORT}"
echo "  SSH_ALLOW_FROM_ANYWHERE = ${SSH_ALLOW_FROM_ANYWHERE}"
echo "  DNS_ENABLED / LAN_ONLY  = ${DNS_ENABLED} / ${DNS_LAN_ONLY}"
echo "  EXTRA_LAN_TCP_PORTS     = ${EXTRA_LAN_TCP_PORTS[*]:-(aucun)}"
echo "  ENABLE_SAFETY_NET       = ${ENABLE_SAFETY_NET} (rollback auto après ${SAFETY_NET_MINUTES} min si non confirmé)"
echo
read -r -p "Ces valeurs correspondent-elles à ton réseau ET ton port SSH réel ? [o/N] " confirm
if [[ ! "${confirm}" =~ ^[oOyY]$ ]]; then
  echo "Corrige les variables en haut du script, puis relance. Aucune règle appliquée."
  exit 1
fi

SAFETY_JOB=""
if [[ "${ENABLE_SAFETY_NET}" == "true" ]]; then
  if ! command -v at >/dev/null 2>&1; then
    echo "--- Installation du paquet 'at' (requis pour le filet de sécurité) ---"
    sudo apt-get update -qq
    sudo apt-get install -y at
  fi
  sudo systemctl enable --now atd >/dev/null 2>&1 || true
fi

echo
echo "--- Réinitialisation d'ufw (état propre) ---"
sudo ufw --force reset

echo "--- Politiques par défaut ---"
sudo ufw default deny incoming
sudo ufw default allow outgoing
sudo ufw default deny routed   # pas de routage : ce host n'est pas une passerelle

echo "--- Règle SSH (appliquée AVANT le reste, jamais oubliée) ---"
if [[ "${SSH_ALLOW_FROM_ANYWHERE}" == "true" ]]; then
  sudo ufw limit "${SSH_PORT}/tcp" comment "SSH - accessible partout, throttle anti brute-force"
else
  sudo ufw limit from "${LAN_CIDR}" to any port "${SSH_PORT}" proto tcp comment "SSH - LAN uniquement, throttle anti brute-force"
fi

if [[ "${DNS_ENABLED}" == "true" ]]; then
  echo "--- Règles DNS (AdGuard Home) ---"
  if [[ "${DNS_LAN_ONLY}" == "true" ]]; then
    sudo ufw allow from "${LAN_CIDR}" to any port 53 proto tcp comment "DNS - LAN uniquement"
    sudo ufw allow from "${LAN_CIDR}" to any port 53 proto udp comment "DNS - LAN uniquement"
  else
    echo "⚠️  DNS ouvert à Internet entier — risque d'abus en amplification DNS."
    sudo ufw allow 53/tcp comment "DNS - public (assumé)"
    sudo ufw allow 53/udp comment "DNS - public (assumé)"
  fi
fi

if [[ "${#EXTRA_LAN_TCP_PORTS[@]}" -gt 0 ]]; then
  echo "--- Ports web/dashboard (LAN uniquement) ---"
  for port in "${EXTRA_LAN_TCP_PORTS[@]}"; do
    sudo ufw allow from "${LAN_CIDR}" to any port "${port}" proto tcp comment "dashboard/web - LAN uniquement"
  done
fi

echo "--- Logging (low : consigne les paquets bloqués sans noyer le journal) ---"
sudo ufw logging low

if [[ "${ENABLE_SAFETY_NET}" == "true" ]]; then
  echo "--- Programmation du filet de sécurité (rollback dans ${SAFETY_NET_MINUTES} min) ---"
  SAFETY_JOB=$(echo "ufw disable" | sudo at now + "${SAFETY_NET_MINUTES}" minutes 2>&1 | grep -oP 'job \K[0-9]+' || true)
  if [[ -z "${SAFETY_JOB}" ]]; then
    echo "⚠️  Impossible de programmer le filet de sécurité (job at non détecté)."
    echo "    Vérifie manuellement avec 'atq' si besoin, ou continue prudemment."
  fi
fi

echo "--- Activation ---"
sudo ufw --force enable

echo
echo "--- État final ---"
sudo ufw status verbose

echo
echo "Ouvre maintenant une NOUVELLE connexion SSH (sans fermer celle-ci) pour"
echo "vérifier que l'accès fonctionne toujours."

if [[ "${ENABLE_SAFETY_NET}" == "true" && -n "${SAFETY_JOB}" ]]; then
  echo
  read -r -p "L'accès fonctionne dans la nouvelle session ? Tape 'ok' pour annuler le rollback automatique : " safety_confirm
  if [[ "${safety_confirm}" == "ok" ]]; then
    sudo atrm "${SAFETY_JOB}"
    echo "Filet de sécurité annulé — configuration ufw définitive."
  else
    echo "Filet de sécurité laissé actif (job at #${SAFETY_JOB}) : ufw se désactivera"
    echo "automatiquement dans ${SAFETY_NET_MINUTES} min si tu ne relances pas ce script"
    echo "avec 'sudo atrm ${SAFETY_JOB}' entre-temps."
  fi
fi
