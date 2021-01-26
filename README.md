# CandyScript

CandyScript is a lightweight yet superfast language for forging small web servers and RestAPIs.
This flavor is inspired from [littledivy/candyscript](https://github.com/littledivy/candyscript) but does a lot more.
[![PRs Welcome](https://img.shields.io/badge/PRs-welcome-brightgreen.svg?style=flat-square)](http://makeapullrequest.com)

## Features

* Line-by-line parser
* One of the fastest web server powered by Nim's `asynchttpserver`
* Short and efficient
* < 400 lines of Nim code!
* A single binary for everything
* Interface with a SQLite database
* Fetch external URLs
* [Mustache](https://github.com/soasme/nim-mustache) templates
* Get data from command lines
* Basic variable replacement system
* Authentication

## TODO

* [ ] Add session handling
* [ ] Use `httpbeast` instead of `asynchttpserver`

## Example

### Hello, World!

```
# this is a comment
GET / Hello, World!
```

For a more advanced showcase, see [the examples](examples/server.candy)

## Building from source

Use the [Nim compiler](https://nim-lang.org) to compile source code.

This code will run your candyscript server.
```bash
nimble build
./candy your_script.candy
```

## Contributing
Pull requests are welcome. For major changes, please open an issue first to discuss what you would like to change.

Please make sure to update tests as appropriate.

## License
[MIT](https://choosealicense.com/licenses/mit/)

