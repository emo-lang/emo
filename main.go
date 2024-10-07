package main

import (
	"fmt"
	"os"

	"github.com/emo-lang/emo/evaluator"
	"github.com/emo-lang/emo/lexer"
	"github.com/emo-lang/emo/object"
	"github.com/emo-lang/emo/parser"
)

func main() {
	if len(os.Args) == 1 {
		fmt.Println("emo <filename>")
		os.Exit(1)
	}

	filename := os.Args[1]
	data, err := os.ReadFile(filename)
	if err != nil {
		fmt.Println(err)
		os.Exit(1)
	}

	l := lexer.New(string(data))
	p := parser.New(l)

	program := p.ParseProgram()

	if len(p.Errors()) != 0 {
		for _, msg := range p.Errors() {
			fmt.Printf("Err: %s\n", msg)
		}
		os.Exit(1)
	}

	env := object.NewEnvironment()

	evaluator.Eval(program, env)
}
