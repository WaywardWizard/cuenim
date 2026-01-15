import std/[paths, macros, os]
when nimvm:
  import std/[staticos]
  
# Cue/sops installed
let NO_CUE*: bool = block:
  when not defined(js):
    findExe("cue") == ""
  else:
    true
let NO_SOPS*: bool = block:
  when not defined(js):
    findExe("sops") == ""
  else:
    true

proc `/`*(a: Path, b: string): Path =
  result = a
  result.add(b.Path)
proc `/`*(a: string, b: Path): Path =
  result = a.Path
  result.add(b)

proc extant*(p: Path): bool =
  when nimvm: 
    staticFileExists($p)
  else:
    fileExists($p)
    
macro getField*(obj: typed, field: string, T: typedesc): untyped =
  ## Get field of object dynamically, where field value is of type T
  obj.expectKind({nnkSym, nnkRefTy, nnkObjectTy})
  let reclist = obj.getTypeImpl().findChild(it.kind == nnkRecList)
  var ifexpr = nnkIfExpr.newTree()
  let throw = nnkRaiseStmt.newTree(
    nnkCall.newTree(
      nnkDotExpr.newTree(ident"ValueError", ident"newException"),
      newLit"Field not found for given type",
    )
  )
  var targetType = T.getTypeInst[1]
  for identDef in reclist.children():
    if sameType(targetType, identDef[1]):
      ifexpr.add(
        nnkElifExpr.newTree(
          infix(field, "==", newLit($identDef[0])),
          newStmtList(newDotExpr(obj, identDef[0])),
        )
      )
  ifexpr.add(nnkElseExpr.newTree(newStmtList(throw)))
  result = ifexpr
