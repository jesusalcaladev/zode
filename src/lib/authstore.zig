const std = @import("std");
const crypto = std.crypto;
const builtin = @import("builtin");

/// Encrypted-at-rest envelope for auth material (fallback storage when keys
/// cannot live entirely in the OS keychain). Uses XChaCha20-Poly1305.
///
/// Format (v1): "ZODE_AUTH_ENC1:" ++ base64url(nonce || ciphertext || tag)
/// Plain legacy format is a JSON object starting with '{'.
pub const magic = "ZODE_AUTH_ENC1:";
pub const mk_pass_magic = "ZODE_AUTH_MKP1:";
const Aead = crypto.aead.chacha_poly.XChaCha20Poly1305;
const Scrypt = crypto.pwhash.scrypt;

pub fn isPassphraseProtectedMasterKey(data: []const u8) bool {
    return std.mem.startsWith(u8, data, mk_pass_magic);
}

pub fn deriveMasterKeyFromPassphrase(
    alloc: std.mem.Allocator,
    passphrase: []const u8,
    salt: [16]u8,
    params: Scrypt.Params,
) ![Aead.key_length]u8 {
    var out: [Aead.key_length]u8 = undefined;
    try Scrypt.kdf(alloc, &out, passphrase, &salt, params);
    return out;
}

pub fn encryptMasterKeyWithPassphrase(
    alloc: std.mem.Allocator,
    master_key_b64: []const u8,
    passphrase: []const u8,
) ![]u8 {
    const params = Scrypt.Params.owasp;
    var salt: [16]u8 = undefined;
    fillRandom(&salt);
    const kek = try deriveMasterKeyFromPassphrase(alloc, passphrase, salt, params);
    defer {
        var k = kek;
        secureZero(&k);
    }

    var nonce: [Aead.nonce_length]u8 = undefined;
    fillRandom(&nonce);
    const pt = master_key_b64;
    const raw = try alloc.alloc(u8, Aead.nonce_length + pt.len + Aead.tag_length);
    defer {
        secureZero(raw);
        alloc.free(raw);
    }
    @memcpy(raw[0..Aead.nonce_length], &nonce);
    const ct = raw[Aead.nonce_length .. Aead.nonce_length + pt.len];
    const tag = raw[Aead.nonce_length + pt.len ..][0..Aead.tag_length];
    @memcpy(ct, pt);
    Aead.encrypt(ct, tag, pt, &.{}, nonce, kek);

    var salt_b64_buf: [64]u8 = undefined;
    var nonce_b64_buf: [64]u8 = undefined;
    const salt_b64 = std.base64.url_safe_no_pad.Encoder.encode(&salt_b64_buf, &salt);
    const nonce_b64 = std.base64.url_safe_no_pad.Encoder.encode(&nonce_b64_buf, &nonce);
    const ct_b64_len = std.base64.url_safe_no_pad.Encoder.calcSize(raw[Aead.nonce_length..].len);
    const ct_b64_buf = try alloc.alloc(u8, ct_b64_len);
    defer alloc.free(ct_b64_buf);
    const ct_b64 = std.base64.url_safe_no_pad.Encoder.encode(ct_b64_buf, raw[Aead.nonce_length..]);

    // Self-describing text envelope.
    return std.fmt.allocPrint(
        alloc,
        "{s}v=1;ln={d};r={d};p={d};salt={s};nonce={s};ct={s}",
        .{ mk_pass_magic, params.ln, params.r, params.p, salt_b64, nonce_b64, ct_b64 },
    );
}

