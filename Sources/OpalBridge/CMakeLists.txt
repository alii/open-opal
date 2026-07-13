cmake_minimum_required(VERSION 3.20)
project(OpalBridge LANGUAGES C CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_OSX_ARCHITECTURES arm64)

# depthai's installed config pulls in its whole dependency graph (XLink, libnop,
# spdlog, libarchive, ...) with the right include dirs. Resolving those by hand
# is how you end up chasing missing headers one at a time.
find_package(depthai CONFIG REQUIRED
    PATHS "${CMAKE_CURRENT_LIST_DIR}/../../vendor/install/lib/cmake/depthai"
    NO_DEFAULT_PATH)

# Built as a dylib so the Xcode app target can link it without also having to
# understand depthai's transitive Hunter dependencies.
add_library(OpalBridge SHARED OpalBridge.cpp)

target_include_directories(OpalBridge PUBLIC
    $<BUILD_INTERFACE:${CMAKE_CURRENT_LIST_DIR}/include>)

target_link_libraries(OpalBridge PRIVATE depthai::core)

set_target_properties(OpalBridge PROPERTIES
    INSTALL_RPATH "@loader_path"
    BUILD_WITH_INSTALL_RPATH TRUE)

# Optional smoke test: exercises the real camera end-to-end.
option(OPAL_BRIDGE_TEST "Build the bridge smoke test" OFF)
if(OPAL_BRIDGE_TEST)
    add_executable(bridge_test test/bridge_test.c)
    add_executable(region_test test/region_test.c)
    target_link_libraries(region_test PRIVATE OpalBridge)
    set_target_properties(region_test PROPERTIES INSTALL_RPATH "@executable_path;${CMAKE_CURRENT_LIST_DIR}/../../vendor/install/lib" BUILD_WITH_INSTALL_RPATH TRUE)
    target_link_libraries(bridge_test PRIVATE OpalBridge)
    set_target_properties(bridge_test PROPERTIES
        INSTALL_RPATH "@executable_path;${CMAKE_CURRENT_LIST_DIR}/../../vendor/install/lib"
        BUILD_WITH_INSTALL_RPATH TRUE)
endif()
