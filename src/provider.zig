const std = @import("std");

pub const default_base_url = "https://opencode.ai/inference/openai/v1";
pub const default_models_url = "https://opencode.ai/inference/v1/models";
pub const default_model = "kimi-k2.6";

pub const Config = struct {
    base_url: []const u8,
    models_url: []const u8,
    model: []const u8,

    /// Reads config from environment variables (phase 1); then: ~/.config/zode/config.json
    pub fn load(env: ?*const std.process.Environ.Map) Config {
        const get = struct {
            fn f(e: ?*const std.process.Environ.Map, key: []const u8, fallback: []const u8) []const u8 {
                if (e) |m| return m.get(key) orelse fallback;
                return fallback;
            }
        }.f;
        return .{
            .base_url = get(env, "ZODE_BASE_URL", default_base_url),
            .models_url = get(env, "ZODE_MODELS_URL", default_models_url),
            .model = get(env, "ZODE_MODEL", default_model),
        };
    }

    /// URL of the models endpoint.
    pub fn urlModels(self: Config, buf: []u8) []const u8 {
        if (buf.len < self.models_url.len) return self.models_url;
        @memcpy(buf[0..self.models_url.len], self.models_url);
        return buf[0..self.models_url.len];
    }

    /// URL of the chat completions endpoint, formatted into `buf`.
    pub fn urlChat(self: Config, buf: []u8) []const u8 {
        return std.fmt.bufPrint(buf, "{s}/chat/completions", .{self.base_url}) catch self.base_url;
    }
};
