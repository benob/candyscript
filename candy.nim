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

type ActionKind = enum
  Auth, Text, Read, SQL, Redirect, Shell, Fetch, View, Json

type Action = object
  kind: ActionKind
  params: string

type Route = object
  verb, path: string
  actions: seq[Action]
  components: seq[string]

proc `$`(action: Action): string = $action.kind & " " & action.params
proc `$`(route: Route): string = $route.verb & " " & route.path & "\n" & route.actions.mapIt("  " & $it).join("\n")

var 
  port = "8080"
  debug = existsEnv("DEBUG")
  db: DbConn
  mimeResolver {.threadvar.}: MimeDB
  staticPath {.threadvar.}: seq[string]
  routes {.threadvar.}: seq[Route]
  passwords {.threadvar.}: seq[string]
 
stdout.styledWrite(fgBlue, "CandyScript is ready to show off", fgDefault, "\n")

mimeResolver = newMimetypes()
routes = newSeq[Route]()
staticPath = newSeq[string]()
passwords = newSeq[string]()

if paramCount() > 0:
  for line in readFile(paramStr(1)).replace("\\\n", " ").split('\n'):
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
    of "PORT": port = path
    of "DB": db = open(path, "", "", "")
    of "STATIC": staticPath.add(path)
    of "AUTH": passwords.add(path)
    of "STARTUP":
      case path
      of "SHELL": 
        if execCmd(rest) != 0:
          quit(1)
      of "SQL": db.exec(sql(rest))
      else: 
        stdout.styledWrite(fgRed, "[ERROR] ", fgDefault, "Invalid startup action: ", rest, "\n")
        quit(1)
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
          stdout.styledWrite(fgRed, "[ERROR] ", fgDefault, "Invalid action kind: ", kind, "\n")
          quit()
        route.actions.add(Action(kind: actionKind, params: params.strip()))
      routes.add(route)

  stdout.styledWrite(fgYellow, "[INFO] ", fgDefault, "Loaded ", $routes.len, " routes\n")
  if debug:
    for route in routes:
      echo route
else:
  stdout.styledWrite(fgYellow, "[INFO] ", fgDefault, "No script, just serving current directory\n")
  staticPath = @["./"]

proc replaceVariables(text: string, variables: Table[string, string]): string =
  multiReplace(text, toSeq(variables.pairs).mapIt(('{' & it[0] & '}', it[1])))

proc sendFile(req: Request, filename: string) {.async, gcsafe.} =
  try:
    let content = readFile(filename)
    let ext = filename.splitFile().ext
    let mime = mimeResolver.getMimetype(ext)
    let headers = newHttpHeaders([("Content-Type", mime)])
    await req.respond(Http200, content, headers)
    if debug: stdout.styledWrite(fgMagenta, "[DEBUG] ", fgDefault, "send file \"", filename, "\"\n")
  except:
    let e = getCurrentException()
    stdout.styledWrite(fgRed, "[ERROR] <<<", fgDefault, e.msg.split('\n')[0], "\n")
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

proc jsonRows*(db: DbConn, query: SqlQuery, args: Table[string, string]): JsonNode {.tags: [ReadDbEffect, WriteIOEffect].} =
  var statement: PStmt
  var formatedQuery = dbFormatArgs(query, args)
  if debug: stdout.styledWrite(fgMagenta, "[DEBUG] ", fgDefault, "sql \"", formatedQuery, "\"\n")
  if prepare_v2(db, formatedQuery, formatedQuery.len.cint, statement, nil) != SQLITE_OK: 
    dbError(db)
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
    if finalize(statement) != SQLITE_OK: dbError(db)

type ContentKind = enum
  Data, Node

type Content = ref object
  kind: ContentKind
  node: JsonNode
  data: string
  content_type: string
  variables: Table[string, string]

proc authAction(req: Request, action: Action, content: Content): Future[bool] {.async, gcsafe.} =
  if not req.headers.hasKey("Authorization"):
    let realm = if action.params == "": "Authentication required" else: replaceVariables(action.params, content.variables).replace('"', '\'')
    let headers = newHttpHeaders([("WWW-Authenticate", "Basic realm=\"" & realm & "\", charset=\"UTF-8\"") ])
    await req.respond(Http401, "Authentication required", headers)
    return false
  else:
    let token = base64.decode(req.headers["Authorization"].split()[^1])
    if debug: stdout.styledWrite(fgMagenta, "[DEBUG] ", fgDefault, "auth \"", token, "\"\n")
    for password in passwords:
      if token == password:
        return true
    await req.respond(Http403, "Access denied")
    return false

proc textAction(req: Request, action: Action, content: Content): Future[bool] {.async, gcsafe.} =
  content.data = replaceVariables(action.params, content.variables)
  if debug: stdout.styledWrite(fgMagenta, "[DEBUG] ", fgDefault, "text \"", content.data, "\"\n")
  content.content_type = "text/plain"
  content.kind = Data
  return true

proc formatValues(variables: seq[(string, string)]): seq[(string, string)] =
  for (name, value) in variables:
    result.add((name, '"' & value.replace("\"", "\\\"") & '"'))

