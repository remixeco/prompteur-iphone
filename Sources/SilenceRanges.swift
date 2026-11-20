import Foundation

/// Découpe d'une prise en segments de voix et en segments de silence.
///
/// Cette partie ne dépend pas d'AVFoundation : elle reste testable seule,
/// en ligne de commande, comme `ScriptFollower`.
enum SilenceRanges {

    /// Un intervalle de temps, en secondes, dans la piste.
    struct Range: Equatable, Sendable {
        var start: Double
        var end: Double

        init(start: Double, end: Double) {
            self.start = start
            self.end = max(start, end)
        }

        var duration: Double { end - start }
        var isEmpty: Bool { duration <= 0 }
    }

    /// Une fenêtre d'analyse : un morceau de la piste, son niveau et son verdict.
    struct Window: Equatable, Sendable {
        var start: Double
        var end: Double
        var decibels: Double
        var isLoud: Bool
    }

    struct Settings: Equatable, Sendable {
        /// Coupe automatique activée ou non.
        var isEnabled: Bool = false
        /// Niveau en dessous duquel la voix est considérée comme absente.
        var thresholdDB: Double = -34
        /// Durée minimale d'un blanc pour qu'il soit coupé.
        var minimumSilence: Double = 0.45
        /// Marge conservée autour de la voix, pour que les coupes ne claquent pas.
        var padding: Double = 0.12

        static let `default` = Settings()
    }

    /// Le découpage retenu : ce que l'on garde, ce que l'on coupe.
    struct Plan: Equatable, Sendable {
        var kept: [Range]
        var removed: [Range]
        var removedDuration: Double

        var removesAnything: Bool { removedDuration > 0 }
    }

    /// Regroupe les fenêtres silencieuses et ne retient que les blancs assez longs.
    static func silences(in windows: [Window], settings: Settings) -> [Range] {
        var runs: [Range] = []
        var current: Range?

        for window in windows {
            if window.isLoud {
                if let open = current {
                    runs.append(open)
                    current = nil
                }
            } else if let open = current {
                current = Range(start: open.start, end: window.end)
            } else {
                current = Range(start: window.start, end: window.end)
            }
        }
        if let open = current {
            runs.append(open)
        }

        return runs.filter { $0.duration >= settings.minimumSilence }
    }

    /// Construit le découpage final à partir des blancs repérés.
    ///
    /// Les segments de voix sont élargis de la marge, puis les blancs sont
    /// recalculés sur ce qui reste réellement coupé.
    static func plan(duration: Double, silences: [Range], padding: Double) -> Plan {
        guard duration > 0 else { return Plan(kept: [], removed: [], removedDuration: 0) }

        var speech: [Range] = []
        var cursor = 0.0
        for silence in silences where silence.duration > 0 {
            if silence.start > cursor {
                speech.append(Range(start: cursor, end: silence.start))
            }
            cursor = max(cursor, silence.end)
        }
        if cursor < duration {
            speech.append(Range(start: cursor, end: duration))
        }

        var kept: [Range] = []
        for span in speech {
            let padded = Range(start: max(0, span.start - padding), end: min(duration, span.end + padding))
            if let last = kept.last, padded.start <= last.end {
                kept[kept.count - 1] = Range(start: last.start, end: max(last.end, padded.end))
            } else {
                kept.append(padded)
            }
        }

        var removed: [Range] = []
        var removedDuration = 0.0
        for silence in silences {
            for piece in subtract(silence, from: kept) {
                removed.append(piece)
                removedDuration += piece.duration
            }
        }

        return Plan(kept: kept, removed: removed, removedDuration: removedDuration)
    }

    /// Les morceaux de `range` que `kept` ne recouvre pas.
    static func subtract(_ range: Range, from kept: [Range]) -> [Range] {
        var pieces: [Range] = []
        var cursor = range.start

        for span in kept {
            guard span.end > cursor else { continue }
            guard span.start < range.end else { break }
            if span.start > cursor {
                pieces.append(Range(start: cursor, end: min(span.start, range.end)))
            }
            cursor = max(cursor, span.end)
            if cursor >= range.end { break }
        }

        if cursor < range.end {
            pieces.append(Range(start: cursor, end: range.end))
        }
        return pieces
    }
}
