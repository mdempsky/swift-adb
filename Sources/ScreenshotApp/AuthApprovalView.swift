import SwiftUI

struct AuthApprovalView: View {
    let fingerprint: String
    let onCancel: () -> Void

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "key.fill")
                .font(.system(size: 48))
                .foregroundStyle(.orange)

            Text("Approve on Your Android Device")
                .font(.headline)

            Text("Your Android device is showing an \"Allow USB debugging?\" prompt. Tap **Allow** on the device to continue.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 300)

            VStack(spacing: 6) {
                Text("RSA Key Fingerprint")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(fingerprint)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(8)
                    .background(Color(nsColor: .windowBackgroundColor))
                    .cornerRadius(6)
            }

            Button("Cancel") { onCancel() }
        }
        .padding(28)
        .frame(width: 380)
    }
}
