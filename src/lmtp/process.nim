import options, strutils, strformat
import ./protocol
import ./address

type
  ClientCallback* = proc(mail_from, rcpt_to: seq[Address], body: string) {.gcsafe.}

  CxState* = ref object
    capabilities*: seq[string]
    fqdn*:         string
    mail_from*:    seq[Address]
    rcpt_to*:      seq[Address]

proc parse_addr(arg0: string): Option[Address] =
  let arg = arg0.strip
  if arg.len < 3 and arg[0] != '<' and arg[^1] != '>':
    return none(Address)
  else:
    return some parse_address(arg[1..^2])

proc processHelo(cx: CxState, cmd: Command): Response =
  cx.mail_from = @[]
  cx.rcpt_to = @[]

  return Response(code: "250", text: cx.fqdn, content: some(cx.capabilities.join(CRLF)))

proc processMailFrom(cx: CxState, cmd: Command): Response =
  if cx.mail_from.len > 0:
    return Response(code: "503", text: "Bad sequence of commands")

  let adr = parse_addr(cmd.args)
  if adr.is_none:
    return Response(code: "501", text: "Syntax error, use MAIL FROM:<address@example.net>")

  cx.mail_from.add(adr.get)

  return Response(code: "250", text: "OK")

proc processRcptTo(cx: CxState, cmd: Command): Response =
  let adr = parse_addr(cmd.args)
  if adr.is_none:
    return Response(code: "501", text: "Syntax error, use RCPT TO:<address@example.net>")

  cx.rcpt_to.add(adr.get)

  return Response(code: "250", text: "OK")

proc processData(cx: CxState, cmd: Command, data: Option[string], cb: ClientCallback): Response {.gcsafe.} =
  if cx.mail_from.len == 0 or cx.rcpt_to.len == 0:
    return Response(code: "503", text: "Bad sequence of commands")
  if data.is_none:
    return Response(code: "354", text: "Start mail input; end with <CRLF>.<CRLF>", expect_body: true)

  cb(cx.mail_from, cx.rcpt_to, data.get)

  return Response(code: "250", text: &"OK")

proc process*(cx: CxState, cmd: Command, data: Option[string], cb: ClientCallback): Response {.gcsafe.} =
  case cmd.command
  of CommandNone:
    return Response(code: "500", text: "command not recognized")
  of CommandConnect:
    return Response(code: "220", text: &"{cx.fqdn} LMTP server ready")
  of CommandQUIT:
    return Response(code: "221", text: &"{cx.fqdn} closing connection", quit: true)
  of CommandLHLO:
    return cx.processHelo(cmd)
  of CommandMAIL_FROM:
    return cx.processMailFrom(cmd)
  of CommandRCPT_TO:
    return cx.processRcptTo(cmd)
  of CommandDATA:
    return cx.processData(cmd, data, cb)


