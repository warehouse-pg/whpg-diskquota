cmake_minimum_required(VERSION 3.20)
# cmake_path requires 3.20

project(diskquota)

if(NOT CMAKE_BUILD_TYPE)
  message(STATUS "Setting build type to 'Debug' as none was specified.")
  set(CMAKE_BUILD_TYPE "Debug" CACHE
      STRING "Choose the type of build." FORCE)
endif()

# generate 'compile_commands.json'
set(CMAKE_EXPORT_COMPILE_COMMANDS ON)

# Retrieve repository information
include(${CMAKE_CURRENT_SOURCE_DIR}/cmake/Git.cmake)
GitHash_Get(DISKQUOTA_GIT_HASH)

include(${CMAKE_CURRENT_SOURCE_DIR}/cmake/Gpdb.cmake)


# set include directories for all sub-projects
include_directories(${PG_INCLUDE_DIR_SERVER})
include_directories(${PG_INCLUDE_DIR}) # for libpq
# Overwrite the default build type flags set by cmake.
# We don't want the '-O3 -DNDEBUG' from cmake. Instead, those will be set by the CFLAGS from pg_config.
# And, the good news is, GPDB release always have '-g'.
set(CMAKE_C_FLAGS_RELEASE "" CACHE
    STRING "Flags for RELEASE build" FORCE)
set(CMAKE_C_FLAGS_DEBUG "-DDISKQUOTA_DEBUG"
    CACHE STRING "Flags for DEBUG build" FORCE)
# set link flags for all sub-projects
set(CMAKE_MODULE_LINKER_FLAGS "${PG_LD_FLAGS}")
if (APPLE)
    set(CMAKE_MODULE_LINKER_FLAGS "${CMAKE_MODULE_LINKER_FLAGS} -bundle_loader ${PG_BIN_DIR}/postgres")
endif()
# set c and ld flags for all projects
set(CMAKE_C_FLAGS "${CMAKE_C_FLAGS} ${PG_C_FLAGS}")

# generate version
if(NOT DEFINED DISKQUOTA_VERSION)
  file(STRINGS VERSION DISKQUOTA_VERSION)
endif()

string(REGEX REPLACE "^([0-9]+).[0-9]+.[0-9]+$" "\\1" DISKQUOTA_MAJOR_VERSION
                     ${DISKQUOTA_VERSION})
string(REGEX REPLACE "^[0-9]+.([0-9]+).[0-9]+$" "\\1" DISKQUOTA_MINOR_VERSION
                     ${DISKQUOTA_VERSION})
string(REGEX REPLACE "^[0-9]+.[0-9]+.([0-9]+)$" "\\1" DISKQUOTA_PATCH_VERSION
                     ${DISKQUOTA_VERSION})

if("${DISKQUOTA_MAJOR_VERSION}.${DISKQUOTA_MINOR_VERSION}" STREQUAL "1.0")
  # in special, version 1.0.x do not has suffix
  set(DISKQUOTA_BINARY_NAME "diskquota")
else()
  set(DISKQUOTA_BINARY_NAME
      "diskquota-${DISKQUOTA_MAJOR_VERSION}.${DISKQUOTA_MINOR_VERSION}")
endif()

add_compile_definitions(
  DISKQUOTA_VERSION="${DISKQUOTA_VERSION}"
  DISKQUOTA_MAJOR_VERSION=${DISKQUOTA_MAJOR_VERSION}
  DISKQUOTA_MINOR_VERSION=${DISKQUOTA_MINOR_VERSION}
  DISKQUOTA_PATCH_VERSION=${DISKQUOTA_PATCH_VERSION}
  DISKQUOTA_BINARY_NAME="${DISKQUOTA_BINARY_NAME}")

set(SRC_DIR "${CMAKE_CURRENT_SOURCE_DIR}/src")
file(GLOB diskquota_SRC "${SRC_DIR}/*.c")

set(DISKQUOTA_DDL_DIR "${CMAKE_CURRENT_SOURCE_DIR}/control/ddl")
file(GLOB diskquota_DDL "${DISKQUOTA_DDL_DIR}/*")

