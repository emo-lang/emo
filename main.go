package main

import (
	"fmt"
	"os"

	"github.com/emo-lang/emo/token"

	"github.com/emo-lang/emo/lexer"
)

func main() {
	if len(os.Args) == 1 {
		fmt.Println("Usage: emo <filename>")
		os.Exit(1)
	}

	filename := os.Args[1]
	data, err := os.ReadFile(filename)

	if err != nil {
		fmt.Println("Error reading file:", err)
		os.Exit(1)
	}

	l := lexer.New(string(data))

	for tok := l.NextToken(); tok.Type != token.EOF; tok = l.NextToken() {
		fmt.Printf("token: %+v\n", tok)
	}
}
