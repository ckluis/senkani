// This is a comment
#include <string>
#include <iostream>

namespace app {

class User {
public:
    std::string name = "hello world";
    int age = 42;
    bool active = true;

    std::string greet() {
        return "Hi, " + name + "!";
    }
};

/* Block comment */
auto raw = R"(raw string)";

} // namespace app
