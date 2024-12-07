package main

import (
	"fmt"
	"os"

	"github.com/emo-lang/emo/evaluator"
	"github.com/emo-lang/emo/lexer"
	"github.com/emo-lang/emo/object"
	"github.com/emo-lang/emo/parser"
	"github.com/emo-lang/emo/repl"
)

func main() {
	if len(os.Args) == 1 {
		fmt.Println("emo [action] [...]")
		os.Exit(1)
	}

	action := os.Args[1]
	switch action {
	case "run":
		run(os.Args[2:])
	case "repl":
		repl.Start(os.Stdin, os.Stdout)
	default:
		fmt.Println("Unknown action: ", action)
	}

}

func run(args []string) {
	if len(args) == 0 {
		fmt.Println("emo run [filename]")
		os.Exit(1)
	}

	filename := args[0]
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
