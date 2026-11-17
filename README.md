# Prompteur

App iPhone en français pour se filmer avec la caméra avant. Le texte apparaît près de l’objectif et avance à mesure que l’app reconnaît les mots du script. Les flèches permettent de changer de passage à la main et le bouton en haut à droite revient au début. Le texte apparaît sur l’écran pendant le tournage. La vidéo contient l’image de la caméra et le son du micro.

## Installer sur un iPhone

1. Ouvre « Prompteur.xcodeproj » dans Xcode 26 ou ultérieur.
2. Dans **Signing & Capabilities**, choisis ton équipe Apple sous **Team**.
3. Sélectionne ton iPhone sous iOS 26 ou ultérieur, puis clique sur **Run** (⌘R). Garde l’iPhone déverrouillé pendant cette étape.

## Tourner une vidéo

1. Remplace le script d’exemple par ton texte et touche **Ouvrir la caméra**.
2. Autorise la caméra et le micro. Attends le statut **À l’écoute** avant de lire. Au premier lancement, iOS peut demander du temps et une connexion pour télécharger le modèle de reconnaissance du français. La reconnaissance s’exécute ensuite sur l’iPhone.
3. Touche **Filmer** et lis le texte. Si tu fais une pause, le texte t’attend. Si tu sautes un passage, tu peux te recaler avec les flèches.
4. Touche **Arrêter** puis ouvre **Dernière prise** pour regarder la vidéo, la partager ou l’ajouter à Photos. Les prises sont aussi accessibles dans **Fichiers → Sur mon iPhone → Prompteur → Prises**.

## Vérifier le suivi du script

Depuis ce dossier :

```sh
swiftc -swift-version 6 Sources/ScriptFollower.swift Tests/ScriptFollowerTests.swift -o /tmp/prompteur-script-tests
/tmp/prompteur-script-tests
```

Le simulateur permet de vérifier l’éditeur et les commandes manuelles. Pour vérifier le suivi vocal avec la caméra, tourne une prise sur un iPhone, avec une pause et un changement volontaire de débit, puis lis le fichier enregistré.
