require 'time'
module Riot2JSON
  class LolClient
    class << self
      attr_accessor :instance
    end

    def start(user, pass, region, port, version, isDaemon)
      @heartbeat_sent = 0
      @ready = false
      @region = region
      @port = port
      @version = version
      LolClient.instance = self

      if isDeamon 
		Process.daemon()
	  end
	  
      token = Auth.request_token(region, user, pass)
      @redis = Redis.new(:path => '/tmp/redis.sock')
	  
      begin
        EventMachine.run do
          @connection = EventMachine::RTMP.ssl_connect("prod.#{region}.lol.riotgames.com", 2099)
          @connection.on_handshake_complete do
            request = LolConnectionRequest.new(@connection)
            request.tcUrl = Config::TC_URL
            request.swfUrl = 'app:/mod_ser.dat'
            request.send
          end

          @connection.on_ready do
            login(user, pass, token)
          end

          EventMachine::PeriodicTimer.new(15) do
            begin
              t = Time.new.strftime('%a %-m %-d %Y %H:%M:%S GMT+%z')
              req = invoke("performLCDSHeartBeat", "loginService", [@account, @token, @heartbeat_sent +=1, t])
              req.send
            rescue => e
              puts "Rescued timer!\n"
              puts e
            end
          end

          Thin::Server.start HttpListener, '0.0.0.0', port
        end
      rescue => e
        log = "/var/log/penguins/rtmp/crash-#{Time.now.strftime("%m-%d-%Y %H:%M:%S")}"
		if not isDaemon
			puts "An unexpected error has been reached, dumping formation to log: #{log}"
			puts "Restarting node now..."
			puts e.backtrace
			puts e.inspect
		end
		
        f = open(log, "w")
        f.write(e.backtrace)
        f.write("\n#{e.inspect}")
        f.close

        start(user, pass, region, port, isDaemon)
      end
    end

    def setDSId(dsid)
      @dsid = dsid
    end

    def getStatus(ins)
      ins.body create_json_success([:region => @region, :port => @port, :online => "true"])
    end

    def getSummonerByName(name, ins)
      cache = cacheExists(@region, "name", name)

      if !cache.nil?
        ins.body cache
        return
      end

      req = invoke("getSummonerByName", "summonerService", [name])
      req.send

      req.callback do |res|
        if !res.message.values[1].body.nil?
          json = create_json_success(res.message.values[1].body)
        else
          json = create_json_error("Summoner does not exist")
        end
        expire_object(@region, "name", name, json, 1800)
        ins.body json
      end
    end

    def getGameInProgress(name, ins)
      cache = cacheExists(@region, "ingame", name)

      if !cache.nil?
        #ins.body cache
        #return
      end

      req = invoke("retrieveInProgressSpectatorGameInfo", "gameService", [name])
      req.send

      req.callback do |res|
        json = create_json_success(res.message.values[1].body)
        expire_object(@region, "ingame", name, json, 1800)
        ins.body json
      end

      req.errback do |res|
        #not in cache, save this message for 1m30s
        puts res.message.values.inspect
        json = create_json_error(res.message.values[1].body)
        expire_object(@region, "ingame", name, json, 180)
        ins.body json
      end
    end

    def getRecentGames(account,ins)
      cache = cacheExists(@region, "recent", account)
      if !cache.nil?
        ins.body cache
        return
      end

      req = invoke("getRecentGames", "playerStatsService", account)
      req.send

      req.callback do |res|
        json = create_json_success(res.message.values[1].body)
        expire_object(@region, "recent", account, json, 1800)
        ins.body json
      end

      req.errback do |res|
        json = create_json_error(res.message.values[1].rootCause[:message])
        expire_object(@region, "recent", json, 30)
        isn.body json
      end

    end

    def getPlayerStats(account, ins, season)
      key = ''
      if season.nil?
        cache = cacheExists(@region, "playerstats", account)

        if !cache.nil?
          ins.body cache
          return
        end
        req = invoke("retrievePlayerStatsByAccountId", "playerStatsService", [account])
        req.send
      else
        cache = cacheExists(@regiom, "playerstats-#{season}", account)

        if !cache.nil?
          ins.body cache
          return
        end
        req = invoke("retrievePlayerStatsByAccountId", "playerStatsService", [account, season.upcase])
        req.send
      end

      req.callback do |res|
        json = create_json_success(res.message.values[1].body)
        expire_object(@region, cache.nil? ? "playerstats" : "playerstats-#{season}", account, json, 1800)
        ins.body json
      end

      req.errback do |res|
        json = create_json_error(res.message.values[1].rootCause[:message])
        expire_object(@region, cache.nil? ? "playerstats" : "playerstats-#{season}", account, json, 30)
        ins.body json
      end
    end

    def getLeaguesForPlayer(summoner, ins)
      cache = cacheExists(@region, "leagues", summoner)

      if !cache.nil?
        ins.body cache
        return
      end

      req = invoke("getAllLeaguesForPlayer", "leaguesServiceProxy", [summoner])
      req.send

      req.callback do |res|
        json = create_json_success(res.message.values[1].body)
        expire_object(@region, "leagues", summoner, json, 1800)
        ins.body json
      end

      req.errback do |res|
        json = create_json_error(res.message.values[1].rootCause[:message])
        expire_object(@region, "leagues", summoner, json, 1800)
        ins.body json
      end
    end

    def getAvailableQueues(ins)
      req = invoke("getAvailableQueues", "matchmakerService", [])
      req.send

      req.callback do |res|
        ins.body JSON.pretty_generate(res.message.values[1].body)
      end

      req.errback do |res|
        puts res.inspect
        ins.body JSON.pretty_generate([:error => "Unable to get queue information.", :reason => res.message.values[1].rootCause[:message]])
      end
    end

    def getQueueInfo(queue, ins)
      req = invoke("getQueueInfo", "matchmakerService", [queue])
      req.send

      req.callback do |res|
        ins.body JSON.pretty_generate(res.message.values[1].body)
      end

      req.errback do |res|
        ins.body JSON.pretty_generate([:error => "Error looking up queue.", :reason => res.message.values[1].rootCause[:message]])
      end
    end

    private
    def cacheExists(region, type, value)
      @redis.get("#{region}-#{type}-#{value}")
    end

    def expire_object(region, name, key, value, time)
      entry = "#{region}-#{name}-#{key}"
      @redis.set(entry, value)
      @redis.expireat(entry, Time.now.to_i + time)
    end

    def create_json_success(value)
      JSON.pretty_generate([:error => "success", :data => value])
    end

    def create_json_error(value)
      JSON.pretty_generate([:error => "error", :reason => value])
    end

    def create_remote_message(operation, dest, body, dsid)
      msg = RocketAMF::Values::RemotingMessage.new
      msg.operation = operation
      msg.destination = dest
      msg.body = body
      msg.timestamp = 0
      msg.timeToLive = 0
      msg.messageId = EventMachine::RTMP::UUID.random
      msg.headers ={
        "DSRequestTimeout" => 60,
        "DSId" => dsid,
        "DSEndpoint" => "my-rtmps"
      }
      msg
    end

    def create_command_message(operation, dest, body)
      msg = RocketAMF::Values::CommandMessage.new
      msg.body = body
      msg.messageId = EventMachine::RTMP::UUID.random
      msg.timestamp = 0
      msg.timeToLive = 0
      msg.headers = {:DSId => @dsid, :DSEndpoint => 'my-rtmps'}
      msg.correlationId = ''
      msg.operation = operation
      msg.destination = dest
      msg
    end

    def invoke(operation, service, args)
      req = EventMachine::RTMP::Request.new(@connection)
      req.header.message_type = :amf3
      req.header.message_type_id = 17
      req.message.version = 3
      msg = create_remote_message(operation, service, args, @dsid)
      req.message.values = [msg]
      req.body = req.message.encode
      req
    end

    def sendinvoke(operation, service, args)
      req = invoke(operation, service, args)
      req.send
      req
    end

    def auth(body)
      msg = create_command_message(RocketAMF::Values::CommandMessage::LOGIN_OPERATION, 'auth', Base64.encode64(body))
      req = EventMachine::RTMP::Request.new(@connection)
      req.header.message_type = :amf3
      req.message.version = 3
      req.message.values = [msg]
      req.body = req.message.encode
      req.send
      req.callback do |res|
        puts "Login complete\n"
        @ready = true
      end
    end

    def login(user, pass, token)
      ac = RocketAMF::Values::TypedHash.new('com.riotgames.platform.login.AuthenticationCredentials')
      ac[:ipAddress] = 'NA'
      ac[:locale] = 'en_US'
      ac[:clientVersion] = @version
      ac[:domain] = 'lolclient.lol.riotgames.com'
      ac[:username] = user
      ac[:password] = pass
      ac[:authToken] = token
      ac[:TypeName] = "com.riotgames.platform.login.AuthenticationCredentials"

      req = invoke("login", "loginService", ac)
      req.send

      req.callback do |res| 
        @account = res.message.values[1].body[:accountSummary][:accountId]
        @token = res.message.values[1].body[:accountSummary][:token]
        auth("%s:%s" % [res.message.values[1].body[:accountSummary][:username], res.message.values[1].body[:token]])
      end
      req.errback do |res|
        puts res.message.values[1].inspect
      end
    end
  end
end
