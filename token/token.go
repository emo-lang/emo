package token

import "fmt"

type TokenType string

type Token struct {
	Type    TokenType
	Literal string
}

func (t Token) String() string {
	if t.Type == NEWLINE {
		return "<NEWLINE>"
	}

	return fmt.Sprintf("(%+v):<%+v>", t.Type, t.Literal)
}

const (
	ILLEGAL = "ILLEGAL"
	EOF     = "EOF"

	// Identifiers + literals
	IDENT  = "IDENT"
	INT    = "INT"
	STRING = "STRING"

	ASSIGN   = "="
	PLUS     = "+"
	MINUS    = "-"
	ASTERISK = "*"
	SLASH    = "/"
	BANG     = "!"

	DOT       = "."
	COMMA     = ","
	SEMICOLON = ";"
	COLON     = ":"

	NEWLINE = "\n"

	LPAREN   = "("
	RPAREN   = ")"
	LBRACE   = "{"
	RBRACE   = "}"
	LBRACKET = "["
	RBRACKET = "]"

	LT     = "<"
	GT     = ">"
	EQ     = "=="
	NOT_EQ = "!="

	ARROW = "->"

	IMPORT   = "IMPORT"
	FUNCTION = "FUNCTION"
	LET      = "LET"
	VAR      = "VAR"
	IF       = "IF"
	ELSE     = "ELSE"
	RETURN   = "RETURN"
	TRUE     = "TRUE"
	FALSE    = "FALSE"

	CLASS = "CLASS"
	SELF  = "SELF"
	ENUM  = "ENUM"

	PUBLIC  = "PUBLIC"
	PRIVATE = "PRIVATE"
)

var keywords = map[string]TokenType{
	"import":  IMPORT,
	"func":    FUNCTION,
	"let":     LET,
	"var":     VAR,
	"if":      IF,
	"else":    ELSE,
	"return":  RETURN,
	"true":    TRUE,
	"false":   FALSE,
	"class":   CLASS,
	"self":    SELF,
	"enum":    ENUM,
	"public":  PUBLIC,
	"private": PRIVATE,
}

func LookupKeyword(ident string) TokenType {
	if tok, ok := keywords[ident]; ok {
		return tok
	}
	return IDENT
}
