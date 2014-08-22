include(FindPackageHandleStandardArgs)
include(PythonInstall)
include(TargetCopyFiles)
include(EnvironmentScript)

if(NOT PYTHON_BINARY_DIR)
    set(PYTHON_BINARY_DIR "${PROJECT_BINARY_DIR}/python_package"
        CACHE PATH "Location of python package in build tree")
endif()
add_to_python_path(${PYTHON_BINARY_DIR})
set(DEPS_SCRIPT
    ${CMAKE_CURRENT_LIST_DIR}/find_cython_deps.py
    CACHE INTERNAL "Script to determine cython dependencies"
)

function(_pm_location_and_name module module_LOCATION)
    string(REGEX REPLACE "\\." "/" location "${module}")
    get_filename_component(submodule "${location}" NAME)

    set(submodule ${submodule} PARENT_SCOPE)

    if(NOT "${module_LOCATION}" STREQUAL "")
        set(location ${module_LOCATION} PARENT_SCOPE)
    endif()

    set(location ${location} PARENT_SCOPE)
endfunction()

function(_pm_default)
    if(${module}_NOINSTALL)
        set(do_install FALSE PARENT_SCOPE)
    else()
        set(do_install TRUE PARENT_SCOPE)
    endif()
    if(NOT ${module}_CPP)
        set(${module}_CPP "" PARENT_SCOPE)
    else()
        set(${module}_CPP CPP PARENT_SCOPE)
    endif()

    unset(excluded)
    if(${module}_EXCLUDE)
        file(GLOB files RELATIVE
            "${CMAKE_CURRENT_SOURCE_DIR}" ${${module}_EXCLUDE})
        list(APPEND excluded ${files})
    endif()

    unset(sources)
    if(NOT "${${module}_SOURCES}" STREQUAL "")
        file(GLOB sources RELATIVE
            "${CMAKE_CURRENT_SOURCE_DIR}" ${${module}_SOURCES})
        if(NOT "${excluded}" STREQUAL "")
            list(REMOVE_ITEM sources ${excluded})
        endif()
        list(REMOVE_DUPLICATES sources)
    endif()

    if("${sources}" STREQUAL "")
        message(FATAL_ERROR "Python module has no sources")
    endif()
    set(ALL_SOURCES ${sources} PARENT_SCOPE)
endfunction()

function(_pm_filter_list output input)
    unset(result)
    foreach(filename ${${input}})
        foreach(pattern ${ARGN})
            if("${filename}" MATCHES "${pattern}")
                list(APPEND result "${filename}")
            endif()
        endforeach()
    endforeach()
    set(${output} ${result} PARENT_SCOPE)
endfunction()

function(get_pyx_dependencies SOURCE OUTVAR)
    set(local_python "${LOCAL_PYTHON_EXECUTABLE}")
    if(NOT "${local_python}")
        set(local_python ${PYTHON_EXECUTABLE})
    endif()
    execute_process(
        COMMAND ${local_python} ${DEPS_SCRIPT} ${SOURCE} ${ARGN}
        RESULT_VARIABLE RESULT
        OUTPUT_VARIABLE OUTPUT
        ERROR_VARIABLE ERROR
        WORKING_DIRECTORY "${CMAKE_CURRENT_SOURCE_DIR}"
    )
    if("${RESULT}" STREQUAL "0")
        set(${OUTVAR} ${OUTPUT} PARENT_SCOPE)
    else()
        message("Error: ${ERROR}")
        message("Output: ${OUTPUT}")
        message(FATAL_ERROR "Error while computing cython dependencies")
    endif()
endfunction()

function(_pm_add_fake_init location)
    set(fake_init_file "${PYTHON_BINARY_DIR}/${location}/__init__.py")
    if(NOT EXISTS "${fake_init_file}")
        file(WRITE "${fake_init_file}" "# Empty file added by CMake")
    endif()
    if(do_install)
        install_python(FILES "${fake_init_file}" DESTINATION ${location})
    endif()
endfunction()

function(python_extension_targetname outvar module)
    cmake_parse_arguments(_pm_tgname
        ""
        "MODULE_TARGET"
        ";"
        ${ARGN}
    )
    set(module_target ${module}-ext)
    if(NOT "${_pm_tgname_MODULE_TARGET}" STREQUAL "")
        set(module_target ${_pm_tgname_MODULE_TARGET})
    endif()
    set(${outvar} ${module_target} PARENT_SCOPE)
