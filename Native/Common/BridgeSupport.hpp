#pragma once
#include <algorithm>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <stdexcept>
#include <string>

namespace ao {
inline void error(char *buffer, size_t capacity, const char *message) noexcept {
    if (buffer && capacity) std::snprintf(buffer, capacity, "%s", message);
}
inline char *copy(const std::string &value) {
    auto *result = static_cast<char *>(std::malloc(value.size() + 1));
    if (!result) throw std::bad_alloc();
    std::memcpy(result, value.c_str(), value.size() + 1);
    return result;
}
// Token boundaries can split UTF-8. Preserve valid Croatian and replace incomplete
// sequences at an output limit so JSONDecoder always receives valid UTF-8.
inline std::string json_string(const std::string &value) {
    std::string result = "\"";
    for (size_t i = 0; i < value.size();) {
        const auto c = static_cast<unsigned char>(value[i]);
        if (c == '"' || c == '\\') { result += '\\'; result += value[i++]; }
        else if (c < 0x20) {
            char escaped[7]; std::snprintf(escaped, sizeof escaped, "\\u%04x", c);
            result += escaped; ++i;
        } else if (c < 0x80) result += value[i++];
        else {
            size_t length = c >= 0xc2 && c <= 0xdf ? 2 : c >= 0xe0 && c <= 0xef ? 3 : c >= 0xf0 && c <= 0xf4 ? 4 : 0;
            bool valid = length && i + length <= value.size();
            for (size_t j = 1; valid && j < length; ++j)
                valid = (static_cast<unsigned char>(value[i+j]) & 0xc0) == 0x80;
            if (valid && length == 3) {
                const auto b = static_cast<unsigned char>(value[i+1]);
                valid = !(c == 0xe0 && b < 0xa0) && !(c == 0xed && b >= 0xa0);
            }
            if (valid && length == 4) {
                const auto b = static_cast<unsigned char>(value[i+1]);
                valid = !(c == 0xf0 && b < 0x90) && !(c == 0xf4 && b >= 0x90);
            }
            if (valid) { result.append(value, i, length); i += length; }
            else { result += "\\ufffd"; ++i; }
        }
    }
    return result + '"';
}
template<typename Callback> struct Cancellation {
    Callback callback;
    void *user_data;
    bool cancelled() const { return callback && callback(user_data) != 0; }
    static bool abort(void *data) { return static_cast<Cancellation *>(data)->cancelled(); }
    static bool progress(float, void *data) { return !abort(data); }
};
} // namespace ao