# WHPG19 (PG19) dropped the composite-type -> "char" I/O cast that the released
# relation_size() DDL relies on:
#
#   ERROR:  cannot cast type pg_class to "char"
#
# The cast is only reached on server lines *without* pg_class.relstorage, where
# the bare `relstorage` inside the CASE resolves to the whole-row variable of
# the `... as relstorage` alias instead of to a column. Going through text is
# equivalent everywhere, but it cannot be applied to the tracked files:
# upgrade_test/CMakeLists.txt diffs control/ddl against the last release tag, so
# editing them in place both trips that gate and silently rewrites upgrade
# scripts that have already shipped. Patch a copy in the build tree instead and
# keep the tracked DDL byte-identical to the tag.
#
# This only affects what gets *installed*: a fresh CREATE EXTENSION (and a
# dump/restore, which re-runs it) on WHPG19 gets the patched function bodies.
# A database that already carries the unpatched bodies - e.g. one brought over
# with pg_upgrade, which copies pg_proc rows as they are - keeps them and fails
# at call time with the error above; it needs the function recreated.
#
# The rewrite must not silently turn into a no-op: CREATE EXTENSION does not
# validate function bodies, so a missed spelling would only surface as the
# error above when relation_size() is first called. Hence the checks below
# fail configure if any relstorage cast is left unpatched or nothing matched.
# (Many DDL files mention `relstorage` only as a parameter type, with no cast,
# so "mentions relstorage" is not by itself a reason to expect a match.)
if(${GP_MAJOR_VERSION} GREATER_EQUAL 8)
  set(DISKQUOTA_DDL_BUILD_DIR "${CMAKE_BINARY_DIR}/ddl")
  file(MAKE_DIRECTORY ${DISKQUOTA_DDL_BUILD_DIR})
  set(diskquota_DDL_generated "")
  set(diskquota_DDL_patched_casts 0)
  foreach(ddl_file IN LISTS diskquota_DDL)
    cmake_path(GET ddl_file FILENAME ddl_name)
    set(ddl_generated "${DISKQUOTA_DDL_BUILD_DIR}/${ddl_name}")
    file(READ ${ddl_file} ddl_contents)
    # Tolerate whitespace around the cast operator.
    string(REGEX REPLACE "relstorage[ \t\r\n]*::[ \t\r\n]*\"char\""
           "relstorage::text::\"char\"" ddl_contents "${ddl_contents}")
    # Every remaining `relstorage ::` must be one we just wrote ...
    string(REGEX MATCHALL "relstorage[ \t\r\n]*::" ddl_all_casts "${ddl_contents}")
    string(REGEX MATCHALL "relstorage::text::" ddl_good_casts "${ddl_contents}")
    list(LENGTH ddl_all_casts ddl_n_all)
    list(LENGTH ddl_good_casts ddl_n_good)
    if(NOT ddl_n_all EQUAL ddl_n_good)
      message(FATAL_ERROR
              "${ddl_name}: found a `relstorage ::` cast that the WHPG19 "
              "rewrite does not handle (${ddl_n_all} casts, ${ddl_n_good} "
              "rewritten). On WHPG19 it would fail at call time with "
              "'cannot cast type pg_class to \"char\"'; extend the rewrite "
              "in CMakeLists.txt.")
    endif()
    # ... and the function-call spelling of the same cast is not covered.
    string(REGEX MATCH "[Cc][Aa][Ss][Tt][ \t\r\n]*\\([ \t\r\n]*relstorage[ \t\r\n]"
           ddl_cast_call "${ddl_contents}")
    if(ddl_cast_call)
      message(FATAL_ERROR
              "${ddl_name}: CAST(relstorage AS ...) is not handled by the "
              "WHPG19 rewrite in CMakeLists.txt.")
    endif()
    math(EXPR diskquota_DDL_patched_casts
         "${diskquota_DDL_patched_casts} + ${ddl_n_good}")
    file(WRITE ${ddl_generated} "${ddl_contents}")
    list(APPEND diskquota_DDL_generated ${ddl_generated})
    # Re-run configure when the source DDL changes, since the copies are
    # generated at configure time.
    set_property(DIRECTORY APPEND PROPERTY CMAKE_CONFIGURE_DEPENDS ${ddl_file})
  endforeach()
  if(diskquota_DDL_patched_casts EQUAL 0)
    message(FATAL_ERROR
            "WHPG19 DDL rewrite matched nothing in ${DISKQUOTA_DDL_DIR}: the "
            "relstorage cast in relation_size() was not found, so the "
            "installed DDL would still fail on PG19. The DDL spelling changed "
            "or this workaround is stale.")
  endif()
  message(STATUS "WHPG19: rewrote ${diskquota_DDL_patched_casts} relstorage casts in the installed DDL")
  set(diskquota_DDL ${diskquota_DDL_generated})
