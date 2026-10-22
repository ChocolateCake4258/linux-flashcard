#include <stdio.h>

int add(int left, int right)
{
    return left + right;
}

int main(void)
{
    int answer = add(19, 23);
    printf("Hello from C: %d\n", answer);
    return answer == 42 ? 0 : 1;
}
