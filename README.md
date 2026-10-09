# rpimount

Petit outil graphique Windows (PowerShell + WinForms, un script et des fichiers de langue dans `lang/`) pour inspecter et modifier la partition rootfs (ext4) d'une carte SD de Raspberry Pi, via WSL2 et usbipd-win.

## Prérequis

- Windows 11 avec WSL2 et une distribution Debian (nom configurable dans `$script:Distro`, `Debian` par défaut).
- [usbipd-win](https://github.com/dorssel/usbipd-win) installé.
- Un lecteur de cartes USB. `wsl --mount` ne fonctionne pas avec un lecteur déclaré amovible, d'où le passage par usbipd.

## Lancement

```powershell
powershell -ExecutionPolicy Bypass -File .\rpimount.ps1
```

Le script se relance tout seul en administrateur (invite UAC). La console PowerShell est masquée quand elle a été créée pour le script (une console d'où tu le lances toi-même n'est jamais masquée).

## Utilisation

1. **Actualiser** : liste les périphériques USB de stockage de masse vus par `usbipd` (état *Not shared* / *Shared* / *Attached*). Les partitions ext4 apparaissent une fois la carte attachée.
2. **Connect** : bind si besoin, démarrage de WSL, attach, chargement de `usb_storage` et `uas`, montage dans `/mnt/<label>`, puis terminal WSL dans ce répertoire.
3. **Connect + chroot** : comme Connect, puis préparation et ouverture d'un shell root en chroot (voir ci-dessous).
4. **Disconnect** : défait le chroot, `umount -R`, `sync`, `usbipd detach`. Si la cible est occupée (*target is busy*), le journal liste les processus en cause et la carte reste attachée : ferme le terminal et recommence.

5. **Vérifier (e2fsck)** : attache la carte sans la monter, puis lance `e2fsck -f -n` (lecture seule, rien n'est modifié) et affiche le résultat dans le journal. Si des anomalies sont détectées, une confirmation (« Non » par défaut) propose d'ouvrir un terminal de réparation interactive (`e2fsck -f`, sans `-y` : chaque correction est demandée). Une partition montée est refusée : fais Disconnect d'abord. À la fin, la carte reste attachée ; attends la fin de la réparation avant de cliquer sur Disconnect, qui la rend à Windows.

## Distribution WSL

Le menu **Distribution WSL** liste les distributions WSL2 installées (les distributions internes de Docker Desktop sont ignorées) ; la liste est relue à chaque ouverture du menu. Le choix est mémorisé. Au premier lancement, ou si la distribution mémorisée n'existe plus, la distribution par défaut de WSL est prise. Les noms de distribution contenant des espaces ne sont pas pris en charge.

## Chroot

- L'architecture du rootfs (aarch64, arm) est lue dans l'en-tête ELF de `/usr/bin/bash`.
- Si elle diffère de l'hôte (x86_64), `qemu-user-static` et `binfmt-support` sont installés dans WSL s'ils manquent (apt), et `qemu-<arch>-static` est copié dans le rootfs.
- Le `resolv.conf` du rootfs est mis de côté et remplacé par celui de WSL pour avoir le réseau.
- `/proc`, `/sys` et `/dev` (dont `/dev/pts`) sont montés.
- Le shell est lancé avec `LC_ALL=C.UTF-8` pour éviter les avertissements de locale.
- Si `/root/.bashrc` n'existe pas dans le rootfs, il est copié depuis le `/root/.bashrc` de la distribution WSL (root n'a pas de profil par défaut sur Raspberry Pi OS). Un fichier existant n'est écrasé que si la case « Écraser /root/.bashrc en chroot » est cochée (décochée par défaut). Cette copie est **conservée** après Disconnect.

- Si la case « Copier un script dans /root en chroot » est cochée, le fichier choisi est copié dans `/root` du rootfs (fins de ligne CRLF converties en LF, droits 755). Un fichier du même nom est écrasé. Cette copie est aussi **conservée** après Disconnect.

Au Disconnect, tout le reste est défait dans l'ordre inverse : bind-mounts, `resolv.conf` d'origine, binaire qemu (seulement s'il a été copié par l'outil), puis démontage du rootfs. L'état est gardé dans `/run/rpimount/` côté WSL.

## Réglages mémorisés

Enregistrés dans `%APPDATA%\rpimount\settings.json` et rechargés à chaque lancement : case d'écrasement du `.bashrc`, case de transfert de script, chemin du script, langue, distribution WSL.

## Langue

Menu **Langue** : *Automatique* (langue d'affichage de Windows, anglais si elle n'est pas disponible) ou l'une des langues trouvées dans `lang/`. Livré : français (`fr.json`) et anglais (`en.json`, langue de repli).

Pour ajouter une langue : copier `lang/en.json` en `lang/<code>.json` (par exemple `de.json`), traduire les valeurs (pas les clés), et renseigner `language.name` (nom affiché dans le menu). Une clé manquante retombe sur l'anglais.

## Script de test

`test/test-tree.sh` installe `tree` s'il manque puis affiche les permissions, le propriétaire et le groupe d'un répertoire (`/home` par défaut). Il sert à tester le transfert de script : coche « Copier un script dans /root en chroot », choisis ce fichier, puis lance `/root/test-tree.sh` dans le chroot.

## Licence

BSD 3-Clause, voir [LICENSE](LICENSE).

## Limites et précautions

- Seuls les disques USB (`TRAN=usb`) vus par WSL sont considérés ; les disques internes (NVMe) ne sont jamais touchés.
- Aucune opération destructive : pas de `mkfs`, pas de `fsck` automatique.
- Disconnect démonte toutes les partitions ext4 USB vues par WSL, pas seulement celle de la ligne sélectionnée.
- Le terminal s'ouvre avec les droits administrateur (le script est élevé).
- Console masquée : une erreur fatale du script s'affiche dans une boîte de dialogue. Si Windows Terminal est le terminal par défaut de Windows 11, la fenêtre console peut encore apparaître brièvement au lancement.
- Un lecteur fraîchement détaché peut mettre un instant à réapparaître : cliquer sur Actualiser.
