import DokumentumCore
import DokumentumKit
import Foundation

/// The texts of the rule sheet and the "Matching" settings (#10, part 2; maintainer's P3 and P4, plan review B2).
enum MatchingRuleText {
    /// The sidebar rows' context menu item and accessibility action.
    static let edit: LocalizedStringResource = "Edit Matching…"
    /// The mode picker's label.
    static let match: LocalizedStringResource = "Match"
    /// The pattern field's label.
    static let pattern: LocalizedStringResource = "Pattern"

    /// The five modes' names (P4), and a newer build's mode.
    static func name(_ mode: MatchMode) -> LocalizedStringResource {
        switch mode {
        case .none: "None"
        case .any: "Any word"
        case .all: "All words"
        case .exact: "Exact phrase"
        case .regex: "Regular expression"
        case .unknown: "Set by a newer version of Dokumentum"
        }
    }

    /// One line per mode: what it matches (P4; B2: a regular expression ignores case only).
    static func explanation(_ mode: MatchMode) -> LocalizedStringResource {
        switch mode {
        case .none:
            "No rule: nothing is assigned from a document's text."
        case .any:
            "Matches when the text contains one of the words. Whole words only; case and accents are ignored, and ä matches ae. Put a phrase in quotes."
        case .all:
            "Matches when the text contains all of the words, in any order. Whole words only; case and accents are ignored, and ä matches ae. Put a phrase in quotes."
        case .exact:
            "Matches when the text contains these words in this order. Whole words only; case and accents are ignored, and ä matches ae."
        case .regex:
            "Matches when the regular expression is found in the text. Only case is ignored: accents and ae, oe, ue count as written, so write M(ü|ue)ller to find both."
        case .unknown:
            "A newer version of Dokumentum set this rule. It is kept unless you choose another match."
        }
    }

    /// The line under the field for a problem of `MatchingRuleValidation` (T8, review B of #205, N1).
    static func problem(_ problem: MatchingRuleValidation.Problem) -> LocalizedStringResource {
        switch problem {
        case .tooLong: "The pattern can have at most \(MatchingLimits.patternLength) characters."
        case .invalidRegularExpression: "This regular expression is not valid."
        case .tooSlow: "This regular expression takes too long to check."
        case .backReference: "Back-references such as \\1 or \\k<name> are not supported."
        }
    }

    /// The line under the field when the save failed and was rolled back.
    static let notSaved: LocalizedStringResource = "The rule could not be saved."

    /// A record with copies sharing its `instanceID`: matching never applies its rule (review A of #205, N6).
    static func copies(_ name: String) -> LocalizedStringResource {
        "This rule is not applied: “\(name)” exists twice in the archive."
    }

    /// The record is gone or was merged away while the sheet was open.
    static let gone: LocalizedStringResource = "This item no longer exists."

    // MARK: Settings

    static let section: LocalizedStringResource = "Matching"
    static let apply: LocalizedStringResource = "Apply Matching Rules to All Documents…"
    /// What the section does, below it.
    static let about: LocalizedStringResource =
        "Rules assign tags, correspondents and document types from a document's text. New documents get them after text recognition; this applies them to the documents you already have."

    /// The confirmation (P3; plan review N5 c).
    static let confirmTitle: LocalizedStringResource = "Apply matching rules to all documents?"
    static let confirmMessage: LocalizedStringResource =
        "Empty correspondents and document types are filled in, and matching tags are added, also tags you removed by hand. A correspondent or document type is never replaced, also not one that Apple Intelligence or detection filled in. When several correspondents or document types match a document, that field stays empty. Documents in the trash are not changed."
    static let confirm: LocalizedStringResource = "Apply"

    static func progress(_ progress: MatchingRun.Progress?) -> LocalizedStringResource {
        guard let progress else { return "Applying rules…" }
        return "Applying rules… \(progress.done) of \(progress.total)"
    }

    /// The result line's sentences, from the run's report.
    static func result(_ report: MatchingRun.Report) -> [LocalizedStringResource] {
        var lines: [LocalizedStringResource] = []
        if report.failed {
            lines.append("The rules could not be applied to every document.")
        } else if report.cancelled {
            lines.append("Stopped before every document was checked.")
        }
        lines.append(report.changed == 0 ? "No document was changed." : "\(report.changed) documents changed.")
        if report.ambiguous > 0 {
            lines.append(
                "\(report.ambiguous) documents matched several correspondents or document types; that field stays empty."
            )
        }
        if report.skipped > 0 {
            lines.append("\(report.skipped) documents changed meanwhile and were skipped. Apply the rules again.")
        }
        if !report.invalidRules.isEmpty {
            lines.append("Not applied, not valid: \(report.invalidRules, format: .list(type: .and))")
        }
        if !report.slowRules.isEmpty {
            lines.append("Too slow on some documents: \(report.slowRules, format: .list(type: .and))")
        }
        if report.copiedRules > 0 {
            lines.append("\(report.copiedRules) rules are not applied because their item exists twice in the archive.")
        }
        return lines
    }
}
