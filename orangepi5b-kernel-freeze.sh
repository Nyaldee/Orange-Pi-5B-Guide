#!/usr/bin/env bash
# =============================================================================
# orangepi5b-kernel-freeze.sh
# Gèle les paquets noyau/firmware vendor Rockchip pour éviter qu'un
# `apt upgrade` générique ne casse le démarrage.
# Orange Pi 5B / RK3588(S) — Ubuntu Server ARM64
# =============================================================================
#
# POURQUOI
#   Les images Ubuntu pour Orange Pi 5B utilisent un noyau vendor (patches
#   Rockchip pour device tree, eMMC/NVMe, GPU, etc.) qui n'est PAS dans les
#   dépôts Ubuntu officiels et n'y est plus maintenu. Si `apt upgrade` tente
#   un jour d'installer/remplacer par un noyau générique, la carte peut ne
#   plus démarrer (pilotes manquants).
#
#   Ce script détecte les paquets à geler à partir du noyau RÉELLEMENT en
#   cours d'exécution (`uname -r`), pas d'une version codée en dur — il
#   fonctionne donc quelle que soit la version exacte de ton image, et
#   reste valable pour d'autres Orange Pi 5B avec une image différente.
#
# UTILISATION
#   chmod +x orangepi5b-kernel-freeze.sh
#   ./orangepi5b-kernel-freeze.sh             # détecte, affiche, demande confirmation, gèle
#   ./orangepi5b-kernel-freeze.sh --status    # affiche l'état actuel des paquets gelés
#   ./orangepi5b-kernel-freeze.sh --unhold    # dégèle tout ce que ce script a gelé (avec confirmation)
#
# MÉTHODE MANUELLE (si tu préfères comprendre/taper toi-même plutôt que lancer un script)
#
#   1. Identifie le noyau RÉELLEMENT en cours d'exécution (pas un nom deviné) :
#        uname -r
#      Exemple : 6.1.0-1025-rockchip
#
#   2. Liste tous les paquets liés à "linux" pour repérer ceux qui contiennent
#      cette version, colonne 1 = état (ii = installé, hi = déjà gelé+installé) :
#        dpkg -l | grep -i linux
#
#   3. Note les paquets à geler. Deux catégories, les DEUX comptent :
#        a) Ceux qui contiennent la version exacte de l'étape 1, ex :
#             linux-image-6.1.0-1025-rockchip
#             linux-headers-6.1.0-1025-rockchip
#             linux-modules-6.1.0-1025-rockchip
#             linux-modules-extra-6.1.0-1025-rockchip
#             linux-rockchip-headers-6.1.0-1025
#        b) Les META-PAQUETS SANS numéro de version — faciles à oublier, mais
#           ce sont eux qui peuvent tirer une nouvelle version au prochain
#           upgrade si tu ne les gèles pas aussi :
#             linux-rockchip
#             linux-headers-rockchip
#             linux-image-rockchip     ← souvent oublié, vérifie bien qu'il y est
#             linux-firmware
#           + si présents chez toi : u-boot-*, trusted-firmware-*, rkbin-*
#
#   4. Gèle tout en une seule commande (adapte les noms à TA version) :
#        sudo apt-mark hold linux-image-6.1.0-1025-rockchip \
#          linux-headers-6.1.0-1025-rockchip linux-modules-6.1.0-1025-rockchip \
#          linux-modules-extra-6.1.0-1025-rockchip linux-rockchip-headers-6.1.0-1025 \
#          linux-rockchip linux-headers-rockchip linux-image-rockchip linux-firmware
#
#   5. Vérifie que tout y est (compare avec ta liste de l'étape 3) :
#        apt-mark showhold
#
#   6. Pour dégeler un paquet précis (ex: avant une mise à jour ciblée du noyau) :
#        sudo apt-mark unhold <nom-du-paquet>
#      Ou tout dégeler d'un coup :
#        sudo apt-mark unhold $(apt-mark showhold)
#
# METTRE À JOUR LE RESTE DU SYSTÈME SANS TOUCHER AU NOYAU
#   sudo apt update && sudo apt upgrade
#   sudo apt autoremove --dry-run   # ⚠️ TOUJOURS en simulation d'abord (voir note plus bas)
#   sudo apt autoremove             # seulement si aucun paquet noyau/firmware dans la simulation
#
# ⚠️ CE GEL N'EST PAS "À VIE" : il bloque aussi les correctifs de sécurité du
#   noyau. Revérifie tous les 3-6 mois si une image/noyau Rockchip plus
#   récent existe pour ta carte, puis dégèle → upgrade ciblé → regèle,
#   plutôt que d'ignorer indéfiniment.
#
# ⚠️ HISTORIQUEMENT, certaines versions d'apt ont proposé de supprimer un
#   paquet gelé devenu "orphelin" lors d'un autoremove. `apt-mark hold`
#   protège contre l'upgrade, pas nécessairement contre l'autoremove — d'où
#   le --dry-run recommandé ci-dessus avant chaque autoremove réel.
#
# =============================================================================

