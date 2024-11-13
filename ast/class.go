package ast

import (
	"fmt"

	"github.com/emo-lang/emo/token"
)

type TypedField struct {
	Name *Identifier
	Type *Identifier
}

func (tf *TypedField) String() string {
	return fmt.Sprintf("<%s:%s>", tf.Name.String(), tf.Type.String())
}

type ClassField struct {
	Public bool

	Field *TypedField
}

func (cf *ClassField) String() string {
	return fmt.Sprintf("%s:%v", cf.Field.String(), cf.Public)
}

type ClassMethod struct {
	Public   bool
	Function *FunctionDefinition
}

func (cm *ClassMethod) String() string {
	return fmt.Sprintf("%s:%v", cm.Function.String(), cm.Public)
}

type ClassExpression struct {
	Token   token.Token // the 'class' token
	Name    *Identifier
	Fields  map[string]*ClassField
	Methods map[string]*ClassMethod
}

func (ce *ClassExpression) expressionNode() {}
func (ce *ClassExpression) TokenLiteral() string {
	return ce.Token.Literal
}

func (ce *ClassExpression) String() string {
	return "<class " + ce.Name.String() + ">"
}

type NewExpression struct {
	Token token.Token // the 'new' token
	What  *Identifier
	Data  Expression
}

func (ne *NewExpression) expressionNode() {}
func (ne *NewExpression) TokenLiteral() string {
	return ne.Token.Literal
}

func (ne *NewExpression) String() string {
	return "new(" + ne.What.String() + ", " + fmt.Sprintf("%s", ne.Data) + ")"
}
