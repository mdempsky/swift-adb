import SwiftUI

struct ADBAuthPromptView: View {
    let fingerprint: String
    let onDismiss: () -> Void

    private let androidGreen = Color(red: 0.18, green: 0.45, blue: 0.25)

    var body: some View {
        ZStack {
            Color.black.opacity(0.5).ignoresSafeArea()

            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Image(systemName: "hammer.fill")
                        .foregroundStyle(.white)
                        .font(.title3)
                    Text("Allow USB debugging?")
                        .font(.headline)
                        .foregroundStyle(.white)
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(androidGreen)

                VStack(alignment: .leading, spacing: 12) {
                    Text("The device's RSA key fingerprint is:")
                        .font(.subheadline)

                    Text(fingerprint)
                        .font(.system(.caption, design: .monospaced))
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.secondary.opacity(0.15))
                        .clipShape(RoundedRectangle(cornerRadius: 4))

                    HStack(spacing: 8) {
                        Image(systemName: "checkmark.square.fill")
                            .foregroundStyle(.secondary)
                            .font(.body)
                        Text("Always allow from this computer")
                            .font(.subheadline)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 16)

                Divider()

                HStack {
                    Spacer()
                    Button("CANCEL") { onDismiss() }
                        .foregroundStyle(androidGreen)
                        .fontWeight(.medium)
                        .padding(.horizontal, 12)
                    Button("ALLOW") { onDismiss() }
                        .foregroundStyle(androidGreen)
                        .fontWeight(.medium)
                        .padding(.horizontal, 12)
                }
                .padding(.vertical, 12)
                .padding(.horizontal, 8)
            }
            .background(Color(white: 0.97))
            .clipShape(RoundedRectangle(cornerRadius: 4))
            .shadow(radius: 8)
            .padding(.horizontal, 32)
        }
    }
}

#Preview {
    ADBAuthPromptView(
        fingerprint: "a1:b2:c3:d4:e5:f6:07:18:29:3a:4b:5c:6d:7e:8f:90",
        onDismiss: {}
    )
}
