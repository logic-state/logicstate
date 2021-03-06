import tables, strformat, strutils, sugar
import graph, utils


type
  GeneratorError* = object of CatchableError

  Format* {.pure.} = enum
    TypescriptInterface, TypescriptCode, JavascriptCode
    WASM, WAT,
    GDScript, Python,
    RustTrait, RustCode,
    LLVMBytecode, LLVMIR

  Implementation* {.pure.} = enum
    TypeState, StatePattern, Record, ConditionalStatement

# TODO: use template engine instead of doing it procedurally

proc gd(machine: StateDiagram): string =
  var
    context = "\nclass Context:" &
      "\nvar state: State\n".indent(1, "\t")
    astate = "\nclass State extends Node:" &
      "\nvar context: Context\n".indent(1, "\t") &
      "\nfunc _init(ctx: Context = null): context = ctx\n".indent(1, "\t")

  for trigger in machine.events:
    let fn = trigger.snake_case
    context &= (&"\nfunc {fn}(): state.{fn}()").indent(1, "\t")
    astate &= (&"\nfunc {fn}(): pass").indent(1, "\t")

  for current, transition in machine.traverse(skipTransientState = true):
    result &= &"\nclass {current.PascalCase} extends State:"
    if transition.len == 0:
      result &= " pass"
    else:
      for trigger, next in transition.pairs:
        result &= (&"\nfunc {trigger.snake_case}():").indent(1, "\t") & '\n' &
        (&"""# side-effect
        context.state = {next.PascalCase}.new(context)
        """).strip.unindent.indent(2, "\t") & '\n'
    result.stripLineEnd; result.add("\n\n")

  result ="extends Node\n" & context & "\n\n" & astate & "\n\n" & result
  result &= "\nfunc _init(state: State) -> Context:\n" &
  """
  let ctx = Context.new()
  state.context = ctx
  ctx.state = state
  return ctx
  """.strip.unindent.indent(1, "\t")


proc rsTrait(machine: StateDiagram): string =
  let sp = 4 # indentation
  for current, transition in machine.traverse:
    result &= &"pub trait {current.PascalCase} {{"
    for trigger, next in transition.pairs:
      if trigger == "": continue
      result &= (&"\nfn {trigger.snake_case}<T: {next.PascalCase}>(self) -> T;").indent(sp)
    result.add("\n}\n\n")
  result.strip

proc rs(machine: StateDiagram, implementation: Implementation): string =
  let sp = 4 # indentation
  case implementation:

  of TypeState:
    for state in machine.states:
      result &= &"pub struct {($state).PascalCase};\n"
    for current, transition in machine.traverse:
      result &= &"\nimpl {current.PascalCase} {{"
      for trigger, next in transition.pairs:
        if trigger == "": continue
        result &= (&"\npub fn {trigger.snake_case}(self) -> {next.PascalCase} {{")
          .indent(sp)
        result &= (&"\ntodo!(\"side-effect\");" &
                  &"\n{next.PascalCase}"
          ).indent(2*sp)
        result &= "\n}".indent(sp)
      result.add("\n}\n")

  of ConditionalStatement:
    result = "pub enum State {"
    for state in machine.states:
      result &= (&"\n{($state).PascalCase},").indent(sp)
    result &= "\n}\n" & "\nimpl State {"
    for trigger, transition in machine.edges:
      result &= (&"\npub fn {trigger.snake_case}(&self) -> &State {{").indent(sp) &
                  "\nmatch self {".indent(2*sp)
      for current, next in transition.pairs:
        if trigger == "": continue
        result &= (&"\nState::{current.PascalCase} => &State::{next.PascalCase},")
          .indent(3*sp)
      result &= "\n_ => self".indent(3*sp) & "\n}".indent(2*sp) & "\n}".indent(sp)
    result.add("\n}\n\n")

  else:
    raise newException(GeneratorError, &"can't generate RustCode as {implementation}")
  result.strip


proc tsInterface(machine: StateDiagram, implementation: Implementation): string =
  for current, transition in machine.traverse:
    result &= &"export interface {current.PascalCase} {{"
    for trigger, next in transition.pairs:
      if trigger == "": continue
      case implementation:
      of TypeState:
        result &= (&"\n{trigger.camelCase}(): {next.PascalCase}").indent(2)
      of Record:
        result &= (&"\nreadonly {trigger.camelCase}: {next.PascalCase}").indent(2)
      else:
        raise newException(GeneratorError, &"can't generate RustCode as {implementation}")
    result.add("\n}\n\n")
  result.strip

