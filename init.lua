--[[
该模块的主要作用是在nginx启动时加载变量和函数。
--]]
require('config')
--------------------------------------------------------初始化
--规则读取函数
function read_rule(var)
    file = io.open(rulePath .. '/' .. var, 'r')
    if file == nil then
        return
    end
    t = {}
    for line in file:lines() do
        table.insert(t, line)
    end
    file:close()
    return (t)
end
local optionIsOn = function(options)
    return options == 'on' and true or false
end
-------------------------------------------------------变量集合
whiteIpList = WhiteIpList
blackIpList = BlackIpList
CCFrequency = CCFrequency
blackFileExt = BlackFileExt
logPath = LogPath
rulePath = RulePath
checkWhiteIp = optionIsOn(CheckWhiteIp)
checkBlackIp = optionIsOn(CheckBlackIp)
checkBlackUri = optionIsOn(CheckBlackUri)
checkBlackPostArgs = optionIsOn(CheckBlackPostArgs)
checkBlackCookie = optionIsOn(CheckBlackCookie)
checkWhiteUri = optionIsOn(CheckWhiteUri)
PathInfoFix = optionIsOn(PathInfoFix)
wafLog = optionIsOn(WafLog)
checkCC = optionIsOn(CheckCC)
return403Page = optionIsOn(Return403Page)
blackUri = read_rule('blackUri')
blackGetArgs = read_rule('blackGetArgs')
blackUa = read_rule('blackUa')
whiteUri = read_rule('whiteUri')
blackPostArgs = read_rule('blackPostArgs')
blackCookieArgs = read_rule('blackCookieArgs')

-------------------------------------------------------变量集合

-------------------------------------------------------工具函数
--获取客户端IP
function getClientIp()
    IP = ngx.var.remote_addr
    if IP == nil then
        IP = 'unknown'
    end
    return IP
end

--写本地文件
function write(file, msg)
    local fd, err = io.open(file, 'a+b')
    if fd == nil then
        return
    end
    fd:write(msg)
    fd:flush()
    fd:close()
end

--记录日志
function log(method, url, data, Reason)
    if wafLog then
        local realIp = getClientIp()
        local ua = ngx.var.http_user_agent
        local servername = ngx.var.server_name
        local time = ngx.localtime()
        if ua then
            line =
                realIp ..
                ' [' ..
                    time ..
                        '] "' ..
                            method ..
                                ' ' .. servername .. url .. '" "' .. data .. '"  "' .. ua .. '" "' .. Reason .. '"\n'
        else
            line =
                realIp ..
                ' [' ..
                    time .. '] "' .. method .. ' ' .. servername .. url .. '" "' .. data .. '" - "' .. Reason .. '"\n'
        end
        local filename = logPath .. '/' .. servername .. '-' .. ngx.today() .. '.log'
        write(filename, line)
    end
end

--输出禁止访问页面
function say_html()
    if return403Page then
        ngx.header.content_type = 'application/json'
        ngx.header.server = 'LuaWAF.com'
        ngx.say(html)
        ngx.exit(403)
    end
end

--设置header
function setGlobalHeader()
    ngx.header.server = 'LuaWAF.com'
    ngx.header['X-Powered-By'] = 'Protected by LuaWAF.com'
end
--检查黑名单文件后缀名
function fileExtCheck(ext)
    local items = Set(blackFileExt)
    ext = string.lower(ext)
    if ext then
        for rule in pairs(items) do
            if ngx.re.match(ext, rule, 'isjo') then
                return true
            end
        end
    end
    return false
end

--工具函数，转换table的格式
function Set(list)
    local set = {}
    for _, l in ipairs(list) do
        set[l] = true
    end
    return set
end

--检查POST请求中URL编码的数据
function checkEscapedData(data)
    for _, rule in pairs(blackPostArgs) do
        if rule ~= '' and data ~= '' and ngx.re.match(ngx.unescape_uri(data), rule, 'isjo') then
            return true
        end
    end
    return false
end

