# Speed.jl

[![Build Status](https://travis-ci.org/vtjnash/Speed.jl.svg?branch=master)](https://travis-ci.org/vtjnash/Speed.jl)
[![Coverage Status](https://coveralls.io/repos/vtjnash/Speed.jl/badge.png)](https://coveralls.io/r/vtjnash/Speed.jl)

## Installation

Install with `Pkg.add("Speed")

## Usage

`Speed` is intended to be used inside modules. For example:

    module MyModule
    using Speed
    @Speed.upper
    
    include("file1.jl")
    include("file2.jl")
    ...
    end

Currently, `Speed` does not improve the performance of loading individual files at the REPL prompt.

`Speed` works by caching a processed variant of your code to files ending in `".jlc"`.
Loading code from `*.jlc` files is faster than from `*.jl` files.
However, generating `*.jlc` files takes some time; expect a delay the first time you incorporate Speed,
or any time you make changes to one of the files in your module.

## Caution

Currently `Speed` has a number of limitations, and indeed the scope of these limitations is still being worked out.
There are some times when you'll have to manually force it to regenerate the `*.jlc` files:

    using Speed
    Speed.poison!(:ModuleThatNeedsReCaching)
    using ModuleThatNeedsReCaching

Here are at least some of the occasions where manual regeneration is necessary:

 * If package A depends on a macro defined in package B, and an update to package B changes the macro.
 * If your package relies on a type defined in julia or another package, and that type changes definition.
 * If your package uses "impure" macros and the runtime output of those macros changes.
   For example, `@__FILE__` returns the current path and filename for an `include`d file; if you rename the file,
   or move it to a different folder, the module needs to be manually regenerated.
   This issue also applies to some macros in BinDeps.

There are also some cases where, by following proper practice, you can avoid problems or
needing to manually poison the cache:

 * Changing your behavior depending on the availability of other packages, for example by
   `isdefined(main, :OtherModule)`, will break unless it is performed inside the module's `__init__` method.
 * State modifications such as `push!(DL_LOAD_PATH, pathname)`, or any call to functions in other modules
   that modify the loading of your module, should likewise live inside the
   `__init__` method.
