module Riot2JSON
  class HttpListener < Sinatra::Base
    register Sinatra::Async

    before do
      puts "[#{Time.now}]Request from: #{request.env['HTTP_X_REAL_IP']} for: #{request.path_info}\n"
      content_type "application/json"
    end

    aget '/lol/name/:name' do |name|
      LolClient.instance.getSummonerByName(name, self)
    end

    aget '/lol/ingame/:name' do |name|
      LolClient.instance.getGameInProgress(name, self)
    end

    aget '/lol/recentgames/:account' do |acct|
      LolClient.instance.getRecentGames(acct, self)
    end

    aget '/lol/stats/:account/?:season?' do |acct, season|
      LolClient.instance.getPlayerStats(acct, self, season)
    end

    aget '/lol/leagues/:summoner' do |summoner|
      LolClient.instance.getLeaguesForPlayer(summoner, self)
    end

    aget '/lol/practicegames' do
      LolClient.instance.listAllPracticeGames(self)
    end

    aget '/lol/queue/available' do
      LolClient.instance.getAvailableQueues(self)
    end

    aget '/lol/queue/info/:id' do |id|
      LolClient.instance.getQueueInfo(id, self)
    end

  end
end