endfunction()

function(_pm_add_python_extension module)
    string(REGEX REPLACE "/" "_" ext "ext.${module}")
    cmake_parse_arguments(${ext}
        ""
        "INSTALL;TARGET;LOCATION;EXTENSION;MODULE_TARGET"
        "SOURCES;LIBRARIES"
        ${ARGN}
    )
    if("${${ext}_SOURCES}" STREQUAL "")
        return()
    endif()

    include_directories(${PYTHON_INCLUDE_DIRS})
    if(NUMPY_INCLUDE_DIRS)
        include_directories(${NUMPY_INCLUDE_DIRS})
    endif()

    set(location ${${ext}_LOCATION})
    set(container_target ${${ext}_TARGET})
    python_extension_targetname(module_target
        ${${ext}_TARGET} MODULE_TARGET ${${ext}_MODULE_TARGET})

    add_library(${module_target} MODULE ${${ext}_SOURCES})
    target_link_libraries(${module_target} ${PYTHON_LIBRARIES})
    set(output_dir "${location}")
    if(NOT IS_ABSOLUTE "${location}")
        set(output_dir "${PYTHON_BINARY_DIR}/${location}")
    endif()
    set_target_properties(${module_target}
        PROPERTIES
        OUTPUT_NAME "${${ext}_EXTENSION}"
        PREFIX "" SUFFIX ".so"
        LIBRARY_OUTPUT_DIRECTORY "${output_dir}"
    )
    if(${ext}_LIBRARIES)
        target_link_libraries(${module_target} ${${ext}_LIBRARIES})
    endif()
    add_dependencies(${container_target} ${module_target})
    if(TARGET ${container_target}-mako)
        add_dependencies(${module_target} ${container_target}-mako)
    endif()

    if(${${ext}_INSTALL})
        install_python(TARGETS ${module_target} DESTINATION "${location}")
    endif()
endfunction()

function(_pm_add_pure_python)
    string(REGEX REPLACE "/" "_" py "py.${module}")
    cmake_parse_arguments(${py}
        ""
        "INSTALL;TARGET;LOCATION"
        "SOURCES"
        ${ARGN}
    )
    if("${${py}_SOURCES}" STREQUAL "")
        return()
    endif()

    file(RELATIVE_PATH targetname_copy "${PROJECT_SOURCE_DIR}"
        "${CMAKE_CURRENT_SOURCE_DIR}")
    string(REGEX REPLACE "( |/)" "_" targetname_copy "${targetname_copy}")
    if("${targetname_copy}" STREQUAL "")
        set(targetname_copy "${${py}_TARGET}-copy")
    else()
        set(targetname_copy "${targetname_copy}-copy")
    endif()

    add_copy_files(${${py}_TARGET}
        FILES ${${py}_SOURCES}
        DESTINATION "${PYTHON_BINARY_DIR}/${${py}_LOCATION}"
    )
    if(TARGET ${${py}_TARGET}-mako)
        add_dependencies(${${py}_TARGET} ${${py}_TARGET}-mako)
    endif()
    if(${${py}_INSTALL})
        install_python(FILES ${${py}_SOURCES} DESTINATION ${${py}_LOCATION})
    endif()
endfunction()

function(_pm_add_headers module)
    string(REGEX REPLACE "/" "_" h "h.${module}")
    cmake_parse_arguments(${h}
        ""
        "INSTALL;LOCATION;DESTINATION"
        "SOURCES"
        ${ARGN}
    )
    if(NOT ${${h}_INSTALL})
        return()
    endif()

    set(headers ${${h}_SOURCES})
    if("${headers}" STREQUAL "")
        return()
    endif()
    list(REMOVE_DUPLICATES headers)

    string(FIND "${module}" "." first_dot)
    if(first_dot EQUAL -1)
        set(base_module ${module})
    else()
        string(SUBSTRING "${module}" 0 ${first_dot} base_module)
    endif()

    set(header_destination ${base_module}/include/${${h}_LOCATION})
    if(${h}_DESTINATION)
        string(REGEX REPLACE "\\." "/" header_destination ${${h}_DESTINATION})
    endif()

    install_python(FILES ${headers}
        DESTINATION ${header_destination}
        COMPONENT dev
    )
endfunction()