--检查POST请求中base64编码的数据
function checkBase64Data(data)
    for _, rule in pairs(blackPostArgs) do
        if rule ~= '' and data ~= '' and ngx.re.match(ngx.decode_base64(data), rule, 'isjo') then
            return true
        end
    end
    return false
end

-------------------------------------------------------工具函数
---
---函数顺序：按照检查顺序
---
-------------------------------------------------------函数集合
--白名单IP检查
function isWhiteIp()
    if checkWhiteIp then
        if next(whiteIpList) ~= nil then
            for _, ip in pairs(whiteIpList) do
                if getClientIp() == ip then
                    return true
                end
            end
        end
    end

    return false
end

--黑名单IP检查
function isBlackIp()
    if checkBlackIp then
        if next(blackIpList) ~= nil then
            for _, ip in pairs(blackIpList) do
                if getClientIp() == ip then
                    return true
                end
            end
        end
    end

    return false
end

--CC攻击检查
function isCcAttack()
    --开启检查CC开关才检查CC
    if checkCC then
        local uri = ngx.var.uri
        --CCcount/CCseconds，CCseconds 秒内有CCcount访问
        --CC阈值
        CCcount = tonumber(string.match(CCFrequency, '(.*)/'))
        --CC时间阈值
        CCseconds = tonumber(string.match(CCFrequency, '/(.*)'))
        --特定IP访问特定网址作为判断CC的键
        local token = getClientIp() .. uri
        --创建一个nginx字典，用来记录访问次数
        local limit = ngx.shared.limit
        --获取键对应的访问次数
        local req, _ = limit:get(token)
        --第一次访问或者到时低频访问req为nil
        if req then
            --CC时间阈值内访问次数大于次数阈值，就是CC攻击
            if req > CCcount then
                --未达到阈值，访问次数加一
                return true
            else
                limit:incr(token, 1)
            end
        else
            --第一次或者超过阈值键失效则新建记录。
            --在字典中存入token作为键，初始值为1，生存时间为CC时间阈值
            limit:set(token, 1, CCseconds)
        end
    end
    return false
end

--检查是不是扫描器
function isScanner()
    --[[
    Acunetix-Aspect
    Acunetix-Aspect-Password
    Acunetix-Aspect-Queries
    以上三个是AWVS漏洞扫描工具的自带的请求头参数，是其特有字段。可借助这种特征识别出AWVS并及时阻止扫描。
    以上三个字段有值，即发现AWVS扫描器。
    --]]
    if type(ngx.req.get_headers()['http_Acunetix_Aspect']) ~= 'nil' then
        return true
    elseif type(ngx.req.get_headers()['http_Acunetix-Aspect-Password']) ~= 'nil' then
        return true
    elseif type(ngx.req.get_headers()['http_Acunetix-Aspect-Queries']) ~= 'nil' then
        --X_Scan_Memo是X-Scan漏洞扫描器的特征字段，发现其有值，即发现X-Scan漏洞扫描器。
        return true
    elseif type(ngx.req.get_headers()['http_X_Scan_Memo']) ~= 'nil' then
        return true
    else
        return false
    end
end

--白名单URI检查
function isWhiteUri()
    if checkWhiteUri then
        if whiteUri ~= nil then
            for _, rule in pairs(whiteUri) do
                if ngx.re.match(ngx.var.uri, rule, 'isjo') then
                    return true
                end
            end
        end
    end
    return false
end

--检查是否是黑名单中的UA
function isBlackUa()
    local ua = ngx.var.http_user_agent
    if ua ~= nil then
        for _, rule in pairs(blackUa) do
            if rule ~= '' and ngx.re.match(ua, rule, 'isjo') then
                return true
            end
        end
    end
    return false
end

--检查是否是黑名单中的URI
function isBlackUri()
    if checkBlackUri then
        for _, rule in pairs(blackUri) do
            if rule ~= '' and ngx.re.match(ngx.var.request_uri, rule, 'isjo') then
                return true
            end
        end
    end
    return false
end

