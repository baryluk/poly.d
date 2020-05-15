/***
 *
 * poly.d - Customizable runtime polymorphism library for D programming language.
 *
 * Copyright: Witold Baryluk, 2020
 *
 * TODO(baryluk): This is **work in progress** and more of a quick prototype,
 * and it doesn't yet support everything it should.
 *
 * Based on techniques often done manually, wrapped in library that can do it
 * automatically for you. The exact behaviour can be parametrized by the user
 * at compile time.
 *
 * Also somehow based on idea by Louis Dionne in C++ world:
 *  * https://github.com/ldionne/dyno - [Dyno: Runtime polymorphism done right](https://github.com/ldionne/dyno)
 *  * Video Talk: [CppCon 2017: Louis Dionne “Runtime Polymorphism: Back to the Basics”](https://www.youtube.com/watch?v=gVGtNFg4ay0)
 *
 * but using D programming language features to make its implementation
 * significantly simpler, and allowing even less boilerplate in the code.
 *
 * The types provided by this library are sometimes called fat pointers,
 * or using inlined vtable.
 *
 * Library provided various options and policies for storage and call dispatch,
 * including local storage, small buffer optimization, remote storage,
 * shared storage, non-owned (raw) storage, GC and non-GC destruction,
 * and ability to emulate value semantics using references.
 *
 * Primary purpose would be to pass or store multiple types implementing same
 * "interface" by value. I.e. allow storing it on stack, avoiding dynamic heap
 * allocation. This can have considerable performance benefits.
 *
 * Similarly the polymorphic call dispatch can be optimized a bit better in many
 * cases, by avoiding extra indirection and providing better information to
 * branch predictor.
 *
 * The use of vtable inlineing option (disabled by default) available by this
 * library should be measured or benchmarked on real code, because the performance
 * and space usage can vary significantly depending on many factors (object size,
 * number of methods, access patterns, number of different objects being used in hot
 * path, CPU architecture, CPU model used, in particular cache system, and branch
 * predictor, compiler and compiler options used).
 *
 * Tested on compilers and phobos libraries:
 *  * DMD v2.092.0, amd64, Linux amd64
 *  * LDC2 1.20.1 (DMD v2.090.1, LLVM 9.0.1), amd64, Linux amd64, libphobos2-ldc-shared90
 *  * GDC 10.1.0-1, amd64, Linux amd64
 */

module poly;

import std.traits;

struct vtable(Interface) {
  static assert(__traits(isAbstractClass, Interface));
  static assert(__traits(isFinalClass, Interface));

  static foreach (member; __traits(derivedMembers, Interface)) {
    static if (isFunction!(__traits(getMember, Interface, member))) {
      // TODO(baryluk): Propagate const and other attributes.
      mixin("ReturnType!(__traits(getMember, Interface, member)) function(void* ptr, Parameters!(__traits(getMember, Interface, member)) args) @trusted " ~ member ~ ";");
    }
  }
}

struct vtable_for(Interface, T) {
  static assert(__traits(isAbstractClass, Interface));
  static assert(__traits(isFinalClass, Interface));

  static vtable!Interface* create() {
    static vtable!Interface vtable_;
    version(poly_debug) pragma(msg, "Generating vtable_for!(" ~ Interface.stringof ~ ", " ~ T.stringof ~ ")");
    version(poly_debug) __ctfeWrite("Generating vtable_for!(" ~ Interface.stringof ~ ", " ~ T.stringof ~ ")");
    static foreach (member; __traits(derivedMembers, Interface)) {
      static if (isFunction!(__traits(getMember, Interface, member))) {
        // TODO(baryluk): Propagate const and other attributes.
        version(poly_debug) pragma(msg, "  vtable_." ~ member ~ " = ReturnType!(__traits(getMember, Interface, member)) function(void* ptr, Parameters!(__traits(getMember, Interface, member)) args) @trusted { return (cast(T*)(ptr))." ~ member ~ "(args); };");
        version(poly_debug) __ctfeWrite("  vtable_." ~ member ~ " = ReturnType!(__traits(getMember, Interface, member)) function(void* ptr, Parameters!(__traits(getMember, Interface, member)) args) @trusted { return (cast(T*)(ptr))." ~ member ~ "(args); };");
        mixin("vtable_." ~ member ~ " = function ReturnType!(__traits(getMember, Interface, member)) (void* ptr, Parameters!(__traits(getMember, Interface, member)) args) @trusted { return (cast(T*)(ptr))." ~ member ~ "(args); };");
      }
    }
    return &vtable_;
  }
}


