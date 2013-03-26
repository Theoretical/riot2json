module Riot2JSON
  class HttpListener < Sinatra::Base
    register Sinatra::Async

    before do
      puts "[#{Time.now}]Request from: #{request.env['HTTP_X_REAL_IP']} for: #{request.path_info}\n"
      content_type "application/json"
    end

    aget '/lol/:region/name/:name' do |region, name|
      LolClient.instance.getSummonerByName(name, self)
    end

    aget '/lol/:region/ingame/:name' do |region, name|
      LolClient.instance.getGameInProgress(name, self)
    end

    aget '/lol/:region/recentgames/:account' do |region, acct|
      LolClient.instance.getRecentGames(acct, self)
    end

    aget '/lol/:region/stats/:account/?:season?' do |regioan, cct, season|
      LolClient.instance.getPlayerStats(acct, self, season)
    end

    aget '/lol/:region/leagues/:summoner' do |region, summoner|
      LolClient.instance.getLeaguesForPlayer(summoner, self)
    end

    aget '/lol/:region/practicegames' do
      LolClient.instance.listAllPracticeGames(self)
    end

    aget '/lol/:region/queue/available' do
      LolClient.instance.getAvailableQueues(self)
    end

    aget '/lol/:region/queue/info/:id' do |region, id|
      LolClient.instance.getQueueInfo(id, self)
    end

    aget '/lol/:region/status' do
      LolClient.instance.getStatus(self)
    end
  end
end
