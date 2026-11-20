@main
struct SilenceRangesTests {
    static func main() {
        detectsLongSilencesOnly()
        keepsPaddingAroundSpeech()
        removesOnlyTheSilentPart()
        ignoresSilenceShorterThanTheMinimum()
        handlesSilenceAtBothEnds()
        keepsEverythingWhenThereIsNoSilence()
        print("SilenceRanges: tous les tests passent.")
    }

    /// Une fenêtre = un morceau de piste, avec son niveau et son verdict.
    private static func window(_ start: Double, _ end: Double, _ decibels: Double) -> SilenceRanges.Window {
        SilenceRanges.Window(start: start, end: end, decibels: decibels, isLoud: decibels >= -34)
    }

    private static func detectsLongSilencesOnly() {
        var settings = SilenceRanges.Settings()
        settings.minimumSilence = 0.5

        let windows = [
            window(0, 1, -12),      // voix
            window(1, 1.2, -60),    // blanc court : conservé
            window(1.2, 2.2, -12),  // voix
            window(2.2, 3.2, -60),  // blanc long : coupé
            window(3.2, 4, -12)     // voix
        ]

        let silences = SilenceRanges.silences(in: windows, settings: settings)
        precondition(silences.count == 1, "Seul le blanc d'une seconde doit être coupé.")
        precondition(silences[0].start == 2.2 && silences[0].end == 3.2)
    }

    private static func keepsPaddingAroundSpeech() {
        var settings = SilenceRanges.Settings()
        settings.minimumSilence = 0.5
        settings.padding = 0.1

        let windows = [
            window(0, 1, -12),
            window(1, 3, -60),
            window(3, 4, -12)
        ]

        let silences = SilenceRanges.silences(in: windows, settings: settings)
        let plan = SilenceRanges.plan(duration: 4, silences: silences, padding: settings.padding)

        precondition(plan.kept.count == 2)
        precondition(abs(plan.kept[0].end - 1.1) < 0.0001, "La marge doit garder 0,1 s de blanc avant la parole.")
        precondition(abs(plan.kept[1].start - 2.9) < 0.0001, "La marge doit garder 0,1 s de blanc après la parole.")
    }

    private static func removesOnlyTheSilentPart() {
        var settings = SilenceRanges.Settings()
        settings.minimumSilence = 0.5
        settings.padding = 0.1

        let windows = [
            window(0, 1, -12),
            window(1, 3, -60),
            window(3, 4, -12)
        ]

        let silences = SilenceRanges.silences(in: windows, settings: settings)
        let plan = SilenceRanges.plan(duration: 4, silences: silences, padding: settings.padding)

        // 2 s de blanc, dont 0,2 s gardés par la marge : 1,8 s réellement coupés.
        precondition(abs(plan.removedDuration - 1.8) < 0.0001, "Seul le blanc hors marge doit être compté.")
        precondition(plan.removed.count == 1)
        precondition(abs(plan.removed[0].start - 1.1) < 0.0001)
        precondition(abs(plan.removed[0].end - 2.9) < 0.0001)
    }

    private static func ignoresSilenceShorterThanTheMinimum() {
        var settings = SilenceRanges.Settings()
        settings.minimumSilence = 2.0

        let windows = [
            window(0, 1, -12),
            window(1, 2, -60),   // 1 s : trop court
            window(2, 3, -12)
        ]

        let silences = SilenceRanges.silences(in: windows, settings: settings)
        precondition(silences.isEmpty, "Un blanc plus court que la durée minimale doit être conservé.")
    }

    private static func handlesSilenceAtBothEnds() {
        var settings = SilenceRanges.Settings()
        settings.minimumSilence = 0.5
        settings.padding = 0.1

        let windows = [
            window(0, 1, -60),   // blanc de tête
            window(1, 3, -12),   // voix
            window(3, 4, -60)    // blanc de queue
        ]

        let silences = SilenceRanges.silences(in: windows, settings: settings)
        precondition(silences.count == 2, "Les blancs de tête et de queue doivent être repérés.")
        precondition(abs(silences[0].start) < 0.0001 && abs(silences[1].end - 4) < 0.0001)

        let plan = SilenceRanges.plan(duration: 4, silences: silences, padding: settings.padding)
        precondition(plan.kept.count == 1, "La voix et ses marges forment un seul segment.")
        precondition(abs(plan.kept[0].start - 0.9) < 0.0001)
        precondition(abs(plan.kept[0].end - 3.1) < 0.0001)
        precondition(abs(plan.removedDuration - 1.8) < 0.0001)
    }

    private static func keepsEverythingWhenThereIsNoSilence() {
        var settings = SilenceRanges.Settings()
        settings.minimumSilence = 0.5

        let windows = [
            window(0, 1, -12),
            window(1, 2, -10),
            window(2, 3, -14)
        ]

        let silences = SilenceRanges.silences(in: windows, settings: settings)
        precondition(silences.isEmpty)

        let plan = SilenceRanges.plan(duration: 3, silences: silences, padding: settings.padding)
        precondition(plan.removedDuration == 0)
        precondition(plan.kept.count == 1)
        precondition(abs(plan.kept[0].duration - 3) < 0.0001)
    }
}
