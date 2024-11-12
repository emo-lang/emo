package parser

import (
	"fmt"
	"strconv"

	"github.com/emo-lang/emo/ast"
	"github.com/emo-lang/emo/lexer"
	"github.com/emo-lang/emo/token"
)

const (
	_ int = iota
	LOWEST
	EQAULS      // ==
	LESSGREATER // > or <
	SUM         // +
	PRODUCT     // *
	PRIFIX      // -X or !X
	CALL        // myFunction(X)
	INDEX       // array[index]
	DOT         // object.property
)

type (
	prefixParseFn func() ast.Expression
	infixParseFn  func(ast.Expression) ast.Expression
)

var precedences = map[token.TokenType]int{
	token.EQ:       EQAULS,
	token.NOT_EQ:   EQAULS,
	token.LT:       LESSGREATER,
	token.GT:       LESSGREATER,
	token.PLUS:     SUM,
	token.MINUS:    SUM,
	token.SLASH:    PRODUCT,
	token.ASTERISK: PRODUCT,
	token.LPAREN:   CALL,
	token.LBRACKET: INDEX,
	token.DOT:      DOT,
}

type Parser struct {
	l *lexer.Lexer

	errors []string

	curToken  token.Token
	peekToken token.Token

	prefixParseFns map[token.TokenType]prefixParseFn
	infixParseFns  map[token.TokenType]infixParseFn
}

func (p *Parser) peekPrecedence() int {
	if p, ok := precedences[p.peekToken.Type]; ok {
		return p
	}

	return LOWEST
}

func (p *Parser) curPrecendence() int {
	if p, ok := precedences[p.curToken.Type]; ok {
		return p
	}

	return LOWEST
}

func (p *Parser) registerPrefix(tokenType token.TokenType, fn prefixParseFn) {
	p.prefixParseFns[tokenType] = fn
}

func (p *Parser) registerInfix(tokenType token.TokenType, fn infixParseFn) {
	p.infixParseFns[tokenType] = fn
}

func New(l *lexer.Lexer) *Parser {
	p := &Parser{
		l:      l,
		errors: []string{},
	}

	p.prefixParseFns = make(map[token.TokenType]prefixParseFn)
	p.registerPrefix(token.IDENT, p.parseIdentifier)
	p.registerPrefix(token.INT, p.parseIntegerLiteral)
	p.registerPrefix(token.STRING, p.parseStringLiteral)

	p.registerPrefix(token.BANG, p.parsePrefixExpression)
	p.registerPrefix(token.MINUS, p.parsePrefixExpression)

	p.registerPrefix(token.TRUE, p.parseBoolean)
	p.registerPrefix(token.FALSE, p.parseBoolean)

	p.registerPrefix(token.LPAREN, p.parseGroupedExpression)
	p.registerPrefix(token.LBRACKET, p.parseArrayLiteral)
	p.registerPrefix(token.LBRACE, p.parseHashLiteral)

	p.registerPrefix(token.IF, p.parseIfExpression)
	p.registerPrefix(token.FUNCTION, p.parseFunctionExpression)
	p.registerPrefix(token.CLASS, p.parseClassExpression)

	p.infixParseFns = make(map[token.TokenType]infixParseFn)
	p.registerInfix(token.PLUS, p.parseInfixExpression)
	p.registerInfix(token.MINUS, p.parseInfixExpression)
	p.registerInfix(token.SLASH, p.parseInfixExpression)
	p.registerInfix(token.ASTERISK, p.parseInfixExpression)
	p.registerInfix(token.EQ, p.parseInfixExpression)
	p.registerInfix(token.NOT_EQ, p.parseInfixExpression)
	p.registerInfix(token.LT, p.parseInfixExpression)
	p.registerInfix(token.GT, p.parseInfixExpression)

	p.registerInfix(token.LPAREN, p.parseCallExpression)
	p.registerInfix(token.LBRACKET, p.parseIndexExpression)
	p.registerInfix(token.DOT, p.parseDotExpression)

	// Read two tokens, so curToken and peekToken are both set
	p.nextToken()
	p.nextToken()

	return p
}

