# Prompteur

App iPhone en français pour se filmer avec la caméra avant. Le texte apparaît près de l’objectif et avance à mesure que l’app reconnaît les mots du script. Les flèches permettent de changer de passage à la main et le bouton en haut à droite revient au début. Le texte apparaît sur l’écran pendant le tournage. La vidéo contient l’image de la caméra et le son du micro.

## Installer sur un iPhone

1. Ouvre « Prompteur.xcodeproj » dans Xcode 26 ou ultérieur.
2. Dans **Signing & Capabilities**, choisis ton équipe Apple sous **Team**.
3. Sélectionne ton iPhone sous iOS 26 ou ultérieur, puis clique sur **Run** (⌘R). Garde l’iPhone déverrouillé pendant cette étape.

## Tourner une vidéo

1. Remplace le script d’exemple par ton texte et touche **Ouvrir la caméra**. Le bouton **Tout effacer**, en haut de la carte du texte, vide tout le script d’un geste après confirmation.
2. Autorise la caméra et le micro. Attends le statut **À l’écoute** avant de lire. Au premier lancement, iOS peut demander du temps et une connexion pour télécharger le modèle de reconnaissance du français. La reconnaissance s’exécute ensuite sur l’iPhone.
3. Touche **Filmer** et lis le texte. Si tu fais une pause, le texte t’attend. Si tu sautes un passage, tu peux te recaler avec les flèches.
4. Touche **Arrêter** puis ouvre **Dernière prise** pour regarder la vidéo, la partager ou l’ajouter à Photos. Les prises sont aussi accessibles dans **Fichiers → Sur mon iPhone → Prompteur → Prises**.

## Suspendre et reprendre la prise

Le bouton **pause**, à droite du bouton d’enregistrement, suspend **le texte et l’enregistrement**. Le texte se fige, la capture s’arrête, et le bandeau jaune « En pause. Le texte attend et l’enregistrement est suspendu. » le signale. Le chronomètre se fige aussi : il ne compte que le temps réellement filmé.

Quand tu relances, le texte repart au mot près et l’enregistrement reprend **dans la même prise**. La capture est écrite par morceaux : chaque pause ferme le morceau en cours et en ouvre un autre. À la fin, les morceaux sont recollés dans l’ordre en un seul fichier, sans trou et sans coupure visible.

C’est utile quand tu dois t’interrompre — une interruption, une toux, un bruit — sans perdre la prise ni la recommencer. Comme la capture est réellement suspendue, ce moment n’existe pas dans la vidéo : il n’y a rien à couper derrière.

## Couper les blancs

L’option **Couper les blancs**, sous le script, supprime de la vidéo les silences où tu ne parles pas. Elle est désactivée par défaut.

Quand elle est active, la prise est montée à la fin du tournage : les moments trop courts pour être des blancs sont conservés, et une petite marge est gardée autour de la voix pour que les coupes ne claquent pas. La prise brute est toujours conservée à côté, sous le nom `…-brute.mov`, et la version montée sous `…-montée.mov`. La fiche de la prise affiche le temps retiré.

Les morceaux de la prise sont d’abord recollés en un fichier unique, ensuite les blancs sont retirés. Le montage ne touche jamais à l’image.

Deux réglages ajustent le comportement :

| Réglage | Effet |
|-|-|
| **Seuil de voix** | Plus la valeur est basse, plus seuls les vrais silences sont coupés. |
| **Durée minimale** | Un silence plus court que cette durée est conservé. |

Le montage part du niveau sonore de la piste audio de la prise ; il ne touche jamais à l’image.

## Vérifier le suivi du script

Depuis ce dossier :

```sh
swiftc -swift-version 6 Sources/ScriptFollower.swift Tests/ScriptFollowerTests.swift -o /tmp/prompteur-script-tests
/tmp/prompteur-script-tests
```

## Vérifier le montage des blancs

Le découpage est isolé de la capture : `SilenceRanges` ne dépend que de Foundation et se teste comme `ScriptFollower`.

```sh
swiftc -swift-version 6 Sources/SilenceRanges.swift Tests/SilenceRangesTests.swift -o /tmp/prompteur-silence-tests
/tmp/prompteur-silence-tests
```

Le simulateur permet de vérifier l’éditeur et les commandes manuelles. Pour vérifier le suivi vocal avec la caméra, tourne une prise sur un iPhone, avec une pause et un changement volontaire de débit, puis lis le fichier enregistré. Le montage des blancs se vérifie sur cette même prise : active l’option, refais une prise en laissant des silences, puis compare la durée de la version montée et de la prise brute.
