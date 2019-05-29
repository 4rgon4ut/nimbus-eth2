import
  options, macros, algorithm, random, tables,
  std_shims/[macros_shim, tables_shims], chronos, chronicles,
  libp2p/daemon/daemonapi, faststreams/output_stream, serialization,
  eth/async_utils, eth/p2p/p2p_protocol_dsl,
  ssz

export
  daemonapi, p2pProtocol

type
  Eth2Node* = ref object of RootObj
    daemon*: DaemonAPI
    peers*: Table[PeerID, Peer]
    protocolStates*: seq[RootRef]

  Peer* = ref object
    network*: Eth2Node
    id*: PeerID
    connectionState*: ConnectionState
    awaitedMessages: Table[CompressedMsgId, FutureBase]
    protocolStates*: seq[RootRef]

  EthereumNode = Eth2Node # This alias is needed for state_helpers below

  ProtocolInfoObj* = object
    name*: string
    messages*: seq[MessageInfo]
    index*: int # the position of the protocol in the
                # ordered list of supported protocols

    # Private fields:
    peerStateInitializer*: PeerStateInitializer
    networkStateInitializer*: NetworkStateInitializer
    handshake*: HandshakeStep
    disconnectHandler*: DisconnectionHandler

  ProtocolInfo* = ptr ProtocolInfoObj

  MessageInfo* = object
    name*: string

    # Private fields:
    thunk*: ThunkProc
    libp2pProtocol: string
    printer*: MessageContentPrinter
    nextMsgResolver*: NextMsgResolver

  CompressedMsgId = tuple
    protocolIndex, msgId: int

  PeerStateInitializer* = proc(peer: Peer): RootRef {.gcsafe.}
  NetworkStateInitializer* = proc(network: EthereumNode): RootRef {.gcsafe.}
  HandshakeStep* = proc(peer: Peer, handshakeStream: P2PStream): Future[void] {.gcsafe.}
  DisconnectionHandler* = proc(peer: Peer): Future[void] {.gcsafe.}
  ThunkProc* = proc(daemon: DaemonAPI, stream: P2PStream): Future[void] {.gcsafe.}
  MessageContentPrinter* = proc(msg: pointer): string {.gcsafe.}
  NextMsgResolver* = proc(msgData: SszReader, future: FutureBase) {.gcsafe.}

  ConnectionState* = enum
    None,
    Connecting,
    Connected,
    Disconnecting,
    Disconnected

  UntypedResponse = object
    peer*: Peer
    stream*: P2PStream

  Response*[MsgType] = distinct UntypedResponse

  Bytes = seq[byte]

  DisconnectionReason* = enum
    UselessPeer
    BreachOfProtocol

  PeerDisconnected* = object of CatchableError
    reason*: DisconnectionReason

const
  defaultIncomingReqTimeout = 5000
  defaultOutgoingReqTimeout = 10000

var
  gProtocols: seq[ProtocolInfo]

# The variables above are immutable RTTI information. We need to tell
# Nim to not consider them GcSafe violations:
template allProtocols: auto = {.gcsafe.}: gProtocols

proc `$`*(peer: Peer): string = $peer.id

proc disconnect*(peer: Peer, reason: DisconnectionReason, notifyOtherPeer = false) {.async.} =
  # TODO: How should we notify the other peer?
  if peer.connectionState notin {Disconnecting, Disconnected}:
    peer.connectionState = Disconnecting
    await peer.network.daemon.disconnect(peer.id)
    peer.connectionState = Disconnected
    peer.network.peers.del(peer.id)

template raisePeerDisconnected(msg: string, r: DisconnectionReason) =
  var e = newException(PeerDisconnected, msg)
  e.reason = r
  raise e

proc disconnectAndRaise(peer: Peer,
                        reason: DisconnectionReason,
                        msg: string) {.async.} =
  let r = reason
  await peer.disconnect(reason)
  raisePeerDisconnected(msg, reason)

