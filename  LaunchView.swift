import SwiftUI

struct LaunchView: View {

    var body: some View {
        ZStack {

            Color.black.ignoresSafeArea()

            Image("LaunchImage") // имя из Assets
                .resizable()
                .scaledToFit()
                .frame(width: 120)
        }
    }
}
