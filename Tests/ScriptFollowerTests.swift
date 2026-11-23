@main
struct ScriptFollowerTests {
    static func main() {
        followsRevisedFrenchTranscripts()
        skipsOnlyWithNearbyEvidence()
        resumesFromManualPosition()
        keepsSentencesWhole()
        print("ScriptFollower: tous les tests passent.")
    }

    private static func keepsSentencesWhole() {
        let short = ScriptFollower.displayChunks("Bonjour. Je viens te montrer une idée.")
        precondition(short.count == 1, "Deux phrases courtes doivent tenir sur la même ligne.")

        let long = "Une phrase beaucoup trop longue pour tenir sur une seule ligne de lecture, afin de vérifier que le découpage se fait entre deux mots."
        let pieces = ScriptFollower.displayChunks(long, maxWords: 8)
        precondition(pieces.count > 1, "Une phrase trop longue doit être coupée.")
        precondition(pieces.joined() == long, "Le texte doit rester identique après le découpage.")
        precondition(pieces.allSatisfy { $0.split(whereSeparator: \.isWhitespace).count <= 8 },
                     "Chaque morceau doit rester court.")
    }

    private static func followsRevisedFrenchTranscripts() {
        var follower = ScriptFollower("Écoute, j’aime l’été et mon cœur.\nOn continue.")
        follower.update("ECOUTE j'aime", isFinal: false)
        precondition(follower.position == 3, "Les accents et apostrophes ne doivent pas bloquer le suivi.")
        precondition(follower.lines[0].split(at: 3).read == "Écoute, j’aime ")

        follower.update("écoute jo", isFinal: false)
        follower.update("", isFinal: false)
        precondition(follower.position == 3, "Une révision plus courte ou une pause ne déplace pas le texte.")

        follower.update("écoute j’aime l’ete et mon coeur", isFinal: true)
        precondition(follower.position == 8 && follower.activeLine == 1)
        follower.update("on continue", isFinal: true)
        precondition(follower.isFinished && follower.position == follower.wordCount)
    }

    private static func skipsOnlyWithNearbyEvidence() {
        var follower = ScriptFollower("Bonjour je vous présente le nouveau projet demain.")
        follower.update("bonjour", isFinal: true)
        follower.update("euh nouveau", isFinal: true)
        precondition(follower.position == 1, "Un mot isolé ne suffit pas pour sauter une partie du script.")
        follower.update("projet demain", isFinal: true)
        precondition(follower.isFinished, "Deux mots consécutifs permettent de reprendre après un petit saut.")

        var distant = ScriptFollower("Bonjour ce matin les équipes vont préparer plusieurs petits projets. Bonne soirée.")
        distant.update("bonne soirée", isFinal: true)
        precondition(distant.position == 0, "Des mots trop éloignés ne doivent pas déplacer le texte.")
    }

    private static func resumesFromManualPosition() {
        var follower = ScriptFollower("Une phrase reste ici.\nUne phrase reprend ensuite.")
        follower.update("une phrase", isFinal: false)
        follower.update("une phrase", isFinal: false)
        precondition(follower.position == 2, "Une répétition de la même transcription ne compte qu’une fois.")

        follower.seek(toLine: 1)
        follower.update("une phrase", isFinal: false)
        precondition(follower.position == 4 && follower.activeLine == 1, "Une transcription antérieure au saut doit être ignorée.")
        follower.update("une phrase une phrase reprend", isFinal: false)
        precondition(follower.position == 7)

        follower.reset()
        follower.update("une phrase une phrase reprend", isFinal: true)
        precondition(follower.position == 0 && follower.activeLine == 0)
        follower.beginListening()
        follower.update("une phrase", isFinal: true)
        precondition(follower.position == 2)
    }
}
