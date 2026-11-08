#undef NDEBUG
#include "../Llama/JSONGrammar.hpp"
#include "llama-grammar.h"
#include "unicode.h"
#include <cassert>
#include <memory>
#include <string>

static bool accepts(const std::string &text) {
    std::unique_ptr<llama_grammar, decltype(&llama_grammar_free_impl)> grammar(
        llama_grammar_init_impl(nullptr, ao::json_grammar, "root", false, nullptr, 0, nullptr, 0),
        llama_grammar_free_impl);
    assert(grammar);
    for (size_t offset = 0; offset < text.size();) {
        llama_grammar_accept(grammar.get(), unicode_cpt_from_utf8(text, offset));
        if (llama_grammar_get_stacks(grammar.get()).empty()) return false;
    }
    for (const auto &stack : llama_grammar_get_stacks(grammar.get()))
        if (stack.empty()) return true;
    return false;
}
int main() {
    assert(accepts("{}"));
    assert(accepts(R"({"odluke":[{"tekst":"čćđšž","rok":null,"ok":true,"broj":-1.2e+3}]})"));
    assert(accepts(R"({"tekst":"redak\nnavodnik\"","u":"\u010d"})"));
    assert(!accepts("<think>plan</think>{}"));
    assert(!accepts("Objašnjenje: {}"));
    assert(!accepts("{\"odluke\":["));
    assert(!accepts("{}{}"));
    assert(!accepts("[]"));
    assert(!accepts("{\"a\":NaN}"));
    assert(!accepts("true"));
}