function(_pm_add_cythons module)
    string(REGEX REPLACE "/" "_" cys "cys.${module}")
    cmake_parse_arguments(${cys} "" "" "SOURCES" ${ARGN})
    foreach(source ${${cys}_SOURCES})
        _pm_add_cython(${module} ${source} ${${cys}_UNPARSED_ARGUMENTS})
    endforeach()
endfunction()

function(_pm_add_cython module source)

    string(REGEX REPLACE "/" "_" cy "cy.${module}")
    cmake_parse_arguments(${cy} "CPP" "TARGET" "" ${ARGN})
    # Creates command-line arguments for cython for include directories
    get_property(included_dirs
        DIRECTORY ${CMAKE_CURRENT_SOURCE_DIR}
        PROPERTY INCLUDE_DIRECTORIES
    )
    set(inclusion)
    foreach(included ${included_dirs})
        set(inclusion ${inclusion} -I${included})
    endforeach()

    # Computes dependencies
    get_pyx_dependencies(${source} DEPENDENCIES ${included_dirs})
    if(TARGET ${${cy}_TARGET}-mako)
        list(APPEND DEPENDENCIES ${${cy}_TARGET}-mako)
    endif()

    # Call cython
    get_filename_component(cy_module ${source} NAME_WE)
    unset(arguments)
    if(cython_EXECUTABLE)
        set(arguments ${cython_EXECUTABLE})
    elseif(LOCAL_PYTHON_EXECUTABLE)
        set(arguments ${LOCAL_PYTHON_EXECUTABLE} -m cython)
    else()
        set(arguments ${PYTHON_EXECUTABLE} -m cython)
    endif()
    if(${${cy}_CPP})
        set(c_source "cython_${cy_module}.cc")
        list(APPEND arguments --cplus)
    else()
        set(c_source "cython_${cy_module}.c")
    endif()

    # Figure out generated source name
    set(generated_source "${source}")
    if("${source}" MATCHES ".*\\.mako\\..*")
        _pm_get_confed_filename("${source}" generated_source)
        string(REGEX REPLACE "(.*)\\.mako(\\..*)" "\\1\\2"
            generated_source "${generated_source}")
    endif()
    # Create C source from cython
    list(APPEND arguments
        "${generated_source}"
        -o "${CMAKE_CURRENT_BINARY_DIR}/${c_source}" ${inclusion}
    )
    add_custom_command(
        OUTPUT "${c_source}"
        COMMAND ${arguments}
            $<$<OR:$<CONFIG:RelWithDebInfo>,$<CONFIG:Debug>>:--dbg>
        WORKING_DIRECTORY "${CMAKE_CURRENT_SOURCE_DIR}"
        DEPENDS ${DEPENDENCIES}
        COMMENT "Generating c/c++ source ${source} with cython"
    )

    # Extension name
    get_filename_component(extension ${cy_module} NAME_WE)
    if("${extension}" STREQUAL "")
        set(extension ${cy_module})
    endif()

    _pm_cython_full_module_name(full_module ${module} "${source}")
    cython_extension_targetname(targetname ${module} "${source}")
    # Add python module
    _pm_add_python_extension(${full_module}
        TARGET ${${cy}_TARGET}
        MODULE_TARGET ${targetname}
        EXTENSION ${extension}
        SOURCES ${c_source}
        ${${cy}_UNPARSED_ARGUMENTS}
    )
endfunction()

function(_pm_cython_full_module_name outvar module source)
    get_filename_component(cy_module ${source} NAME_WE)
    if("${cy_module}" MATCHES "^${module}")
        set(full_module ${cy_module})
    else()
        set(full_module ${module}.${cy_module})
    endif()
    set(${outvar} ${full_module} PARENT_SCOPE)
endfunction()

function(cython_extension_targetname outvar module source)
    _pm_cython_full_module_name(full_module ${module} "${source}")
    python_extension_targetname(targetname ${module}
        MODULE_TARGET ${full_module}-cython)
    set(${outvar} ${targetname} PARENT_SCOPE)
endfunction()

