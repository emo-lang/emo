package ast

import (
	"testing"

	"github.com/emo-lang/emo/token"
)

func TestString(t *testing.T) {
	program := &Program{
		Statements: []Statement{
			&DefineStatement{
				Token: token.Token{Type: token.CONST, Literal: "let"},
				Name: &Identifier{
					Token: token.Token{Type: token.IDENT, Literal: "myVar"},
					Value: "myVar",
				},
				Value: &Identifier{
					Token: token.Token{Type: token.IDENT, Literal: "anotherVar"},
					Value: "anotherVar",
				},
			},
		},
	}

	if program.String() != "let myVar = anotherVar;" {
		t.Errorf("program.String() wrong. got=%q", program.String())
	}

}
