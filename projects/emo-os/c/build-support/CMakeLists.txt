# The CMake leg (T4.3): the toolchain file names the sysroot wrapper.
cmake_minimum_required(VERSION 3.13)
project(emoos_build_probe C)
add_executable(probe main.c)
