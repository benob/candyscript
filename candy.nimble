version     = "0.1"
author      = "Benoit Favre"
description = "Server for candy script web services"
license     = "MIT"

bin = @["candy"]

requires "nim >= 1.0.0"
requires "mustache >= 0.3.2"
requires "https://github.com/benob/httpform?branch@#refactoring2019"
