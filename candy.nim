import asynchttpserver, asyncdispatch
import base64
import cgi
import db_sqlite
import httpClient
import json
import mimetypes
import mustache
import os
import osproc
import sequtils
import sqlite3
import strutils
import tables
import terminal
import uri
import httpform

type ActionKind* = enum
  Auth, Text, Read, SQL, Redirect, Shell, Fetch, View, Json

type Action* = ref object
  kind: ActionKind
  params: string

type Route* = ref object
  verb, path: string
  actions: seq[Action]
  components: seq[string]

type CandyServer* = ref object
  port: string
  debug: bool
  verbose: bool
  db: DbConn
  mimeResolver: MimeDB
  staticPaths: seq[string]
  routes: seq[Route]
  passwords: seq[string]
  formParser: AsyncHttpForm 

proc initCandyServer*(verbose = false): CandyServer =
  CandyServer(port: "8080", debug: existsEnv("DEBUG"), verbose: verbose, mimeResolver: newMimetypes(), routes: @[], passwords: @[], formParser: newAsyncHttpForm(getTempDir(), true), staticPaths: @["./"])

proc `$`(action: Action): string = $action.kind & " " & action.params
proc `$`(route: Route): string = $route.verb & " " & route.path & "\n" & route.actions.mapIt("  " & $it).join("\n")

type LogKind = enum
  Debug, Info, Warn, Error, None

proc log(server: CandyServer, kind: LogKind = LogKind.None, message: string) =
  let
    color = case kind
      of Debug: fgMagenta
      of Info: fgGreen
      of Warn: fgYellow
      of Error: fgRed
      of None: fgDefault
    prefix = if kind == LogKind.None: "" else: $kind & ": "
  if server.verbose or kind == Error or kind == Debug:
    stdout.styledWrite(color, prefix, fgDefault, message, "\n")

proc parseScript*(server: CandyServer, script: string): bool =
  for line in script.replace("\\\n", " ").split('\n'):
    if line.strip().startswith("#") or line.strip() == "":
      continue
    var 
      verb = ""
      path = ""
      rest = ""
    for token, isSep in tokenize(line):
      if verb == "":
        if not isSep: verb = token
      elif path == "":
        if not isSep: path = token
      else:
        rest &= token
    case verb
    of "PORT": server.port = path
    of "DB": server.db = open(path, "", "", "")
    of "STATIC": server.staticPaths.add(path)
    of "AUTH": server.passwords.add(path)
    of "STARTUP":
      case path
      of "SHELL": 
        if execCmd(rest) != 0:
          quit(1)
      of "SQL": server.db.exec(sql(rest))
      else: 
        server.log(Error, "Invalid startup action: " & rest)
        return false
    else:
      var route = Route(verb: verb, path: path, components: path.split('/'))
      for definition in rest.split('|'): 
        var 
          kind = ""
          params = ""
        for token, isSep in tokenize(definition):
          if kind == "":
            if not isSep: kind = token
          else:
            params &= token
        var actionKind = case kind
        of "AUTH": Auth
        of "TEXT": Text
        of "JSON": Json
        of "READ": Read
        of "SQL": SQL
        of "REDIRECT": Redirect
        of "SHELL": Shell
        of "FETCH": Fetch
        of "VIEW": View
        else:
          server.log(Error, "Invalid action kind: " & kind)
          return false
        route.actions.add(Action(kind: actionKind, params: params.strip()))
      server.routes.add(route)

  server.log(Info, "Loaded " & $server.routes.len & " routes")
  if server.debug:
    for route in server.routes:
      echo route
  return true

proc loadScript*(server: CandyServer, filename: string): bool = server.parseScript(readFile(filename))

proc replaceVariables(text: string, variables: Table[string, string]): string =
  multiReplace(text, toSeq(variables.pairs).mapIt(('{' & it[0] & '}', it[1])))

proc sendFile(server: CandyServer, req: Request, filename: string) {.async, gcsafe.} =
  try:
    let content = readFile(filename)
    let ext = filename.splitFile().ext
    let mime = server.mimeResolver.getMimetype(ext)
    let headers = newHttpHeaders([("Content-Type", mime)])
    await req.respond(Http200, content, headers)
    server.log(Debug, "send file \"" & filename & "\"")
  except:
    let e = getCurrentException()
    server.log(Error, e.msg.split('\n')[0])
    await req.respond(Http404, "Not found")

proc dbFormatArgs(formatstr: SqlQuery, args: Table[string, string]): string =
  result = ""
  var 
    identifier = ""
    inIdentifier = false
    previous = '\0'
  for c in items(string(formatstr)):
    if previous != '\\' and c == '{':
      inIdentifier = true
      identifier = ""
    elif previous != '\\' and c == '}' and inIdentifier:
      inIdentifier = false
      add(result, dbQuote(args[identifier]))
    elif inIdentifier:
      identifier &= c
    else:
      add(result, c)
    previous = c

