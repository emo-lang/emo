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
		fmt.Println(p.Errors())
		os.Exit(1)
	}

	env := object.NewEnvironment()

	evaluated := evaluator.Eval(program, env)
	if evaluated != nil {
		fmt.Println(evaluated.Inspect())
	}
}