struct generate_poly(Interface, string options = "") if (__traits(isAbstractClass, Interface) && __traits(isFinalClass, Interface)) {
  static assert(__traits(isAbstractClass, Interface));
  static assert(__traits(isFinalClass, Interface));

  @disable this();

  this(T)(T x) {
    vtable_ = vtable_for!(Interface, T).create();
    storage_ = cast(void*)(&x);
  }
  import std.conv : to;

  static foreach (member; __traits(derivedMembers, Interface)) {
    // TODO(baryluk): Skip @disable members, using __traits(isDisabled, m).
    static if (isFunction!(__traits(getMember, Interface, member))) {
      mixin("auto " ~ member  ~ "(Parameters!(__traits(getMember, Interface, member)) args) { return vtable_." ~ member ~ "(storage_, args); }");
      // TODO(baryluk): Utilize functionAttributes!member to copy function attributes.
      // TODO(baryluk): Support method overloading.
      // TODO(baryluk): Support passing this and dynamically casting to supported typed
      // for argument (a form of covariance), based on polcy.
    }
  }

  /**  TODO(baryluk): Allow overloads, of the type:
   *
   * struct Truck {
   *   Truck merge(Truck other) {
   *   }
   * }
   *
   * Generated Vehicle code should be able to receive Vehicle as input, and
   * return back Vehicle as output.
   * The check if the Vehicle is actually truck, and is mergable can be done at
   * runtime.
   * If the Truck supports merging with Truck or Plane or Car, do a dispatch at
   * runtime for all supported types. Yay.
   */

  // TODO(baryluk): Add a method or pointer like _name() to return a underlying
  // type name.
  // TODO(baryluk): At the moment, one can compare unlderying types by directly
  // comparying vtable_ between objects.

  const vtable!Interface* vtable_;
 private:
  void* storage_;
}



// To run unittest, depending on the compiler use for example one of:
//   dmd -O -inline -release -unittest -main -version=poly_debug -run poly.d
//   ldc2 -g -mcpu=native -O3 --release --boundscheck=off --unittest --main --d-version=poly_debug --run poly.d
//   gdc-10 -march=native -O3 -frelease -fversion=poly_debug -funittest -fmain -o poly poly.d && ./poly
// To run benchmarks, use for example: dmd -O -inline -release -boundscheck=off -unittest -main -version=benchmark poly.d
unittest {
  import std.stdio;

  final interface IVehicle {
    void draw(int x, int y);
    float accelerate(const float x) @nogc;
    string name() pure;
  }

  // Will automatically create a struct (value semantics) with all methods,
  // dispatch tables and constructors.
  alias Vehicle = generate_poly!IVehicle;

  import std.conv : to;

  struct Truck {
    void draw(int x, int y) { writefln("Truck %d %d", x, y); }
    float accelerate(float x) { return a += x; }
    string name() { return "a=" ~ to!string(a); }
   private:
    float a;
  }

  struct Rock {
    void draw(int x, int y) { writefln("Rock %d", x + y); }
    float accelerate(float x) { return a; }
    string name() { return "Rock"; }
   private:
    float a;
  }

  // Some example function that receives any Vehicle type.
  float f(Vehicle v) {
    v.draw(1, 2);
    v.accelerate(2.0);
    writefln("name: %s", v.name());
    return v.accelerate(3.0);
  }

  Truck truck1 = {5.0};
  Rock rock1 = {7.0};

  f(Vehicle(truck1));
  f(Vehicle(rock1));

  Vehicle[] vehicles = [Vehicle(truck1), Vehicle(rock1)];

  foreach (ref vehicle; vehicles) {
    f(vehicle);
  }
}
