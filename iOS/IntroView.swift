import SwiftUI

// Four pages shown on the first launch, before pairing: what the app is, how
// to connect the Mac, what to allow there, and the modes. It can be opened
// again from the menu.
struct IntroView: View {
    let controller: MouseController
    @State private var page = 0

    private let pages = 4
    private let releases = URL(string: "https://github.com/abilkhan023/swiss-knife/releases/latest")!

    var body: some View {
        ZStack {
            LinearGradient(colors: [Palette.shellTop, Palette.shellBottom], startPoint: .top, endPoint: .bottom)
            VStack(spacing: 0) {
                HStack {
                    Spacer()
                    if page < pages - 1 {
                        Button("Skip") { controller.finishIntro() }
                            .font(.marking(16))
                            .foregroundStyle(Palette.ink.opacity(0.7))
                    }
                }
                .frame(height: 44)
                .padding(.horizontal, 24)
                TabView(selection: $page) {
                    welcome.tag(0)
                    connect.tag(1)
                    permissions.tag(2)
                    modes.tag(3)
                }
                .tabViewStyle(.page(indexDisplayMode: .never))
                dots
                    .padding(.bottom, 18)
                Button {
                    if page < pages - 1 {
                        withAnimation { page += 1 }
                    } else {
                        controller.finishIntro()
                    }
                } label: {
                    Text(page < pages - 1 ? String(localized: "Next") : controller.pairings.isEmpty ? String(localized: "Pair a Mac") : String(localized: "Done"))
                        .font(.marking(18))
                        .foregroundStyle(Palette.shellBottom)
                        .frame(maxWidth: .infinity)
                        .frame(height: 54)
                        .background(Palette.ink, in: RoundedRectangle(cornerRadius: 16))
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 24)
            }
            .padding(.top, 60)
            .padding(.bottom, 44)
        }
        .ignoresSafeArea()
    }

    private var dots: some View {
        HStack(spacing: 8) {
            ForEach(0..<pages, id: \.self) { index in
                Circle()
                    .fill(Palette.ink.opacity(index == page ? 0.9 : 0.25))
                    .frame(width: 7, height: 7)
            }
        }
    }

    private var welcome: some View {
        IntroPage(symbol: "computermouse", title: "Swiss Knife") {
            Text("Your iPhone as a mouse, a touchpad and a remote for your Mac.")
            Text("Point it at the screen, slide it on the desk, or drag a finger across it. Type on the Mac, switch apps, translate what you select, and unlock the Mac with Face ID.")
        }
    }

    private var connect: some View {
        IntroPage(symbol: "laptopcomputer.and.iphone", title: "Connect your Mac") {
            IntroStep(number: 1, text: "Install Swiss Knife on the Mac. It lives in the menu bar.")
            Link(destination: releases) {
                Label("Download for Mac", systemImage: "arrow.down.circle")
                    .font(.marking(16))
            }
            .foregroundStyle(Palette.ink)
            IntroStep(number: 2, text: "Keep both on the same Wi-Fi, put the Mac on this iPhone's hotspot, or connect them with a cable.")
            IntroStep(number: 3, text: "In the Mac's menu bar, open Swiss Knife, choose Pair iPhone, and scan the code with this phone.")
        }
    }

    private var permissions: some View {
        IntroPage(symbol: "lock.shield", title: "Allow it on the Mac") {
            Text("In System Settings, Privacy & Security. The Mac asks for each one the first time it is needed.")
            IntroPermission(name: "Accessibility", detail: "Needed. Lets it move the pointer, click and type.")
            IntroPermission(name: "Screen Recording", detail: "For the mini screen of the Mac on the phone.")
            IntroPermission(name: "Automation", detail: "For the tabs of Safari and Chrome in the Apps list.")
        }
    }

    private var modes: some View {
        IntroPage(symbol: "square.grid.2x2", title: "Four ways to use it") {
            IntroMode(symbol: PointerMode.air.symbol, name: "In air", detail: "Hold the phone and point it at the screen.")
            IntroMode(symbol: PointerMode.desk.symbol, name: "On desk", detail: "Slide it across the desk like a mouse.")
            IntroMode(symbol: PointerMode.touchpad.symbol, name: "Touchpad", detail: "Drag, tap and scroll like a Mac trackpad.")
            IntroMode(symbol: PointerMode.remote.symbol, name: "Remote", detail: "Media, slides, apps, the Mac's screen, translation and actions.")
        }
    }
}

private struct IntroPage<Content: View>: View {
    let symbol: String
    let title: LocalizedStringKey
    @ViewBuilder let content: Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Image(systemName: symbol)
                    .font(.system(size: 54, weight: .light))
                    .frame(maxWidth: .infinity)
                    .padding(.bottom, 6)
                Text(title)
                    .font(.marking(28))
                    .frame(maxWidth: .infinity)
                VStack(alignment: .leading, spacing: 14) {
                    content
                }
                .font(.system(size: 16))
            }
            .foregroundStyle(Palette.ink)
            .padding(.horizontal, 28)
            .padding(.vertical, 12)
        }
    }
}

private struct IntroStep: View {
    let number: Int
    let text: LocalizedStringKey

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text("\(number)")
                .font(.marking(16))
                .frame(width: 26, height: 26)
                .background(Palette.pressed, in: Circle())
            Text(text)
        }
    }
}

private struct IntroPermission: View {
    let name: LocalizedStringKey
    let detail: LocalizedStringKey

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(name).font(.marking(17))
            Text(detail).opacity(0.75)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(Palette.pressed, in: RoundedRectangle(cornerRadius: 14))
    }
}

private struct IntroMode: View {
    let symbol: String
    let name: LocalizedStringKey
    let detail: LocalizedStringKey

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: symbol)
                .font(.system(size: 22, weight: .medium))
                .frame(width: 32)
            VStack(alignment: .leading, spacing: 2) {
                Text(name).font(.marking(17))
                Text(detail).opacity(0.75)
            }
        }
    }
}
