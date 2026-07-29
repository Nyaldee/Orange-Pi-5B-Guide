# Notes — points ouverts

Points identifiés en cours de route, mis de côté volontairement pour l'instant.
À reprendre si le contexte change (nouveau bug, nouvelle carte réseau, etc.).

## 1. `sleep 5` dans discord-bot.service (non diagnostiqué, accepté tel quel)

`ExecStartPre=/bin/sleep 5` est un palliatif, pas une vraie dépendance
systemd. Aucun problème rencontré en pratique avec cette valeur — décision :
on le garde tel quel, pas de diagnostic plus poussé pour l'instant.

Si le problème revient un jour (erreur au démarrage du bot juste après un
reboot), deux pistes à vérifier avant de re-toucher au `sleep` :
```bash
journalctl -u <nom-du-service>.service -b -1 | grep -iE "error|ENOTFOUND|EAI_AGAIN|certificate|CERT_"
```
- `ENOTFOUND` / `EAI_AGAIN` → race avec AdGuard Home (DNS pas encore prêt) →
  remplacer par `After=AdGuardHome.service` (nom exact à vérifier avec
  `systemctl list-units | grep -i adguard`)
- erreur `certificate`/TLS → horloge pas encore synchronisée (pas de RTC) →
  remplacer par `After=time-sync.target`
