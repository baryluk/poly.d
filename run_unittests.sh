#!/bin/sh

time dmd -O -inline -release -unittest -main -version=poly_debug -run poly.d

time ldc2 -g -mcpu=native -O3 --release --boundscheck=off --unittest --main --d-version=poly_debug --run poly.d

time gdc-10 -march=native -O3 -frelease -fversion=poly_debug -funittest -fmain -o poly poly.d && ./poly