func (p *Parser) parseHashLiteral() ast.Expression {
	hash := &ast.HashLiteral{Token: p.curToken}
	hash.Pairs = make(map[ast.Expression]ast.Expression)

	for !p.peekTokenIs(token.RBRACE) {
		p.nextToken()
		key := p.parseExpression(LOWEST)

		if !p.expectPeek(token.COLON) {
			return nil
		}

		p.nextToken()
		value := p.parseExpression(LOWEST)

		hash.Pairs[key] = value

		if !p.peekTokenIs(token.RBRACE) && !p.expectPeek(token.COMMA) {
			return nil
		}
	}

	if !p.expectPeek(token.RBRACE) {
		return nil
	}

	return hash
}

func (p *Parser) parseIndexExpression(left ast.Expression) ast.Expression {
	exp := &ast.IndexExpression{Token: p.curToken, Left: left}
	p.nextToken()
	exp.Index = p.parseExpression(LOWEST)

	if !p.expectPeek(token.RBRACKET) {
		return nil
	}

	return exp

}

func (p *Parser) parseDotExpression(left ast.Expression) ast.Expression {
	exp := &ast.DotExpression{Token: p.curToken, Left: left}

	p.nextToken()

	exp.Right = p.parseExpression(LOWEST)

	return exp
}

func (p *Parser) parseArrayLiteral() ast.Expression {
	array := &ast.ArrayLiteral{Token: p.curToken}
	array.Elements = p.parseExpressionList(token.RBRACKET)
	return array
}

func (p *Parser) parseExpressionList(end token.TokenType) []ast.Expression {
	list := []ast.Expression{}

	if p.peekTokenIs(end) {
		p.nextToken()
		return list
	}

	p.nextToken()
	list = append(list, p.parseExpression(LOWEST))

	for p.peekTokenIs(token.COMMA) {
		p.nextToken()
		p.nextToken()
		list = append(list, p.parseExpression(LOWEST))
	}

	if !p.expectPeek(end) {
		return nil
	}

	return list
}

func (p *Parser) parseStringLiteral() ast.Expression {
	return &ast.StringLiteral{Token: p.curToken, Value: p.curToken.Literal}
}

func (p *Parser) parseCallExpression(function ast.Expression) ast.Expression {
	exp := &ast.CallExpression{Token: p.curToken, Function: function}
	exp.Arguments = p.parseExpressionList(token.RPAREN)
	return exp
}

// parse the following code:
//
// 1. func add(a: Int, b: Int) -> Int { return a + b }
// 2. let fx = func(a: Int, b: Int) -> Int { return a + b }
// 3. func add(a: Int, b: Int) -> (Int, String) { return a + b, "ok" }
func (p *Parser) parseFunctionExpression() ast.Expression {
	if p.peekTokenIs(token.IDENT) {
		return p.parseFunctionDefinition()
	} else {
		return p.parseFunctionLiteral()
	}
}

func (p *Parser) parseClassExpression() ast.Expression {
	class := &ast.ClassExpression{Token: p.curToken}

	if !p.expectPeek(token.IDENT) {
		return nil
	}

	class.Name = &ast.Identifier{Token: p.curToken, Value: p.curToken.Literal}

	if !p.expectPeek(token.LBRACE) {
		return nil
	}

	class.Fields = make(map[string]*ast.ClassField)
	class.Methods = make(map[string]*ast.ClassMethod)

	for !p.curTokenIs(token.RBRACE) && !p.curTokenIs(token.EOF) {
		p.nextToken()

		if p.curTokenIs(token.PUBLIC) || p.curTokenIs(token.PRIVATE) {
			if p.peekTokenIs(token.NEWLINE) {
				p.nextToken()
			}

			if p.peekTokenIs(token.FUNCTION) {
				isPublic := p.curTokenIs(token.PUBLIC)
				p.nextToken()

				p.parseClassMethod(class, isPublic)
			} else if p.peekTokenIs(token.VAR) {
				isPublic := p.curTokenIs(token.PUBLIC)

				p.nextToken()
				p.parseClassField(class, isPublic)
			}
		}

		if p.curTokenIs(token.VAR) {
			p.parseClassField(class, false)
		} else if p.curTokenIs(token.FUNCTION) {
			p.parseClassMethod(class, true)
		}
	}

	return class
}

func (p *Parser) parseClassField(class *ast.ClassExpression, isPublic bool) {
	field := &ast.ClassField{}

	if !p.expectPeek(token.IDENT) {
		return
	}

	field.Field = p.parseTypedField()
	field.Public = isPublic

	class.Fields[field.Field.Name.Value] = field
}