endif()

add_library(diskquota MODULE ${diskquota_SRC})

if(CMAKE_INSTALL_PREFIX_INITIALIZED_TO_DEFAULT)
  set(CMAKE_INSTALL_PREFIX
      "${PG_HOME}"
      CACHE PATH "default install prefix" FORCE)
endif()

# WHPG19 (GP8)'s c.h expanded StaticAssertDecl()/StaticAssertStmt() to the
# bare `static_assert` spelling, which is only defined as a macro by
# <assert.h> under C11+ (it's a real keyword only in C23). Under C99 it's
# just an undeclared identifier, breaking every header that uses it - a
# cascade, not a diskquota-specific bug. GP7/WHPG7 stays on C99 since its
# headers don't require more.
if(${GP_MAJOR_VERSION} GREATER_EQUAL 8)
  set(DISKQUOTA_C_STANDARD 11)
else()
  set(DISKQUOTA_C_STANDARD 99)
endif()

set_target_properties(
  diskquota
  PROPERTIES OUTPUT_NAME ${DISKQUOTA_BINARY_NAME}
             PREFIX ""
             C_STANDARD ${DISKQUOTA_C_STANDARD}
             LINKER_LANGUAGE "C")

# 2.4 targets WHPG 7 only; WHPG 6 keeps shipping from the 2.3.x tags.
if(${GP_MAJOR_VERSION} EQUAL 6)
  message(FATAL_ERROR "diskquota ${DISKQUOTA_VERSION} requires WHPG 7; "
          "build WHPG6 packages from the 2.3.x maintenance tags")
endif()

# STRGREATER_EQUAL is a *lexicographic* string comparison: "19" < "7" (since
# '1' < '7'), so this silently skipped linking libpq on GP8/WHPG19 - the
# .so built and installed fine, but crashed the postmaster at
# shared_preload_libraries load time with "undefined symbol: PQresultStatus".
# Numeric GREATER_EQUAL compares major version numbers correctly for any
# number of digits.
if (${GP_MAJOR_VERSION} GREATER_EQUAL 7)
  TARGET_LINK_LIBRARIES(diskquota ${PG_LIB_DIR}/libpq.so)
endif()

# packing part, move to a separate file if this part is too large
include(${CMAKE_CURRENT_SOURCE_DIR}/cmake/Distro.cmake)

