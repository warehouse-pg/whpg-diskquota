include(${CMAKE_SOURCE_DIR}/cmake/Regress.cmake)

list(APPEND isolation2_expected_DIR ${CMAKE_CURRENT_SOURCE_DIR}/isolation2/expected)
list(APPEND regress_expected_DIR ${CMAKE_CURRENT_SOURCE_DIR}/regress/expected)
# GP_MAJOR_VERSION >= 7 covers both GP7 (PG12-based, WHPG7) and GP8 (PG19-based,
# WHPG19) - both use the same plpython3u/gp_role=dispatch test setup introduced
# in GP7. Only GP6 and earlier used plpython2u / the "-E" postmaster flag, and
# there is no supported GP6 target for this branch anymore, so this was
# previously mis-gated as "== 7" (which silently fell through to the GP6-era
# else branch for GP8/WHPG19, where plpython2u doesn't even exist).
if (${GP_MAJOR_VERSION} GREATER_EQUAL 7)
  list(APPEND isolation2_expected_DIR ${CMAKE_CURRENT_SOURCE_DIR}/isolation2/expected7)
  list(APPEND regress_expected_DIR ${CMAKE_CURRENT_SOURCE_DIR}/regress/expected7)
  # PLPYTHON_LANG_STR will be replaced by Regress.cmake
  set(PLPYTHON_LANG_STR "plpython3u")
  set(POSTMASTER_START_CMD "pg_ctl -D $MASTER_DATA_DIRECTORY -w -o \"-c gp_role=dispatch\" start")
else()
  set(PLPYTHON_LANG_STR "plpython2u")
  set(POSTMASTER_START_CMD "pg_ctl -D $MASTER_DATA_DIRECTORY -w -o \"-E\" start")
endif()

# WHPG19 (GP8/PG19) differs from GP7 in a few server-side behaviours that change
# expected output - e.g. the AO block directory relation is now created eagerly
# for every AO table, so it shows up alongside aoseg/aovisimap in the rejectmap.
# Directories later in the list win, so these files override the expected7 ones
# for the handful of tests that differ.
if (${GP_MAJOR_VERSION} GREATER_EQUAL 19)
  list(APPEND isolation2_expected_DIR ${CMAKE_CURRENT_SOURCE_DIR}/isolation2/expected19)
  list(APPEND regress_expected_DIR ${CMAKE_CURRENT_SOURCE_DIR}/regress/expected19)
endif()

set(exclude_fault_injector OFF)
# GP7 release build doesn't support fault injector.
if (CMAKE_BUILD_TYPE STREQUAL "Release")
  message(WARNING "Fault injector test cases will be disabled.")
  set(exclude_fault_injector ON)
endif()

RegressTarget_Add(regress
    INIT_FILE
    ${CMAKE_CURRENT_SOURCE_DIR}/init_file
    SQL_DIR ${CMAKE_CURRENT_SOURCE_DIR}/regress/sql
    EXPECTED_DIR ${regress_expected_DIR}
    RESULTS_DIR ${CMAKE_CURRENT_SOURCE_DIR}/regress/results
    DATA_DIR ${CMAKE_CURRENT_SOURCE_DIR}/data
    SCHEDULE_FILE ${CMAKE_CURRENT_SOURCE_DIR}/regress/diskquota_schedule
    EXCLUDE_FAULT_INJECT_TEST ${exclude_fault_injector}
    REGRESS_OPTS
    --load-extension=gp_inject_fault
    --load-extension=diskquota_test
    --dbname=contrib_regression)

RegressTarget_Add(isolation2
    REGRESS_TYPE
    isolation2
    INIT_FILE
    ${CMAKE_CURRENT_SOURCE_DIR}/init_file
    SQL_DIR ${CMAKE_CURRENT_SOURCE_DIR}/isolation2/sql
    EXPECTED_DIR ${isolation2_expected_DIR}
    RESULTS_DIR ${CMAKE_CURRENT_SOURCE_DIR}/isolation2/results
    DATA_DIR ${CMAKE_CURRENT_SOURCE_DIR}/data
    SCHEDULE_FILE ${CMAKE_CURRENT_SOURCE_DIR}/isolation2/isolation2_schedule
    EXCLUDE_FAULT_INJECT_TEST ${exclude_fault_injector}
    REGRESS_OPTS
    --load-extension=gp_inject_fault
    --dbname=isolation2test)

add_custom_target(install_test_extension
  COMMAND
  cmake -E copy ${CMAKE_SOURCE_DIR}/control/test/diskquota_test.control ${PG_HOME}/share/postgresql/extension
  COMMAND
  cmake -E copy ${CMAKE_SOURCE_DIR}/control/test/diskquota_test--1.0.sql ${PG_HOME}/share/postgresql/extension
  )

add_custom_target(installcheck)
add_dependencies(isolation2 install_test_extension)
add_dependencies(regress install_test_extension)
add_dependencies(installcheck isolation2 regress)

# Example to run test_truncate infinite times
# RegressTarget_Add(regress_config
#     INIT_FILE
#     ${CMAKE_CURRENT_SOURCE_DIR}/init_file
#     SQL_DIR ${CMAKE_CURRENT_SOURCE_DIR}/regress/sql
#     EXPECTED_DIR ${CMAKE_CURRENT_SOURCE_DIR}/regress/expected
#     RESULTS_DIR ${CMAKE_CURRENT_SOURCE_DIR}/regress/results
#     DATA_DIR ${CMAKE_CURRENT_SOURCE_DIR}/data
#     REGRESS
#     config test_create_extension
#     REGRESS_OPTS
#     --load-extension=gp_inject_fault
#     --dbname=contrib_regression)
# RegressTarget_Add(regress_truncate_loop
#     INIT_FILE
#     ${CMAKE_CURRENT_SOURCE_DIR}/init_file
#     SQL_DIR ${CMAKE_CURRENT_SOURCE_DIR}/regress/sql
#     EXPECTED_DIR ${CMAKE_CURRENT_SOURCE_DIR}/regress/expected
#     RESULTS_DIR ${CMAKE_CURRENT_SOURCE_DIR}/regress/results
#     DATA_DIR ${CMAKE_CURRENT_SOURCE_DIR}/data
#     REGRESS
#     test_truncate
#     RUN_TIMES -1
#     REGRESS_OPTS
#     --load-extension=gp_inject_fault
#     --dbname=contrib_regression
#     --use-existing)
# add_dependencies(regress_truncate_loop regress_config)
# add_dependencies(installcheck regress_truncate_loop)
