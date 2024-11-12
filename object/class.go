package object

import (
	"bytes"

	"github.com/emo-lang/emo/ast"
)

type Class struct {
	Name    *ast.Identifier
	Fields  map[string]*ast.ClassField
	Methods map[string]*ast.ClassMethod
	Env     *Environment
}

func (klass *Class) Type() ObjectType { return CLASS_OBJ }
func (klass *Class) Inspect() string {
	var out bytes.Buffer

	out.WriteString("class ")
	out.WriteString(klass.Name.Value)
	out.WriteString(" {}")

	return out.String()
}

type ClassInstance struct {
	Klass *Class
	Name  *ast.Identifier
	Env   *Environment
}

func (ci *ClassInstance) Type() ObjectType { return CLASS_INSTANCE_OBJ }
func (ci *ClassInstance) Inspect() string {
	var out bytes.Buffer

	out.WriteString("<object:")
	out.WriteString(ci.Name.Value)
	out.WriteString(">(" + ci.Klass.Inspect() + ")")

	return out.String()
}