if(DEFINED DISKQUOTA_LAST_RELEASE_PATH)
  message(STATUS "Copy pervious installer from ${DISKQUOTA_LAST_RELEASE_PATH}")
  file(ARCHIVE_EXTRACT INPUT ${DISKQUOTA_LAST_RELEASE_PATH} PATTERNS "*.so")
  file(GLOB so_files_list
       "${CMAKE_BINARY_DIR}/lib/postgresql/*.so")

  foreach(so_path IN LISTS so_files_list)
    get_filename_component(so_name ${so_path} NAME_WLE)
    # Replace 'diskquota-x.y' with 'x.y'. 'diskquota' won't be replaced, which belongs to 1.x release.
    string(REPLACE "diskquota-" "" so_ver ${so_name})
    # Install the previous so files. Those so files have versions less than current version.
    # diskqutoa.so doesn't have version string in the file name. It belongs to 1.x release.
    if((${so_ver} STREQUAL "diskquota") OR
      ${so_ver} VERSION_LESS ${DISKQUOTA_MAJOR_VERSION}.${DISKQUOTA_MINOR_VERSION})
      list(APPEND DISKQUOTA_PREVIOUS_LIBRARY ${so_path})
    endif()
  endforeach()

  install(PROGRAMS ${DISKQUOTA_PREVIOUS_LIBRARY} DESTINATION "lib/postgresql/")

  get_filename_component(
    DISKQUOTA_LAST_RELEASE_FILENAME ${DISKQUOTA_LAST_RELEASE_PATH} NAME CACHE
    "last release installer name")
  string(
    REGEX
    REPLACE "^diskquota-([0-9]+).[0-9]+.[0-9]+-.*$" "\\1"
            DISKQUOTA_LAST_MAJOR_VERSION ${DISKQUOTA_LAST_RELEASE_FILENAME})
  string(
    REGEX
    REPLACE "^diskquota-[0-9]+.([0-9]+).[0-9]+-.*$" "\\1"
            DISKQUOTA_LAST_MINOR_VERSION ${DISKQUOTA_LAST_RELEASE_FILENAME})
  string(
    REGEX
    REPLACE "^diskquota-[0-9]+.[0-9]+.([0-9]+)-.*$" "\\1"
            DISKQUOTA_LAST_PATCH_VERSION ${DISKQUOTA_LAST_RELEASE_FILENAME})

  set(DISKQUOTA_LAST_VERSION
      "${DISKQUOTA_LAST_MAJOR_VERSION}.${DISKQUOTA_LAST_MINOR_VERSION}.${DISKQUOTA_LAST_PATCH_VERSION}"
  )
endif()

set(tgz_NAME
    "diskquota-${DISKQUOTA_MAJOR_VERSION}.${DISKQUOTA_MINOR_VERSION}.${DISKQUOTA_PATCH_VERSION}-${DISTRO_NAME}_x86_64"
)
set(CPACK_GENERATOR "TGZ")
set(CPACK_INCLUDE_TOPLEVEL_DIRECTORY OFF)
set(CPACK_PACKAGE_FILE_NAME ${tgz_NAME})
include(CPack)
# create_artifact target is used to tar the package with version into a version-less tarball to be
# used on concourse gcs resource. It will be uploaded to a gcs version file (no diskquota version
# string in the file name), and be retrieved in the release step. Then we don't have to firgure out
# a way to add the version string back to the release file name, just untar it.
set(artifact_NAME "diskquota.tar.gz")
add_custom_target(create_artifact
  COMMAND
  ${CMAKE_COMMAND} --build . --target package
  COMMAND
  ${CMAKE_COMMAND} -E tar czvf ${artifact_NAME} "${tgz_NAME}.tar.gz")
# packing end

# Create build-info
# The diskquota-build-info shouldn't be copied to GPDB release by install_gpdb_component
include(${CMAKE_CURRENT_SOURCE_DIR}/cmake/BuildInfo.cmake)
set(build_info_PATH ${CMAKE_CURRENT_BINARY_DIR}/diskquota-build-info)
BuildInfo_Create(${build_info_PATH}
  VARS
  DISKQUOTA_GIT_HASH
  DISKQUOTA_VERSION
  GP_MAJOR_VERSION
  GP_VERSION
  CMAKE_BUILD_TYPE)
# Create build-info end

# Add installcheck targets
add_subdirectory(tests)
add_subdirectory(upgrade_test)

# NOTE: keep install part at the end of file, to overwrite previous binary
install(PROGRAMS "cmake/install_gpdb_component" DESTINATION ".")
install(FILES ${diskquota_DDL} DESTINATION "share/postgresql/extension/")
install(TARGETS diskquota DESTINATION "lib/postgresql/")
install(FILES ${build_info_PATH} DESTINATION ".")
