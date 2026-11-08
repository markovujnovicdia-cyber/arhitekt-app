#undef NDEBUG
#include "../Common/BridgeSupport.hpp"
#include <cassert>
#include <string>
int main() {
    assert(ao::json_string("čćđšž") == "\"čćđšž\"");
    assert(ao::json_string("\"\\\n\t") == "\"\\\"\\\\\\u000a\\u0009\"");
    assert(ao::json_string(std::string("\xc4", 1)) == "\"\\ufffd\"");
    assert(ao::json_string(std::string("\xed\xa0\x80", 3)) == "\"\\ufffd\\ufffd\\ufffd\"");
    assert(ao::json_string("😀") == "\"😀\"");
    auto *copy = ao::copy("hrvatski");
    assert(std::string(copy) == "hrvatski");
    std::free(copy);
}