proc jsonRows(server: CandyServer, query: SqlQuery, args: Table[string, string]): JsonNode {.tags: [ReadDbEffect, WriteIOEffect].} =
  var statement: PStmt
  var formatedQuery = dbFormatArgs(query, args)
  server.log(Debug, "sql \"" & formatedQuery & "\"")
  if prepare_v2(server.db, formatedQuery, formatedQuery.len.cint, statement, nil) != SQLITE_OK: 
    dbError(server.db)
  var numColumns = column_count(statement)
  result = newJArray()
  try:
    while step(statement) == SQLITE_ROW:
      var node = newJObject()
      for col in 0'i32..numColumns-1:
        let name = column_name(statement, col)
        let value = column_text(statement, col)
        if isNil(value): 
          node.add($name, newJNull())
        else:
          node.add($name, newJString($value))
      result.add(node)
  finally:
    if finalize(statement) != SQLITE_OK: dbError(server.db)

type ContentKind = enum
  Data, Node

type Content = ref object
  kind: ContentKind
  node: JsonNode
  data: string
  content_type: string
  variables: Table[string, string]

proc authAction(server: CandyServer, req: Request, action: Action, content: Content): Future[bool] {.async, gcsafe.} =
  if not req.headers.hasKey("Authorization"):
    let realm = if action.params == "": "Authentication required" else: replaceVariables(action.params, content.variables).replace('"', '\'')
    let headers = newHttpHeaders([("WWW-Authenticate", "Basic realm=\"" & realm & "\", charset=\"UTF-8\"") ])
    await req.respond(Http401, "Authentication required", headers)
    return false
  else:
    let token = base64.decode(req.headers["Authorization"].split()[^1])
    server.log(Debug, "auth \"" & token & "\"")
    for password in server.passwords:
      if token == password:
        return true
    await req.respond(Http403, "Access denied")
    return false

proc textAction(server: CandyServer, req: Request, action: Action, content: Content): Future[bool] {.async, gcsafe.} =
  content.data = replaceVariables(action.params, content.variables)
  server.log(Debug, "text \"" & content.data & "\"")
  content.content_type = "text/plain"
  content.kind = Data
  return true

#proc formatValues(variables: seq[(string, string)]): seq[(string, string)] =
#  for (name, value) in variables:
#    result.add((name, '"' & value.replace("\"", "\\\"") & '"'))

proc jsonAction(server: CandyServer, req: Request, action: Action, content: Content): Future[bool] {.async, gcsafe.} =
  let text = replaceVariables(action.params, content.variables)
  server.log(Debug, "json \"" & text & "\"")
  content.node = parseJson(text)
  content.content_type = "application/json"
  content.kind = Node
  return true

proc readAction(server: CandyServer, req: Request, action: Action, content: Content): Future[bool] {.async, gcsafe.} =
  let filename = replaceVariables(action.params, content.variables).replace("/../", "/")
  server.log(Debug, "read file \"" & filename & "\"")
  try:
    content.data = readFile(filename)
  except:
    await req.respond(Http404, "Not found")
    return false
  content.content_type = server.mimeResolver.getMimetype(filename.splitFile().ext)
  return true

proc viewAction(server: CandyServer, req: Request, action: Action, content: Content): Future[bool] {.async, gcsafe.} =
  let filename = replaceVariables(action.params, content.variables).replace("/../", "/")
  server.log(Debug, "render view \"" & filename & "\"")
  content.content_type = server.mimeResolver.getMimetype(filename.splitFile().ext)
  let view = readFile(filename)
  if content.kind == Data:
    content.node = parseJson(content.data)
  let context = newContext()
  context["data"] = content.node
  context["vars"] = content.variables
  content.data = view.render(context)
  content.kind = Data
  return true
  
proc sqlAction(server: CandyServer, req: Request, action: Action, content: Content): Future[bool] {.async, gcsafe.} =
  content.node = server.jsonRows(sql(action.params), content.variables)
  content.kind = Node
  content.content_type = "application/json"
  content.variables["{last_insert_rowid}"] = $server.db.last_insert_rowid
  return true

proc shellAction(server: CandyServer, req: Request, action: Action, content: Content): Future[bool] {.async, gcsafe.} =
  server.log(Debug, "shell \"" & action.params & "\"")
  content.data = execCmdEx(action.params).output
  content.kind = Data
  content.content_type = "text/plain"
  return true

