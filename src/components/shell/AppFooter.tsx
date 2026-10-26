// The last line of every page, at the bottom of the screen when the page is short. On Home the Ask McFly pill takes
// the right-hand side, so only the left line shows there.
export function AppFooter({ home }: { home: boolean }) {
  return (
    <footer className="app-foot">
      <span>A little more clarity, every day.</span>
      {!home && <span>Personal health records · Not a diagnosis</span>}
    </footer>
  );
}
