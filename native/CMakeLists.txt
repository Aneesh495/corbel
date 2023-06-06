cmake_minimum_required(VERSION 3.16)
project(corbel_simd C)

set(CMAKE_C_STANDARD 11)
set(CMAKE_C_STANDARD_REQUIRED ON)

if(MSVC)
  add_compile_options(/O2)
else()
  add_compile_options(-O3 -fPIC)
  if(CMAKE_SYSTEM_PROCESSOR MATCHES "x86_64|AMD64")
    add_compile_options(-mavx2 -mfma)
  endif()
endif()

include_directories(include)

add_library(corbel_simd SHARED
  src/corbel_simd.c
)

target_include_directories(corbel_simd PUBLIC
  $<BUILD_INTERFACE:${CMAKE_CURRENT_SOURCE_DIR}/include>
  $<INSTALL_INTERFACE:include>
)

set_target_properties(corbel_simd PROPERTIES
  OUTPUT_NAME "corbel_simd"
  C_VISIBILITY_PRESET default
)
