JAVA = java
JAVAC = javac
JAR = jar
JAVACFLAGS = --release 21 -encoding UTF-8 -Xlint:all -Werror -g

.PHONY: all run check clean
all: build/hello.jar

build/classes/Hello.class: Hello.java
	mkdir -p build/classes
	$(JAVAC) $(JAVACFLAGS) -d build/classes $<

build/hello.jar: build/classes/Hello.class
	$(JAR) --create --file $@ --main-class Hello -C build/classes Hello.class

run: all
	$(JAVA) -jar build/hello.jar

check: all
	$(JAVA) -cp build/classes Hello > build/class-output.txt
	$(JAVA) -jar build/hello.jar > build/jar-output.txt
	cmp build/class-output.txt build/jar-output.txt
	cmp build/jar-output.txt result.txt
	cat build/jar-output.txt

clean:
	rm -rf build
