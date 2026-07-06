# Brainf*ck interpreter in zig

## Run

``` sh
zig run main.zig -- <params>
```

## Params
* `filename`: the file to interpret
* `-all`: use all of optimizations
* `-repeat`: use repeat optimization
* `-clear`: use clear optimization
* `-mul`: use multiplication loop optimization
* `-scan`: use scan loop optimization
* `-offs`: use offset optimization

## References
- [wiki brainfuck](https://en.wikipedia.org/wiki/Brainfuck)
- [optimizations](http://calmerthanyouare.org/2015/01/07/optimizing-brainfuck.html)
- [brainfuck tests](https://github.com/fabianishere/brainfuck/tree/master/examples)

## Requirements
- Zig 0.17.0
