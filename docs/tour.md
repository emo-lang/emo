# A tour of Emo

This tour is a program you can read and run. Every Emo block marked `run`
is compiled to Wasm and executed when the documentation is checked; the
block after each program is exactly what it prints. Nothing here is
illustrative pseudocode.

If you have ten minutes, read the quick start and the first two chapters.
If you have an afternoon, read the whole thing and type the examples.

## 0 · Quick start

A program in Emo is a sequence of declarations and statements, read top to
bottom. Classes are value types, functions are plain `def`s, and a cart is
just an array of items:

```emo run id=quickstart
class Item {
  def init(name String, price Int64) {
    self.name = name
    self.price = price
  }
}

def total(items Array[Item]) Int64 {
  var sum = 0
  for var i = 0; i < items.length(); i = i + 1 {
    sum = sum + items[i].price
  }
  return sum
}

const cart = [Item.new(name: "tea", price: 12), Item.new(name: "cake", price: 30)]
println("${cart.length()} items, ${total(cart)} yuan")
```

```output
2 items, 42 yuan
```

Everything in that program is ordinary syntax: bindings are `const` or
`var`, a call has parentheses, a `for` loop has three clauses, and
`return` is written out. Emo has no implicit last-expression return, no
inheritance, and no template language.

## 1 · Values and bindings

`const` binds a value once; `var` binds a mutable one, scoped to its block.
Numbers, strings, and booleans are ordinary values, and `${...}` inside a
string runs any expression:

```emo run id=values
const name = "Emo"
var visits = 3
visits = visits + 1
const ratio = 2.5
const flag = visits > 3
println("${name}: ${visits} visits, ratio ${ratio}, flag ${flag}")
println("7 / 2 = ${7 / 2}, 7 % 2 = ${7 % 2}")
println("1 + 2 * 3 = ${1 + 2 * 3}")
```

```output
Emo: 4 visits, ratio 2.5, flag true
7 / 2 = 3, 7 % 2 = 1
1 + 2 * 3 = 7
```

Strings are UTF-8 byte sequences, and a `Char` is one code point. String
length counts bytes; `chars()` walks code points:

```emo run id=values-strings
const greeting = "hello"
println("${greeting}, world")
println(greeting.length())
println("a" + "b")
const c = '世'
println(c)
println(c.to_int64())
```

```output
hello, world
5
ab
世
19990
```

## 2 · Control flow

`if` has one statement shape, with an optional `else`; there is no
`else if`, and a further test is a visibly nested `if`. The one-line form
is an expression that picks a value:

```emo run id=control-if
const n = 42
if n % 2 == 0 {
  println("${n} is even")
} else {
  println("${n} is odd")
}
const size = if n >= 40 { "big" } else { "small" }
println(size)
```

```output
42 is even
big
```

`for` takes three `;`-separated clauses and binds its index in the header.
`while` tests a condition. `break` leaves the nearest loop and `continue`
skips to the next iteration, running a `for`'s post clause first:

```emo run id=control-loops
for var i = 1; i <= 3; i = i + 1 {
  println("i = ${i}")
}

var n = 3
while n > 0 {
  println("countdown ${n}")
  n = n - 1
}

for var j = 0; j < 6; j = j + 1 {
  if j == 1 {
    continue
  }
  if j == 4 {
    break
  }
  println(j)
}
```

```output
i = 1
i = 2
i = 3
countdown 3
countdown 2
countdown 1
0
2
3
```

## 3 · Functions and blocks

`def` declares a function or a method. Parameter types are explicit; the
return type is written after the parameter list, and a function with a
declared return type must return on every path. Arguments can be passed by
position or by name — named arguments keep the parameter order:

```emo run id=functions-def
def area(width Int64, height Int64) Int64 {
  return width * height
}

def is_wide?(w Int64) Bool {
  return w > 100
}

println(area(3, 4))
println(area(width: 2, height: 5))
println(is_wide?(120))
```

```output
12
10
true
```

An arrow block is an anonymous function, and a call may take a trailing
block as its final argument. A function that receives a block declares the
parameter as `Block` and calls it like a function:

