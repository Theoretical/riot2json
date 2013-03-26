module Riot2JSON
  class LolConnectionRequest < EventMachine::RTMP::ConnectRequest
    def initialize(connection)
      super connection

      callback do |res|
        puts "Login Started."
        @connection.dsid = res.message.values[1][:id]
        @connection.change_state :ready
      end
    end
  end
end
