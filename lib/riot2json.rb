require "net/http"
require "json"
require "eventmachine"
require "rocketamf"
require "em-rtmp"
require "sinatra"
require "sinatra/async"
require "redis"
require "thin"
require "base64"

#Gem sources.
require "riot2json/auth"
require "riot2json/client"
require "riot2json/config"
require "riot2json/connectionrequest"
require "riot2json/http"


module Riot2JSON
  user = ARGV[0]
  pass = ARGV[1]
  region = ARGV[2]
  port = ARGV[3]
  LolClient.new.start user, pass, region, port
end
