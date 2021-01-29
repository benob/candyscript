# CandyScript

CandyScript is a lightweight yet superfast language for forging small web servers and RestAPIs.
It is inspired by [littledivy/candyscript](https://github.com/littledivy/candyscript) but does a lot more.

## Features

* Line-by-line parser
* Relatively fast thanks to Nim's `asynchttpserver`
* Short and efficient
* A single binary for everything
* Interface with a SQLite database
* Fetch external URLs
* [Mustache](https://github.com/soasme/nim-mustache) templates
* Get data from command lines
* Variable substitution system
* Authentication with http basic
* Sessions (though probably not that secure)

## TODO

* [ ] Clean up the mess with variable substitution
* [ ] Easily grab data from FETCH requests
* [ ] Tests
* [ ] More examples
* [ ] Use `httpbeast` instead of `asynchttpserver`
* [ ] Make it robust, fast and secure

## Example

### Hello, World!

```
# this is a comment
GET / Hello, World!
```

For a more advanced usage, see [the examples](examples/).

## Building from source

Use the [Nim compiler](https://nim-lang.org) to build source code.

This code will run your candyscript server.
```bash
nimble build
./candyscript your_script.candy
```

## Contributing
Pull requests are welcome. For major changes, please open an issue first to discuss what you would like to change.

Please make sure to update tests as appropriate.

## License
[MIT](https://choosealicense.com/licenses/mit/)

