local M = {}

-- 读取文件内容
M.read_file = function(filepath)
  local file = io.open(filepath, "r")
  if not file then
    return nil
  end
  local content = file:read("*a")
  file:close()
  return content
end

-- 检查文件是否存在
M.file_exists = function(filepath)
  local file = io.open(filepath, "r")
  if file then
    file:close()
    return true
  end
  return false
end

-- 扫描目录获取子目录或者指定后缀的文件
-- scan_sub(dir, ext): ext为空则查目录，否则查指定后缀文件
M.scan_sub = function(dir, ext)
  local result = {}
  local handle = vim.loop.fs_scandir(dir)
  if handle then
    while true do
      local name, type = vim.loop.fs_scandir_next(handle)
      if not name then break end
      if not ext then
        if type == "directory" then
          table.insert(result, name)
        end
      else
        if type == "file" and name:sub(- #ext) == ext then
          table.insert(result, name)
        end
      end
    end
  end
  return result
end

return M