proc init*(node: Eth2Node) {.async.} =
  node.daemon = await newDaemonApi({PSGossipSub})
  node.daemon.userData = node
  init node.peers

  newSeq node.protocolStates, allProtocols.len
  for proto in allProtocols:
    if proto.networkStateInitializer != nil:
      node.protocolStates[proto.index] = proto.networkStateInitializer(node)

    for msg in proto.messages:
      if msg.libp2pProtocol.len > 0:
        await node.daemon.addHandler(@[msg.libp2pProtocol], msg.thunk)

include eth/p2p/p2p_backends_helpers
include eth/p2p/p2p_tracing

proc readMsg(stream: P2PStream, MsgType: type,
             timeout = 10.seconds): Future[Option[MsgType]] {.async.} =
  var timeout = sleepAsync timeout
  var sizePrefix: uint32
  var readSizePrefix = stream.transp.readExactly(addr sizePrefix, sizeof(sizePrefix))
  await readSizePrefix or timeout
  if not readSizePrefix.finished: return

  var msgBytes = newSeq[byte](sizePrefix.int + sizeof(sizePrefix))
  copyMem(addr msgBytes[0], addr sizePrefix, sizeof(sizePrefix))
  var readBody = stream.transp.readExactly(addr msgBytes[sizeof(sizePrefix)], sizePrefix.int)
  await readBody or timeout
  if not readBody.finished: return

  let decoded = SSZ.decode(msgBytes, MsgType)
  try:
    return some(decoded)
  except SerializationError:
    return

proc sendMsg(peer: Peer, protocolId: string, requestBytes: Bytes) {.async} =
  var stream = await peer.network.daemon.openStream(peer.id, @[protocolId])
  # TODO how does openStream fail? Set a timeout here and handle it
  let sent = await stream.transp.write(requestBytes)
  # TODO: Should I check that `sent` is equal to the desired number of bytes

proc sendBytes(stream: P2PStream, bytes: Bytes) {.async.} =
  let sent = await stream.transp.write(bytes)
  # TODO: Should I check that `sent` is equal to the desired number of bytes

proc makeEth2Request(peer: Peer, protocolId: string, requestBytes: Bytes,
                     ResponseMsg: type,
                     timeout = 10.seconds): Future[Option[ResponseMsg]] {.async.} =
  var stream = await peer.network.daemon.openStream(peer.id, @[protocolId])
  # TODO how does openStream fail? Set a timeout here and handle it
  let sent = await stream.transp.write(requestBytes)
  # TODO: Should I check that `sent` is equal to the desired number of bytes
  return await stream.readMsg(ResponseMsg, timeout)

proc p2pStreamName(MsgType: type): string =
  mixin msgProtocol, protocolInfo, msgId
  MsgType.msgProtocol.protocolInfo.messages[MsgType.msgId].libp2pProtocol

template handshakeImpl*(HandshakeTypeExpr: untyped,
                         # TODO: we cannot use a type parameter above
                         # because of the following Nim issue:
                         #
                       peerExpr: Peer,
                       streamExpr: P2PStream,
                       lazySendCall: Future[void],
                       timeoutExpr: Duration): auto =
  # We make sure the inputs are evaluated only once.
  let
    stream = streamExpr
    peer = peerExpr
    timeout = timeoutExpr

  # TODO: This is a work-around for a Nim issue. Please note that it's
  # semantically wrong, so if you get a compilation failure, try to
  # remove it (perhaps Nim got fixed)
  type HandshakeType = type(HandshakeTypeExpr)

  proc asyncStep(stream: P2PStream): Future[HandshakeType] {.async.} =
    var stream = stream
    if stream == nil:
      stream = await openStream(peer.network.daemon, peer.id,
                                @[p2pStreamName(HandshakeType)],
                                # TODO openStream should accept Duration
                                int milliseconds(timeout))

    # Please pay attention that `lazySendCall` is evaluated lazily here.
    # For this reason `handshakeImpl` must remain a template.
    await lazySendCall

    let response = await readMsg(stream, HandshakeType, timeout)
    if response.isSome:
      return response.get
    else:
      await disconnectAndRaise(peer, BreachOfProtocol, "Handshake not completed in time")

  asyncStep(stream)

