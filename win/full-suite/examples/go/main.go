package main

import (
	"fmt"
	"os"
)

func main() {
	message := fmt.Sprintf("Go: %d\nПривет, LinuxFlashcard!\n", 19+23)
	fmt.Print(message)
	if err := os.WriteFile("result.txt", []byte(message), 0644); err != nil {
		panic(err)
	}
}