proc fetchAction(server: CandyServer, req: Request, action: Action, content: Content): Future[bool] {.async, gcsafe.} =
  let client = newAsyncHttpClient()
  let url = replaceVariables(action.params, content.variables)
  server.log(Debug, "fetch \"" & url & "\"")
  let response = await client.get(url)
  content.data = await response.body
  content.kind = Data
  content.content_type = $response.headers["Content-Type"]
  return true

proc redirectAction(server: CandyServer, req: Request, action: Action, content: Content): Future[bool] {.async, gcsafe.} =
  let location = replaceVariables(action.params, content.variables)
  server.log(Debug, "redirect \"" & location & "\"")
  let headers = newHttpHeaders([("Location", location)])
  await req.respond(Http301, "Moved permanently", headers)
  return false

proc handleRoute(server: CandyServer, req: Request, route: Route, variables: Table[string, string]) {.async, gcsafe.} =
  echo variables
  var content = Content(kind: Data, data: "{}", content_type: "application/json", variables: variables)
  for action in route.actions:
    try:
      let proceed = case action.kind
      of Auth: await server.authAction(req, action, content)
      of Text: await server.textAction(req, action, content)
      of Json: await server.jsonAction(req, action, content)
      of Read: await server.readAction(req, action, content)
      of SQL: await server.sqlAction(req, action, content)
      of Shell: await server.shellAction(req, action, content)
      of Fetch: await server.fetchAction(req, action, content)
      of View: await server.viewAction(req, action, content)
      of Redirect: await server.redirectAction(req, action, content)
      if not proceed:
        return
    except:
      stdout.styledWrite(fgRed, "[ERROR] ", fgDefault, repr(getCurrentException()), "\n")
      await req.respond(Http500, "Server error")
      return

  if content.kind == Node:
    content.data = $content.node
  let headers = newHttpHeaders([("Content-Type", content.content_type)])
  await req.respond(Http200, content.data, headers)

proc parseQuery(query: string): Table[string, string] =
  for token in query.split('&'):
    let found = token.find('=')
    var 
      name = token
      value = ""
    if found >= 0:
      name = token[0 .. found - 1]
      value = token[found + 1..^1]
    if name != "":
      result[name] = value

proc parseBody(formParser: AsyncHttpForm, req: Request): Future[Table[string, string]] {.async, gcsafe.} =
  if req.headers.hasKey("Content-Type"):
    var (fields, files) = await formParser.parseAsync(req.headers["Content-Type"], req.body)
    discard files
    for name, value in fields:
      result[$name] = value.str

proc handleRequest*(server: CandyServer, req: Request) {.async, gcsafe.} =
  let 
    verb = $req.reqMethod
    path = decodeUrl(req.url.path)
    components = path.split('/')

  server.log(Info, verb & " " & path)

  var 
    bodyParams = await server.formParser.parseBody(req)
    queryParams = parseQuery(decodeUrl(req.url.query))
  let page = queryParams.getOrDefault("page", "0").parseInt
  let limit = queryParams.getOrDefault("limit", "10").parseInt
  queryParams["offset"] = $(page * limit)
  queryParams["nextPage"] = $(page + 1)
  queryParams["page"] = $page
  queryParams["limit"] = $limit

  for route in server.routes:
    if route.components.len == components.len and route.verb == verb:
      var 
        variables = initTable[string, string]()
        found = true
      for i in 0..components.len - 1:
        let
          value = components[i] 
          name = route.components[i]
        if name.len > 1 and name[0] == '{' and name[^1] == '}':
          variables[name[1..^2]] = value
        else:
          if value != name:
            found = false
            break
      if found:
        for key, value in bodyParams.pairs:
          variables[key] = value
        for key, value in queryParams.pairs:
          variables[key] = value
        await server.handleRoute(req, route, variables)
        return
  for directory in server.staticPaths:
    let filename = joinPath(getCurrentDir(), directory, "/" & path.replace("/../", "/"))
    if fileExists(filename):
      server.log(Debug, "static file \"" & filename & "\"")
      await server.sendFile(req, filename)
      return
  server.log(Debug, "not found")
  await req.respond(Http404, "Not found")


when isMainModule:
  var server {.threadvar.}: CandyServer
  server = initCandyServer(verbose=true)
  stdout.styledWrite(fgBlue, "CandyScript is ready to show off", fgDefault, "\n")
  if paramCount() >= 1:
    if not server.loadScript(paramStr(1)):
      quit()
  else:
    server.log(Info, "No script, just serving current directory")

  proc ctrlcHandler() {.noconv.} =
    quit()
  setControlCHook(ctrlcHandler)

  proc handler(req: Request) {.async, gcsafe.} =
    await server.handleRequest(req)

  server.log(Warn, "Listening on port: " & server.port)
  var httpServer = newAsyncHttpServer()
  waitFor httpServer.serve(Port(server.port.parseInt()), handler)