```emo run id=functions-blocks
const double = -> (n Int64) { return n * 2 }
println(double(21))

def apply_twice(n Int64, f Block) Int64 {
  return f(f(n))
}
println(apply_twice(3, double))

def each(xs Array[Int64], f Block) {
  for var i = 0; i < xs.length(); i = i + 1 {
    f(xs[i])
  }
}

each([1, 2, 3]) -> (v Int64) {
  println(v * 10)
}
```

```output
42
12
10
20
30
```

Functions can return several values at once as a tuple, and a binding
pattern destructures it:

```emo run id=functions-tuples
def min_max(xs Array[Int64]) (Int64, Int64) {
  var lo = xs[0]
  var hi = xs[0]
  for var i = 1; i < xs.length(); i = i + 1 {
    if xs[i] < lo {
      lo = xs[i]
    }
    if xs[i] > hi {
      hi = xs[i]
    }
  }
  return (lo, hi)
}

const (lo, hi) = min_max([4, 1, 9, 3])
println("min ${lo}, max ${hi}")
```

```output
min 1, max 9
```

## 4 · Classes and interfaces

`class` is the only notation for user-defined types. Fields come into
existence through `self.x = ...` inside `init`, and nowhere else — a class
is an immutable value type, and instances with equal content are `==`:

```emo run id=objects-values
class Point {
  def init(x Int64, y Int64) {
    self.x = x
    self.y = y
  }

  def shifted(dx Int64, dy Int64) Point {
    return Point.new(x: self.x + dx, y: self.y + dy)
  }
}

const p = Point.new(x: 1, y: 2)
const q = p.shifted(3, 4)
println(p)
println(q)
println(p == Point.new(x: 1, y: 2))
```

```output
#Point(x: 1, y: 2)
#Point(x: 4, y: 6)
true
```

Methods end in `?` when they answer a Bool. A method that "changes" a
value returns a new instance; the original is untouched:

```emo run id=objects-methods
class Ticket {
  def init(price Int64, sold Bool) {
    self.price = price
    self.sold = sold
  }

  def sell() Ticket {
    return Ticket.new(price: self.price, sold: true)
  }

  def available?() Bool {
    return !self.sold
  }

  def describe() String {
    if self.available?() {
      return "ticket ${self.price}: available"
    }
    return "ticket ${self.price}: sold"
  }
}

const t = Ticket.new(price: 80, sold: false)
println(t.describe())
println(t.sell().describe())
println(t.available?())
```

```output
ticket 80: available
ticket 80: sold
true
```

An `interface` declares method signatures, and satisfaction is structural —
no `implements` declaration, no inheritance. The interface belongs to the
consumer: a class never needs to know it exists:

```emo run id=objects-interfaces
interface Greeter {
  def greet() String
}

class English {
  def greet() String {
    return "Hello"
  }
}

class Chinese {
  def greet() String {
    return "你好"
  }
}

def welcome(g Greeter) String {
  return g.greet() + "!"
}

println(welcome(English.new()))
println(welcome(Chinese.new()))
```

```output
Hello!
你好!
```

## 5 · Enums and `case`

An `enum` is a closed set of named values. `case` matches a value against
patterns; branches are `pattern then { ... }`, the first match wins, and
enum matching must cover every member:

```emo run id=enums-color
enum Color {
  red,
  green,
  blue
}

def name(c Color) String {
  case c {
    Color.red then { return "red" }
    Color.green then { return "green" }
    Color.blue then { return "blue" }
  }
}

println(name(Color.red))
println(name(Color.blue))
```

```output
red
blue
```

A branch may carry a `when` guard, and a tuple scrutinee matches several
facts at once. `_` matches anything:

```emo run id=enums-case
def mood(n Int64) String {
  case n {
    0 then { return "zero" }
    _ when n < 0 then { return "negative" }
    _ then { return "positive" }
  }
}

def classify(n Int64) String {
  case (n % 2, n > 10) {
    (0, true) then { return "even and big" }
    (0, false) then { return "even and small" }
    (_, _) then { return "odd" }
  }
}

println(mood(0))
println(mood(-5))
println(mood(7))
println(classify(12))
println(classify(2))
println(classify(9))
```

```output
zero
negative
positive
even and big
even and small
odd
```

## 6 · Collections

