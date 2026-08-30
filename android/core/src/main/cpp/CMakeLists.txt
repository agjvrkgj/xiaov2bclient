cmake_minimum_required(VERSION 3.22.1)

project(xiaov2b_core LANGUAGES CXX)

set(MIHOMO_LIBRARY
    "${CMAKE_CURRENT_SOURCE_DIR}/../jniLibs/${ANDROID_ABI}/libmihomo.so")

if(NOT EXISTS "${MIHOMO_LIBRARY}")
    message(FATAL_ERROR
        "Missing ${MIHOMO_LIBRARY}. Run tool/build_android_core.sh before building Android.")
endif()

add_library(mihomo SHARED IMPORTED)
set_target_properties(mihomo PROPERTIES IMPORTED_LOCATION "${MIHOMO_LIBRARY}")

add_library(xiaov2b_core SHARED core.cpp)
target_compile_features(xiaov2b_core PRIVATE cxx_std_17)
target_compile_options(xiaov2b_core PRIVATE -Wall -Wextra -Werror)
target_link_libraries(xiaov2b_core PRIVATE mihomo log)
