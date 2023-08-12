import std/asyncdispatch
import std/options
import std/net
import std/asyncnet
import std/strformat

import ./lmtp/utils/parse_port
import ./lmtp/lineproto
import ./lmtp/protocol as smtp
import ./lmtp/process
import ./lmtp/address

export process.ClientCallback
export address

export Connection

proc process_lmtp_client*(client: AsyncSocket, cx: CxState, cb: ClientCallback, log: bool = false, crypto: SslContext = nil) {.async.} =

  proc process(cmd: smtp.Command, data: Option[string]): smtp.Response {.gcsafe.} =
    return cx.process(cmd, data, cb)

  let conn = smtp.Connection(
    read: get_read(client, "LMTP", log),
    write: get_write(client, "LMTP", log),
    close: get_close(client, "LMTP", log),
    starttls: get_starttls(client, crypto),
    process: process)

  await conn.handle_protocol()

proc listen_inet*(socket: var AsyncSocket, port: Port = Port(2525), address: string = "127.0.0.1", name: string = "LMTP") =
  socket = newAsyncSocket()
  socket.setSockOpt(OptReuseAddr, true)
  socket.bindAddr(port, address)
  if name != "": echo &"Listen {name} on {address} port {port}"
  socket.listen()

proc listen_socket*(socket: var AsyncSocket, socket_descr: string, name: string = "LMTP") =
  let (address, port) = parse_addr_and_port(socket_descr, 2525)
  if address != "" and port != Port(0):
    listen_inet(socket, port, address, name)
    return

  let sd: int = parse_sd_socket_activation(socket_descr)
  if sd != -1:
    let fd = cast[AsyncFD](sd)
    asyncdispatch.register(fd)
    socket = newAsyncSocket(fd)
    if name != "": echo &"Listen {name} on fd={sd}"
  else:
    socket = newAsyncSocket(AF_UNIX, SOCK_STREAM, IPPROTO_IP)
    socket.bindUnix(socket_descr)
    if name != "": echo &"Listen {name} on {socket_descr}"
  socket.listen()

proc serve*(socket: AsyncSocket, fqdn: string, cb: ClientCallback) {.async.} =
  let cx = CxState(fqdn: fqdn)
  while true:
    let client = await socket.accept()
    try:
      asyncCheck process_lmtp_client(client, cx, cb)
    except:
      echo "----------"
      let e = getCurrentException()
      #echo getStackTrace(e)
      echo &"{e.name}: {e.msg}"
      echo "----------"

proc connect*(address: string, port: Port, log: bool = false, crypto: SslContext = nil): Future[Connection] {.async.} =
  var socket = await asyncnet.dial(address, port)

  result = smtp.Connection(
    read: get_read(socket, "LMTP", log),
    write: get_write(socket, "LMTP", log),
    close: get_close(socket, "LMTP", log),
    starttls: get_starttls(socket, crypto),
    process: nil)

proc lhlo*(conn: Connection, address: string) {.async.} =
  await conn.write(&"LHLO {address}{CRLF}")
  await conn.check_reply("220")

proc mail_from*(conn: Connection, address: string) {.async.} =
  await conn.write(&"MAIL FROM:<{address}>{CRLF}")
  await conn.check_reply("250")

proc rcpt_to*(conn: Connection, address: string) {.async.} =
  await conn.write(&"RCPT TO:<{address}>{CRLF}")
  await conn.check_reply("250")

proc send_data*(conn: Connection, data: string) {.async.} =
  await conn.write(&"DATA{CRLF}")
  await conn.check_reply("250")
  await conn.check_reply("354")
  await conn.write(&"{data}{CRLF}.{CRLF}")
  await conn.check_reply("250")

proc quit*(conn: Connection) {.async.} =
  await conn.write(&"QUIT{CRLF}")
  conn.close()

when defined(ssl):
  proc serve_tls*(socket: var AsyncSocket, fqdn: string, cb: ClientCallback, crypto: SslContext) {.async.} =
    let cx = CxState(fqdn: fqdn)
    while true:
      let client = await socket.accept()
      try:
        wrapConnectedSocket(crypto, client, handshakeAsServer)
        asyncCheck process_lmtp_client(client, cx, cb, crypto = crypto)
      except:
        echo "----------"
        let e = getCurrentException()
        #echo getStackTrace(e)
        echo &"{e.name}: {e.msg}"
        echo "----------"
