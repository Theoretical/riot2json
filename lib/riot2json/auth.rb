module Riot2JSON
  module Auth
    def self.send_request(url, path, post, get=false)
      headers = {
        'Referer' => 'app:/LolClient.swf/[[DYNAMIC]]/6',
        'Accept' => 'text/xml, application/xml, application/xhtml+xml, text/html;q=0.9, text/plain;q=0.8, text/css, image/png, image/jpeg, image/gif;q=0.8, application/x-shockwave-flash, video/mp4;q=0.9, flv-application/octet-stream;q=0.8, video/x-flv;q=0.7, audio/mp4, application/futuresplash, */*;q=0.5',
        'x-flash-version' => '11,1,102,58',
        'User-Agent' => 'Mozilla/5.0 (Windows; U; en-US) AppleWebKit/533.19.4 (KHTML, like Gecko) AdobeAIR/3.1',
      }


      http = Net::HTTP.start(url, 443, :use_ssl => true)
      if !get
        req = Net::HTTP::Post.new(path, headers)
        req.set_form_data(post)
        JSON.parse(http.request(req).body)
      else
        req = Net::HTTP::Get.new(path, headers)
        JSON.parse(http.request(req).body)
      end
    end

    def self.request_token(region, user, password)
      post_data = {'payload' => "user=%s,password=%s" % [user, password].map {|x| URI.escape(x)}}
      resp = send_request(Config::QUEUE_SERVER % (region), Config::QUEUE_PATH, post_data)

      token = resp["token"]

      if resp["reason"] == "OpeningSite"
        puts "Server is currently busy, please hold!"
        sleep(resp["delay"] / 1000)
        request_token(region, user, password)
        return
      end
      return resp["reason"].to_sym if resp["reason"] != "login_rate"
      return token if token

      puts "Currently ing login queue, please hold!"

      node = resp["node"]
      champ = resp["champ"]
      rate = resp["rate"]
      delay = resp["delay"]

      id = -1
      cur = -1

      resp["tickers"].each do |tick|
        if tick["node"] == node
          id = tick["id"]
          cur = tick["current"]
        end
      end

      while id - cur > rate
        puts "Currently in positon: #{id - cur} |  delay: #{delay}"
        sleep(delay/1000)

        resp = send_request(Config::QUEUE_SERVER % (region), "/login-queue/rest/queue/ticker/#{champ}", "", true)
        cur = resp[node.to_s].to_i(16)
      end

      return resp["token"] if resp["token"]
      sleep(delay/10) if  id - cur < 0

      begin
        resp = send_request(Config::QUEUE_SERVER % (region), "/login-queue/rest/queue/authToken/#{user.downcase}", "", true)
      rescue => e
        return request_token(region, user, password)
      end
      return resp["token"]
    end
  end
end