--检查GET请求中是否有恶意字符串
function isBlackGetArgs()
    for _, rule in pairs(blackGetArgs) do
        local args = ngx.req.get_uri_args()
        for key, val in pairs(args) do
            if type(val) == 'table' then
                local t = {}
                for k, v in pairs(val) do
                    if v == true then
                        v = ''
                    end
                    table.insert(t, v)
                end
                data = table.concat(t, ' ')
            else
                data = val
            end
            if
                data and type(data) ~= 'boolean' and rule ~= '' and
                    ngx.re.match(ngx.unescape_uri(ngx.unescape_uri(ngx.unescape_uri(data))), rule, 'isjo')
             then
                return true
            end
        end
    end
    return false
end

--检查Cookie中是否有恶意字符串
function isBlackCookieArgs()
    local ck = ngx.var.http_cookie
    if checkBlackCookie and ck then
        for _, rule in pairs(blackCookieArgs) do
            if rule ~= '' and ngx.re.match(ck, rule, 'isjo') then
                return true
            end
        end
    end
    return false
end

function isBlackPostArgs()
    if checkBlackPostArgs then
        if ngx.req.get_method() == 'POST' then
            --重写POST检查，检查POST传输的所有信息，消除上一版本中检查不全面的隐患
            if isBlackPostData() then
                return true
            else
                return false
            end
        end
    else
        return false
    end
end

--检查POST过来的所有信息中是否有恶意字符串
function isBlackPostData()
    --初始化函数返回值
    local status = false
    local post_data = ''
    --打开一个SOCKET用来接收数据
    local sock, err = ngx.req.socket()
    if not sock then
        status = false
    end
    --为当前请求创建一个新请求体并初始化一个缓存区，大小为128KB。
    ngx.req.init_body(128 * 1024)
    --设置接收超时时间0，一旦接收不到数据就停止，不等待。
    sock:settimeout(0)
    --从headers里获取请求体大小
    local content_length = nil
    content_length = tonumber(ngx.req.get_headers()['content-length'])
    --默认接收块大小是4KB
    local chunk_size = 4096
    --如果请求体比默认接收块还小，就接收请求体大小的数据即可。
    if content_length < chunk_size then
        chunk_size = content_length
    end
    --size是当前已经接收的请求体总大小
    local size = 0

    --要是当前接收的请求体大小小于总大小就继续接收
    while size < content_length do
        --从打开的socket里读取默认接受块大小的数据
        --兼顾TCP和UDP的写法，UDP没有partial只有两个参数
        local data, err, partial = sock:receive(chunk_size)
        data = data or partial
        if not data then
            status = false
        end
        --将读取到的数据追加到请求体里
        ngx.req.append_body(data)

        --这一步是为了得到文件的后缀名
        local m, _ = ngx.re.match(data, [[Content-Disposition: form-data;(.+)filename="(.+)\.(.+)"]], 'ijo')
        if m then
            --如果有文件则先执行文件名黑名单检查
            if fileExtCheck(m[3]) then
                status = true
            end
        end
        --检查当前读到的数据块
        --当前POST请求的某一参数在黑名单中，即checkEscapedData(data)为true，执行then后语句，记录恶意请求信息，返回错误页面，请求截断；当前POST请求的某一参数不在黑名单中，checkEscapedData(data)为false，程序向下运行；
        --检查不通过，结束读取，返回错误页面。
        --ngx.say(data)
        if checkEscapedData(data) then
            status = true
        end
        --检查base64编码过的内容
        if checkBase64Data(data) then
            status = true
        end

        post_data = post_data .. data
        --给当前已经接收的请求体总大小加上刚刚读取到的数据大小。
        size = size + string.len(data)
        --将最后剩余的请求体大小和当前默认块大小比较，如果剩余的比4KB还小最后一次就只读取剩余大小的数据。
        local less = content_length - size
        if less < chunk_size then
            chunk_size = less
        end
    end
    --结束multipart/form-data编码的POST表单读取
    ngx.req.finish_body()
    return status, post_data
end
