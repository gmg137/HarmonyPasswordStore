# 就地裁剪一个静态库，且只在内容真的变了时才写回。
#
# llvm-strip --strip-debug 是内容幂等的，但即使无事可做也会刷新文件 mtime；
# 而 third_party 下的 .a 是 libnativebridge.so 的链接输入，mtime 一变 Ninja
# 就会在每次构建重链接一次。先比 SHA256、只有真变了才 rename，可让增量构建
# 不抖动。
#
# 调用（见 CMakeLists.txt）：
#   cmake -DSTRIP_TOOL=<llvm-strip> -DARCHIVE=<path.a> -P strip_archive.cmake

set(temp "${ARCHIVE}.stripped.tmp")

execute_process(COMMAND ${STRIP_TOOL} --strip-debug ${ARCHIVE} -o ${temp}
                RESULT_VARIABLE rc)
if(NOT rc EQUAL 0)
  file(REMOVE ${temp})
  message(WARNING "strip_archive: strip failed for ${ARCHIVE} (rc=${rc})")
  return()
endif()

file(SHA256 ${ARCHIVE} h_orig)
file(SHA256 ${temp} h_new)

if(NOT h_orig STREQUAL h_new)
  file(RENAME ${temp} ${ARCHIVE})
  message(STATUS "strip_archive: ${ARCHIVE} stripped")
else()
  file(REMOVE ${temp})
endif()