proc jsonAction(req: Request, action: Action, content: Content): Future[bool] {.async, gcsafe.} =
  let text = replaceVariables(action.params, content.variables)
  if debug: stdout.styledWrite(fgMagenta, "[DEBUG] ", fgDefault, "json \"", text, "\"\n")
  content.node = parseJson(text)
  content.content_type = "application/json"
  content.kind = Node
  return true

proc readAction(req: Request, action: Action, content: Content): Future[bool] {.async, gcsafe.} =
  let filename = replaceVariables(action.params, content.variables).replace("/../", "/")
  if debug: stdout.styledWrite(fgMagenta, "[DEBUG] ", fgDefault, "read file \"", filename, "\"\n")
  try:
    content.data = readFile(filename)
  except:
    await req.respond(Http404, "Not found")
    return false
  content.content_type = mimeResolver.getMimetype(filename.splitFile().ext)
  return true

proc viewAction(req: Request, action: Action, content: Content): Future[bool] {.async, gcsafe.} =
  let filename = replaceVariables(action.params, content.variables).replace("/../", "/")
  if debug: stdout.styledWrite(fgMagenta, "[DEBUG] ", fgDefault, "render view \"", filename, "\"\n")
  content.content_type = mimeResolver.getMimetype(filename.splitFile().ext)
  let view = readFile(filename)
  if content.kind == Data:
    content.node = parseJson(content.data)
  let context = newContext()
  context["data"] = content.node
  context["vars"] = content.variables
  content.data = view.render(context)
  content.kind = Data
  return true
  
proc sqlAction(req: Request, action: Action, content: Content): Future[bool] {.async, gcsafe.} =
  content.node = db.jsonRows(sql(action.params), content.variables)
  content.kind = Node
  content.content_type = "application/json"
  content.variables["{last_insert_rowid}"] = $db.last_insert_rowid
  return true

proc shellAction(req: Request, action: Action, content: Content): Future[bool] {.async, gcsafe.} =
  if debug: stdout.styledWrite(fgMagenta, "[DEBUG] ", fgDefault, "shell \"", action.params, "\"\n")
  content.data = execCmdEx(action.params).output
  content.kind = Data
  content.content_type = "text/plain"
  return true

proc fetchAction(req: Request, action: Action, content: Content): Future[bool] {.async, gcsafe.} =
  let client = newAsyncHttpClient()
  let url = replaceVariables(action.params, content.variables)
  if debug: stdout.styledWrite(fgMagenta, "[DEBUG] ", fgDefault, "fetch \"", url, "\"\n")
  let response = await client.get(url)
  content.data = await response.body
  content.kind = Data
  content.content_type = $response.headers["Content-Type"]
  return true

proc redirectAction(req: Request, action: Action, content: Content): Future[bool] {.async, gcsafe.} =
  let location = replaceVariables(action.params, content.variables)
  if debug: stdout.styledWrite(fgMagenta, "[DEBUG] ", fgDefault, "redirect \"", location, "\"\n")
  let headers = newHttpHeaders([("Location", location)])
  await req.respond(Http301, "Moved permanently", headers)
  return false

proc handleRoute(req: Request, route: Route, variables: Table[string, string]) {.async, gcsafe.} =
  echo variables
  var content = Content(kind: Data, data: "{}", content_type: "application/json", variables: variables)
  for action in route.actions:
    try:
      let proceed = case action.kind
      of Auth: await req.authAction(action, content)
      of Text: await req.textAction(action, content)
      of Json: await req.jsonAction(action, content)
      of Read: await req.readAction(action, content)
      of SQL: await req.sqlAction(action, content)
      of Shell: await req.shellAction(action, content)
      of Fetch: await req.fetchAction(action, content)
      of View: await req.viewAction(action, content)
      of Redirect: await req.redirectAction(action, content)
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

proc handler(req: Request) {.async, gcsafe.} =
  let 
    verb = $req.reqMethod
    path = decodeUrl(req.url.path)
    components = path.split('/')

  stdout.styledWrite(fgGreen, verb, fgDefault, " ", path, "\n")

  var params = parseQuery(decodeUrl(req.url.query))
  let page = params.getOrDefault("page", "0").parseInt
  let limit = params.getOrDefault("limit", "10").parseInt
  params["offset"] = $(page * limit)
  params["nextPage"] = $(page + 1)
  params["page"] = $page
  params["limit"] = $limit

  for route in routes:
    if route.components.len == components.len:
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
        for key, value in params.pairs:
          variables[key] = value
        await req.handleRoute(route, variables)
        return
  for directory in staticPath:
    let filename = joinPath(getCurrentDir(), directory, "/" & path.replace("/../", "/"))
    if fileExists(filename):
      if debug: stdout.styledWrite(fgMagenta, "[DEBUG] ", fgDefault, "static file \"", filename, "\"\n")
      await req.sendFile(filename)
      return
  if debug: stdout.styledWrite(fgMagenta, "[DEBUG] ", fgDefault, "not found\n")
  await req.respond(Http404, "Not found")

stdout.styledWrite(fgYellow, "[START] ", fgDefault, "Listening to requests on port: ", port, "\n")

proc ctrlcHandler() {.noconv.} =
  quit()
setControlCHook(ctrlcHandler)

var server = newAsyncHttpServer()
waitFor server.serve(Port(port.parseInt()), handler)
