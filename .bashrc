# =============================================================================
# Prompt coloré (segments utilisateur/hôte/dossier avec séparateurs triangle)
# Recharger après modif : . ~/.bashrc
# =============================================================================

# Raccourcit le chemin affiché : garde les 25 derniers caractères, jamais le
# nom du dossier courant tronqué en plein milieu, ~ à la place de $HOME.
__short_pwd() {
  local max=25 base=${PWD##*/}
  (( max < ${#base} )) && max=${#base}
  PWD_SHORT=${PWD/#$HOME/\~}
  local offset=$(( ${#PWD_SHORT} - max ))
  if (( offset > 0 )); then
    PWD_SHORT=${PWD_SHORT:offset:max}
    PWD_SHORT="../${PWD_SHORT#*/}"
  fi
}
PROMPT_COMMAND=__short_pwd

# Titre de la fenêtre/onglet du terminal (utilisateur:dossier), seulement
# si le terminal le supporte.
case $TERM in
  xterm*|rxvt*) TITLE='\[\033]0;\u:${PWD_SHORT}\007\]' ;;
  *)            TITLE='' ;;
esac

# Palette nommée (RGB "R;G;B", couleurs vraies 24-bit) — puisée dans les
# couleurs de marque des emojis plats. Sert à choisir les couleurs ci-dessous
# par leur nom plutôt qu'en RGB brut.
COLOR_BLACK='49;55;61'      # #31373D
COLOR_GRAY='153;170;181'    # #99AAB5
COLOR_BLUE='85;172;238'     # #55ACEE
COLOR_BROWN='193;105;79'    # #C1694F
COLOR_GREEN='120;177;89'    # #78B159
COLOR_ORANGE='244;144;12'   # #F4900C
COLOR_PINK='244;171;186'    # #F4ABBA
COLOR_PURPLE='170;142;214'  # #AA8ED6
COLOR_RED='221;46;68'       # #DD2E44
COLOR_WHITE='230;231;232'   # #E6E7E8
COLOR_YELLOW='253;203;88'   # #FDCB58

# Fond des 3 segments (thème fixe, orange)
BG1=$COLOR_ORANGE   # <- change la couleur du thème ici (une valeur parmi COLOR_* ci-dessus)
BG2=$COLOR_BLACK
BG3=$COLOR_WHITE
FG3=$COLOR_BLACK   # texte du 3e segment (foncé pour rester lisible sur fond clair)
INPUT_RGB=$BG1     # texte tapé = couleur du 1er segment, change automatiquement avec le thème

TRIANGLE=$''
SEG_USER="\[\033[1;38;2;${COLOR_WHITE}m\033[48;2;${BG1}m\]"
SEG_HOST="\[\033[1;38;2;${COLOR_WHITE}m\033[48;2;${BG2}m\]"
SEG_PWD="\[\033[1;38;2;${FG3}m\033[48;2;${BG3}m\]"
SEP_USER_HOST="\[\033[38;2;${BG1}m\033[48;2;${BG2}m\]"
SEP_HOST_PWD="\[\033[38;2;${BG2}m\033[48;2;${BG3}m\]"
SEP_PWD_END="\[\033[38;2;${BG3}m\033[49m\]"
INPUT="\[\033[1;38;2;${INPUT_RGB}m\]"

# Pas de reset couleur ici après ${INPUT} : on veut que la couleur reste active
# pendant que tu tapes. Le trap DEBUG plus bas s'occupe de nettoyer juste avant
# l'exécution de la commande, pour ne pas teinter sa sortie.
PS1="${TITLE}\n${SEG_USER} \u ${SEP_USER_HOST}${TRIANGLE}${SEG_HOST} \h ${SEP_HOST_PWD}${TRIANGLE}${SEG_PWD} \${PWD_SHORT} ${SEP_PWD_END}${TRIANGLE}${INPUT} "

# Réinitialise la couleur avant chaque commande (évite que le prompt déteigne sur la sortie)
trap 'printf "\033[0m"' DEBUG


# =============================================================================
# Gestion des bots (voir discord-bot.service, README.md section 7)
# =============================================================================

bot() {
  local bots=('<nom-bot1>' '<nom-bot2>' '<nom-bot3>')   # <- remplace par tes vrais noms de service (garde les guillemets, < et > cassent bash sinon)
  local svc_list=("${bots[@]/%/.service}")

  local journal_args=()
  for svc in "${svc_list[@]}"; do journal_args+=(-u "$svc"); done

  local usage="Usage :
  bot {flush|status|reload|start|stop|logs}
    reload : bot reload all | bot reload <botname>
    start  : bot start <botname>
    stop   : bot stop <botname>
    logs   : bot logs"

  case "$1" in
    flush)
      echo "🌀 Rotation et purge des journaux..."
      sudo journalctl --rotate && sudo journalctl --vacuum-time=1s
      echo "✔ Journaux nettoyés. Suivi en direct des logs..."
      journalctl "${journal_args[@]}" -f --output=cat
      ;;

    status)
      for svc in "${svc_list[@]}"; do
        echo "=== $svc ==="
        # Garde le bloc d'état (à partir de "●"), sans le tail de logs
        systemctl status --no-pager --lines=0 "$svc" | sed '/^●/,$!d;/^-- Logs begin/,$d'
        echo
      done
      ;;

    reload|start|stop)
      local action=$1 botname=$2

      if [[ $action == reload && $botname == all ]]; then
        echo "🔄 Redémarrage de tous les bots..."
        sudo systemctl restart "${svc_list[@]}"
        return
      fi

      if [[ -z $botname ]]; then
        echo "Usage : bot $action <botname> | bot reload all"
        return
      fi

      if [[ " ${bots[*]} " != *" $botname "* ]]; then
        echo "⚠️ Bot inconnu : $botname"
        echo "Bots connus : ${bots[*]}"
        return
      fi

      local emoji systemctl_action=$action
      case "$action" in
        start)  emoji="▶️" ;;
        stop)   emoji="⏹️" ;;
        reload) emoji="🔄"; systemctl_action=restart ;;
      esac

      echo "${emoji} ${action^} du bot $botname..."
      sudo systemctl "$systemctl_action" "$botname.service"
      ;;

    log|logs)
      echo "👀 Suivi des logs en direct pour tous les bots..."
      journalctl "${journal_args[@]}" -f --output=cat
      ;;

    *)
      echo "$usage"
      ;;
  esac
}


# =============================================================================
# Alias pratiques
# =============================================================================

alias update='sudo apt update && sudo apt upgrade && sudo apt autoremove'
alias ll='ls -lah'
alias services='systemctl --type=service --state=running'
