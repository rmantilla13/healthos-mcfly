// PLACEHOLDER: replaced by the AI build. Profile's "Manage chatbot AI" and "Connect AI key" open these sheets; this
// stand-in only lets the Profile branch compile and open them.
import { Sheet } from '../Sheet.tsx';

export function ChatbotSheet({ onClose }: { onClose: () => void }) {
  return (
    <Sheet eyebrow="Profile" title="Chatbot" onClose={onClose}>
      <p className="muted">Ask McFly uses healthOS's shared Claude key.</p>
    </Sheet>
  );
}

export function OpenAIKeySheet({ onClose }: { onClose: () => void }) {
  return (
    <Sheet eyebrow="Profile" title="OpenAI · Nutrition & portraits" onClose={onClose}>
      <p className="muted">Connecting your own OpenAI key isn't available in this build yet.</p>
    </Sheet>
  );
}
