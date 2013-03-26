module Riot2JSON
  class Config
    CLIENT_VERSION = "3.04.13"
    RTMP_HOST = "prod.na1.lol.riotgames.com"
    RTMP_PORT = 2099
    TC_URL = "rtmps://#{RTMP_HOST}:#{RTMP_PORT}/"
    USER = "gamenaobot"
    PASS = "gamenaobot123"
    QUEUE_SERVER ="lq.%s.lol.riotgames.com"
    QUEUE_PATH ="/login-queue/rest/queue/authenticate"
  end
end

