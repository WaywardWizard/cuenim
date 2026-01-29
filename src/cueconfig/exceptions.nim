type
  CodepathDefect* = object of Defect
    ## Exception for codepaths that should not be traversed

  ConfigError* = object of CatchableError ## Exception for configuration errors
