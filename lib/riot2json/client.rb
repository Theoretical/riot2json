module Riot2JSON
  class LolClient
    class << self
      attr_accessor :instance
    end

    def start(region)
      @heartbeat_sent = 0
      @ready = false
      @region = region
      LolClient.instance = self

      user = Config::USER
      pass = Config::PASS
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

          Thin::Server.start HttpListener, '0.0.0.0', 3000
        end
      rescue => e
        puts "crash reached, reconnecting!"
        puts e.inspect
        puts e.backtrace
        start(region)
      end
    end

    def getSummonerByName(name, ins)
      cache = cacheExists(@region, "name", name)

      if !cache.nil?
        ins.body JSON.pretty_generate(JSON.load(cache))
        return
      end

      req = invoke("getSummonerByName", "summonerService", [name])
      req.send

      req.callback do |res|
        expire_object(@region, "name", name, JSON.generate(res.message.values[1].body), 1800)
        ins.body JSON.pretty_generate(res.message.values[1].body)
      end
    end

    def getGameInProgress(name, ins)
      cache = cacheExists(@region, "ingame", name)

      if !cache.nil?
        ins.body JSON.pretty_generate(JSON.load(cache))
        return
      end

      req = invoke("retrieveInProgressSpectatorGameInfo", "gameService", name)
      req.send

      req.callback do |res|
        expire_object(@region, "ingame", name,  JSON.generate(res.message.values[1].body), 1800)
        ins.body JSON.pretty_generate(res.message.values[1].body)
      end

      req.errback do |res|
        #not in cache, save this message for 1m30s
        expire_object(@region, "ingame", name, JSON.generate(res.message.values[1]), 180)
        ins.body JSON.pretty_generate([:error => "Summoner: #{name} is not in-game.", :reason => res.message.values[1].rootCause[:message]])
      end
    end

    def getRecentGames(account,ins)
      cache = cacheExists(@region, "recent", account)
      if !cache.nil?
        ins.body JSON.pretty_generate(JSON.load(cache))
        return
      end

      req = invoke("getRecentGames", "playerStatsService", account)
      req.send

      req.callback do |res|
        expire_object(@region, "recent", account, JSON.generate(res.message.values[1].body), 1800)
        ins.body JSON.pretty_generate(res.message.values[1].body)
      end

      req.errback do |res|
        expire_object(@region, "recent", JSON.generate([:error => "Error looking up account."]), 30)
        ins.body JSON.pretty_generate([:error => "Error looking up account."])
      end

    end

    def getPlayerStats(account, ins, season)
      key = ''
      if season.nil?
        cache = cacheExists(@region, "playerstats", account)

        if !cache.nil?
          ins.body JSON.pretty_generate(JSON.load(cache))
          return
        end
        req = invoke("retrievePlayerStatsByAccountId", "playerStatsService", [account])
        req.send
      else
        cache = cacheExists(@regiom, "playerstats-#{season}", account)

        if !cache.nil?
          ins.body JSON.pretty_generate(JSON.load(cache))
          return
        end
        req = invoke("retrievePlayerStatsByAccountId", "playerStatsService", [account, season.upcase])
        req.send
      end

      req.callback do |res|
        expire_object(@region, cache.nil? ? "playerstats" : "playerstats-#{season}", account, JSON.generate(res.message.values[1].body), 1800)
        ins.body JSON.pretty_generate(res.message.values[1].body)
      end

      req.errback do |res|
        expire_object(@region, cache.nil? ? "playerstats" : "playerstats-#{season}", account, JSON.generate([:error => "Error looking up account statistics."]), 30)
        ins.body JSON.pretty_generate([:error => "Error looking up account.", :reason => res.message.values[1].rootCause[:message]])
      end
    end

    def getLeaguesForPlayer(summoner, ins)
      cache = cacheExists(@region, "leagues", summoner)

      if !cache.nil?
        ins.body JSON.pretty_generate(JSON.load(cache))
        return
      end

      req = invoke("getAllLeaguesForPlayer", "leaguesServiceProxy", [summoner])
      req.send

      req.callback do |res|
        value = JSON.generate(res.message.values[1].body)
        expire_at(@region, "leagues", summoner, value, 1800)
        ins.body JSON.pretty_generate(res.message.values[1].body)
      end

      req.errback do |res|
        ins.body JSON.pretty_generate(res.message.values[1])
      end
    end

    #These should not be cached since they change more frequently than other calls.
    #If resources go up too high, I will cache them then.
    #
    def listAllPracticeGames(ins)
      req = invoke("listAllPracticeGames", "gameService", [])
      req.send

      req.callback do |res|
        ins.body JSON.pretty_generate(res.message.values[1].body)
      end

      req.errback do |res|
        ins.body JSON.pretty_generate([:error => "Error looking up account.", :reason => res.message.values[1].rootCause[:message]])
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
      msg.headers = {:DSId => @DSId, :DSEndpoint => 'my-rtmps'}
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
      msg = create_remote_message(operation, service, args, @connection.dsid)
      req.message.values = [msg]
      req.body = req.message.encode
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
        puts "Logged in complete\n"
        @ready = true
      end
    end

    def login(user, pass, token)
      ac = RocketAMF::Values::TypedHash.new('com.riotgames.platform.login.AuthenticationCredentials')
      ac[:ipAddress] = 'NA'
      ac[:locale] = 'en_US'
      ac[:clientVersion] = Config::CLIENT_VERSION
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
      req.errback do |wat|
        puts wat.message.values[1].inspect
      end
    end
  end
end
