import { StrictMode } from 'react';
import { createRoot } from 'react-dom/client';
import { App } from './App.tsx';
// DM Sans, served from this app (never a font CDN: privacy.html promises nothing goes to third parties).
import '@fontsource-variable/dm-sans';
import './styles.css';

// No right-click menu and no dragging images, charts or links off the page, on every screen (sign-in included).
// Form fields keep both, so pasting and fixing typed text still work; selecting text and copying it with the
// keyboard work everywhere. Dropping a file onto an upload area is a different event (drop), and still works.
const editable = (t: EventTarget | null) => t instanceof Element && t.closest('input, textarea, select, [contenteditable]:not([contenteditable="false"])') !== null;
document.addEventListener('contextmenu', (e) => {
  if (!editable(e.target)) e.preventDefault();
});
document.addEventListener('dragstart', (e) => {
  if (!editable(e.target)) e.preventDefault();
});

createRoot(document.getElementById('root')!).render(
  <StrictMode>
    <App />
  </StrictMode>,
);