function(_pm_get_confed_filename filename OUTPUT)
    get_filename_component(filename "${filename}" ABSOLUTE)
    file(RELATIVE_PATH relfile "${CMAKE_CURRENT_SOURCE_DIR}" "${filename}")
    if("${relfile}" MATCHES "\\.\\./")
        file(RELATIVE_PATH relfile "${CMAKE_CURRENT_BINARY_DIR}" "${filename}")
        if("${relfile}" MATCHES "\\.\\./")
            message(FATAL_ERROR "File ${filename} is not in build or source "
                "directory or subdirectory.")
        endif()
    endif()
    set(${OUTPUT} "${CMAKE_CURRENT_BINARY_DIR}/${relfile}" PARENT_SCOPE)
endfunction()

function(_pm_configure_files files_to_modify OUTPUT)
    if("${${files_to_modify}}" STREQUAL "")
        return()
    endif()
    set(all_sources ${ARGN})
    unset(configured_files)
    foreach(filename ${${files_to_modify}})
        _pm_get_confed_filename("${filename}" output)
        string(REGEX REPLACE "(.*)\\.in(\\..*)" "\\1\\2" output "${output}")
        file(RELATIVE_PATH relpath "${CMAKE_CURRENT_BINARY_DIR}" "${output}")
        configure_file("${filename}" "${relpath}" @ONLY)
        list(APPEND configured_files "${output}")
    endforeach()
    list(REMOVE_ITEM all_sources ${${files_to_modify}})
    list(APPEND all_sources ${configured_files})
    set(${OUTPUT} ${all_sources} PARENT_SCOPE)
endfunction()

function(_pm_mako_files)
    # Parses arguments
    cmake_parse_arguments(_pm_mako
        ""
        "MAKO_SCRIPT;OUTPUT_PYTHON_SOURCES;TARGETNAME"
        "MAKO_CMDLINE"
        ${ARGN}
    )
    set(all_sources ${_pm_mako_UNPARSED_ARGUMENTS})
    if("${all_sources}" STREQUAL "")
        return()
    endif()
    _pm_filter_list(mako_files all_sources ".*\\.mako\\..*")
    if("${mako_files}" STREQUAL "")
        return()
    endif()

    set(local_python "${LOCAL_PYTHON_EXECUTABLE}")
    if(NOT "${local_python}")
        set(local_python ${PYTHON_EXECUTABLE})
    endif()
    set(mako_script "${_pm_mako_MAKO_SCRIPT}")
    if("${mako_script}" STREQUAL "")
        if("${mako_SCRIPT}" STREQUAL "")
            message(FATAL_ERROR "Mako render script not defined")
        endif()
        set(mako_script "${mako_SCRIPT}")
    endif()

    if(NOT TARGET ${_pm_mako_TARGETNAME}-mako)
        add_custom_target(${_pm_mako_TARGETNAME}-mako)
    endif()

    foreach(filename ${mako_files})
        _pm_get_confed_filename("${filename}" output)
        string(REGEX REPLACE "(.*)\\.mako(\\..*)" "\\1\\2" output "${output}")
        get_filename_component(abspath "${filename}" ABSOLUTE)
        add_custom_command(
            TARGET ${_pm_mako_TARGETNAME}-mako
            COMMAND ${local_python} -B ${mako_SCRIPT} ${abspath} > ${output}
            DEPENDS "${filename}"
            COMMENT "Mako-ing file ${filename}"
        )
        list(REMOVE_ITEM all_sources "${filename}")
        list(APPEND all_sources "${output}")
    endforeach()

    set(${_pm_mako_OUTPUT_PYTHON_SOURCES} ${all_sources} PARENT_SCOPE)
endfunction()