proc jsCode(machine: StateDiagram,
            format: Format,
            implementation: Implementation): string {.raises:
              [GeneratorError, ValueError].} =
  let typescript = format == TypescriptCode
  case implementation:

  of Record:
    for current, transition in machine.traverse:
      result &= &"export class {current.PascalCase} {{"
      for trigger, next in transition.pairs:
        if trigger == "": continue
        let mut = if typescript: "readonly " else: ""
        result &= (&"\n{mut}{trigger.camelCase} = new {next.PascalCase}").indent(2)
      result.add("\n}\n\n")

  of TypeState:
    for current, transition in machine.traverse:
      result &= &"export class {current.PascalCase} {{"
      for trigger, next in transition.pairs:
        if trigger == "": continue
        let retTy = if typescript: &": {next.PascalCase}" else: ""
        result &= (&"\nget {trigger.camelCase}(){retTy} {{").indent(2)
        result &= (&"\n// side-effect" &
                  &"\nreturn new {next.PascalCase}"
          ).indent(4)
        result &= "\n}".indent(2)
      result.add("\n}\n\n")

  of StatePattern:
    let `!` = if typescript: "!" else: ""
    var
      ievent = "interface IEvent {"
      context = "class Context " &
        (if typescript:
          "implements IEvent {\n" &
          "constructor(public state?: State) {}\n"
          .indent(2) else: "{")
      astate = "class State " &
        (if typescript:
          "implements IEvent {\n" &
          "constructor(public context?: Context) {}\n"
          .indent(2) else:
          "{\n" & "constructor(ctx) { this.context = ctx }\n"
          .indent(2))
    if typescript: astate = "abstract " & astate

    for trigger in machine.events:
      let fn = trigger.camelCase
      ievent &= (&"\n{fn}(): void").indent(2)
      context &= (&"\n{fn}() {{ this.state{`!`}.{fn}() }}").indent(2)
      astate &=
        (if typescript: &"\nabstract {fn}(): void" else: &"\n{fn}() {{}}")
        .indent(2)
    ievent.add("\n}\n"); context.add("\n}\n"); astate.add("\n}\n")

    for current, transition in machine.traverse(skipTransientState = true):
      result &= &"export class {current.PascalCase} extends State {{\n"

      proc genHandler(trigger: string): string =
        if trigger in transition:
          let next = transition[trigger]
          result &= (&"{trigger.camelCase}() {{").indent(2) & '\n' &
          (&"""// side-effect
          this.context{`!`}.state = new {next.PascalCase}(this.context)
          """).strip.unindent.indent(4) & "\n}\n".indent(2) & '\n'
        else:
          result &= (&"{trigger.camelCase}() {{}}\n").indent(2) & '\n'

      if typescript:
        for trigger in machine.events: result &= genHandler(trigger)
      else:
        for trigger in transition.keys: result &= genHandler(trigger)

      result = result.strip; result.add("\n}\n\n")
    result = context & '\n' & astate & '\n' & result
    if typescript: result = ievent & '\n' & result
    result &= "export function " &
    (if typescript: "init(state: State): Context" else: "init(state)") &
    " {\n" & """
    let ctx = new Context
    state.context = ctx
    ctx.state = state
    return ctx
    """.strip.unindent.indent(2) & "\n}"

  else: raise newException(GeneratorError,
        &"can't generate {format} as {implementation}")
  result.strip


proc generate*(machine: StateDiagram,
               format: Format,
               into: Implementation,
              ): string {.raises:
                [GeneratorError, ValueError].} =
  assert machine.diagram == TransitionTable
  let errMsg = &"can't generate {format} as {into}"

  case format:
  of RustCode: machine.rs(into)
  of RustTrait: machine.rsTrait
  of TypescriptInterface: machine.tsInterface(into)
  of JavascriptCode, TypescriptCode: machine.jsCode(format, into)
  of GDScript: machine.gd
  else: raise newException(GeneratorError, errMsg)