Arrays are fixed-length values written `[a, b, c]`; `ArrayBuilder` grows
one by pushing and hands out an array with `to_array()`:

```emo run id=collections-arrays
const xs = [3, 1, 4, 1, 5]
println(xs)
println(xs.length())
println(xs[0] + xs[4])

const ys = ArrayBuilder.new()
ys.push(2)
ys.push(7)
println(ys.to_array())
println(ys.length())
```

```output
[3, 1, 4, 1, 5]
5
8
[2, 7]
2
```

A `Map` is mutable and insertion-ordered, written `{ "key": value }`.
`get` reads a key, `set` inserts or replaces and returns the map, and
`keys()`/`values()` answer in insertion order:

```emo run id=collections-maps
const ages = { "alice": 30, "bob": 25 }
ages.set("bob", 26)
println(ages)
println(ages.get("bob"))
println(ages.keys())
println(ages.has("carol"))
```

```output
{"alice": 30, "bob": 26}
26
[alice, bob]
false
```

## 7 · Errors are values

A call that can fail for data reasons answers a tuple: `(R.ok, value)` or
`(R.error, reason)`. `R` is the built-in result enum; match it with
`case`, and the compiler keeps the two arms in view:

```emo run id=errors-matching
def parse_flag(raw String) (R, String) {
  if raw == "on" {
    return (R.ok, "flag is on")
  }
  return (R.error, "flag: expected `on`")
}

case parse_flag("on") {
  (R.ok, value) then { println(value) }
  (R.error, why) then { println("read failed: ${why}") }
}

case parse_flag("off") {
  (R.ok, value) then { println(value) }
  (R.error, why) then { println("read failed: ${why}") }
}
```

```output
flag is on
read failed: flag: expected `on`
```

A binding pattern asserts the shape and binds the payload. A pattern that
does not match is a runtime error, so use it when the caller already knows
the call cannot fail:

```emo run id=errors-binding
def half(n Int64) (R, Int64) {
  if n % 2 != 0 {
    return (R.error, "half: odd input")
  }
  return (R.ok, n / 2)
}

const (R.ok, value) = half(8)
println(value)
```

```output
4
```

A violation — broken caller discipline, not data — is a `raise`. `:raise`
borrows the keyword and rewrites to the exception constructor. This block
is not executed: a raise ends the process, so there is no passing run to
show:

```emo no-run id=errors-raise
def check(n Int64) Int64 {
  if n < 0 {
    :raise "check: negative input"
  }
  return n
}
```

## 8 · Modules and packages

A file is a module, and a directory is a module path. A package is a
module prefix: `require "json"` brings the standard library's JSON
package into scope, and the manifest pins the version. There is no
install step — the compiler carries the standard library inside it.

```emo run id=modules-json-decode deps=json
require "json"

const (R.ok, doc) = json.decode("{\"name\": \"tea\", \"price\": 12}")
if doc.is(json.JsonObject) {
  println(doc.get("name").as_string())
  println(doc.get("price").as_int())
}
```

```output
tea
12
```

The same package builds documents as well as reading them. Objects and
arrays are built from explicit pairs and arrays, and `encode` writes the
compact form:

```emo run id=modules-json-build deps=json
require "json"

const order = json.object([
  ("id", json.int64(7)),
  ("tags", json.array([json.string("fresh"), json.string("hot")]))
])
println(json.encode(order))
```

```output
{"id":7,"tags":["fresh","hot"]}
```

## 9 · Processes

A process is cheap: `do call()` starts one and answers its pid. A message
is sent with `<-`, and `receive` matches the message at the head of the
mailbox against its branches. The language also offers **selective**
receive — a guard (`n when n > 3`) or a pattern the head does not match
lets the mailbox be scanned, with the non-matching message staying queued —
but the Wasm backend in this tree dispatches the head only, so the runnable
blocks below stay with FIFO receives.

```emo run id=processes-pingpong
def worker(boss Pid, n Int64) {
  boss <- n * 2
}

const me = self_pid()
do worker(me, 21)
receive {
  answer then { println(answer) }
}
```

```output
42
```

Messages queue in the order they arrive, and each `receive` takes the head.
On Wasm a `receive` must be the last statement of its body, so a second take
is its own function:

