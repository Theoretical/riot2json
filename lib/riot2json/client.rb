require 'time'
module Riot2JSON
  class LolClient
    class << self
      attr_accessor :instance
    end

    def start(user, pass, region, port, version)
      @heartbeat_sent = 0
      @ready = false
      @region = region
      @port = port
      @version = version
      LolClient.instance = self

#      Process.daemon()
      token = Auth.request_token(region, user, pass)
      @redis = Redis.new(:path => '/tmp/redis.sock')
      @sql = Mysql2::Client.new(:host => 'localhost', :user => 'root', :password => 'lol', :database => 'lol')
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

          EventMachine::PeriodicTimer.new(30) do
            @sql.query("SELECT * FROM tracker").each do |row|
              next if row['region'] != @region
              next if row['current_div'] == row['ending_div']
              name = row['name']

              addMatchHistory(name)
              updateBoost(name)
            end
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
        log = "/var/log/riot2json/crash-#{Time.now.to_i}.log"
        puts "An unexpected error has been reached, dumping formation to log: #{log}"
        puts "Restarting node now..."
        puts e.backtrace
        puts e.inspect
        f = open(log, "w")
        f.write(e.backtrace)
        f.write("\n#{e.inspect}")
        f.close

        start(user, pass, region, port)
      end
    end

    def setDSId(dsid)
      @dsid = dsid
    end

    def getStatus(ins)
      ins.body create_json_success([:region => @region, :port => @port, :online => "true"])
    end

    def updateBoost(name)
      sendinvoke('getSummonerByName', 'summonerService', [name]).callback do |summonerRes|
        summoner = summonerRes.message.values[1].body
        sendinvoke("getAllLeaguesForPlayer", "leaguesServiceProxy", [summoner[:summonerId]]).callback do |leaguesRes|
          leaguesRes.message.values[1].body[:summonerLeagues].each do |leagues|
            next if leagues[:queue] != "RANKED_SOLO_5x5"
            tier = getTier(leagues[:tier], leagues[:requestorsRank])
            @sql.query("update tracker set current_div=#{tier}, updated_at=NOW() where summonerid=#{summoner[:summonerId].to_i}")
          end
        end
      end
    end

    def addMatchHistory(name)
      sendinvoke('getSummonerByName', 'summonerService', [name]).callback do |summonerRes|
        summoner = summonerRes.message.values[1].body
        #part 2 match history
        sendinvoke('getRecentGames', 'playerStatsService', [summoner[:acctId]]).callback do |recentRes|
          if recentRes.message.values[1].nil?
            puts recentRes.message.values.inspect
            return
          end
          games = recentRes.message.values[1].body[:gameStatistics]

          games.each do |game|
            next if game[:ranked] == false
            next if game[:queueType] != "RANKED_SOLO_5x5"

            #easier formatting ^_^
            champId = game[:championId]
            champ = game[:skinName]
            gameId = game[:gameId].to_i
            spell1 = game[:spell1]
            spell2 = game[:spell2]
            ping = game[:userServerPing]
            completed = game[:afk] or game[:leaver]
            duoqueue = game[:premadeSize] != 0
            date = game[:createDate]

            exists = 0
            @sql.query("select count(id) as count from matches where game_id=#{gameId} and summonerId=#{summoner[:summonerId]}").each do |row|
              exists = row['count']
            end

            #skip it if it exists
            next if exists > 0

            # zzz
            win = 0
            multikill = 0
            spree = 0
            cs = 0
            kills = 0
            deaths = 0
            assists = 0
            gold = 0
            item0 = 0
            item1 = 0
            item2 = 0
            item3 = 0
            item4 = 0
            item5 = 0
            game[:statistics].each do |stat|
              case stat[:statType].downcase
              when "champions_killed"
                kills = stat[:value].to_i
              when "num_deaths"
                deaths = stat[:value].to_i
              when "item0"
                item0 = stat[:value].to_i
              when "item1"
                item1 = stat[:value].to_i
              when "item2"
                item2 = stat[:value].to_i
              when "item3"
                item3 = stat[:value].to_i
              when "item4"
                item4 = stat[:value].to_i
              when "item5"
                item5 = stat[:value].to_i
              when "largest_multi_kill"
                multikill = stat[:value].to_i
              when "largest_killing_spree"
                spree = stat[:value].to_i
              when "assists"
                assists = stat[:value].to_i
              when "win"
                win = stat[:value].to_i
              when "gold_earned"
                gold = stat[:value].to_i
              when "neutral_minions_killed"
                cs += stat[:value].to_i
              when "neutral_minions_killed_enemy_jungle"
                cs += stat[:value].to_i
              when "neutral_minions_killed_your_jungle"
                cs += stat[:value].to_i
              when "minions_killed"
                cs += stat[:value].to_i
              end
            end

            @sql.query("insert into matches(game_id, summonerid, champion, skin, win, completed, multikill, spree, date_played, ping, cs,kills, deaths, assists, gold, spell1, spell2, duoqueue, item0, item1, item2, item3, item4, item5, created_at, updated_at) values (#{gameId}, #{summoner[:summonerId].to_i}, #{champId}, '#{champ}', #{win}, #{completed}, #{multikill}, #{spree}, STR_TO_DATE('#{date.strftime("%Y/%m/%d %H")}', '%Y/%m/%d %T'), #{ping}, #{cs}, #{kills}, #{deaths}, #{assists}, #{gold}, #{spell1}, #{spell2}, #{duoqueue}, #{item0}, #{item1}, #{item2}, #{item3}, #{item4}, #{item5}, NOW(), NOW())")
          end
        end
      end
    end
    #tracker functions, handles /everything/
    def addTracker(name, booster, startingdiv, endingdiv, ins)
      res = @sql.query("SELECT COUNT(id) as count from boosters WHERE name='#{@sql.escape(booster)}'")
      count = 0
      res.each do |row|
        count = row['count']
      end

      if count < 1
        ins.body create_json_error("Invalid booster")
        return
      end

      #booster exists, check if client already has a bosst
      count = false
      @sql.query("SELECT * from tracker where name='#{@sql.escape(name)}'").each do |row|
        count = true
      end

      if count == true
        ins.body create_json_error("Account is already being boosted!")
        return
      end

      booster_id = 0
      @sql.query("SELECT id FROM boosters WHERE name='#{@sql.escape(booster)}'").each do |row|
        booster_id = row['id']
      end

      #now comes the fun nested parts.
      #part 1 - summoner info
      sendinvoke('getSummonerByName', 'summonerService', [name]).callback do |summonerRes|
        summoner = summonerRes.message.values[1].body
        #part 2 match history
        sendinvoke('getRecentGames', 'playerStatsService', [summoner[:acctId]]).callback do |recentRes|
          games = recentRes.message.values[1].body[:gameStatistics]
          @sql.query("INSERT INTO tracker(booster_id, region, summonerId, name, starting_div, current_div, ending_div, created_at, updated_at) VALUES (#{booster_id}, '#{@region}', #{summoner[:summonerId]}, '#{@sql.escape(name)}', #{startingdiv}, #{startingdiv}, #{endingdiv}, NOW(), NOW())")

          games.each do |game|
            next if game[:ranked] == false
            next if game[:queueType] != "RANKED_SOLO_5x5"

            #easier formatting ^_^
            champId = game[:championId]
            champ = game[:skinName]
            gameId = game[:gameId].to_i
            spell1 = game[:spell1]
            spell2 = game[:spell2]
            ping = game[:userServerPing]
            completed = game[:afk] or game[:leaver]
            duoqueue = game[:premadeSize] != 0
            date = game[:createDate]

            exists = 0
            @sql.query("select count(id) as count from matches where game_id=#{gameId}").each do |row|
              exists = row[:count]
            end

            #skip it if it exists
            next if exists == 1

            # zzz
            win = 0
            multikill = 0
            spree = 0
            cs = 0
            kills = 0
            deaths = 0
            assists = 0
            gold = 0
            item0 = 0
            item1 = 0
            item2 = 0
            item3 = 0
            item4 = 0
            item5 = 0
            game[:statistics].each do |stat|
              case stat[:statType].downcase
              when "champions_killed"
                kills = stat[:value].to_i
              when "num_deaths"
                deaths = stat[:value].to_i
              when "item0"
                item0 = stat[:value].to_i
              when "item1"
                item1 = stat[:value].to_i
              when "item2"
                item2 = stat[:value].to_i
              when "item3"
                item3 = stat[:value].to_i
              when "item4"
                item4 = stat[:value].to_i
              when "item5"
                item5 = stat[:value].to_i
              when "largest_multi_kill"
                multikill = stat[:value].to_i
              when "largest_killing_spree"
                spree = stat[:value].to_i
              when "assists"
                assists = stat[:value].to_i
              when "win"
                win = stat[:value].to_i
              when "gold_earned"
                gold = stat[:value].to_i
              when "neutral_minions_killed"
                cs += stat[:value].to_i
              when "neutral_minions_killed_enemy_jungle"
                cs += stat[:value].to_i
              when "neutral_minions_killed_your_jungle"
                cs += stat[:value].to_i
              when "minions_killed"
                cs += stat[:value].to_i
              end
            end

            @sql.query("insert into matches(game_id, summonerid, champion, skin, win, completed, multikill, spree, date_played, ping, cs,kills, deaths, assists, gold, spell1, spell2, duoqueue, item0, item1, item2, item3, item4, item5, created_at, updated_at) values (#{gameId}, #{summoner[:summonerId].to_i}, #{champId}, '#{champ}', #{win}, #{completed}, #{multikill}, #{spree}, STR_TO_DATE('#{date.strftime("%Y/%m/%d %H")}', '%Y/%m/%d %T'), #{ping}, #{cs}, #{kills}, #{deaths}, #{assists}, #{gold}, #{spell1}, #{spell2}, #{duoqueue}, #{item0}, #{item1}, #{item2}, #{item3}, #{item4}, #{item5}, NOW(), NOW())")
          end
          ins.body create_json_success("Added #{name}")
        end
      end
    end

    #helper function
    def getTier(tier, div)
      tiers = {'bronze' => 0, 'silver' => 10, 'gold' => 20, 'platinum' => 30, 'diamond ' => 40}
      divisions = {'I' => 5, 'II' => 4, 'III' => 3, 'IV' => 2, 'V' => 1}
      return tiers[tier.downcase] + divisions[div.upcase]
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

    #These should not be cached since they change more frequently than other calls.
    #If resources go up too high, I will cache them then.
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
        puts "Logged in complete\n"
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
