cmake_minimum_required(VERSION 3.22.1)
project(cleartone_audio_engine CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

find_package(oboe REQUIRED CONFIG)

add_library(cleartone_audio_engine SHARED audio_engine.cpp)

target_link_libraries(cleartone_audio_engine
    oboe::oboe
    log
    android
)