proc getCompressedMsgId(MsgType: type): CompressedMsgId =
  mixin msgProtocol, protocolInfo, msgId
  (protocolIndex: MsgType.msgProtocol.protocolInfo.index, msgId: MsgType.msgId)

proc nextMsg*(peer: Peer, MsgType: type): Future[MsgType] =
  ## This procs awaits a specific P2P message.
  ## Any messages received while waiting will be dispatched to their
  ## respective handlers. The designated message handler will also run
  ## to completion before the future returned by `nextMsg` is resolved.
  mixin msgProtocol, protocolInfo, msgId
  let awaitedMsgId = getCompressedMsgId(MsgType)
  let f = getOrDefault(peer.awaitedMessages, awaitedMsgId)
  if not f.isNil:
    return Future[MsgType](f)

  newFuture result
  peer.awaitedMessages[awaitedMsgId] = result

proc resolveNextMsgFutures(peer: Peer, msg: auto) =
  type MsgType = type(msg)
  let msgId = getCompressedMsgId(MsgType)
  let future = peer.awaitedMessages.getOrDefault(msgId)
  if future != nil:
    Future[MsgType](future).complete msg

proc init*(T: type Peer, network: Eth2Node, id: PeerID): Peer =
  new result
  result.id = id
  result.network = network
  result.awaitedMessages = initTable[CompressedMsgId, FutureBase]()
  result.connectionState = Connected
  newSeq result.protocolStates, allProtocols.len
  for i in 0 ..< allProtocols.len:
    let proto = allProtocols[i]
    if proto.peerStateInitializer != nil:
      result.protocolStates[i] = proto.peerStateInitializer(result)

proc performProtocolHandshakes*(peer: Peer) {.async.} =
  var subProtocolsHandshakes = newSeqOfCap[Future[void]](allProtocols.len)
  for protocol in allProtocols:
    if protocol.handshake != nil:
      subProtocolsHandshakes.add((protocol.handshake)(peer, nil))

  await all(subProtocolsHandshakes)

proc getPeer*(node: Eth2Node, peerId: PeerID): Peer =
  result = node.peers.getOrDefault(peerId)
  if result == nil:
    result = Peer.init(node, peerId)
    node.peers[peerId] = result

proc peerFromStream(daemon: DaemonAPI, stream: P2PStream): Peer =
  Eth2Node(daemon.userData).getPeer(stream.peer)

template getRecipient(peer: Peer): Peer =
  peer

# TODO: this should be removed eventually
template getRecipient(stream: P2PStream): P2PStream =
  stream

template getRecipient(response: Response): Peer =
  UntypedResponse(response).peer

proc initProtocol(name: string,
                  peerInit: PeerStateInitializer,
                  networkInit: NetworkStateInitializer): ProtocolInfoObj =
  result.name = name
  result.messages = @[]
  result.peerStateInitializer = peerInit
  result.networkStateInitializer = networkInit

proc setEventHandlers(p: ProtocolInfo,
                      handshake: HandshakeStep,
                      disconnectHandler: DisconnectionHandler) =
  p.handshake = handshake
  p.disconnectHandler = disconnectHandler

proc registerMsg(protocol: ProtocolInfo,
                 name: string,
                 thunk: ThunkProc,
                 libp2pProtocol: string,
                 printer: MessageContentPrinter) =
  protocol.messages.add MessageInfo(name: name,
                                    thunk: thunk,
                                    libp2pProtocol: libp2pProtocol,
                                    printer: printer)

proc registerProtocol(protocol: ProtocolInfo) =
  # TODO: This can be done at compile-time in the future
  let pos = lowerBound(gProtocols, protocol)
  gProtocols.insert(protocol, pos)
  for i in 0 ..< gProtocols.len:
    gProtocols[i].index = i

