package ast

import (
	"bytes"
	"strings"

	"github.com/emo-lang/emo/token"
)

type FunctionLiteral struct {
	Token       token.Token // the 'func' token
	Parameters  []*Identifier
	ReturnTypes []*Identifier
	Body        *BlockStatement
}

func (fd *FunctionLiteral) expressionNode() {}
func (fd *FunctionLiteral) TokenLiteral() string {
	return fd.Token.Literal
}

func (fd *FunctionLiteral) String() string {
	var out bytes.Buffer

	params := []string{}
	for _, p := range fd.Parameters {
		params = append(params, p.String())
	}

	out.WriteString(fd.TokenLiteral())
	out.WriteString("(")
	out.WriteString(strings.Join(params, ", "))
	out.WriteString(") ")
	out.WriteString(fd.Body.String())

	return out.String()
}

type FunctionDefinition struct {
	Token       token.Token // the 'func' token
	Name        *Identifier
	Parameters  []*Identifier
	ReturnTypes []*Identifier
	Body        *BlockStatement
}

func (fd *FunctionDefinition) expressionNode() {}
func (fd *FunctionDefinition) TokenLiteral() string {
	return fd.Token.Literal
}

func (fd *FunctionDefinition) String() string {
	var out bytes.Buffer

	params := []string{}
	for _, p := range fd.Parameters {
		params = append(params, p.String())
	}

	out.WriteString(fd.TokenLiteral())
	out.WriteString(" ")
	out.WriteString(fd.Name.String())
	out.WriteString("(")
	out.WriteString(strings.Join(params, ", "))
	out.WriteString(") ")
	out.WriteString(fd.Body.String())

	return out.String()
}
