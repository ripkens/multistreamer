-- luacheck: globals ngx
local ngx = ngx
local Model = require('lapis.db.model').Model
local from_json = require('lapis.util').from_json
local to_json = require('lapis.util').to_json
local config = require'multistreamer.config'.get()
local http
local encode_base64
local decode_base64
local hmac_sha1
local resty_random
local resty_md5
local str
local ngx_log
local ngx_err
local ngx_debug

if ngx then
    http = require'resty.http'
    encode_base64 = ngx.encode_base64
    decode_base64 = ngx.decode_base64
    hmac_sha1 = ngx.hmac_sha1
    resty_random = require'resty.random'
    resty_md5 = require "resty.md5"
    str = require'resty.string'
    ngx_log = ngx.log
    ngx_err = ngx.ERR
    ngx_debug = ngx.DEBUG
else
    local md5 = require'md5'
    resty_random = {
      bytes = function(num,whatever)
        math.randomseed(os.time())
        local b = ''
        for i=1,num,1 do
          b = b .. math.random(1,255)
        end
        return b
      end
    }
    resty_md5 = {
      new = function(self)
        local n = md5.new()
        n.to_hex = n.tohex
        n.final = n.finish
        return n
      end,
    }
end

local match = string.match
local upper = string.upper
local sub = string.sub

local function make_token()
    local rand = resty_random.bytes(16,true)
    while rand == nil do
      rand = resty_random.bytes(16,true)
    end
    local md5 = resty_md5:new()
    md5:update(rand)
    local digest = md5:final()
    return sub(upper(str.to_hex(digest)),1,20)
end

local User = Model:extend('users', {
  timestamp = true,
  relations = {
    { 'accounts', has_many = 'Account' },
    { 'streams', has_many = 'Stream' },
    { 'shared_accounts', has_many = 'SharedAccount' },
    { 'shared_streams', has_many = 'SharedStream' },
  },
  write_session = function(self, res)
    res.session.user = {
      username = self.username,
      key = encode_base64(hmac_sha1(config.secret,self.username))
    }
  end,
  reset_token = function(self)
    self:update({access_token = make_token()})
  end,
  get_pref = function(self, key)
    if not self.prefs then
      self.prefs = from_json(self.preferences)
    end
    return self.prefs[key]
  end,
  save_pref = function(self, key, value)
    if not self.prefs then
      self.prefs = from_json(self.preferences)
    end
    self.prefs[key] = value
    self:update({ preferences = to_json(self.prefs) })
  end
})

function User:login(username,password)
  local error = nil
  local user = nil

  ngx_log(ngx_debug,'User:login: contacting ' .. config.auth_endpoint)

  local httpc = http.new()
  local res, err = httpc:request_uri(config.auth_endpoint, {
    method = "GET",
    headers = {
      ["Authorization"] = "Basic " .. encode_base64(username .. ':' .. password)
    }
  })
  if not res then
    ngx_log(ngx_err, 'User:login: connection to ' .. config.auth_endpoint ..' failed: ' .. err)
    error = err
    return user, error
  end

  ngx_log(ngx_debug,'User:login: endpoint returned ' .. res.status .. ' response code')

  if(res.status >= 200 and res.status < 300) then
    ngx_log(ngx_debug, 'User:login: login succeeded for ' .. username);
    user = self:find({ username = username:lower() })
    if not user then
      user = self:create({username = username:lower(), access_token = make_token() })
    end
  else
    ngx_log(ngx_debug, 'User:login: login failed for ' .. username);
  end

  return user, error
end

function User.read_session(res)
  if res.session and res.session.user then
    local u_session = res.session.user
    if(encode_base64(hmac_sha1(config.secret,u_session.username)) == u_session.key) then
      return User:find({ username = u_session.username })
    end
  end
  if res.params.token then
    return User:find({ access_token = res.params.token })
  end
  return nil
end

function User.unwrite_session(res)
  res.session.user = nil
end

function User.read_auth(res)
  local auth = res.req.headers['authorization']
  if not auth then
    return nil
  end

  local userpassword = decode_base64(match(auth,"Basic%s+(.*)"))
  if not userpassword then return nil end
  local username, password = match(userpassword,"([^:]*):(.*)")
  return User:login(username,password)
end

function User.read_bearer(res)
  local auth = res.req.headers['authorization']
  if not auth then
    return nil
  end

  local bearertoken = match(auth,"Bearer%s(.*)")
  if not bearertoken then return nil end
  return User:find({ access_token = bearertoken })
end

return User;

