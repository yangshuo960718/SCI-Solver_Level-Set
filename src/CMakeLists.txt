cmake_minimum_required(VERSION 2.8)
project(LevelSet_Solver)

if(${CMAKE_SYSTEM_NAME} MATCHES "Windows")
  add_definitions(-D_CRT_SECURE_NO_WARNINGS)
endif()

SET(BUILD_EXAMPLES false CACHE BOOL "Build sample executables")

find_package(CUDA REQUIRED)

###################
# Externals
set(EXTERNAL_DIR "${CMAKE_BINARY_DIR}/externals")
include(ExternalProject)
# Eikonal EXTERNAL
set(EIKONAL_INSTALL_DIR "${EXTERNAL_DIR}/eikonal")
file( WRITE ${CMAKE_BINARY_DIR}/generated/CMakeLists.txt
  "cmake_minimum_required( VERSION 2.8 )\n"
  "add_subdirectory( src )\n"
  )
ExternalProject_Add(eikonal
  PREFIX "${EIKONAL_INSTALL_DIR}"
  GIT_REPOSITORY "https://github.com/SCIInstitute/SCI-Solver_Eikonal.git"
  CMAKE_ARGS -DBUILD_TESTING:bool=off -DBUILD_EXAMPLES:bool=off
  UPDATE_COMMAND ${CMAKE_COMMAND} -E copy ${CMAKE_BINARY_DIR}/generated/CMakeLists.txt ${EIKONAL_INSTALL_DIR}/src/eikonal
  INSTALL_DIR "${EIKONAL_INSTALL_DIR}/include"
  BINARY_DIR "${EIKONAL_INSTALL_DIR}/lib"
  INSTALL_COMMAND ""
  )
include_directories("${EIKONAL_INSTALL_DIR}/src/eikonal/src/core3d/include")
include_directories("${EIKONAL_INSTALL_DIR}/src/eikonal/src/core2d/include")
include_directories("${EIKONAL_INSTALL_DIR}/lib/externals/metis/include")
SET(EIKONAL2D_LIB ${EIKONAL_INSTALL_DIR}/lib/src/core2d/${CMAKE_STATIC_LIBRARY_PREFIX}Eikonal-2D_CORE${CMAKE_STATIC_LIBRARY_SUFFIX})
SET(EIKONAL3D_LIB ${EIKONAL_INSTALL_DIR}/lib/src/core3d/${CMAKE_STATIC_LIBRARY_PREFIX}Eikonal-3D_CORE${CMAKE_STATIC_LIBRARY_SUFFIX})
SET(METIS_LIB ${EIKONAL_INSTALL_DIR}/lib/externals/metis/lib/${CMAKE_STATIC_LIBRARY_PREFIX}metis${CMAKE_STATIC_LIBRARY_SUFFIX})
include_directories("${EIKONAL_INSTALL_DIR}/lib/externals/cusp/src")
###################
#CMAKE SETTING CUDA_NVCC_FLAGS
#############################
# Check for GPUs present and their compute capability
# based on http://stackoverflow.com/questions/2285185/easiest-way-to-test-for-existence-of-cuda-capable-gpu-from-cmake/2297877#2297877 (Christopher Bruns)
if(CUDA_FOUND AND NOT CUDA_HAVE_GPU)
  message(STATUS "Checking CUDA compute capability.")
  try_run(RUN_RESULT_VAR COMPILE_RESULT_VAR
    ${CMAKE_BINARY_DIR}
    ${CMAKE_SOURCE_DIR}/cuda_compute_capability.c
    CMAKE_FLAGS
    -DINCLUDE_DIRECTORIES:STRING=${CUDA_TOOLKIT_INCLUDE}
    -DLINK_LIBRARIES:STRING=${CUDA_CUDART_LIBRARY}
    COMPILE_OUTPUT_VARIABLE COMPILE_OUTPUT_VAR
    RUN_OUTPUT_VARIABLE RUN_OUTPUT_VAR)
  # COMPILE_RESULT_VAR is TRUE when compile succeeds
  # RUN_RESULT_VAR is zero when a GPU is found
  if(COMPILE_RESULT_VAR AND NOT RUN_RESULT_VAR)
    set(CUDA_HAVE_GPU TRUE CACHE INTERNAL BOOL "Whether CUDA-capable GPU is present")
    set(CUDA_COMPUTE_CAPABILITY ${RUN_OUTPUT_VAR} CACHE STRING "Compute capability of CUDA-capable GPU present")
    set(CUDA_GENERATE_CODE "arch=compute_${CUDA_COMPUTE_CAPABILITY},code=sm_${CUDA_COMPUTE_CAPABILITY}" CACHE STRING "Which GPU architectures to generate code for (each arch/code pair will be passed as --generate-code option to nvcc, separate multiple pairs by ;)")
    mark_as_advanced(CUDA_COMPUTE_CAPABILITY CUDA_GENERATE_CODE)
    LIST(REMOVE_ITEM CUDA_NVCC_FLAGS "-arch=sm_10" "-arch=sm_11" "-arch=sm_12" "-arch=sm_13" "-arch=sm_20" "-arch=sm_21" "-arch=sm_30" "-arch=sm_31")
    set(CUDA_NVCC_FLAGS "${CUDA_NVCC_FLAGS};-arch=sm_${CUDA_COMPUTE_CAPABILITY}"  CACHE LIST "Semi-colon delimit multiple arguments." FORCE)
    message(STATUS "Automatic Compute Capability Set: ${CUDA_COMPUTE_CAPABILITY}")
  else()
    message(STATUS "You must set your compute capability manually")
    set(CUDA_HAVE_GPU FALSE CACHE INTERNAL BOOL "Whether CUDA-capable GPU is present")
  endif()
