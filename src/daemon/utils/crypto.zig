const std = @import("std");
const ChaCha20Poly1305 = std.crypto.aead.chacha_poly.ChaCha20Poly1305;
const Sha256 = std.crypto.hash.sha2.Sha256;

const SHORT_HASH_SIZE = 8;

pub const Hash = [32]u8;
pub const ShortHash = [SHORT_HASH_SIZE]u8;

pub fn hashFile(file_path: []const u8) !Hash {
    const file = try std.fs.cwd().openFile(file_path, .{});
    defer file.close();

    var hasher = Sha256.init(.{});
    var buffer: [8192]u8 = undefined;

    while (true) {
        const bytes_read = try file.read(&buffer);
        if (bytes_read == 0) break;
        hasher.update(buffer[0..bytes_read]);
    }

    var result: Hash = undefined;
    hasher.final(&result);
    return result;
}

// NOTE: May not need this but nice to have for potential future use.
pub fn getShortHash(hash: Hash) ShortHash {
    return hash[0..SHORT_HASH_SIZE].*;
}

pub const EncryptedData = struct {
    data: []u8,
    nonce: [ChaCha20Poly1305.nonce_length]u8,

    pub fn deinit(self: *EncryptedData, allocator: std.mem.Allocator) void {
        allocator.free(self.data);
    }
};

// NOTE: May not need to encrypt data if we keep everything local, but adding this for future use.
pub fn encrypt(allocator: std.mem.Allocator, data: []const u8, key: [32]u8) !EncryptedData {
    var nonce: [ChaCha20Poly1305.nonce_length]u8 = undefined;
    std.crypto.random.bytes(&nonce);

    const encrypted_data = try allocator.alloc(u8, data.len + ChaCha20Poly1305.tag_length);

    ChaCha20Poly1305.encrypt(encrypted_data[0..data.len], encrypted_data[data.len..], data, "", nonce, key);

    return EncryptedData{
        .data = encrypted_data,
        .nonce = nonce,
    };
}

// NOTE: May not need to decrypt data if we keep everything local, but adding this for future use.
pub fn decrypt(allocator: std.mem.Allocator, encrypted: EncryptedData, key: [32]u8) ![]u8 {
    if (encrypted.data.len < ChaCha20Poly1305.tag_length) return error.InvalidEncryptedData;

    const data_len = encrypted.data.len - ChaCha20Poly1305.tag_length;
    const decrypted_data = try allocator.alloc(u8, data_len);
    errdefer allocator.free(decrypted_data);

    const ciphertext = encrypted.data[0..data_len];
    const tag = encrypted.data[data_len..];

    try ChaCha20Poly1305.decrypt(decrypted_data, ciphertext, tag.*, "", encrypted.nonce, key);

    return decrypted_data;
}
