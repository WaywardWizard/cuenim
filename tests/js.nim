## Tests on the JS backend
# the js backend allows file selectors at compiletime but not at runtime
# compiletime commit config is accessible at runtime
# no registrations possible for browser at runtime
# only env registrations possible for nodejs at runtime
# runtime env registrations show in nodejs 

# when(backend == "js"):
#   const BROWSER = isBrowser()
#   const NODE = isNode()