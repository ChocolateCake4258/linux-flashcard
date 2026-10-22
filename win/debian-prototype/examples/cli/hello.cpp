#include <iostream>

int main()
{
    const auto answer = 19 + 23;
    std::cout << "Hello from C++: " << answer << '\n';
    return answer == 42 ? 0 : 1;
}
