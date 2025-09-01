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

-- 扫描目录获取子目录
M.scan_dir = function(dir)
    local dirs = {}
    local handle = vim.loop.fs_scandir(dir)
    if handle then
        while true do
            local name, type = vim.loop.fs_scandir_next(handle)
            if not name then break end
            if type == "directory" then
                table.insert(dirs, name)
            end
        end
    end
    return dirs
end

return M
