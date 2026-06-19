import SwiftUI

struct ContentView: View {
    @StateObject private var controller = PairingController.shared

    var body: some View {
        VStack(spacing: 28) {
            Spacer()

            appIcon

            Text("StikPair")
                .font(.largeTitle.bold())

            content
                .frame(maxWidth: 320)

            Spacer()
        }
        .padding()
        .animation(.default, value: controller.phase)
    }

    @ViewBuilder
    private var content: some View {
        switch controller.phase {
        case .idle:
            VStack(spacing: 20) {
                Button {
                    controller.start()
                } label: {
                    Text("Pair")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.glass)
                .controlSize(.large)

                keepAliveOptions
            }

        case .waiting:
            VStack(spacing: 16) {
                ProgressView()
                Text("Waiting for a device to connect…")
                    .foregroundStyle(.secondary)

                VStack(alignment: .leading, spacing: 12) {
                    Text("On this device:")
                        .font(.subheadline.weight(.semibold))
                    guideStep(1, "Open the **Settings** app")
                    guideStep(2, "Go to **Privacy & Security**")
                    guideStep(3, "Tap **Developer Mode**")
                    guideStep(4, "Scroll down and tap **Pair with StikPair**")
                }
                .padding()
                .frame(maxWidth: .infinity, alignment: .leading)
                .glassEffect(.regular, in: .rect(cornerRadius: 20))

                Text("If **Pair with StikPair** doesn't show up, close the app and try again.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

        case .showPin(let pin):
            VStack(spacing: 16) {
                Text("Enter this code on your device")
                    .font(.headline)
                Text(pin)
                    .font(.system(size: 48, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .tracking(8)
                    .textSelection(.enabled)
                    .padding(.horizontal, 28)
                    .padding(.vertical, 14)
                    .glassEffect(.regular, in: .capsule)
                ProgressView()
            }

        case .success(let device):
            VStack(spacing: 12) {
                Label("Paired", systemImage: "checkmark.seal.fill")
                    .foregroundStyle(.green)
                    .font(.title3.bold())
                if !device.name.isEmpty {
                    Text("\(device.name) · \(device.model)")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                ShareLink(item: URL(fileURLWithPath: device.pairingFilePath)) {
                    Label("Export Pairing File", systemImage: "square.and.arrow.up")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.glass)
                .controlSize(.large)
                .padding(.top, 4)

                Button("Done") { controller.reset() }
                    .buttonStyle(.glass)
            }

        case .failed(let message):
            VStack(spacing: 10) {
                Label("Failed", systemImage: "xmark.octagon.fill")
                    .foregroundStyle(.red)
                    .font(.title3.bold())
                Text(message)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .textSelection(.enabled)
                Button("Try Again") { controller.reset() }
                    .buttonStyle(.glass)
                    .controlSize(.large)
                    .padding(.top, 4)
            }
        }
    }

    private var keepAliveOptions: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Background keep-alive")
                .font(.subheadline.weight(.semibold))
            Toggle("Silent audio", isOn: $controller.keepAliveAudio)
            Toggle("Location", isOn: $controller.keepAliveLocation)
            Text("Enable one or more of these if the Live Activity doesn't start.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassEffect(.regular, in: .rect(cornerRadius: 20))
    }

    private var appIcon: some View {
        Image("AppLogo")
            .resizable()
            .scaledToFit()
            .frame(width: 116, height: 116)
    }

    private func guideStep(_ number: Int, _ text: LocalizedStringKey) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text("\(number)")
                .font(.caption.bold())
                .foregroundStyle(.white)
                .frame(width: 20, height: 20)
                .background(.tint, in: Circle())
            Text(text)
                .font(.subheadline)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

#Preview {
    ContentView()
}
