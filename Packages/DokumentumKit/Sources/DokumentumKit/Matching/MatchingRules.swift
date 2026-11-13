import Foundation

/// Decides for one document which records' rules match its text (plan of #10, Approach 2).
///
/// - **The text** is the document's extracted text only (T9), never the title or the file name.
/// - `none` and `unknown` (a newer build's mode) never match; neither does an empty pattern (or one of only quotes
///   and whitespace).
/// - `any`: one term occurs. `all`: every term occurs, in any order. `exact`: the whole pattern (quotes ignored)
///   occurs as consecutive words. Words and terms: `MatchingPattern`. `regex`: `RegexMatcher`.
/// - **Several records of one kind (P2): none.** More than one matching correspondent (or type) leaves the field
///   empty and puts the kind in `ambiguous`. Every matching tag is in `tags`.
/// - A rule that cannot run (`MatchingRuleValidation.check` fails) is in `invalid`; a regular expression whose
///   budget ran out on this text is in `timedOut`. Both match nothing.
///
/// The outcome depends on the set of rules, never on their order, so two devices with the same rules decide alike
/// (T7).
public enum MatchingRules {
    /// The outcome for `text` under `rules`.
    public static func evaluate(
        text: String, rules: [MatchingRule], budget: MatchingBudget = .production
    ) -> RuleOutcome {
        Prepared(rules).evaluate(text: text, budget: budget)
    }

    /// Rules parsed and compiled once, for many documents (the bulk run, T6). Holds `NSRegularExpression`s, so it
    /// stays in the task that made it.
    public struct Prepared {
        private enum Matcher {
            case words(any: Bool, terms: [[MatchingPattern.Word]])
            case regex(NSRegularExpression)
            case never
        }

        private let rules: [(rule: MatchingRule, matcher: Matcher)]
        /// The rules that cannot run.
        public let invalid: Set<UUID>

        public init(_ rules: [MatchingRule]) {
            var prepared: [(MatchingRule, Matcher)] = []
            var invalid: Set<UUID> = []
            for rule in rules {
                guard MatchingRuleValidation.check(mode: rule.mode, pattern: rule.pattern) == nil else {
                    invalid.insert(rule.id)
                    continue
                }
                prepared.append((rule, Self.matcher(for: rule, invalid: &invalid)))
            }
            self.rules = prepared
            self.invalid = invalid
        }

        private static func matcher(for rule: MatchingRule, invalid: inout Set<UUID>) -> Matcher {
            guard !rule.pattern.allSatisfy({ $0.isWhitespace }) else { return .never }
            switch rule.mode {
            case .none, .unknown:
                return .never
            case .any, .all:
                let terms = MatchingPattern.terms(of: rule.pattern).map(MatchingPattern.words(of:)).filter {
                    !$0.isEmpty
                }
                return terms.isEmpty ? .never : .words(any: rule.mode == .any, terms: terms)
            case .exact:
                let words = MatchingPattern.words(of: rule.pattern)
                return words.isEmpty ? .never : .words(any: true, terms: [words])
            case .regex:
                guard let regex = RegexMatcher.compile(rule.pattern) else {
                    invalid.insert(rule.id)
                    return .never
                }
                return .regex(regex)
            }
        }

        /// The outcome for `text`. Rules in `skipping` are left out: the bulk run's rules that timed out earlier.
        ///
        /// **A correspondent or type rule that timed out or is skipped makes its kind ambiguous** (review A of #205,
        /// N4): whether it matches is unknown, so none of that kind is set, as for several matches (P2). Otherwise a
        /// slower device would set the other record alone where a faster one leaves the field empty, and the value
        /// would depend on the device's speed.
        public func evaluate(text: String, budget: MatchingBudget, skipping: Set<UUID> = []) -> RuleOutcome {
            var outcome = RuleOutcome(invalid: invalid)
            var words: MatchingText?
            var nfc: String?
            var matched: [MetadataKind: Set<UUID>] = [:]
            var undecided: Set<MetadataKind> = []
            for (rule, matcher) in rules {
                guard !skipping.contains(rule.id) else {
                    undecided.insert(rule.kind)
                    continue
                }
                let matches: Bool
                switch matcher {
                case .never:
                    matches = false
                case .words(let any, let terms):
                    let text = words ?? MatchingText(text)
                    words = text
                    matches = any ? terms.contains(where: text.contains) : terms.allSatisfy(text.contains)
                case .regex(let regex):
                    let normalized = nfc ?? text.precomposedStringWithCanonicalMapping
                    nfc = normalized
                    switch RegexMatcher.firstMatch(of: regex, inNFC: normalized, budget: budget) {
                    case .match: matches = true
                    case .noMatch: matches = false
                    case .timedOut:
                        matches = false
                        outcome.timedOut.insert(rule.id)
                        undecided.insert(rule.kind)
                    }
                }
                if matches { matched[rule.kind, default: []].insert(rule.id) }
            }
            outcome.tags = matched[.tag] ?? []
            for kind in [MetadataKind.correspondent, .documentType] {
                let ids = matched[kind] ?? []
                let isAmbiguous = ids.count > 1 || undecided.contains(kind)
                if isAmbiguous { outcome.ambiguous.insert(kind) }
                let single = ids.count == 1 && !isAmbiguous ? ids.first : nil
                if kind == .correspondent { outcome.correspondent = single } else { outcome.documentType = single }
            }
            return outcome
        }
    }
}