pub fn decryptMasterKeyWithPassphrase(
    alloc: std.mem.Allocator,
    data: []const u8,
    passphrase: []const u8,
) ![]u8 {
    if (!isPassphraseProtectedMasterKey(data)) return error.NotProtected;
    const body = data[mk_pass_magic.len..];
    var ln: u6 = 0;
    var r: u30 = 0;
    var p: u30 = 0;
    var salt_b64: []const u8 = "";
    var nonce_b64: []const u8 = "";
    var ct_b64: []const u8 = "";

    var it = std.mem.splitScalar(u8, body, ';');
    while (it.next()) |kv| {
        if (kv.len == 0) continue;
        const eq = std.mem.indexOfScalar(u8, kv, '=') orelse continue;
        const k = kv[0..eq];
        const v = kv[eq + 1 ..];
        if (std.mem.eql(u8, k, "v")) {
            if (!std.mem.eql(u8, v, "1")) return error.BadEncoding;
        } else if (std.mem.eql(u8, k, "ln")) {
            ln = std.fmt.parseInt(u6, v, 10) catch return error.BadEncoding;
        } else if (std.mem.eql(u8, k, "r")) {
            r = std.fmt.parseInt(u30, v, 10) catch return error.BadEncoding;
        } else if (std.mem.eql(u8, k, "p")) {
            p = std.fmt.parseInt(u30, v, 10) catch return error.BadEncoding;
        } else if (std.mem.eql(u8, k, "salt")) {
            salt_b64 = v;
        } else if (std.mem.eql(u8, k, "nonce")) {
            nonce_b64 = v;
        } else if (std.mem.eql(u8, k, "ct")) {
            ct_b64 = v;
        }
    }
    if (salt_b64.len == 0 or nonce_b64.len == 0 or ct_b64.len == 0) return error.BadEncoding;

    var salt: [16]u8 = undefined;
    const salt_need = std.base64.url_safe_no_pad.Decoder.calcSizeForSlice(salt_b64) catch return error.BadEncoding;
    if (salt_need != salt.len) return error.BadEncoding;
    std.base64.url_safe_no_pad.Decoder.decode(&salt, salt_b64) catch return error.BadEncoding;

    const ct_raw_len = std.base64.url_safe_no_pad.Decoder.calcSizeForSlice(ct_b64) catch return error.BadEncoding;
    if (ct_raw_len < Aead.tag_length) return error.BadEncoding;
    const ct_raw = try alloc.alloc(u8, ct_raw_len);
    defer {
        secureZero(ct_raw);
        alloc.free(ct_raw);
    }
    std.base64.url_safe_no_pad.Decoder.decode(ct_raw, ct_b64) catch return error.BadEncoding;

    const params = Scrypt.Params{ .ln = ln, .r = r, .p = p };
    const kek = deriveMasterKeyFromPassphrase(alloc, passphrase, salt, params) catch return error.BadPassphrase;
    defer {
        var k = kek;
        secureZero(&k);
    }

    // ct_raw here is ciphertext+tag (we stored raw[Aead.nonce_length..] in encrypt)
    const nonce_need = std.base64.url_safe_no_pad.Decoder.calcSizeForSlice(nonce_b64) catch return error.BadEncoding;
    if (nonce_need != Aead.nonce_length) return error.BadEncoding;
    var nonce: [Aead.nonce_length]u8 = undefined;
    std.base64.url_safe_no_pad.Decoder.decode(&nonce, nonce_b64) catch return error.BadEncoding;

    const plain_len = ct_raw_len - Aead.tag_length;
    const plain = try alloc.alloc(u8, plain_len);
    errdefer {
        secureZero(plain);
        alloc.free(plain);
    }
    const ct = ct_raw[0..plain_len];
    var tag: [Aead.tag_length]u8 = undefined;
    @memcpy(&tag, ct_raw[plain_len..][0..Aead.tag_length]);
    Aead.decrypt(plain, ct, tag, &.{}, nonce, kek) catch return error.AuthFailed;
    return plain; // master key b64
}

fn fillRandom(buf: []u8) void {
    if (buf.len == 0) return;
    if (comptime builtin.os.tag == .linux) {
        var off: usize = 0;
        while (off < buf.len) {
            const rc = std.os.linux.getrandom(buf[off..].ptr, buf.len - off, 0);
            const signed: isize = @bitCast(rc);
            if (signed <= 0) break;
            off += @intCast(rc);
        }
        if (off == buf.len) return;
    }
    // Fallback: /dev/urandom (best-effort).
    if (comptime @hasDecl(std.fs, "openFileAbsolute")) {
        const file = std.fs.openFileAbsolute("/dev/urandom", .{}) catch return;
        defer file.close();
        _ = file.readAll(buf) catch {};
    }
}