function(add_python_module module)

    set(oneargs
        HEADER_DESTINATION TARGETNAME LOCATION OUTPUT_PYTHON_SOURCES
        MAKO_SCRIPT
    )
    # Parses arguments
    cmake_parse_arguments(${module}
        "FAKE_INIT;NOINSTALL;INSTALL;CPP;NOCONFIG;NOMAKO"
        "${oneargs}"
        "SOURCES;EXCLUDE;LIBRARIES;MAKO_CMDLINE"
        ${ARGN}
    )
    list(APPEND ${module}_SOURCES ${${module}_UNPARSED_ARGUMENTS})
    # Sets submodule, location, and module from module
    _pm_location_and_name(${module} "${${module}_LOCATION}")

    # Sets defaults, do_install, and  ALL_SOURCES
    _pm_default()
    set(targetname ${module})
    if(${module}_TARGETNAME)
        set(targetname ${${module}_TARGETNAME})
    endif()
    # creates a global target
    if(NOT TARGET ${targetname})
        add_custom_target(${targetname} ALL)
    endif()

    # Figure out files that should be passed through configure
    if(NOT ${module}_NOCONFIG)
        _pm_filter_list(IN_FILES ALL_SOURCES ".*\\.in\\..*")
        # Configure requested files and modifies ALL_SOURCES accordingly
        # Eg remove the *.in.* files and replace them with the configure files.
        _pm_configure_files(IN_FILES ALL_SOURCES ${ALL_SOURCES})
    endif()
    # Figure out files that should be passed through mako and render them
    set(MODIFIED_SOURCES ${ALL_SOURCES})
    if(NOT ${module}_NOMAKO)
        _pm_mako_files(${ALL_SOURCES}
            TARGETNAME "${targetname}"
            OUTPUT_PYTHON_SOURCES MODIFIED_SOURCES
            MAKO_SCRIPT "${${module}_MAKO_SCRIPT}"
            MAKO_CMDLINE ${${module}_MAKO_CMDLINE}
        )
    endif()
    # Figures out C/C++/HEADERS/Python sources
    _pm_filter_list(C_SOURCES MODIFIED_SOURCES ".*\\.c$")
    _pm_filter_list(C_HEADERS MODIFIED_SOURCES ".*\\.h$")
    _pm_filter_list(CPP_SOURCES MODIFIED_SOURCES ".*\\.cpp$" ".*\\.cc$")
    _pm_filter_list(CPP_HEADERS MODIFIED_SOURCES ".*\\.hpp" ".*\\.h")
    _pm_filter_list(PY_SOURCES MODIFIED_SOURCES ".*\\.py$")
    # We need to keep track of the original sources file to figure out
    # cython dependencies. This is difficult if files can be changed by mako.
    # So filename transformation are applied when treating cython.
    # Of course, if cmake were a decent language, it would have key-value pairs
    # of some kind and we couuld the info reguarding the origin of a generated
    # file. That is not the case.
    _pm_filter_list(CY_SOURCES ALL_SOURCES ".*\\.pyx")
    _pm_filter_list(CY_HEADERS MODIFIED_SOURCES ".*\\.pxd")

    if(C_SOURCES OR CPP_SOURCES)
        if(PY_SOURCES OR CY_SOURCES)
            message(FATAL_ERROR "Python/Cython and C sources in same call"
                " to add_python_module.\n"
                "Please split into separate pure C extensions from othes."
            )
        endif()
    endif()

    # Now for the actual meat

    # First adds fake init if necessary
    if(${module}_FAKE_INIT)
        if(C_SOURCES OR CPP_SOURCES)
            message(FATAL_ERROR
                "FAKE_INIT AND C/C++ extensions are incompatible")
        endif()
        _pm_add_fake_init(${location})
    endif()


    # Then compiles an extension if C/C++ sources
    get_filename_component(extension_location "${location}" PATH)
    _pm_add_python_extension(${module}
        TARGET ${targetname}
        INSTALL ${do_install}
        EXTENSION ${submodule}
        LOCATION ${extension_location}
        LIBRARIES ${${module}_LIBRARIES}
        SOURCES ${C_SOURCES} ${CPP_SOURCES}
    )

    # Then copy/install pure python files
    _pm_add_pure_python(${module}
        TARGET ${targetname}
        INSTALL ${do_install}
        LOCATION ${location}
        SOURCES ${PY_SOURCES}
    )

    # Then copy/install header files
    _pm_add_headers(${module}
        LOCATION ${location}
        DESTINATION ${${module}_HEADER_DESTINATION}
        SOURCES ${CPP_HEADERS} ${C_HEADERS} ${CY_HEADERS}
        INSTALL ${do_install}
    )

    # Then create cython extensions
    _pm_add_cythons(${module}
        ${${module}_CPP}
        LOCATION ${location}
        INSTALL ${do_install}
        LIBRARIES ${${module}_LIBRARIES}
        TARGET ${targetname}
        SOURCES ${CY_SOURCES}
    )

    # Outputs pure python sources if requested.
    # This is used mainly by add_pytest. It makes configurable tests trivial to
    # add.
    if(NOT ${${module}_OUTPUT_PYTHON_SOURCES} STREQUAL "")
        set(${${module}_OUTPUT_PYTHON_SOURCES} ${PY_SOURCES} PARENT_SCOPE)
    endif()

endfunction()