func (p *Parser) parseClassMethod(class *ast.ClassExpression, isPublic bool) {
	method := &ast.ClassMethod{}

	fn := p.parseFunctionDefinition()

	if fn == nil {
		return
	}

	method.Function = fn
	method.Public = isPublic

	class.Methods[fn.Name.Value] = method

	if p.curTokenIs(token.RBRACE) {
		p.nextToken()
	}
}

func (p *Parser) parseTypedField() *ast.TypedField {
	field := &ast.TypedField{}

	field.Name = &ast.Identifier{Token: p.curToken, Value: p.curToken.Literal}

	if !p.expectPeek(token.COLON) {
		return nil
	}

	p.nextToken()

	field.Type = &ast.Identifier{Token: p.curToken, Value: p.curToken.Literal}

	return field
}

func (p *Parser) parseFunctionDefinition() *ast.FunctionDefinition {
	fn := &ast.FunctionDefinition{Token: p.curToken}

	if !p.expectPeek(token.IDENT) {
		return nil
	}

	fn.Name = &ast.Identifier{Token: p.curToken, Value: p.curToken.Literal}

	if !p.expectPeek(token.LPAREN) {
		return nil
	}

	fn.Parameters = p.parseFunctionParameters()

	// parse return type
	if p.peekTokenIs(token.ARROW) {
		fn.ReturnTypes = p.parseReturnTypes()
	} else {
		fn.ReturnTypes = []*ast.Identifier{}
	}

	// fmt.Printf("---> (after parse return type) name = %s, current token: %v; peek token: %v;\n", fn.Name, p.curToken, p.peekToken)

	if !p.expectPeek(token.LBRACE) {
		return nil
	}

	fn.Body = p.parseBlockStatement()

	return fn
}

func (p *Parser) parseFunctionLiteral() ast.Expression {
	lit := &ast.FunctionLiteral{Token: p.curToken}

	if !p.expectPeek(token.LPAREN) {
		return nil
	}

	lit.Parameters = p.parseFunctionParameters()

	// parse return type
	if p.peekTokenIs(token.ARROW) {
		lit.ReturnTypes = p.parseReturnTypes()
	} else {
		lit.ReturnTypes = []*ast.Identifier{}
	}

	if !p.expectPeek(token.LBRACE) {
		return nil
	}

	lit.Body = p.parseBlockStatement()

	return lit
}

func (p *Parser) parseFunctionParameters() []*ast.TypedField {
	identifiers := []*ast.TypedField{}

	if p.peekTokenIs(token.RPAREN) {
		p.nextToken()
		return identifiers
	}

	p.nextToken()

	var tf = p.parseTypedField()
	identifiers = append(identifiers, tf)

	// fmt.Println("current token after parse one params: ", p.curToken)
	// fmt.Println("current token after parse one params, peek token: ", p.peekToken)
	for p.peekTokenIs(token.COMMA) {
		p.nextToken()
		p.nextToken()

		ident := p.parseTypedField()
		identifiers = append(identifiers, ident)
	}

	if !p.expectPeek(token.RPAREN) {
		return nil
	}

	return identifiers
}

func (p *Parser) parseParameter() *ast.Identifier {
	fmt.Println("parse one parameter: ", p.curToken)

	ident := &ast.Identifier{Token: p.curToken, Value: p.curToken.Literal}

	if !p.expectPeek(token.COLON) {
		return nil
	}

	return ident
}

func (p *Parser) parseReturnTypes() []*ast.Identifier {
	identifiers := []*ast.Identifier{}

	// skip: `->`
	p.nextToken()

	if p.curTokenIs(token.LPAREN) {
		// parsing: (Foo, Bar)
		p.nextToken()

		for !p.peekTokenIs(token.RPAREN) {
			p.nextToken()

			ident := &ast.Identifier{Token: p.curToken, Value: p.curToken.Literal}
			identifiers = append(identifiers, ident)

			if p.peekTokenIs(token.COMMA) {
				p.nextToken()
			}
		}

		return identifiers
	}

	// if not starting with `(`, then it should be a single type
	ident := &ast.Identifier{Token: p.curToken, Value: p.curToken.Literal}
	identifiers = append(identifiers, ident)

	p.nextToken()

	return identifiers
}