pub fn secureZero(buf: []u8) void {
    if (buf.len == 0) return;
    @memset(buf, 0);
    // Best-effort compiler barrier.
    std.mem.doNotOptimizeAway(buf.ptr);
}

pub fn isEncrypted(data: []const u8) bool {
    return std.mem.startsWith(u8, data, magic);
}

pub fn encrypt(alloc: std.mem.Allocator, plaintext: []const u8, key: [Aead.key_length]u8) ![]u8 {
    var nonce: [Aead.nonce_length]u8 = undefined;
    fillRandom(&nonce);
    const out_raw = try alloc.alloc(u8, Aead.nonce_length + plaintext.len + Aead.tag_length);
    defer {
        secureZero(out_raw);
        alloc.free(out_raw);
    }
    @memcpy(out_raw[0..Aead.nonce_length], &nonce);
    const ct = out_raw[Aead.nonce_length .. Aead.nonce_length + plaintext.len];
    const tag = out_raw[Aead.nonce_length + plaintext.len ..][0..Aead.tag_length];
    @memcpy(ct, plaintext);
    Aead.encrypt(ct, tag, plaintext, &.{}, nonce, key);

    const enc_len = std.base64.url_safe_no_pad.Encoder.calcSize(out_raw.len);
    const out = try alloc.alloc(u8, magic.len + enc_len);
    errdefer alloc.free(out);
    @memcpy(out[0..magic.len], magic);
    _ = std.base64.url_safe_no_pad.Encoder.encode(out[magic.len..], out_raw);
    return out;
}

pub fn decrypt(alloc: std.mem.Allocator, data: []const u8, key: [Aead.key_length]u8) ![]u8 {
    if (!isEncrypted(data)) return error.NotEncrypted;
    const b64 = data[magic.len..];
    const raw_len = std.base64.url_safe_no_pad.Decoder.calcSizeForSlice(b64) catch return error.BadEncoding;
    if (raw_len < Aead.nonce_length + Aead.tag_length) return error.BadEncoding;
    const raw = try alloc.alloc(u8, raw_len);
    defer {
        secureZero(raw);
        alloc.free(raw);
    }
    std.base64.url_safe_no_pad.Decoder.decode(raw, b64) catch return error.BadEncoding;

    var nonce: [Aead.nonce_length]u8 = undefined;
    @memcpy(&nonce, raw[0..Aead.nonce_length]);
    const ct_len = raw_len - Aead.nonce_length - Aead.tag_length;
    const ct = raw[Aead.nonce_length .. Aead.nonce_length + ct_len];
    var tag: [Aead.tag_length]u8 = undefined;
    @memcpy(&tag, raw[Aead.nonce_length + ct_len ..][0..Aead.tag_length]);
    const pt = try alloc.alloc(u8, ct_len);
    errdefer {
        secureZero(pt);
        alloc.free(pt);
    }
    Aead.decrypt(pt, ct, tag, &.{}, nonce, key) catch return error.AuthFailed;
    return pt;
}

pub fn keyFromBytes(bytes: []const u8) ?[Aead.key_length]u8 {
    if (bytes.len < Aead.key_length) return null;
    var k: [Aead.key_length]u8 = undefined;
    @memcpy(&k, bytes[0..Aead.key_length]);
    return k;
}

pub fn generateKeyB64(buf: []u8) ![]const u8 {
    var key: [Aead.key_length]u8 = undefined;
    defer secureZero(&key);
    fillRandom(&key);
    const n = std.base64.url_safe_no_pad.Encoder.calcSize(key.len);
    if (buf.len < n) return error.NoSpace;
    return std.base64.url_safe_no_pad.Encoder.encode(buf[0..n], &key);
}

pub fn decodeKeyB64(b64: []const u8) ?[Aead.key_length]u8 {
    const need = std.base64.url_safe_no_pad.Decoder.calcSizeForSlice(b64) catch return null;
    if (need != Aead.key_length) return null;
    var key: [Aead.key_length]u8 = undefined;
    std.base64.url_safe_no_pad.Decoder.decode(&key, b64) catch {
        secureZero(&key);
        return null;
    };
    return key;
}
