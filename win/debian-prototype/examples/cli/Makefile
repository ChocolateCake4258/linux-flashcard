CC = gcc
CXX = g++
CFLAGS = -std=c17 -Wall -Wextra -Werror -g -O0
CXXFLAGS = -std=c++17 -Wall -Wextra -Werror -g -O0

.PHONY: all check clean
all: build/hello-c build/hello-cpp

build:
	mkdir -p $@

build/hello-c: hello.c | build
	$(CC) $(CPPFLAGS) $(CFLAGS) $< $(LDFLAGS) $(LDLIBS) -o $@

build/hello-cpp: hello.cpp | build
	$(CXX) $(CPPFLAGS) $(CXXFLAGS) $< $(LDFLAGS) $(LDLIBS) -o $@

check: all
	./build/hello-c
	./build/hello-cpp
	test "$$(./build/hello-c)" = "Hello from C: 42"
	test "$$(./build/hello-cpp)" = "Hello from C++: 42"

clean:
	rm -rf build
