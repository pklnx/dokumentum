import DokumentumCore
import SwiftUI

/// The settings' "Matching" section (plan of #10, §9; maintainer's P3): "Apply Matching Rules to All Documents…" with
/// its confirmation, then a progress line with Cancel while the run goes on, and the last run's result. What the
/// section does is below it: in the footer on the Mac, in a row without a background on the iPhone, as the
/// "Suggestions" section (#139). Texts are primary, callout medium, for the same reason as there.
struct MatchingSettingsSection: View {
    @Bindable var model: MatchingRunModel

    var body: some View {
        Section {
            if case .running(let progress) = model.phase {
                VStack(alignment: .leading, spacing: 8) {
                    if let progress, progress.total > 0 {
                        ProgressView(value: Double(progress.done), total: Double(progress.total)) {
                            Text(MatchingRuleText.progress(progress))
                        }
                        .accessibilityIdentifier(AccessibilityID.settingsMatchingProgress)
                    } else {
                        ProgressView {
                            Text(MatchingRuleText.progress(progress))
                        }
                        .accessibilityIdentifier(AccessibilityID.settingsMatchingProgress)
                    }
                    Button("Cancel") { model.cancel() }
                        .accessibilityIdentifier(AccessibilityID.settingsMatchingCancel)
                }
                .font(.callout.weight(.medium))
            } else {
                Button {
                    model.requestApply()
                } label: {
                    Text(MatchingRuleText.apply)
                }
                .accessibilityIdentifier(AccessibilityID.settingsMatchingApply)
            }
            if case .finished(let report) = model.phase {
                MatchingResultLine(report: report)
            }
        } header: {
            Text(MatchingRuleText.section)
        } footer: {
            #if os(macOS)
                about
            #endif
        }
        #if os(iOS)
            Section {
                about
                    .listRowBackground(Color.clear)
            }
        #endif
    }

    private var about: some View {
        Text(MatchingRuleText.about)
            .font(.callout.weight(.medium))
            .foregroundStyle(.primary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// The last run's result: its sentences (`MatchingRuleText.result`), one element to VoiceOver.
struct MatchingResultLine: View {
    let report: MatchingRun.Report

    var body: some View {
        // In a stack, as the section texts below the "Suggestions" switch: as the row's own text, the iPhone audit
        // reported "Dynamic Type font sizes are partially unsupported" on it (#200), as on texts in a footer (#139).
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(MatchingRuleText.result(report).enumerated()), id: \.offset) { _, line in
                Text(line)
            }
        }
        .font(.callout.weight(.medium))
        .foregroundStyle(.primary)
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier(AccessibilityID.settingsMatchingResult)
    }
}

/// The confirmation of "Apply Matching Rules to All Documents…" (P3). An alert, as the Empty Trash confirmation: on
/// the iPhone a confirmation dialog showed no Cancel button (#46).
struct MatchingRunConfirmation: ViewModifier {
    @Bindable var model: MatchingRunModel

    func body(content: Content) -> some View {
        content
            .alert(Text(MatchingRuleText.confirmTitle), isPresented: $model.isConfirming) {
                Button {
                    model.confirm()
                } label: {
                    Text(MatchingRuleText.confirm)
                }
                .accessibilityIdentifier(AccessibilityID.settingsMatchingConfirm)
                // The system's label for a cancel button: no catalog entry of its own.
                Button(role: .cancel) {}
                    .accessibilityIdentifier(AccessibilityID.settingsMatchingConfirmCancel)
            } message: {
                Text(MatchingRuleText.confirmMessage)
            }
    }
}