set -euo pipefail

KERNEL_VERSION="$(uname -r)"   # ex: 6.1.0-1025-rockchip — sert de clé de détection

# Paquets liés au noyau EXACTEMENT en cours d'exécution (image, modules, headers)
detect_kernel_packages() {
  dpkg -l | awk '$1 ~ /^.i$/ {print $2}' | grep -F -- "${KERNEL_VERSION}" || true
}

# Meta-paquets et firmware vendor, indépendants du numéro de version exact
detect_meta_packages() {
  dpkg -l | awk '$1 ~ /^.i$/ {print $2}' \
    | grep -E '^(linux-rockchip.*|linux-headers-rockchip.*|linux-image-rockchip.*|linux-firmware|u-boot.*|trusted-firmware.*|rkbin.*)$' \
    || true
}

case "${1:-}" in
  --status)
    echo "Paquets actuellement gelés :"
    apt-mark showhold
    exit 0
    ;;
  --unhold)
    HELD="$(apt-mark showhold)"
    if [[ -z "${HELD}" ]]; then
      echo "Aucun paquet gelé."
      exit 0
    fi
    echo "Paquets actuellement gelés :"
    echo "${HELD}"
    echo
    read -r -p "Tout dégeler ? [o/N] " confirm
    if [[ "${confirm}" =~ ^[oOyY]$ ]]; then
      # shellcheck disable=SC2086
      sudo apt-mark unhold ${HELD}
      echo "Dégelé. Un 'sudo apt update && sudo apt upgrade' peut maintenant proposer une mise à jour noyau."
    else
      echo "Annulé."
    fi
    exit 0
    ;;
esac

echo "Noyau actuellement en cours d'exécution : ${KERNEL_VERSION}"
echo
echo "--- Paquets détectés (rappel brut, pour vérification visuelle) ---"
dpkg -l | grep -i linux || true
echo

mapfile -t PACKAGES < <( { detect_kernel_packages; detect_meta_packages; } | sort -u)

if [[ "${#PACKAGES[@]}" -eq 0 ]]; then
  echo "Aucun paquet correspondant détecté automatiquement."
  echo "Vérifie manuellement le nom exact avec la commande ci-dessus et gèle à la main :"
  echo "  sudo apt-mark hold <nom-du-paquet>"
  exit 1
fi

echo "--- Paquets qui seraient gelés (apt-mark hold) ---"
printf '  %s\n' "${PACKAGES[@]}"
echo
read -r -p "Confirmer le gel de ces ${#PACKAGES[@]} paquets ? [o/N] " confirm
if [[ ! "${confirm}" =~ ^[oOyY]$ ]]; then
  echo "Annulé, aucun paquet gelé."
  exit 1
fi

sudo apt-mark hold "${PACKAGES[@]}"

echo
echo "--- État après gel ---"
apt-mark showhold