```emo run id=processes-queue
def first(boss Pid) {
  boss <- "first"
}

def second(boss Pid) {
  boss <- "second"
}

def take() {
  receive {
    msg then { println(msg) }
  }
}

const me = self_pid()
do first(me)
do second(me)
take()
take()
```

```output
first
second
```

## 10 · A small business slice

The pieces meet in one program: JSON from the outside world, a class for
the domain value, `(R, …)` for data that can be wrong, a `Map` for the
report, and integer arithmetic for money. It decodes an order, validates
each line, totals by category, and adds tax — the shape of a small service:

```emo run id=business deps=json
require "json"

class Line {
  def init(name String, category String, price Int64, qty Int64) {
    self.name = name
    self.category = category
    self.price = price
    self.qty = qty
  }

  def subtotal() Int64 {
    return self.price * self.qty
  }
}

def parse_line(item json.Json) (R, Line) {
  if item.is(json.JsonObject) {
    const name = item.get("name").as_string()
    const category = item.get("category").as_string()
    const price = item.get("price").as_int()
    const qty = item.get("qty").as_int()
    if qty <= 0 {
      return (R.error, "order: ${name} has no quantity")
    }
    return (R.ok, Line.new(name: name, category: category, price: price, qty: qty))
  }
  return (R.error, "order: line is not an object")
}

const text = "{\"tax\": 10, \"lines\": [{\"name\": \"tea\", \"category\": \"drink\", \"price\": 12, \"qty\": 2}, {\"name\": \"cake\", \"category\": \"food\", \"price\": 30, \"qty\": 1}, {\"name\": \"coffee\", \"category\": \"drink\", \"price\": 20, \"qty\": 1}]}"
const (R.ok, doc) = json.decode(text)
if doc.is(json.JsonObject) {
  const lines = doc.get("lines")
  if lines.is(json.JsonArray) {
    const totals = { "drink": 0, "food": 0 }
    const items = lines.items()
    for var i = 0; i < items.length(); i = i + 1 {
      case parse_line(items[i]) {
        (R.ok, line) then {
          const category = line.category
          if totals.has(category) {
            totals.set(category, totals.get(category) + line.subtotal())
          } else {
            totals.set(category, line.subtotal())
          }
        }
        (R.error, why) then {
          println("skip: ${why}")
        }
      }
    }
    var net = 0
    const categories = totals.keys()
    for var i = 0; i < categories.length(); i = i + 1 {
      net = net + totals.get(categories[i])
    }
    const tax = net * doc.get("tax").as_int() / 100
    println(totals)
    println("net ${net}, tax ${tax}, total ${net + tax}")
  }
}
```

```output
{"drink": 44, "food": 30}
net 74, tax 7, total 81
```

The program never asks "could this be null": a value is a `Json`, the
narrowing `is()` calls prove its shape, and a failed parse is a value the
`case` handles. The domain class carries the arithmetic, and the `Map`
keeps the report in the order categories were first seen.

## 11 · Where next

You now know the shape of the language: explicit calls, `const`/`var`,
classes as immutable value types, structural interfaces, `case` with
guards, collections, `(R, …)` errors, packages, and processes.

The next reads:

- [`examples/language_tour/`](../examples/language_tour/) — one longer
  program that runs on every target, with a golden output.
- [`docs/intro/syntax.md`](intro/syntax.md) — the complete syntax
  reference, including sugar (`:chain`, `:foreach`, `:when`) and the
  naming rules.
- [`docs/intro/type-system.md`](intro/type-system.md) — gradual typing,
  width-explicit numbers, and narrowing.
- [`docs/stdlib.md`](stdlib.md) — the standard library: JSON, YAML,
  TOML, HTTP, SQL, crypto, plotting, and more.
- [`docs/intro/testing.md`](intro/testing.md) — `emo test` and the
  `expect_*` assertions (interpreter only, which is why this tour does
  not run them).
- [`docs/intro/concurrency.md`](intro/concurrency.md) — processes,
  message passing, and the scheduler.

Beyond the language, EmoUI builds interfaces from the same ordinary
syntax, EmoOS (and its desktop) takes the same code to bare metal, and the
playground runs Emo in a browser tab. Start with the
[project README](../README.md) for the map.
