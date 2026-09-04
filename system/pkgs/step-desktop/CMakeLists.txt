cmake_minimum_required(VERSION 3.16)
project(plasma-containmentactions-stepdesktop)

find_package(ECM REQUIRED NO_MODULE)
set(CMAKE_MODULE_PATH ${ECM_MODULE_PATH})
include(KDEInstallDirs)
include(KDECMakeSettings)
include(KDECompilerSettings NO_POLICY_SCOPE)
# kcoreaddons_add_plugin insists on this; KDECMakeSettings only sets it for
# a project that opts into its build-tree layout.
set(CMAKE_LIBRARY_OUTPUT_DIRECTORY ${CMAKE_BINARY_DIR}/bin)

find_package(Qt6 REQUIRED COMPONENTS Core Widgets DBus)
# PlasmaConfig.cmake links KF6::ConfigCore but does not find_dependency it,
# so it has to be found here first or the imported target is dangling.
find_package(KF6 REQUIRED COMPONENTS CoreAddons Config)
find_package(Plasma REQUIRED)

# Two plugins from one source: the direction is baked in at compile time
# because Plasma's ContainmentActions bind ONE plugin id per mouse trigger
# and give it no per-trigger argument.
function(step_plugin target id shortcut json)
  kcoreaddons_add_plugin(${target} SOURCES step.cpp step.h INSTALL_NAMESPACE "plasma/containmentactions")
  set_target_properties(${target} PROPERTIES OUTPUT_NAME ${id})
  target_compile_definitions(${target} PRIVATE STEP_SHORTCUT="${shortcut}" STEP_JSON="${json}")
  target_link_libraries(${target} Qt::Widgets Qt::DBus Plasma::Plasma)
endfunction()

step_plugin(stepdesktop_previous local.stepdesktop.previous "Switch One Desktop to the Left"  previous.json)
step_plugin(stepdesktop_next     local.stepdesktop.next     "Switch One Desktop to the Right" next.json)