func (p *Parser) parseIfExpression() ast.Expression {
	expression := ast.IfExpression{Token: p.curToken}

	p.nextToken()
	expression.Condition = p.parseExpression(LOWEST)

	if !p.expectPeek(token.LBRACE) {
		return nil
	}

	expression.Consequence = p.parseBlockStatement()

	if p.peekTokenIs(token.ELSE) {
		p.nextToken()

		if !p.expectPeek(token.LBRACE) {
			return nil
		}

		expression.Alternative = p.parseBlockStatement()
	}

	return &expression
}

func (p *Parser) parseBlockStatement() *ast.BlockStatement {
	block := &ast.BlockStatement{Token: p.curToken}
	block.Statements = []ast.Statement{}

	p.nextToken()

	for !p.curTokenIs(token.RBRACE) && !p.curTokenIs(token.EOF) {
		stmt := p.parseStatement()
		if stmt != nil {
			block.Statements = append(block.Statements, stmt)
		}

		p.nextToken()
	}

	return block
}

func (p *Parser) parseGroupedExpression() ast.Expression {
	p.nextToken()

	exp := p.parseExpression(LOWEST)

	if !p.expectPeek(token.RPAREN) {
		return nil
	}

	return exp
}

func (p *Parser) parseBoolean() ast.Expression {
	return &ast.Boolean{Token: p.curToken, Value: p.curTokenIs(token.TRUE)}
}

func (p *Parser) parseInfixExpression(left ast.Expression) ast.Expression {
	expression := &ast.InfixExpression{
		Token:    p.curToken,
		Operator: p.curToken.Literal,
		Left:     left,
	}

	precedence := p.curPrecendence()
	p.nextToken()
	expression.Right = p.parseExpression(precedence)

	return expression
}

func (p *Parser) parsePrefixExpression() ast.Expression {
	expression := &ast.PrefixExpression{
		Token:    p.curToken,
		Operator: p.curToken.Literal,
	}

	p.nextToken()

	expression.Right = p.parseExpression(PRIFIX)

	return expression
}

func (p *Parser) noPrefixParseFnError(t token.TokenType) {
	msg := fmt.Sprintf("no prefix parse function for %s found", t)
	p.errors = append(p.errors, msg)
}

func (p *Parser) parseIdentifier() ast.Expression {
	return &ast.Identifier{Token: p.curToken, Value: p.curToken.Literal}
}

func (p *Parser) parseIntegerLiteral() ast.Expression {
	lit := &ast.IntegerLiteral{Token: p.curToken}

	value, err := strconv.ParseInt(p.curToken.Literal, 0, 64)
	if err != nil {
		msg := fmt.Sprintf("could not parse %q as integer", p.curToken.Literal)
		p.errors = append(p.errors, msg)
		return nil
	}

	lit.Value = value

	return lit
}

func (p *Parser) Errors() []string {
	return p.errors
}

func (p *Parser) peekError(t token.TokenType) {
	msg := fmt.Sprintf("expected next token to be %s, got %+v instead",
		t, p.peekToken)

	p.errors = append(p.errors, msg)
}

func (p *Parser) nextToken() {
	p.curToken = p.peekToken
	p.peekToken = p.l.NextToken()
}

func (p *Parser) parseExpression(precedence int) ast.Expression {

	prefix := p.prefixParseFns[p.curToken.Type]
	if prefix == nil {
		p.noPrefixParseFnError(p.curToken.Type)
		return nil
	}

	leftExp := prefix()

	for !p.peekTokenIs(token.NEWLINE) && precedence < p.peekPrecedence() {
		infix := p.infixParseFns[p.peekToken.Type]
		if infix == nil {
			return leftExp
		}

		p.nextToken()

		leftExp = infix(leftExp)
	}

	return leftExp
}

func (p *Parser) curTokenIs(t token.TokenType) bool {
	return p.curToken.Type == t
}

func (p *Parser) peekTokenIs(t token.TokenType) bool {
	// if t == token.NEWLINE {
	// 	fmt.Println("expected peek token to be <newline>, got: ", p.peekToken)
	// } else {
	// 	fmt.Println("current peek token: ", p.peekToken, "expected: ", t)
	// }

	return p.peekToken.Type == t
}

func (p *Parser) expectPeek(t token.TokenType) bool {
	if p.peekTokenIs(t) {
		p.nextToken()
		return true
	} else {
		p.peekError(t)
		return false
	}
}