proc getRequestProtoName(fn: NimNode): NimNode =
  # `getCustomPragmaVal` doesn't work yet on regular nnkProcDef nodes
  # (TODO: file as an issue)

  let pragmas = fn.pragma
  if pragmas.kind == nnkPragma and pragmas.len > 0:
    for pragma in pragmas:
      if pragma.len > 0 and $pragma[0] == "libp2pProtocol":
        return pragma[1]

  error "All stream opening procs must have the 'libp2pProtocol' pragma specified.", fn

template libp2pProtocol*(name, version: string) {.pragma.}

proc p2pProtocolBackendImpl*(p: P2PProtocol): Backend =
  var
    response = ident"response"
    name_openStream = newTree(nnkPostfix, ident("*"), ident"openStream")
    outputStream = ident"outputStream"
    currentProtocolSym = ident"CurrentProtocol"
    Format = ident"SSZ"
    Option = bindSym "Option"
    UntypedResponse = bindSym "UntypedResponse"
    Response = bindSym "Response"
    DaemonAPI = bindSym "DaemonAPI"
    P2PStream = ident "P2PStream"
    # XXX: Binding the int type causes instantiation failure for some reason
    # Int = bindSym "int"
    Int = ident "int"
    Void = ident "void"
    Peer = bindSym "Peer"
    Eth2Node = bindSym "Eth2Node"
    writeField = bindSym "writeField"
    getOutput = bindSym "getOutput"
    messagePrinter = bindSym "messagePrinter"
    getRecipient = bindSym "getRecipient"
    peerFromStream = bindSym "peerFromStream"
    makeEth2Request = bindSym "makeEth2Request"
    sendMsg = bindSym "sendMsg"
    sendBytes = bindSym "sendBytes"
    resolveNextMsgFutures = bindSym "resolveNextMsgFutures"
    milliseconds = bindSym "milliseconds"
    registerMsg = bindSym "registerMsg"
    initProtocol = bindSym "initProtocol"
    bindSymOp = bindSym "bindSym"
    msgRecipient = ident"msgRecipient"
    sendTo = ident"sendTo"
    writer = ident"writer"
    recordStartMemo = ident"recordStartMemo"
    receivedMsg = ident"msg"
    daemon = ident "daemon"
    stream = ident "stream"
    await = ident "await"
    peerIdent = ident "peer"

  new result

  result.PeerType = Peer
  result.NetworkType = Eth2Node
  result.registerProtocol = bindSym "registerProtocol"
  result.setEventHandlers = bindSym "setEventHandlers"
  result.SerializationFormat = Format
  result.ResponseType = Response

  result.afterProtocolInit = proc (p: P2PProtocol) =
    p.onPeerConnected.params.add newIdentDefs(ident"handshakeStream", P2PStream)

  result.implementMsg = proc (p: P2PProtocol, msg: Message, resp: Message = nil) =
    let
      n = msg.procDef
      msgId = newLit(msg.id)
      msgIdent = n.name
      msgName = $msgIdent
      msgKind = msg.kind
      msgRecName = msg.recIdent
      responseRecord = if resp != nil: resp.recIdent else: nil
      userPragmas = n.pragma

    var
      # variables used in the sending procs
      appendParams = newNimNode(nnkStmtList)
      paramsToWrite = newSeq[NimNode](0)

      # variables used in the receiving procs
      tracing = newNimNode(nnkStmtList)

      # nodes to store the user-supplied message handling proc if present
      userHandlerProc: NimNode = nil
      userHandlerCall: NimNode = nil
      awaitUserHandler = newStmtList()

    if n.body.kind != nnkEmpty:
      # This is the call to the user supplied handler.
      # Here we add only the initial params, the rest will be added later.
      userHandlerCall = newCall(msg.userHandler.name)
      # When there is a user handler, it must be awaited in the thunk proc.
      # Above, by default `awaitUserHandler` is set to a no-op statement list.
      awaitUserHandler = newCall(await, userHandlerCall)

      var extraDefs: NimNode
      if msgKind == msgRequest:
        # Request procs need an extra param - the stream where the response
        # should be written:
        msg.userHandler.params.insert(1, newIdentDefs(stream, P2PStream))
        userHandlerCall.add stream
        let peer = msg.userHandler.params[2][0]
        extraDefs = quote do:
          # Jump through some hoops to work aroung
          # https://github.com/nim-lang/Nim/issues/6248
          let `response` = `Response`[`responseRecord`](
            `UntypedResponse`(peer: `peer`, stream: `stream`))

      # Resolve the Eth2Peer from the LibP2P data received in the thunk
      userHandlerCall.add peerIdent

      msg.userHandler.addPreludeDefs extraDefs
      p.outRecvProcs.add msg.userHandler

    elif msgName == "status":
      #awaitUserHandler = quote do:
      #  `await` `handshake`(`peerIdent`, `stream`)
      discard
      # TODO: revisit this

    for param, paramType in n.typedParams(skip = 1):
      paramsToWrite.add param

      # If there is user message handler, we'll place a call to it by
      # unpacking the fields of the received message:
      if userHandlerCall != nil:
        userHandlerCall.add quote do: get(`receivedMsg`).`param` # newDotExpr(newCall("get", receivedMsg), param)

    when tracingEnabled:
      tracing = quote do:
        logReceivedMsg(`stream`.peer, `receivedMsg`.get)

    let requestDataTimeout = newCall(milliseconds, newLit(defaultIncomingReqTimeout))
    let thunkName = ident(msgName & "_thunk")
    var thunkProc = quote do:
      proc `thunkName`(`daemon`: `DaemonAPI`, `stream`: `P2PStream`) {.async, gcsafe.} =
        var `receivedMsg` = `await` readMsg(`stream`, `msgRecName`, `requestDataTimeout`)
        if `receivedMsg`.isNone:
          # TODO: This peer is misbehaving, perhaps we should penalize him somehow
          return
        let `peerIdent` = `peerFromStream`(`daemon`, `stream`)
        `tracing`
        `awaitUserHandler`
        `resolveNextMsgFutures`(`peerIdent`, get(`receivedMsg`))

    for p in userPragmas:
      thunkProc.addPragma p

    p.outRecvProcs.add thunkProc

    var msgSendProc = n
    let msgSendProcName = n.name
    p.outSendProcs.add msgSendProc

    # TODO: check that the first param has the correct type
    msgSendProc.params[1][0] = sendTo
    msgSendProc.addPragma ident"gcsafe"

    # Add a timeout parameter for all request procs
    case msgKind
    of msgRequest:
      # Add a timeout parameter for all request procs
      msgSendProc.params.add msg.timeoutParam
    of msgResponse:
      # A response proc must be called with a response object that originates
      # from a certain request. Here we change the Peer parameter at position
      # 1 to the correct strongly-typed ResponseType. The incoming procs still
      # gets the normal Peer paramter.
      let ResponseType = newTree(nnkBracketExpr, Response, msgRecName)
      msgSendProc.params[1][1] = ResponseType
      p.outSendProcs.add quote do:
        template send*(r: `ResponseType`, args: varargs[untyped]): auto =
          `msgSendProcName`(r, args)
    else: discard

    # We change the return type of the sending proc to a Future.
    # If this is a request proc, the future will return the response record.
    let rt = if msgKind != msgRequest: Void
             else: newTree(nnkBracketExpr, Option, responseRecord)
    msgSendProc.params[0] = newTree(nnkBracketExpr, ident("Future"), rt)

    if msgKind == msgHandshake:
      var
        rawSendProc = msgName & "RawSend"
        handshakeTypeName = $msgRecName
        handshakeExchanger = msg.createSendProc(nnkMacroDef)
        paramsArray = newTree(nnkBracket).appendAllParams(handshakeExchanger.def)
        bindSym = ident "bindSym"
        getAst = ident "getAst"
        handshakeImpl = ident "handshakeImpl"

      # TODO: macros.body triggers an assertion error when the proc type is nnkMacroDef
      handshakeExchanger.def[6] = quote do:
        let
          stream = ident"handshakeStream"
          rawSendProc = `bindSymOp` `rawSendProc`
          params = `paramsArray`
          lazySendCall = newCall(rawSendProc, params)
          peer = params[0]
          timeout = params[^1]

        lazySendCall[1] = stream
        lazySendCall.del(lazySendCall.len - 1)

        return `getAst`(`handshakeImpl`(`msgRecName`, peer, stream, lazySendCall, timeout))

      p.outSendProcs.add handshakeExchanger.def

      msgSendProc.params[1][1] = P2PStream
      msgSendProc.name = ident rawSendProc
    else:
      # Make the send proc public
      msgSendProc.name = msg.identWithExportMarker

    let initWriter = quote do:
      var `outputStream` = init OutputStream
      var `writer` = init(WriterType(`Format`), `outputStream`)
      var `recordStartMemo` = beginRecord(`writer`, `msgRecName`)

    for param in paramsToWrite:
      appendParams.add newCall(writeField, writer, newLit($param), param)

    when tracingEnabled:
      appendParams.add logSentMsgFields(msgRecipient, protocol, msgName, paramsToWrite)

    let msgBytes = ident"msgBytes"
    let finalizeRequest = quote do:
      endRecord(`writer`, `recordStartMemo`)
      let `msgBytes` = `getOutput`(`outputStream`)

    var msgProto = newLit("")
    let sendCall =
      if msgKind != msgResponse:
        msgProto = getRequestProtoName(n)

        when false:
          var openStreamProc = n.copyNimTree
          var openStreamProc.name = name_openStream
          openStreamProc.params.insert 1, newIdentDefs(ident"T", msgRecName)

        if msgKind == msgRequest:
          let timeout = msg.timeoutParam[0]
          quote: `makeEth2Request`(`msgRecipient`, `msgProto`, `msgBytes`,
                                   `responseRecord`, `timeout`)
        elif msgId.intVal == 0:
          quote: `sendBytes`(`sendTo`, `msgBytes`)
        else:
          quote: `sendMsg`(`msgRecipient`, `msgProto`, `msgBytes`)
      else:
        quote: `sendBytes`(`UntypedResponse`(`sendTo`).stream, `msgBytes`)

    msgSendProc.body = quote do:
      let `msgRecipient` = `getRecipient`(`sendTo`)
      `initWriter`
      `appendParams`
      `finalizeRequest`
      return `sendCall`

    p.outProcRegistrations.add(
      newCall(registerMsg,
              p.protocolInfoVar,
              newLit(msgName),
              thunkName,
              msgProto,
              newTree(nnkBracketExpr, messagePrinter, msgRecName)))

  result.implementProtocolInit = proc (p: P2PProtocol): NimNode =
    return newCall(initProtocol, newLit(p.name), p.peerInit, p.netInit)

proc makeMessageHandler[MsgType](msgHandler: proc(msg: MsgType)): P2PPubSubCallback =
  result = proc(api: DaemonAPI, ticket: PubsubTicket, msg: PubSubMessage): Future[bool] {.async.} =
    msgHandler SSZ.decode(msg.data, MsgType)
    return true

proc subscribe*[MsgType](node: EthereumNode,
                         topic: string,
                         msgHandler: proc(msg: MsgType)) {.async.} =
  discard await node.daemon.pubsubSubscribe(topic, makeMessageHandler(msgHandler))

proc broadcast*(node: Eth2Node, topic: string, msg: auto) =
  traceAsyncErrors node.daemon.pubsubPublish(topic, SSZ.encode(msg))

# TODO:
# At the moment, this is just a compatiblity shim for the existing RLPx functionality.
# The filtering is not implemented properly yet.
iterator randomPeers*(node: EthereumNode, maxPeers: int, Protocol: type): Peer =
  var peers = newSeq[Peer]()
  for _, peer in pairs(node.peers): peers.add peer
  shuffle peers
  if peers.len > maxPeers: peers.setLen(maxPeers)
  for p in peers: yield p

