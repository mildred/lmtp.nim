import asyncdispatch, strformat, options, strutils

const CRLF* = "\c\L"

type
  CommandKind* = enum
    CommandNone
    CommandConnect
    CommandLHLO      = "LHLO"
    CommandQUIT      = "QUIT"
    CommandMAIL_FROM = "MAIL FROM"
    CommandRCPT_TO   = "RCPT TO"
    CommandDATA      = "DATA"

  Command* = ref object
    command*: CommandKind
    cmd_name*: string
    args*: string

  Response* = ref object
    code*: string
    text*: string
    content*: Option[string]
    quit*: bool
    expect_body*: bool
    expect_line*: bool
    starttls*: bool

  Connection* = ref object
    read*:     proc(): Future[Option[string]]
    ## Read a line and return it with end line markers removed
    ## Returns none(string) at end of stream

    write*:    proc(line: string): Future[void]
    ## Write a line to the client, the passed string must contain the CRLF end
    ## line marker

    close*:    proc()

    starttls*: proc()
    ## Start TLS handshake as server

    process*:  proc(cmd: Command, body: Option[string]): Future[Response] {.async.}

  ReplyError* = object of IOError

proc split_command(line: string, sep: string, cmd, args: var string) =
  let splitted = line.split(sep, 1)
  if splitted.len < 1:
    cmd  = ""
    args = ""
  elif splitted.len == 1:
    cmd  = splitted[0].toUpper()
    args = ""
  else:
    cmd  = splitted[0].toUpper()
    args = splitted[1]

proc split_command(line: string, n: int, cmd, args: var string) =
  let splitted = line.splitWhitespace(n)
  if splitted.len < n:
    cmd  = ""
    args = ""
  elif splitted.len == n:
    cmd  = splitted.join(" ").toUpper()
    args = ""
  else:
    cmd  = splitted[0..n-1].join(" ").toUpper()
    args = splitted[n]

proc parse_command*(line: string): Command =
  var name, args: string
  split_command(line, ":", name, args)
  var cmd = parseEnum[CommandKind](name, CommandNone)

  if cmd != CommandNone:
    return Command(command: cmd, cmd_name: name, args: args)

  split_command(line, 2, name, args)
  cmd = parseEnum[CommandKind](name, CommandNone)

  if cmd != CommandNone:
    return Command(command: cmd, cmd_name: name, args: args)

  split_command(line, 1, name, args)
  cmd = parseEnum[CommandKind](name, CommandNone)
  return Command(command: cmd, cmd_name: name, args: args)

proc quit_excpt(conn: Connection, msg: string) {.async.} =
  await conn.write("QUIT")
  raise newException(ReplyError, msg)

proc check_reply*(conn: Connection, reply: string, multiline: bool = true) {.async.} =
  while true:
    let line = await conn.read()
    if line.is_none:
      await quit_excpt(conn, "Expected " & reply & " reply, got nothing")
    if not line.get.startsWith(reply):
      await quit_excpt(conn, "Expected " & reply & " reply, got: " & line.get)
    if line.get.starts_with(&"{reply}-"):
      continue
    break

proc send*(res: Response, conn: Connection) {.async.} =
  if res.content.is_none:
    await conn.write(&"{res.code} {res.text}{CRLF}")
  else:
    var last_line: string = res.text
    var content = res.content.get
    stripLineEnd(content)
    for line in content.split(CRLF):
      await conn.write(&"{res.code}-{last_line}{CRLF}")
      last_line = line
    await conn.write(&"{res.code} {last_line}{CRLF}")

proc handle_protocol*(conn: Connection) {.async.} =
  let initial_cmd = Command(command: CommandConnect)
  let initial_response = await conn.process(initial_cmd, none(string))
  await initial_response.send(conn)
  while true:
    let line = await conn.read()
    if line.is_none:
      break
    let command = parse_command(line.get)
    var response = await conn.process(command, none(string))
    await response.send(conn)
    while response.expect_body or response.expect_line:
      var data = ""
      while true:
        var dataline = await conn.read()
        if dataline.is_none:
          break
        elif response.expect_line:
          data = dataline.get
          break
        elif dataline.get == ".":
          break
        elif dataline.get == "":
          data = data & CRLF
        elif dataline.get[0] == '.':
          data = data & dataline.get[1..^1] & CRLF
        else:
          data = data & dataline.get & CRLF
      response = await conn.process(command, some data)
      await response.send(conn)
    if response.quit:
      break
    when defined(ssl):
      if response.starttls:
        conn.starttls()

proc response_text*(code: string): string =
  case code
  of "250": result = "OK"
  of "251": result = "User not local; will forward"
  of "421": result = "Service not available, closing transmission channel"
  of "450": result = "Requested mail action not taken: mailbox unavailable"
  of "451": result = "Requested action aborted: local error in processing"
  of "452": result = "Requested action not taken: insufficient system storage"
  of "500": result = "Command not recognized"
  of "501": result = "Syntax error in parameters or arguments"
  of "502": result = "Command not implemented"
  of "503": result = "Bad sequence of commands"
  of "550": result = "Requested action not taken: mailbox unavailable"
  of "551": result = "User not local; please try elsewhere"
  of "552": result = "Requested mail action aborted: exceeded storage allocation"
  of "553": result = "Requested action not taken: mailbox name not allowed"
  of "554": result = "Transaction failed"
  else: result = ""
