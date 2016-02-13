# Chlorophyll Language and Compiler

Chlorophyll language is a language for spatial computation. It is a subset of C with *partition annotation* for pinning data and computation onto computing units (multiple cores). Chlorophyll compiler is a prototype of a *synthesis-aided* compiler. It is built for [GreenArrays 144](http://www.greenarraychips.com/).

Please refer to [Chlorophyll: Synthesis-Aided Compiler for Low-Power Spatial Architectures (PLDI'14)](http://www.eecs.berkeley.edu/~mangpo/www/papers/chlorophyll-pldi14.pdf) for more details on the concept of the *synthesis-aided* compiler and the compilation strategies used in Chlorophyll.

Note: Chlorophyll compiler has only been tested on Linux OS, so it might be incompatible with other operating systems. Please report bugs to mangpo@eecs.berkeley.edu.  

# Setting Up

### Requirements

- Python and Python's numpy package
- [Racket](http://download.racket-lang.org)
- [Rosette](http://github.com/emina/rosette)
- [F18A superoptimizer](http://bitbucket.org/rohinmshah/forth-interpreter): install as a local package. In command terminal, type:

```
raco planet link mangpo aforth-optimizer.plt 1 0 path/to/F18A_superoptimizer/repo
```

### Installation

After setting up all the requirements, run
```
make
```

# First Program

Let compile a simple addition program (examples/simple/hello.cll).

```
void main() {
  int@0 a;
  int@1 b;
  int@2 c;
  a = 1; 
  b = 2
  c = a +@2 b;
}
```
This program simply adds 1 and 2, and stores the result in variable *c*. "@" is an annotation for pinning data and computation onto *logical cores*, which are mapped to physical cores later by the compiler. In this example, we assign variable *a*, *b*, and *c* to different cores, and specify that the addition happens at where *c* is. Thus, logical core 0 and 1 send value of *a* and *b* to logical core 2 respectively.

### Compile
```
./src/chlorophyll examples/simple/hello.cll
```

The compiler will generate directory `examples/simple/output-hello`, in which contains many files. If everything goes well, you should see the final arrayForth program generated by the compiler, `examples/simple/output-hello/hello-noopt2.aforth`.

### Compile -o
Compile with `-o` to turn the superoptimizer (optimizing back-end code generator) on. Note that the compiler is much slower when compiling with `-o`, but the output program is more efficient. The superoptimizer caches its outputs, so if you have already compiled a program with `-o`, the subsequent compilation of the same program will be fast. The final optimized arrayForth program is `examples/simple/output-hello/hello.aforth`. 

The compiler invokes multiple superoptimizers to optimize code of multiple GA nodes in parallel. The default number of threads used is 4. To change the number of threads, in `src/header.rkt`, modify the following line:
```
(define procs 4)
```
Only compiling with `-o` when you are certain that your program is correct.

### Other Compiler Options

The default number of rows of nodes is 2, and the default number of columns of nodes is 3. Modify the number of rows and columns using `-r` and `-c` options. `--heu-partition` uses a heuristic partitioner (greedy algorithm) instead of the default synthesizing partitioner.  Note that the heuristic partitioner is much faster than the synthesizing partitioner, but the output partitioning from the heuristic partitioner is less optimal.

To view all compiler options and the default settings, run
```
./src/chlorophyll -h
```

### Testing Your Programs
To facilitate testing, in the testing mode, we introduce `in()` and `out()` constructs that read from standard input and write to standard output respectively. In `examples/simple/hello-io.cll`, we modify `examples/simple/hello.cll` to read *a* and *b* from standard input, and write *c* to standard output.

You can test your implementation before fully compiling the program by running
```
./src/chlorophyll-test examples/simple/hello-io.cll 2
```

The second argument is the input data file in `testdata` directory. In this case, `testdata/2` is the input data, which contains two integers, since our program takes two integers from standard input. `chlorophyll-test` generates
- **examples/simple/output-hello/hello-io_seq.cpp**, a sequential C++ program that is semantically equivalent to the source program, and
- **examples/simple/output-hello/hello-io.cpp**, a multi-threaded C++ program that simulates multiple GA nodes and is semantically equivalent to the source program.

Given `testdata/2` as the input, the outputs of hello-io_seq.cpp and hello-io.cpp are `testdata/out/hello-io_2.out` and `testdata/out/hello-io_2.tmp`. `chlorophyll-test` displays **PASSED** at the end if the two output data files are the same, or displays **FAILED** otherwise. We expect `chlorophyll-test` to always display **PASSED**. If not, there is a problem with the compiler (not your implementation). In such case, please file a bug report.

If all go well, you can refer to either `hello-io_2.out` or `hello-io_2.tmp` as the output from your implementation.

##### in()/out()
`in()` and `out()` are meant for testing only. When generating the final arrayforth to be used, please remember to remove them.

### Forth to colorForth
`cforth_tools` directory contains scripts for converting the generated arrayForth program in text file into colorForth binary compatible with [GreenArrays 144 IDE](http://www.greenarraychips.com/home/support/download-02b.html). 

Starting from `template.cfs`, replace block 790, 792, and 800 with the generated code from the compiler (e.g. `examples/simple/output-hello/hello-noopt2.aforth`). Then, change the following line of `cforth_tools/Makefile` to match the .cfs file you want to convert.
```
NEW_CFS=template.cfs
```

Under `cforth_tools` directory, run
```
make clean
make install
```
Copy the generated `OkadWork.cf` to GreenArrays 144 IDE directory. Compile the program in the IDE, and modify block 792 so that all nodes start executing at the appropriate words (where main functions start) and not 0, which is the default. For `hello-noopt2.aforth`, all main functions are at 0, so we do not have to modify block 792. Now, you can run the GreenArrays 144 softsim.

# Compilation Strategies

Chlorophyll compiler consists the following components.
1. **Partitioner** partitions data and computations onto logical cores.
2. **Layout** maps logical cores to physical cores and determines the routing between cores.
3. **Code separator** separates the program into multiple program fragments that fit in GA cores and inserts communication code at the appropriate places in the program fragments.
4. **Code generator** generates arrayForth code. Our code generator uses a superoptimization technique to optimize code.

When you compile `xxx.cll`, the compiler will generate a directory `output-xxx` which contains
- **xxx.part**: output from the partitioner, a fully partitioned xxx program (all variables and operators are annotated with logical cores)
- **xxx.dat** and **xxx.graph**: inputs to the layout
- **xxx.layout**: output from the layout
- **xxx.part2core**: summarize the mapping of partitions to cores
- **xxx-gen1.rkt** and **xxx-gen2.rkt**: outputs from the code separator as Racket objects. When we discover repeating sequences of instructions, we define a function that executes such sequence of instructions, and replace each of those repeating sequences with a function call. *xxx-gen2.rkt* is the version that replaces the repeating sequences with function calls.
- **xxx.cpp**: output of compiling *xxx-gen1.rkt* into C++ programs. Each thread represents each GA core. *xxx.cpp* can be compiled to an executable using `g++ -pthread -std=c++0x xxx.cpp`.
- **xxx-noopt1.rkt** and **xxx-noopt2.rkt**: outputs from compiling *xxx-gen1.rkt* and *xxx-gen2.rkt* to arrayForth respectively. xxx-noopt1.rkt and xxx-noopt2.rkt are generated without superoptimization.
- **xxx.aforth**: the final optimized arrayForth program from the superoptimizer.
- many more files generated during superoptimization process.

# Language Constructs

### Partition Annotation

You can choose to annotate all variables and operators with partitions (logical cores) they belong to, to annotate parts of them, or to not annotate the program at all.

For example, if we modify `examples/simple/hello.cll` by removing the partition annotations of variable *a* and *b* as follows:

```
void main() {
  int a;
  int b;
  int@2 c;
  a = 1; 
  b = 2;
  c = a +@2 b;
}
```

The partitioner will complete those annotations automatically. In this example, the entire program can fit in one core, so the partitioner will assign both *a* and *b* to logical core 2 as it tries to minimize communication between cores. You can check this by rerunning the compiler and look at `example/simple/output-hello/hello.part`. 

Note that the partitioner can be very slow if it partitions a large program without much annotation. When it is very slow, you can try to annotation more, or use `--hue-partition` option when compiling.

### Data Type

Chlorophyll currently supports two primitive data types: integer and fixed point. Both data types are 18 bits, as GreenArrays is a 18-bit architecture. Use `int` for integer. Use `fixK_t` for fixed-point number with 1 bit for sign, K-1 bits for integer and 18-K bits for fractional part; for example, `fix2_t` uses 1 bits for integer and 16 bits for fractional part. The available fixed point types are `fix0_t`, `fix1_t`, ..., and `fix17_t`.

Chlorophyll also supports tuples and arrays of the primitive types.

##### Tuples
Define *x* as a tuple of 3 elements whose elements live at logical core 0, 1, and 2:
```
int::3@(0,1,2) x;
```

Reference to the first element in tuple *x*:
```
x::0
```

See `examples/simple/function-pair.cll` for an example program with tuples.

##### Arrays

Non-distributed array:
```
int@6 k[10];
```

Distributed array:
```
int@{[0:5]=6, [5:10]=7} k[10];
```
k[0] to k[4] are on core 6, and k[5] to k[9] are on core 7. Note that the beginning of the range is inclusive, while the end of the range is exclusive.

Distributed array of tuples:
```
int::2@{[0:10]=(6,7)} k[10];
```
All first elements of the tuples are in core 6, and all second elements of the tuples are in core 7.


### Parallelism

#### Parallel Module

##### Challenges of Parallelism in Chlorophyll
Say we want these two function calls to run in parallel:
```
hmm_step(acc, model1);
hmm_step(acc, model2);
```
They will not run in parallel in this implementation because only one set of partitions
are responsible for executing the function. In order to make
them run in parallel, we can use the `module` construct as follows:

```
# Define module .
module Hmm(model_init) {
fix1_t model[N] = model_init;
fix1_t step(fit1_t[] acc) { ... }
}
# Create module instances .
hmm1 = new Hmm(model1);
hmm2 = new Hmm(model2);
# Call two different functions .
hmm1.step(acc);
hmm2.step(acc);
```

This guarantees that the two module instances occupy two disjoint sets of partitions. If programmers annotation partitions inside the module, each module instance will get fresh partitions. A module can contain also contain more than one function.

#### Parallel Map and Reduce

Parallel map:
```
output_array = map(func, input_array1, input_array2, ...);
```

Parallel reduce:
```
output_var = reduce(func, init, input_array);
```

`example/mapreduce` contains example programs that use map and reduce constructs.

### IO

The following functions are provided for interacting with GA144 IO functionality.
All IO functions require the pins node coordinate as their first argument.


Set IO pin states:
```
set_io(node, state_1, ..., state_N, wakeup)
```
`state_i`: The state for GPIO pin i. see [GPIO states](#GPIO_pin_states)  
`wakeup`: Sets the state for `digital_wakeup`, either WAKEUP_LOW or WAKEUP_HIGH


Read GPIO pins:
```
digital_read(node, pin)
```
`pin`: GPIO pin number between 0 and 3. see [pin numbering](#GPIO_pin_numbering)

Returns zero if the pin is low, non-zero if the pin is high


Pin Wakeup:
```
digital_wait(node)
```
Suspends execution in the node until pin 0 is in the state specified by the
last call to `set_io`. The default is WAKEUP_HIGH.

<a name="GPIO_pin_numbering"></a>
##### GPIO pin numbering
In the Greenarrays documentation, pins are referenced by the bit positions
used to control them in the IO register. In Chlorophyll, they are numbered
sequentially from 0. For example, in Greenarrays documentation 705.17
corresponds to 705.0.

Mapping of chlorophyll pin numbers to those used in Greenarrays documentation:

| Chlorophyll | Greenarrays |
| ----------- | ----------- |
|           0 |          17 |
|           1 |           1 |
|           2 |           3 |
|           3 |           5 |


<a name="GPIO_pin_states"></a>
##### GPIO pin states

Possible states for GPIO pins:

| Pin state      | Description                |
| -------------- | -------------------------- |
| HIGH_IMPEDANCE | High impedance (tristate)  |
| WEAK_PULLDOWN  | Weak pulldown ~47 KΩ       |
| SINK           | Lo:  Sink ≤40mA to Vss     |
| SOURCE         | Hi:  Source ≤40mA from Vdd |

### Delay functions
Like IO functions, delay functions require the node as their first argument.
The shortest delay time (and resolution) is about 2.4ns.
These functions use delay loops and therefor cause the node to run at full
power. The delay time is currently limited by the 18 bit word length, so the
longest delay time is about 0.629ms.

Nanosecond Delay:
```
 delay_ns(node, time, volts)
```
`time`: time in nanoseconds to delay  
`volts`: voltage used to power the GA144(execution speed is voltage dependent).


Delay for unext loop iterations:
```
delay_unext(node, iterations)
```
`iterations`: number of 'unext' loop iterations to delay for

This function exposes the arrayforth 'unext' looping instruction.
The generated code is equivalent to "*iterations* for unext".
It is currently the only delay function that can take variable arguments.
Each iteration consumes about 2.4ns.
It is up to the programmer to turn the iterations into the
desired time, unlike `delay_ns` changes in voltage are not accounted for.

### Advanced Program Structure Partitioning

Chlorophyll's default strategy for partitioning control statements is SPMD (Single-Program Multiple-Data), duplicating control statements in all relevant partitions/cores. However, this strategy may not be desirable for every core because duplication incurs more code. `actor*` directive let programmers specify which functions should be compiler to *actors*. Programmers *actorize* a function by defining:

```
# Do not specify the requester and master actor
actor* FUNC;
# Specify the requester and master actor
actor* FUNC(REQUESTER ~> MASTER);
```
A function `FUNC` may contain one or more partitions (logical cores).
One of the actor partitions in the function is a dedicated *master
actor* partition, and the rest are *subordinate actor* partitions. A
*requester* partition is responsible for sending a remote execution
request to the master actor to invoke the function and in turn
triggers subordinate actors to invoke their functions through data
dependency. Therefore, program fragments of actor partitions of the
function `FUNC` do not need to contain the control statements between
the function `main` to the calls to `FUNC`.

`example/actor` contains example programs that use actors.

##### Restrictions
- We restrict a partition to be an actor for no more than one function. If a partition is an actor for a function, it cannot be used anywhere else outside the function. If it uses outside the function, that partition will not be an actor partition.
- If a partition is an actor for a function, it also
cannot be used for
routing messages outside the function. Thus, too much actorization
may cause the compilation to fail due to its implication on the routing
restriction
- The partition of the return of a function cannot be an actor.  For example, `actor* func(1~>2); int@2 func(int@2 x) {...}` is illegal. Usually, we assign the return to be at the same partition as the requester partition, e.g., `actor* func(1~>2); int@1 func(int@2 x) {...}`.

### Language/Compiler Limitations
- `return` can only be used at the end of a function.
- The second argument of multiplication `*` cannot be negative. Unfortunately, we have not yet supported `uint` data type, so programmers have to keep this in mind.
- We support array initialization but not yet support variable initialization.


# Bugs and Features
For a bug report or a feature request, please contact mangpo@eecs.berkeley.edu.
