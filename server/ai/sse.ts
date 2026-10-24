// Server-sent events from a provider's streaming reply (OpenAI's Responses API, Gemini's streamGenerateContent): each
// event's data, parsed as JSON. Lines end in \n, \r\n or \r; several data lines make one event, joined by \n.

/** Each event's JSON data in order, until the stream ends. An event whose data isn't JSON is skipped. */
export async function* sseData(body: ReadableStream<Uint8Array> | null): AsyncGenerator<Record<string, unknown>> {
  if (!body) return;
  const decoder = new TextDecoder();
  const reader = body.getReader();
  let buf = '';
  let data: string[] = [];
  let finished = false;
  const flush = function* () {
    if (!data.length) return;
    const text = data.join('\n');
    data = [];
    if (text === '[DONE]') return;
    try {
      const v = JSON.parse(text) as unknown;
      if (v && typeof v === 'object') yield v as Record<string, unknown>;
    } catch {
      // Not JSON (a keep-alive or a cut-off event): nothing to read.
    }
  };
  try {
    for (;;) {
      const { value, done } = await reader.read();
      buf += done ? decoder.decode() : decoder.decode(value, { stream: true });
      let cut;
      while ((cut = buf.search(/[\r\n]/)) >= 0) {
        // A \r at the very end may be the first half of \r\n: wait for the next chunk to tell.
        if (!done && buf[cut] === '\r' && cut === buf.length - 1) break;
        const line = buf.slice(0, cut);
        buf = buf.slice(cut + (buf.startsWith('\r\n', cut) ? 2 : 1));
        if (line === '') yield* flush();
        else if (line.startsWith('data:')) data.push(line.slice(line.startsWith('data: ') ? 6 : 5));
        // event:, id:, retry: and comments aren't needed: every payload names its own type.
      }
      if (done) break;
    }
    finished = true;
    if (buf.startsWith('data:')) data.push(buf.slice(buf.startsWith('data: ') ? 6 : 5));
    yield* flush();
  } finally {
    // Stopped early (an abort, or the reader is done with it): stop downloading the rest.
    if (!finished) await reader.cancel().catch(() => {});
    reader.releaseLock();
  }
}
