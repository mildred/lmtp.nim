import strutils, net
import ./sd_daemon

proc parse_sd_socket_activation*(arg: string): int =
  var parts = arg.split("=")

  if parts.len == 2 and parts[0] == "fd":
    return parse_int(parts[1])

  if parts.len == 2 and parts[0] == "sd":
    parts = parts[1].split(':', 1)
    if parts.len == 1:
      let n = parse_int(parts[0])
      if n < sd_listen_fds():
        return SD_LISTEN_FDS_START + n
    else:
      let fds = sd_listen_fds_with_names()
      var n = parse_int(parts[1])
      var fd = SD_LISTEN_FDS_START
      for fdname in fds:
        if fdname == parts[0]:
          if n == 0:
            return fd
          else:
            n = n - 1
        fd = fd + 1

  return -1

proc parse_addr_and_port*(arg: string, def: int): (string, Port) =
  var parts = arg.split("=")
  if parts[0] == "fd" or parts[0] == "sd": return ("", Port(0))

  parts = arg.split(":")
  if parts.len == 2:
    return (parts[0], Port(parse_int(parts[1])))
  else:
    return (arg, Port(def))

proc parse_port*(arg: string, def: int): Port =
  let parts = arg.split("=")
  if parts.len == 2 and parts[0] == "sd":
    return Port(def)
  return Port(parse_int(arg))