endif()

IF (NOT CUDA_HAVE_GPU)
  SET(CUDA_USE_COMPUTE_CAPABILITY_10 false CACHE BOOL "Use Compute Capability 1.0")
  SET(CUDA_USE_COMPUTE_CAPABILITY_11 false CACHE BOOL "Use Compute Capability 1.1")
  SET(CUDA_USE_COMPUTE_CAPABILITY_12 false CACHE BOOL "Use Compute Capability 1.2")
  SET(CUDA_USE_COMPUTE_CAPABILITY_13 false CACHE BOOL "Use Compute Capability 1.3")
  SET(CUDA_USE_COMPUTE_CAPABILITY_20 true CACHE BOOL "Use Compute Capability 2.0")
  SET(CUDA_USE_COMPUTE_CAPABILITY_21 false CACHE BOOL "Use Compute Capability 2.1")

  IF(CUDA_USE_COMPUTE_CAPABILITY_10)
    LIST(REMOVE_ITEM CUDA_NVCC_FLAGS "-arch=sm_10" "-arch=sm_11" "-arch=sm_12" "-arch=sm_13" "-arch=sm_20" "-arch=sm_21")
    LIST(APPEND CUDA_NVCC_FLAGS "-arch=sm_10")
    SET(CUDA_NVCC_FLAGS ${CUDA_NVCC_FLAGS} CACHE LIST "Semi-colon delimit multiple arguments." FORCE)
    set(CUDA_HAVE_GPU TRUE CACHE INTERNAL BOOL "Whether CUDA-capable GPU is present")
  ELSEIF(CUDA_USE_COMPUTE_CAPABILITY_11)
    LIST(REMOVE_ITEM CUDA_NVCC_FLAGS "-arch=sm_10" "-arch=sm_11" "-arch=sm_12" "-arch=sm_13" "-arch=sm_20" "-arch=sm_21")
    LIST(APPEND CUDA_NVCC_FLAGS "-arch=sm_11")
    SET(CUDA_NVCC_FLAGS ${CUDA_NVCC_FLAGS} CACHE LIST "Semi-colon delimit multiple arguments." FORCE)
    set(CUDA_HAVE_GPU TRUE CACHE INTERNAL BOOL "Whether CUDA-capable GPU is present")
  ELSEIF(CUDA_USE_COMPUTE_CAPABILITY_12)
    LIST(REMOVE_ITEM CUDA_NVCC_FLAGS "-arch=sm_10" "-arch=sm_11" "-arch=sm_12" "-arch=sm_13" "-arch=sm_20" "-arch=sm_21")
    LIST(APPEND CUDA_NVCC_FLAGS "-arch=sm_12")
    SET(CUDA_NVCC_FLAGS ${CUDA_NVCC_FLAGS} CACHE LIST "Semi-colon delimit multiple arguments." FORCE)
    set(CUDA_HAVE_GPU TRUE CACHE INTERNAL BOOL "Whether CUDA-capable GPU is present")
  ELSEIF(CUDA_USE_COMPUTE_CAPABILITY_13)
    LIST(REMOVE_ITEM CUDA_NVCC_FLAGS "-arch=sm_10" "-arch=sm_11" "-arch=sm_12" "-arch=sm_13" "-arch=sm_20" "-arch=sm_21")
    LIST(APPEND CUDA_NVCC_FLAGS "-arch=sm_13")
    SET(CUDA_NVCC_FLAGS ${CUDA_NVCC_FLAGS} CACHE LIST "Semi-colon delimit multiple arguments." FORCE)
    set(CUDA_HAVE_GPU TRUE CACHE INTERNAL BOOL "Whether CUDA-capable GPU is present")
  ELSEIF(CUDA_USE_COMPUTE_CAPABILITY_20)
    LIST(REMOVE_ITEM CUDA_NVCC_FLAGS "-arch=sm_10" "-arch=sm_11" "-arch=sm_12" "-arch=sm_13" "-arch=sm_20" "-arch=sm_21")
    LIST(APPEND CUDA_NVCC_FLAGS "-arch=sm_20")
    SET(CUDA_NVCC_FLAGS ${CUDA_NVCC_FLAGS} CACHE LIST "Semi-colon delimit multiple arguments." FORCE)
    set(CUDA_HAVE_GPU TRUE CACHE INTERNAL BOOL "Whether CUDA-capable GPU is present")
  ELSEIF(CUDA_USE_COMPUTE_CAPABILITY_21)
    LIST(REMOVE_ITEM CUDA_NVCC_FLAGS "-arch=sm_10" "-arch=sm_11" "-arch=sm_12" "-arch=sm_13" "-arch=sm_20" "-arch=sm_21")
    LIST(APPEND CUDA_NVCC_FLAGS "-arch=sm_21")
    SET(CUDA_NVCC_FLAGS ${CUDA_NVCC_FLAGS} CACHE LIST "Semi-colon delimit multiple arguments." FORCE)
    set(CUDA_HAVE_GPU TRUE CACHE INTERNAL BOOL "Whether CUDA-capable GPU is present")
  ENDIF()
