import SwiftUI

// The two key sheets (src/components/ai/AiSheets.tsx), opened from Profile's Chatbot and "OpenAI · Nutrition &
// portraits" rows, and by #/profile?connect=chatbot or ?connect=openai (Nutrition's setup line). Profile (slice D)
// presents them; slice E builds them here. `onClose` is the web's: the presenter's own close, or the sheet's dismiss.

/// Your own AI key for Ask McFly (Anthropic, OpenAI or Gemini).
struct ChatbotSheet: View {
    var onClose: (() -> Void)?

    init(onClose: (() -> Void)? = nil) { self.onClose = onClose }

    var body: some View {
        SheetScaffold(eyebrow: "Profile", title: "Chatbot", onClose: onClose) {
            Text("Connecting your own key is coming in this build.").font(.app(.subheadline)).foregroundStyle(Palette.ink2)
        }
    }
}

/// Your own OpenAI key for meal estimates, voice notes and portraits.
struct OpenAIKeySheet: View {
    var onClose: (() -> Void)?

    init(onClose: (() -> Void)? = nil) { self.onClose = onClose }

    var body: some View {
        SheetScaffold(eyebrow: "Profile", title: "OpenAI · Nutrition & portraits", onClose: onClose) {
            Text("Connecting your own key is coming in this build.").font(.app(.subheadline)).foregroundStyle(Palette.ink2)
        }
    }
}
