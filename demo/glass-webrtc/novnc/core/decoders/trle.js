/*
 * noVNC TRLE decoder.
 *
 * glass's TRLE (encoding 15) is ZRLE's exact tile format (RFC 6143 §7.7.4 tile
 * subencodings, 64x64 tiles, 3-byte CPIXELs) sent RAW — no zlib, no length prefix.
 * That drops the serial deflate that caps ZRLE's frame rate, at the cost of a bigger
 * (uncompressed) payload the transport must carry.
 *
 * With no length prefix we can't wait for the whole rect, so we decode tile by tile
 * straight off the socket and resume across partial reads: every read goes through
 * `_read`, which uses Websock.rQwait's `goback` to roll the read index back to the
 * current tile's start on underflow. A tile is only blitted once fully read, so a
 * re-decode after "need more data" is idempotent.
 */

const TRLE_TILE = 64;
const WAIT = Symbol("TRLE_WAIT");

export default class TRLEDecoder {
    constructor() {
        this._tiles = 0;
        this._consumed = 0;   // bytes taken since the current tile's start (for rQwait goback)
        this._pixelBuffer = new Uint8Array(TRLE_TILE * TRLE_TILE * 4);
        this._tileBuffer = new Uint8Array(TRLE_TILE * TRLE_TILE * 4);
    }

    decodeRect(x, y, width, height, sock, display, depth) {
        if (this._tiles === 0) {
            this._tilesX = Math.ceil(width / TRLE_TILE);
            this._tilesY = Math.ceil(height / TRLE_TILE);
            this._totalTiles = this._tilesX * this._tilesY;
            this._tiles = this._totalTiles;
        }

        while (this._tiles > 0) {
            const curr = this._totalTiles - this._tiles;
            const tx = x + (curr % this._tilesX) * TRLE_TILE;
            const ty = y + Math.floor(curr / this._tilesX) * TRLE_TILE;
            const tw = Math.min(TRLE_TILE, x + width - tx);
            const th = Math.min(TRLE_TILE, y + height - ty);
            if (!this._decodeTile(sock, display, tx, ty, tw, th)) {
                return false;   // short read: rQwait rewound to this tile's start
            }
            this._tiles--;
        }
        return true;
    }

    // Take N bytes; on underflow rewind to the tile start (this._consumed) and abort the tile.
    _read(sock, n) {
        if (sock.rQwait("TRLE", n, this._consumed)) {
            throw WAIT;
        }
        this._consumed += n;
        return sock.rQshiftBytes(n, false);
    }

    _decodeTile(sock, display, tx, ty, tw, th) {
        this._consumed = 0;
        try {
            const tileSize = tw * th;
            const sub = this._read(sock, 1)[0];
            if (sub === 0) {                                   // raw
                display.blitImage(tx, ty, tw, th, this._readPixels(sock, tileSize), 0, false);
            } else if (sub === 1) {                            // solid colour
                const bg = this._readPixels(sock, 1);
                display.fillRect(tx, ty, tw, th, [bg[0], bg[1], bg[2]]);
            } else if (sub >= 2 && sub <= 16) {                // packed palette
                display.blitImage(tx, ty, tw, th, this._packedPalette(sock, sub, tw, th), 0, false);
            } else if (sub === 128) {                          // plain RLE
                display.blitImage(tx, ty, tw, th, this._plainRLE(sock, tileSize), 0, false);
            } else if (sub >= 130 && sub <= 255) {             // palette RLE
                display.blitImage(tx, ty, tw, th, this._paletteRLE(sock, sub - 128, tileSize), 0, false);
            } else {
                throw new Error("TRLE: unknown subencoding " + sub);
            }
            return true;
        } catch (e) {
            if (e === WAIT) { return false; }
            throw e;
        }
    }

    _bpp(paletteSize) { return paletteSize <= 2 ? 1 : paletteSize <= 4 ? 2 : 4; }

    // Read PIXELS 3-byte CPIXELs into RGBA in _pixelBuffer.
    _readPixels(sock, pixels) {
        const out = this._pixelBuffer;
        const buf = this._read(sock, 3 * pixels);
        for (let i = 0, j = 0; i < pixels * 4; i += 4, j += 3) {
            out[i] = buf[j]; out[i + 1] = buf[j + 1]; out[i + 2] = buf[j + 2]; out[i + 3] = 255;
        }
        return out;
    }

    _packedPalette(sock, paletteSize, tw, th) {
        const data = this._tileBuffer;
        const palette = this._readPixels(sock, paletteSize).slice(0, paletteSize * 4);
        const bpp = this._bpp(paletteSize);
        const mask = (1 << bpp) - 1;
        const rowBytes = Math.ceil((tw * bpp) / 8);       // each row is byte-aligned
        const packed = this._read(sock, rowBytes * th);
        let offset = 0;
        for (let ry = 0; ry < th; ry++) {
            const rowBase = ry * rowBytes;
            for (let rx = 0; rx < tw; rx++) {
                const bit = rx * bpp;
                const idx = (packed[rowBase + (bit >> 3)] >> (8 - bpp - (bit & 7))) & mask;
                data[offset] = palette[idx * 4]; data[offset + 1] = palette[idx * 4 + 1];
                data[offset + 2] = palette[idx * 4 + 2]; data[offset + 3] = 255;
                offset += 4;
            }
        }
        return data;
    }

    _rleLength(sock) {
        let length = 0, current;
        do { current = this._read(sock, 1)[0]; length += current; } while (current === 255);
        return length + 1;
    }

    _plainRLE(sock, tileSize) {
        const data = this._tileBuffer;
        let i = 0;
        while (i < tileSize) {
            const px = this._readPixels(sock, 1);             // used immediately below
            const r = px[0], g = px[1], b = px[2];
            const len = this._rleLength(sock);
            for (let j = 0; j < len && i < tileSize; j++, i++) {
                data[i * 4] = r; data[i * 4 + 1] = g; data[i * 4 + 2] = b; data[i * 4 + 3] = 255;
            }
        }
        return data;
    }

    _paletteRLE(sock, paletteSize, tileSize) {
        const data = this._tileBuffer;
        const palette = this._readPixels(sock, paletteSize).slice(0, paletteSize * 4);
        let offset = 0;
        while (offset < tileSize) {
            let idx = this._read(sock, 1)[0];
            let len = 1;
            if (idx >= 128) { idx -= 128; len = this._rleLength(sock); }
            for (let j = 0; j < len && offset < tileSize; j++, offset++) {
                data[offset * 4] = palette[idx * 4]; data[offset * 4 + 1] = palette[idx * 4 + 1];
                data[offset * 4 + 2] = palette[idx * 4 + 2]; data[offset * 4 + 3] = 255;
            }
        }
        return data;
    }
}
