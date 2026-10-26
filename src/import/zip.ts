// Reads a .zip in the browser without loading it: the central directory at the end lists every file, and each file
// wanted is sliced out of the Blob and inflated with the browser's own DecompressionStream. A Takeout archive can be
// several GB (zip64), so nothing reads the whole thing. No library: stored and deflated entries are all Takeout uses.

export type ZipEntry = { name: string; method: number; compressedSize: number; size: number; localOffset: number };

const EOCD = 0x06054b50;
const EOCD64 = 0x06064b50;
const EOCD64_LOCATOR = 0x07064b50;
const CENTRAL = 0x02014b50;
const LOCAL = 0x04034b50;
const MAX_COMMENT = 0xffff;

export class ZipError extends Error {
  name = 'ZipError';
}

async function bytes(blob: Blob, start: number, end: number): Promise<DataView> {
  return new DataView(await blob.slice(start, end).arrayBuffer());
}

const u64 = (v: DataView, at: number) => Number(v.getBigUint64(at, true));

/** Every file in the archive, from its central directory. */
export async function listZip(blob: Blob): Promise<ZipEntry[]> {
  // The end record is the last 22 bytes, unless the archive has a comment after it.
  const tailStart = Math.max(0, blob.size - 22 - MAX_COMMENT);
  const tail = await bytes(blob, tailStart, blob.size);
  let at = -1;
  for (let i = tail.byteLength - 22; i >= 0; i--) {
    if (tail.getUint32(i, true) === EOCD) {
      at = i;
      break;
    }
  }
  if (at < 0) throw new ZipError("This isn't a .zip file, or it's incomplete. Download the export again.");
  let count = tail.getUint16(at + 10, true);
  let dirSize = tail.getUint32(at + 12, true);
  let dirOffset = tail.getUint32(at + 16, true);
  // A zip64 archive (over 4 GB, or over 65,535 files) keeps the real numbers in a second end record.
  if (count === 0xffff || dirSize === 0xffffffff || dirOffset === 0xffffffff) {
    const loc = tailStart + at - 20;
    const locator = loc >= 0 ? await bytes(blob, loc, loc + 20) : null;
    if (!locator || locator.getUint32(0, true) !== EOCD64_LOCATOR) throw new ZipError("This .zip can't be read. Download the export again.");
    const endOffset = u64(locator, 8);
    const end64 = await bytes(blob, endOffset, endOffset + 56);
    if (end64.getUint32(0, true) !== EOCD64) throw new ZipError("This .zip can't be read. Download the export again.");
    count = u64(end64, 32);
    dirSize = u64(end64, 40);
    dirOffset = u64(end64, 48);
  }
  if (dirOffset + dirSize > blob.size) throw new ZipError('This .zip is incomplete. Download the export again.');
  const dir = await bytes(blob, dirOffset, dirOffset + dirSize);
  const names = new TextDecoder('utf-8');
  const entries: ZipEntry[] = [];
  let p = 0;
  for (let i = 0; i < count && p + 46 <= dir.byteLength; i++) {
    if (dir.getUint32(p, true) !== CENTRAL) throw new ZipError("This .zip can't be read. Download the export again.");
    const method = dir.getUint16(p + 10, true);
    let compressedSize = dir.getUint32(p + 20, true);
    let size = dir.getUint32(p + 24, true);
    const nameLen = dir.getUint16(p + 28, true);
    const extraLen = dir.getUint16(p + 30, true);
    const commentLen = dir.getUint16(p + 32, true);
    let localOffset = dir.getUint32(p + 42, true);
    const name = names.decode(new Uint8Array(dir.buffer, dir.byteOffset + p + 46, nameLen));
    // Zip64 sizes and offset, in that order, for whichever of them didn't fit in 32 bits.
    let e = p + 46 + nameLen;
    const extraEnd = e + extraLen;
    while (e + 4 <= extraEnd) {
      const id = dir.getUint16(e, true);
      const len = dir.getUint16(e + 2, true);
      if (id === 0x0001) {
        let f = e + 4;
        if (size === 0xffffffff) {
          size = u64(dir, f);
          f += 8;
        }
        if (compressedSize === 0xffffffff) {
          compressedSize = u64(dir, f);
          f += 8;
        }
        if (localOffset === 0xffffffff) localOffset = u64(dir, f);
      }
      e += 4 + len;
    }
    if (!name.endsWith('/')) entries.push({ name, method, compressedSize, size, localOffset });
    p = extraEnd + commentLen;
  }
  return entries;
}

/** One file's text. Its local header says where the data starts (its own name and extra field come first). */
export async function readZipText(blob: Blob, entry: ZipEntry): Promise<string> {
  const head = await bytes(blob, entry.localOffset, entry.localOffset + 30);
  if (head.getUint32(0, true) !== LOCAL) throw new ZipError("This .zip can't be read. Download the export again.");
  const start = entry.localOffset + 30 + head.getUint16(26, true) + head.getUint16(28, true);
  const data = blob.slice(start, start + entry.compressedSize);
  if (entry.method === 0) return data.text();
  if (entry.method !== 8) throw new ZipError(`${entry.name} is packed in a way healthOS can't read.`);
  return new Response(data.stream().pipeThrough(new DecompressionStream('deflate-raw'))).text();
}