ENDIF ()

IF(NOT CUDA_HAVE_GPU)
  message( FATAL_ERROR "You must set your compute capability" )
ENDIF()
#END CMAKE SETTING CUDA_NVCC_FLAGS
###################
# Core / Examples
add_subdirectory(core3d)
add_subdirectory(core2d)
include_directories(core2d/include core3d/include )
include_directories(${CMAKE_CURRENT_DIRECTORY})
CUDA_ADD_LIBRARY(LEVELSET_CORE LevelSet.cu LevelSet.h)
TARGET_LINK_LIBRARIES(LEVELSET_CORE LEVELSET-2D_CORE LEVELSET-3D_CORE)

if (${BUILD_EXAMPLES})
  add_subdirectory(examples)
endif()
###################
# Testing
INCLUDE(CTest)
if (BUILD_TESTING)
  ENABLE_TESTING()
  # Use gcov for code coverage (useful for seeing test completeness)
  OPTION(USE_GCOV "Enable code coverage for GNUCXX Platforms" OFF)
  if (USE_GCOV)
    if(CMAKE_COMPILER_IS_GNUCXX)
      INCLUDE(${PROJECT_SOURCE_DIR}/CodeCoverage.cmake)
      SET(CMAKE_CXX_FLAGS "-g -O0 -fprofile-arcs -ftest-coverage")
      SET(CMAKE_C_FLAGS "-g -O0 -fprofile-arcs -ftest-coverage")
    endif()
  endif()
  ADD_SUBDIRECTORY(test)
endif()
